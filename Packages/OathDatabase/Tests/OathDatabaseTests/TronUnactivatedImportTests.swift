import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

extension TronLedgerTests {
    /// Read-only, opt-in public address check. The isolated database contains no
    /// secret material and is removed after checking Home and its offline cache.
    func testLiveUnactivatedFreshImportReachesHomeAndOfflineCache() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["OATH_TRON_INACTIVE_PUBLIC_ADDRESS"],
              let configPath = env["OATH_TRON_READ_CONFIG"],
              let expected = env["OATH_TRON_INACTIVE_EXPECTED_ATOMIC"] else {
            throw XCTSkip("Opt-in public unactivated import check")
        }
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: configPath)), format: nil) as? [String: String]
        let key = try XCTUnwrap(config?["AnkrAPIKey"])
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='a1'", arguments: [address]) }
        let tracked = try await db.trackedAssets(walletID: "w1")
        let previous = try await db.tronInventory(accountID: "a1")
        XCTAssertTrue(tracked.isEmpty)
        XCTAssertNil(previous)

        var request = URLRequest(url: TronSendNetwork.mainnet.endpoint.appendingPathComponent("wallet/getaccount"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TronJSON.object(["address": .string(address), "visible": .bool(true)]))
        let (bytes, status) = try await AnkrHTTPTransport().send(request)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try JSONDecoder().decode(TronJSON.self, from: bytes), .object([:]))

        let independent = try TronSendClient(network: .mainnet, apiKey: key)
        let amount = try await independent.balance(owner: address, reference: usdt)
        XCTAssertEqual(amount, expected)

        let sync = try TronSynchronizer(database: db, apiKey: key)
        do { try await sync.refresh(accountID: "a1") }
        catch { await sync.cancel(); throw error }
        await sync.cancel()
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == "native" }?.amountAtomic, "0")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == usdt }?.amountAtomic, amount)
        XCTAssertNotNil(snapshot.holdings.first { $0.reference == usdt }?.usdPrice)
        let otherWallet = try await db.snapshot(walletID: "w2", currency: "USD")
        XCTAssertFalse(otherWallet.holdings.contains { $0.reference == usdt })
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let cached = try await reopened.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(cached.holdings, snapshot.holdings)
        print("TRON unactivated fresh import: independent contract balance, production refresh, Home snapshot, quote and offline reopen verified")
    }
}
