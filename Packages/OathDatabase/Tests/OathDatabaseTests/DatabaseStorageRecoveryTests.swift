import XCTest
import GRDB
import OathDiagnostics
@testable import OathDatabase

@MainActor final class DatabaseStorageRecoveryTests: XCTestCase {
    private func fixture(root: URL = FileManager.default.temporaryDirectory) async throws -> (OathDatabase, URL) {
        let url = root.appendingPathComponent("OathStorageFixture-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        let chains = ["ethereum", "polygon", "story"]
        try await db.seed(networks: chains.enumerated().map { i, chain in
            NetworkRecord(id: chain, name: chain, family: "evm", symbol: "TEST", decimals: 18, derivationPath: "fixture", logo: "fixture", sortOrder: i)
        }, assets: chains.map { AssetRecord(id: $0, networkID: $0, reference: "native", name: $0, symbol: "TEST", decimals: 18) })
        try await db.importWalletIfNeeded(WalletRecord(id: "wallet", name: "Synthetic", kind: "hd", vaultReference: "fixture-reference", createdAt: 1), accounts: chains.map {
            AccountRecord(id: $0, walletID: "wallet", networkID: $0, address: "fixture-public", derivationPath: "fixture")
        })
        try await db.saveBalances(chains.map { BalanceRecord(accountID: $0, assetID: $0, networkID: $0, amountAtomic: "123456789", observedAt: 1, source: "fixture") })
        try await db.setSetting("currency", value: "USD")
        try await db.saveDraft(SendRecord(id: "pending", walletID: "wallet", accountID: "ethereum", networkID: "ethereum", assetID: "ethereum", idempotencyKey: "fixture-send", recipient: "fixture-recipient", amountAtomic: "1", state: "draft", createdAt: 1, updatedAt: 1))
        _ = try await db.queueSend("pending", networkNonce: 7)
        _ = try await db.transitionSend("pending", from: "queued", to: "signed", signedPayload: Data("synthetic-signed-payload".utf8))
        for chain in chains {
            var batch = SyncBatch(cursor: SyncCursor(accountID: chain, stream: "history", cursor: "saved-cursor", updatedAt: 1), expectedCursor: nil)
            batch.transactions = [TransactionRecord(id: chain + "-transaction", networkID: chain, hash: chain + "-fixture-hash", state: "confirmed", timestamp: 1, updatedAt: 1)]
            batch.activity = [ActivityRecord(id: chain + "-activity", walletID: "wallet", accountID: chain, networkID: chain,
                transactionID: chain + "-transaction", assetID: chain, direction: "incoming", amountAtomic: "123", counterparty: "fixture", timestamp: 1)]
            try await db.apply(batch)
        }
        try await db.pool.write { sql in
            try sql.execute(sql: "CREATE TABLE storageFixture (id INTEGER PRIMARY KEY, payload BLOB)")
            try sql.execute(sql: "INSERT INTO storageFixture VALUES (1, X'01')")
        }
        return (db, url)
    }

    private func snapshot(_ db: OathDatabase) async throws -> [String: [String]] {
        try await db.pool.read { sql in
            var result: [String: [String]] = [:]
            for table in try String.fetchAll(sql, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") {
                let identifier = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                result[table] = try Row.fetchAll(sql, sql: "SELECT * FROM " + identifier).map {
                    $0.databaseValues.map { value in
                        // Compare exact bytes/types, including signed journals;
                        // debug descriptions may summarize BLOBs by length only.
                        switch value.storage {
                        case .null: return "N"
                        case .int64(let number): return "I" + String(number)
                        case .double(let number): return "D" + String(number.bitPattern)
                        case .string(let text): return "S" + Data(text.utf8).base64EncodedString()
                        case .blob(let data): return "B" + data.base64EncodedString()
                        }
                    }.joined(separator: "|")
                }.sorted()
            }
            return result
        }
    }

    private func cap(_ db: OathDatabase) async throws {
        try await db.pool.writeWithoutTransaction { sql in
            let count = try Int.fetchOne(sql, sql: "PRAGMA page_count")!
            _ = try Int.fetchOne(sql, sql: "PRAGMA max_page_count=\(count)")
        }
    }
    private func allowProbe(_ db: OathDatabase) async throws {
        try await db.pool.writeWithoutTransaction { [recovery = db.storageRecovery] _ in
            recovery.retryAfter = .now.advanced(by: .seconds(-1))
        }
    }
    private func failAtomicWrite(_ db: OathDatabase) async throws {
        try await db.storageWrite { sql in
            try sql.execute(sql: "UPDATE wallets SET name='must-roll-back' WHERE id='wallet'")
            try sql.execute(sql: "UPDATE balances SET amountAtomic='0'")
            try sql.execute(sql: "UPDATE sends SET state='failed' WHERE id='pending'")
            try sql.execute(sql: "UPDATE syncCursors SET cursor='must-roll-back'")
            try sql.execute(sql: "UPDATE activity SET amountAtomic='0'")
            try sql.execute(sql: "INSERT INTO storageFixture VALUES (2, zeroblob(8388608))")
        }
    }

    func testRealSQLiteFullRollsBackAllTablesAndRecoversWithoutReopen() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try await snapshot(db)
        try await cap(db)
        do { try await failAtomicWrite(db); XCTFail("Full database accepted growth") }
        catch { XCTAssertTrue(error is DatabaseStorageDeferred) }
        let after = try await snapshot(db)
        XCTAssertEqual(before, after, "Wallets, balances, pending send, cursors and every other table must survive")
        do { try await db.renameWallet("wallet", name: "blocked"); XCTFail("Cooldown admitted a write") }
        catch { XCTAssertTrue(error is DatabaseStorageDeferred) }
        do { try await db.checkStorageForRefresh(); XCTFail("Refresh should defer") }
        catch { XCTAssertTrue(error is DatabaseStorageDeferred) }
        try await db.pool.writeWithoutTransaction { sql in _ = try Int.fetchOne(sql, sql: "PRAGMA max_page_count=2147483646") }
        try await allowProbe(db)
        try await db.setSetting("recovered", value: "yes")
        try await db.checkStorageForRefresh()
        try await db.setSetting("recovered", value: nil)
        let snapshot1 = try await snapshot(db)
        XCTAssertEqual(snapshot1, before)
        try db.pool.close()
        let reopened = try await OathDatabase.open(at: url)
        let snapshot2 = try await snapshot(reopened)
        XCTAssertEqual(snapshot2, before)
        let integrity = try await reopened.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(integrity, "ok")
        for chain in ["ethereum", "polygon", "story"] {
            var batch = SyncBatch(cursor: SyncCursor(accountID: chain, stream: "history", cursor: "next-page", updatedAt: 2), expectedCursor: "saved-cursor")
            batch.balances = [BalanceRecord(accountID: chain, assetID: chain, networkID: chain, amountAtomic: "123456790", observedAt: 2, source: "fixture")]
            let applied = try await reopened.apply(batch)
            XCTAssertTrue(applied)
            let cursor = try await reopened.cursor(accountID: chain, stream: "history")
            XCTAssertEqual(cursor?.cursor, "next-page")
        }
        let signed = try await reopened.pool.read { try Data.fetchOne($0, sql: "SELECT signedPayload FROM sends WHERE id='pending'") }
        XCTAssertEqual(signed, Data("synthetic-signed-payload".utf8))
        let foreignKeyFailures = try await reopened.pool.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        XCTAssertEqual(foreignKeyFailures, 0)
    }

