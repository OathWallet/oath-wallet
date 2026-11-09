import Foundation
import OathDiagnostics

/// Bounded shared work owned by its consumers, rather than by a disappearing
/// row. Cancelling one waiter preserves other owners; cancelling the last one
/// removes queued work and cancels an active transport. Cancellation/eviction
/// is expected view teardown, not a diagnostic failure or a failed-image cache.
actor ArtworkWorkPool<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        let operation: @Sendable () async -> Value?
        var waiters: [UUID: CheckedContinuation<Value?, Never>]
        var task: Task<Void, Never>?
    }
    private let concurrency: Int
    private let queueLimit: Int
    private var entries: [Key: Entry] = [:]
    private var queued: [Key] = []
    private var active: Set<UUID> = []

    init(concurrency: Int, queueLimit: Int = 512) {
        self.concurrency = max(1, concurrency)
        self.queueLimit = max(1, queueLimit)
    }

    func value(for key: Key, operation: @escaping @Sendable () async -> Value?) async -> Value? {
        let owner = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if entries[key] != nil {
                    entries[key]?.waiters[owner] = continuation
                } else {
                    if queued.count >= queueLimit {
                        let obsolete = queued.removeFirst()
                        entries.removeValue(forKey: obsolete)?.waiters.values.forEach { $0.resume(returning: nil) }
                    }
                    // A queued producer may start from another producer's
                    // completion. Retain the requesting operation's diagnostic
                    // context instead of inheriting that other chain's context.
                    let chain = OathDiagnostics.chain, operationID = OathDiagnostics.operationID
                    entries[key] = Entry(id: UUID(), operation: {
                        await OathDiagnostics.$chain.withValue(chain) {
                            await OathDiagnostics.$operationID.withValue(operationID) { await operation() }
                        }
                    }, waiters: [owner: continuation])
                    queued.append(key)
                    startAvailable()
                }
            }
        } onCancel: {
            Task { await self.cancel(key, owner: owner) }
        }
    }

    // Internal occupancy permits deterministic cancellation/ownership tests.
    func consumerCount(for key: Key) -> Int { entries[key]?.waiters.count ?? 0 }
    var queuedCount: Int { queued.count }

    private func cancel(_ key: Key, owner: UUID) {
        guard var entry = entries[key], let waiter = entry.waiters.removeValue(forKey: owner) else { return }
        waiter.resume(returning: nil)
        if entry.waiters.isEmpty {
            entries[key] = nil
            queued.removeAll { $0 == key }
            entry.task?.cancel()
            // The slot remains occupied until the cancelled producer exits.
        } else { entries[key] = entry }
    }

    private func startAvailable() {
        while active.count < concurrency, !queued.isEmpty {
            let key = queued.removeFirst()
            guard let entry = entries[key] else { continue }
            active.insert(entry.id)
            entries[key]?.task = Task {
                let value = await entry.operation()
                self.complete(key, id: entry.id, value: Task.isCancelled ? nil : value)
            }
        }
    }

    private func complete(_ key: Key, id: UUID, value: Value?) {
        active.remove(id)
        if entries[key]?.id == id {
            entries.removeValue(forKey: key)?.waiters.values.forEach { $0.resume(returning: value) }
        }
        startAvailable()
    }
}
