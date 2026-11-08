import Foundation
import GRDB
import OathDiagnostics

/// A failed write is never success and never a zero balance. The original
/// SQLITE_FULL is recorded once at the writer boundary. Propagation and queued
/// work respecting that same storage incident are not additional failures.
public struct DatabaseStorageDeferred: Error, Sendable, DiagnosticControlFlowError, LocalizedError {
    init() {}
    public var isExpectedDiagnosticControlFlow: Bool { true }
    public var errorDescription: String? {
        "Storage is full. Free some space on your device, then try again."
    }
}

/// Like the SQLite connection, mutable state is confined to the pool's writer
/// queue. No timer, task, wallet data, or unbounded queue is retained here.
final class DatabaseStorageRecovery: @unchecked Sendable {
    var retryAfter: ContinuousClock.Instant?
    var incidentReported = false
    var now: @Sendable () -> ContinuousClock.Instant = { .now }

    func check() throws {
        if let retryAfter, now() < retryAfter { throw DatabaseStorageDeferred() }
    }
}

extension OathDatabase {
    /// Stop refresh fan-out during an already-observed full-storage cooldown.
    /// Reads remain available; a later refresh may retry without reopening.
    public func checkStorageForRefresh() async throws {
        try await pool.writeWithoutTransaction { [storageRecovery] _ in
            try storageRecovery.check()
        }
    }

    /// Same serialized, atomic transaction semantics as GRDB.write, with a
    /// shared cooldown across every chain. Never replay a failed transaction:
    /// callers must re-read their state/tickets before submitting fresh work.
    func storageWrite<T: Sendable>(
        _ updates: @Sendable (Database) throws -> T,
        file: String = #fileID, function: String = #function, line: UInt = #line
    ) async throws -> T {
        let chain = OathDiagnostics.chain
        let operationID = OathDiagnostics.operationID ?? UUID()
        return try await pool.writeWithoutTransaction { [storageRecovery] db in
            try storageRecovery.check()
            do {
                var result: T?
                try db.inTransaction {
                    result = try updates(db)
                    return .commit
                }
                storageRecovery.retryAfter = nil
                storageRecovery.incidentReported = false
                return result!
            } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
                // inTransaction has unwound before reporting. Pending failure-
                // status writes also pass this guard and cannot create a storm.
                storageRecovery.retryAfter = storageRecovery.now().advanced(by: .seconds(5))
                if !storageRecovery.incidentReported {
                    storageRecovery.incidentReported = true
                    OathDiagnostics.$chain.withValue(chain) {
                        OathDiagnostics.$operationID.withValue(operationID) {
                            OathDiagnostics.record(error, component: "storage", operation: "database_full",
                                context: ["stage": "transaction"], file: file, function: function, line: line)
                        }
                    }
                }
                throw DatabaseStorageDeferred()
            }
        }
    }
}
