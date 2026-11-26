import Foundation
import GRDB
import XCTest
@testable import OathDatabase

@MainActor final class WalletReadSchedulingTests: XCTestCase {
    func testSlowObservationDoesNotBlockCommitsAndDeliversLatestBurst() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await OathDatabase.open(at: directory.appendingPathComponent("fixture.sqlite"))
        try await store.setSetting("schedulingFixture", value: "0")
        let initial = expectation(description: "initial")
        let readerEntered = expectation(description: "reader")
        let latest = expectation(description: "latest committed value")
        let committed = expectation(description: "writer remains available")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let values = store.stream(observing: ["settings"]) { db in
            let value = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key='schedulingFixture'")!
            if value == "1" {
                readerEntered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return value
        }
        let observation = Task {
            for try await value in values {
                if value == "0" { initial.fulfill() }
                if value == "3" { latest.fulfill(); return }
            }
        }
        defer { observation.cancel() }
        await fulfillment(of: [initial], timeout: 3)
        try await store.setSetting("schedulingFixture", value: "1")
        await fulfillment(of: [readerEntered], timeout: 3)
        let writer = Task {
            try await store.setSetting("schedulingFixture", value: "2")
            try await store.setSetting("schedulingFixture", value: "3")
            committed.fulfill()
        }
        await fulfillment(of: [committed], timeout: 2)
        release.signal()
        try await writer.value
        await fulfillment(of: [latest], timeout: 3)
        try await observation.value
    }

    func testInitiallyEmptyWalletObservationIncludesNewAccountAndToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await OathDatabase.open(at: directory.appendingPathComponent("fixture.sqlite"))
        try await store.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [])
        var iterator = store.observeHomeWallet(walletID: "wallet", currency: "USD").makeAsyncIterator()
        let empty = try await iterator.next()
        XCTAssertEqual(empty?.holdings.count, 0)
        try await store.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [
            .init(id: "eth", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18)
        ])
        try await store.pool.write { db in
            try AccountRecord(id: "account", walletID: "wallet", networkID: "ethereum", address: "0x0000000000000000000000000000000000000001", derivationPath: "m/44'/60'/0'/0/0").insert(db)
        }
        try await store.saveBalances([.init(accountID: "account", assetID: "eth", networkID: "ethereum", amountAtomic: "2000000000000000000", observedAt: 1, source: "fixture")])
        try await store.savePrices([.init(assetID: "eth", currency: "USD", value: "3", observedAt: 1, source: "fixture")])
        var result = try await iterator.next()
        while result?.totalFiat != 6 { result = try await iterator.next() }
        XCTAssertEqual(result?.holdings.first?.amountAtomic, "2000000000000000000")
        XCTAssertEqual(result?.totalFiat, 6)
        let totals = try await store.walletValuations(walletIDs: ["wallet"], currency: "USD")
        XCTAssertEqual(totals.first?.totalFiat, 6)
    }
}
