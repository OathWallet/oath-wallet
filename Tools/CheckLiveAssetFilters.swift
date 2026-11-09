import Foundation
import OathDatabase

@MainActor private final class FilterSaveGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

extension CheckHomePortfolio {
    @MainActor static func verifyLiveAssetFilters() async throws {
        enum FixtureError: Error { case write }

        // Gate a real production writer: rapid changes coalesce into its latest
        // pending selection, and Reset wins even while an older save is active.
        let gate = FilterSaveGate()
        var writes: [PortfolioFilter] = []
        var activeWrites = 0
        let editor = OathAssetFilterModel(selection: .init(), currency: "USD", locale: Locale(identifier: "en_US")) { value in
            activeWrites += 1
            precondition(activeWrites == 1, "Filter writes must never overlap")
            defer { activeWrites -= 1 }
            writes.append(value)
            if writes.count == 1 { await gate.wait() }
        }
        editor.set(\.hidesZeroBalances, to: true)
        try await waitUntil { gate.entered }
        editor.set(\.sort, to: .mostActive)
        editor.set(\.networkIDs, to: ["bitcoin"])
        editor.set(\.hidesUnverifiedTokens, to: false)
        editor.set(\.groupsTokensByChain, to: true)
        editor.setMinimum("5"); editor.setMaximum("10")
        editor.reset()
        precondition(editor.selection == PortfolioFilter() && editor.minimum.isEmpty && editor.maximum.isEmpty)
        gate.release()
        await editor.waitForPendingSave()
        precondition(writes.count == 2 && writes.last == PortfolioFilter() && !editor.saveFailed)
        editor.reset()
        await editor.waitForPendingSave()
        precondition(writes.count == 2, "A default Reset must not write again")

        // A write can commit before a later snapshot read fails. A newer Reset
        // must still save, even though it equals the last acknowledged value.
        let failureGate = FilterSaveGate()
        var ambiguousWrites: [PortfolioFilter] = []
        let ambiguous = OathAssetFilterModel(selection: .init(), currency: "USD") { value in
            ambiguousWrites.append(value)
            if ambiguousWrites.count == 1 { await failureGate.wait(); throw FixtureError.write }
        }
        ambiguous.set(\.hidesZeroBalances, to: true)
        try await waitUntil { failureGate.entered }
        ambiguous.reset()
        failureGate.release()
        await ambiguous.waitForPendingSave()
        precondition(ambiguousWrites.count == 2 && ambiguousWrites.last == PortfolioFilter() && !ambiguous.saveFailed)

        // Invalid text never clears the last valid range or blocks a toggle.
        var saved = PortfolioFilter()
        let range = OathAssetFilterModel(selection: .init(), currency: "USD", locale: Locale(identifier: "de_DE")) { saved = $0 }
        range.setMinimum("2,5"); range.setMaximum("10")
        await range.waitForPendingSave()
        precondition(saved.minimumValue == Decimal(string: "2.5") && saved.maximumValue == 10)
        range.setMinimum("20")
        precondition(range.hasInvalidRange)
        range.set(\.hidesZeroBalances, to: true)
        await range.waitForPendingSave()
        precondition(saved.hidesZeroBalances && saved.minimumValue == Decimal(string: "2.5"))
        range.acceptCommitted(saved)
        precondition(range.minimum == "20", "Snapshot updates must not erase incomplete typing")
        range.setMaximum("30")
        await range.waitForPendingSave()
        precondition(!range.hasInvalidRange && saved.minimumValue == 20 && saved.maximumValue == 30)
        range.setMinimum("oops")
        range.reset()
        await range.waitForPendingSave()
        precondition(saved == PortfolioFilter() && !range.hasInvalidRange && !range.canReset)
        range.setMinimum("1,5")
        await range.waitForPendingSave()
        range.updateCurrency("EUR")
        await range.waitForPendingSave()
        precondition(saved.minimumValue == nil && saved.rangeCurrency == nil && range.minimum.isEmpty)

        var attempts = 0
        let retry = OathAssetFilterModel(selection: .init(), currency: "USD") { _ in
            attempts += 1
            if attempts == 1 { throw FixtureError.write }
        }
        retry.set(\.sort, to: .nameAscending)
        await retry.waitForPendingSave()
        precondition(retry.saveFailed && attempts == 1)
        retry.retry()
        await retry.waitForPendingSave()
        precondition(!retry.saveFailed && attempts == 2)

        // The writer survives a sheet dropping its reference. A session
        // invalidation instead stops pending edits, even with a late callback.
        let closeGate = FilterSaveGate()
        var closedWrites: [PortfolioFilter] = []
        var closing: OathAssetFilterModel? = .init(selection: .init(), currency: "USD") { value in
            if closedWrites.isEmpty { await closeGate.wait() }
            closedWrites.append(value)
        }
        closing?.set(\.sort, to: .highestValue)
        try await waitUntil { closeGate.entered }
        closing?.set(\.groupsTokensByChain, to: true)
        closing = nil
        closeGate.release()
        try await waitUntil { closedWrites.count == 2 }
        precondition(closedWrites.last?.sort == .highestValue && closedWrites.last?.groupsTokensByChain == true)

        let cancelGate = FilterSaveGate()
        var cancelledWrites = 0
        let cancelled = OathAssetFilterModel(selection: .init(), currency: "USD") { _ in
            cancelledWrites += 1
            await cancelGate.wait()
        }
        cancelled.set(\.hidesZeroBalances, to: true)
        try await waitUntil { cancelGate.entered }
        cancelled.set(\.networkIDs, to: ["bitcoin"])
        cancelled.cancel()
        cancelGate.release()
        cancelled.reset(); cancelled.retry()
        await Task.yield()
        precondition(cancelledWrites == 1 && !cancelled.saveFailed && !cancelled.isSaving)
        print("PASS: production live filter writer serializes edits/Reset, survives dismissal, excludes invalid ranges, retries failed saves, and stops obsolete session work")
    }
}
