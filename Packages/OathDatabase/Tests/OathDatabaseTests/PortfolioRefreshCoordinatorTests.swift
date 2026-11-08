import Foundation
import XCTest
import GRDB
import OathAnkr
@testable import OathDatabase

@MainActor final class PortfolioRefreshCoordinatorTests: XCTestCase {
    enum Failure: Error { case provider, observer }
    actor Delays {
        var values: [Duration] = []
        func pause(_ value: Duration) { values.append(value) }
    }
    func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Production coordinator did not publish its result")
    }

    func testStoppedObserverAndProviderFailureStillPublishCommittedBalances() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)],
            assets: [.init(id: "ethereum:native", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "wallet", networkID: "ethereum", address: "0x1111111111111111111111111111111111111111", derivationPath: "")])
        let coordinator = PortfolioRefreshCoordinator<WalletSnapshot>(pause: { _ in })
        var shown = try await db.snapshot(walletID: "wallet", currency: "USD")
        coordinator.observe(stream: { AsyncThrowingStream { $0.finish(throwing: Failure.observer) } },
            isCurrent: { true }, publish: { shown = $0 }, exhausted: {})
        try await waitFor { !coordinator.isObserving }
        do {
            try await coordinator.perform(work: {
                do {
                    try await db.pool.write { database in
                        try BalanceRecord(accountID: "account", assetID: "ethereum:native", networkID: "ethereum", amountAtomic: "2000000000000000000", observedAt: 20, source: "fixture").upsert(database)
                        try PriceRecord(assetID: "ethereum:native", currency: "USD", value: "3", observedAt: 20, source: "fixture").upsert(database)
                    }
                    return [.complete, .failed(Failure.provider)]
                } catch { return [.failed(error)] }
            }, read: { try await db.snapshot(walletID: "wallet", currency: "USD") }, isCurrent: { true }, publish: { shown = $0 })
            XCTFail("Keep the failed provider outcome")
        } catch Failure.provider {}
        XCTAssertEqual(shown.holdings.first?.amountAtomic, "2000000000000000000")
        XCTAssertEqual(shown.totalFiat, 6)
        // Reattach to the SAME open database, then independently change units.
        coordinator.observe(stream: { db.observeWallet(walletID: "wallet", currency: "USD") },
            isCurrent: { true }, publish: { shown = $0 }, exhausted: { XCTFail("Healthy stream stopped") })
        try await db.pool.write { database in
            try BalanceRecord(accountID: "account", assetID: "ethereum:native", networkID: "ethereum", amountAtomic: "4000000000000000000", observedAt: 30, source: "fixture").upsert(database)
        }
        try await waitFor { shown.totalFiat == 12 }
        coordinator.stop()
    }

    func testErrorsAndUnexpectedCompletionHaveExactlyThreeBoundedRetries() async throws {
        for throwsError in [false, true] {
            let delays = Delays(), coordinator = PortfolioRefreshCoordinator<Int>(pause: { await delays.pause($0) })
            var exhausted = 0
            coordinator.observe(stream: {
                AsyncThrowingStream { c in
                    c.yield(1)
                    if throwsError { c.finish(throwing: Failure.observer) } else { c.finish() }
                }
            }, isCurrent: { true }, publish: { XCTAssertEqual($0, 1) }, exhausted: { exhausted += 1 })
            try await waitFor { !coordinator.isObserving }
            let pauses = await delays.values
            XCTAssertEqual(pauses, [.seconds(1), .seconds(2), .seconds(4)])
            XCTAssertEqual(exhausted, 1)
            coordinator.observe(stream: { AsyncThrowingStream { $0.yield(2) } }, isCurrent: { true },
                publish: { XCTAssertEqual($0, 2) }, exhausted: { XCTFail() })
            XCTAssertTrue(coordinator.isObserving)
            coordinator.stop()
        }
    }

    func testObsoleteWalletNeverReadsOrPublishesAndStopDoesNotRetry() async throws {
        let coordinator = PortfolioRefreshCoordinator<Int>()
        var current = true, read = false, published = false
        do {
            try await coordinator.perform(work: { current = false; return [.complete] },
                read: { 2 }, isCurrent: { current }, publish: { _ in published = true })
            XCTFail()
        } catch is CancellationError {}
        XCTAssertFalse(published)
        coordinator.observe(stream: { AsyncThrowingStream { $0.yield(3) } }, isCurrent: { current },
                            publish: { _ in read = true }, exhausted: { XCTFail() })
        coordinator.stop()
        await Task.yield()
        XCTAssertFalse(read)
    }
}

private actor ObservationAttempts {
    var count = 0
    func next() -> Int { count += 1; return count }
}
extension PortfolioRefreshCoordinatorTests {
    func testTransientObservationFailureRecoversAutomatically() async throws {
        let attempts = ObservationAttempts(), delays = Delays()
        let coordinator = PortfolioRefreshCoordinator<Int>(pause: { await delays.pause($0) })
        var shown = 0
        coordinator.observe(stream: {
            AsyncThrowingStream { continuation in
                Task {
                    if await attempts.next() == 1 { continuation.finish(throwing: Failure.observer) }
                    else { continuation.yield(7) }
                }
            }
        }, isCurrent: { true }, publish: { shown = $0 }, exhausted: { XCTFail("A transient error must recover") })
        try await waitFor { shown == 7 }
        let waits = await delays.values, count = await attempts.count
        XCTAssertEqual(waits, [.seconds(1)])
        XCTAssertEqual(count, 2)
        coordinator.stop()
    }
    func testCancelledProviderOutcomeNeverPublishes() async throws {
        let coordinator = PortfolioRefreshCoordinator<Int>()
        var published = false
        do {
            try await coordinator.perform(work: { [.complete, .cancelled] }, read: { 7 }, isCurrent: { true }, publish: { _ in published = true })
            XCTFail("Cancelled work must stop before reconciliation")
        } catch is CancellationError {}
        XCTAssertFalse(published)
    }
}