    func testConcurrentChainsReportOneOriginalFailureAndPreservePrivacy() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await DatabaseDiagnosticProbe.shared.configure()
        let operationID = UUID()
        try await cap(db)
        await OathDiagnostics.$operationID.withValue(operationID) {
            await withTaskGroup(of: Bool.self) { group in
                for index in 0..<64 {
                    group.addTask {
                        do { try await OathDiagnostics.withChain(index % 2 == 0 ? "ethereum" : "story") {
                            try await db.setSetting("fixture-private-value", value: String(repeating: "x", count: 1_000_000))
                        }; return false }
                        catch { OathDiagnostics.record(error, component: "sync", operation: "failure_status"); return error is DatabaseStorageDeferred }
                    }
                }
                for await deferred in group { XCTAssertTrue(deferred) }
            }
        }
        // A second actual probe on the still-full database is the same incident.
        try await allowProbe(db)
        do { try await OathDiagnostics.$operationID.withValue(operationID) { try await failAtomicWrite(db) }; XCTFail("Expected full") }
        catch { XCTAssertTrue(error is DatabaseStorageDeferred) }
        // record() formats/enqueues on a detached utility worker. flush() only
        // drains the outbox and is not an ingress barrier; await delivery here.
        var events: [DiagnosticEvent] = []
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            events = await DatabaseDiagnosticProbe.shared.events().filter { $0.operationID == operationID }
            if !events.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.code, 13)
        XCTAssertEqual(events.first?.operation, "database_full")
        XCTAssertTrue(["ethereum", "story"].contains(events.first?.context["chain"] ?? ""))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-private-value"))
        XCTAssertFalse(encoded.contains("INSERT INTO"))
    }

    func testNonStorageErrorsAndCancellationDoNotTripStorageGuard() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do { try await db.storageWrite { sql in try sql.execute(sql: "INSERT INTO storageFixture VALUES (1, X'02')") }; XCTFail("Expected constraint") }
        catch { XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT) }
        do { try await db.storageWrite { _ in throw CancellationError() }; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await db.setSetting("healthy", value: "yes")
        try await db.checkStorageForRefresh()
    }

    func testJournalRetentionLimitDoesNotLimitDatabaseGrowth() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let limit = try await db.pool.read { try Int.fetchOne($0, sql: "PRAGMA journal_size_limit") }
        XCTAssertEqual(limit, 4_194_304)
        try await db.storageWrite { sql in
            try sql.execute(sql: "INSERT INTO storageFixture VALUES (2, zeroblob(8388608))")
        }
        let bytes = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT length(payload) FROM storageFixture WHERE id=2") }
        XCTAssertEqual(bytes, 8_388_608)
    }

    /// Opt-in real filesystem exhaustion. The test runner supplies a dedicated
    /// small mounted image; never fill the host volume or a user's app container.
    func testRealFullVolumePreservesWalletAndRecoversAfterSpaceIsFreed() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_STORAGE_TEST_VOLUME"],
              path.hasPrefix("/Volumes/OathStorageTest-") else { throw XCTSkip("Requires an isolated disposable test volume") }
        let root = URL(fileURLWithPath: path)
        let (db, url) = try await fixture(root: root)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try await snapshot(db)
        let filler = root.appendingPathComponent("disposable-filler")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: filler) }
        let handle = try FileHandle(forWritingTo: filler)
        let chunk = Data(repeating: 0x5a, count: 65536)
        var filled = false
        do {
            for _ in 0..<4096 { try handle.write(contentsOf: chunk) }
        } catch { filled = true }
        try handle.close()
        XCTAssertTrue(filled, "Test volume must actually reject writes")
        do { try await failAtomicWrite(db); XCTFail("Expected actual disk full") }
        catch { XCTAssertTrue(error is DatabaseStorageDeferred, "Expected SQLITE_FULL translated at the database boundary") }
        let snapshot3 = try await snapshot(db)
        XCTAssertEqual(snapshot3, before)
        try FileManager.default.removeItem(at: filler)
        // Exercise the real production cooldown on the real full-volume path.
        try await Task.sleep(for: .milliseconds(5_100))
        try await db.setSetting("after-space-freed", value: "yes")
        try await db.setSetting("after-space-freed", value: nil)
        let snapshot4 = try await snapshot(db)
        XCTAssertEqual(snapshot4, before)
        try db.pool.close()
        let reopened = try await OathDatabase.open(at: url)
        let snapshot5 = try await snapshot(reopened)
        XCTAssertEqual(snapshot5, before)
        let integrity = try await reopened.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(integrity, "ok")
    }
}
