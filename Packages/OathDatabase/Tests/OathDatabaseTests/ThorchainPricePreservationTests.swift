import Foundation
import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

extension ThorchainSendJournalTests {
    private var repairedPriceReferences: [String] {
        ["avax-avax", "doge-doge", "eth-usdt-0xdac17f958d2ee523a2206206994597c13d831ec7"]
    }
    private func verifyPriceOnlyUpdate(_ prices: [String: String]) async throws {
        let (db, folder, plan) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        var old = ThorchainCatalog(); old.observedAt = Date(timeIntervalSince1970: 100)
        for (ref, price) in zip(repairedPriceReferences, ["7.7338", "0.07889", "0.9444"]) {
            old.tokens[ref] = .fallback(ref); old.prices[ref] = price
        }
        let holdings = [ThorchainHolding(reference: "native", amount: plan.nativeBalance)] + repairedPriceReferences.map { ThorchainHolding(reference: $0, amount: "100000000") }
        try await db.commitThorchainInventory(.init(owner: plan.sender, holdings: holdings, height: 100), ticket: ticket, catalog: old)
        try await db.commitThorchainCatalog(old, ticket: ticket)
        try await draft("price-preservation", plan: plan, db: db)
        try await db.queueThorchainSend(sendID: "price-preservation", plan: plan)
        let signed = try ThorchainSendCrypto.sign(plan, privateKey: key)
        try await db.journalThorchainSignature(sendID: "price-preservation", signed: signed)
        let wallets = try await db.pool.read { try WalletRecord.fetchAll($0) }
        let accounts = try await db.pool.read { try AccountRecord.fetchAll($0) }
        let balances = try await db.pool.read { try BalanceRecord.fetchAll($0) }
        let transactions = try await db.pool.read { try TransactionRecord.fetchAll($0) }
        let activities = try await db.pool.read { try ActivityRecord.fetchAll($0) }
        let sends = try await db.pool.read { try SendRecord.fetchAll($0) }
        var corrected = old; corrected.observedAt = Date(timeIntervalSince1970: 200); corrected.prices = prices
        try await db.commitThorchainCatalog(corrected, ticket: ticket)
        for ref in repairedPriceReferences {
            let quote = try await db.latestPrice(assetID: "thorchain:" + ref, currency: "USD")
            XCTAssertEqual(quote?.value, prices[ref]); XCTAssertEqual(quote?.observedAt, 200)
        }
        // An all-provider outage may refresh metadata, but must not erase or
        // freshen the last valid quote; a late older catalog cannot regress it.
        var unavailable = corrected; unavailable.observedAt = Date(timeIntervalSince1970: 300); unavailable.prices = [:]
        try await db.commitThorchainCatalog(unavailable, ticket: ticket)
        try await db.commitThorchainCatalog(old, ticket: ticket)
        var invalid = corrected; invalid.observedAt = Date(timeIntervalSince1970: 400); invalid.prices["avax-avax"] = "-1"
        do { try await db.commitThorchainCatalog(invalid, ticket: ticket); XCTFail("Invalid quote must roll back") } catch {}
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        for ref in repairedPriceReferences {
            let quote = try await reopened.latestPrice(assetID: "thorchain:" + ref, currency: "USD")
            XCTAssertEqual(quote?.value, prices[ref]); XCTAssertEqual(quote?.observedAt, 200)
        }
        let afterWallets = try await reopened.pool.read { try WalletRecord.fetchAll($0) }
        let afterAccounts = try await reopened.pool.read { try AccountRecord.fetchAll($0) }
        let afterBalances = try await reopened.pool.read { try BalanceRecord.fetchAll($0) }
        let afterTransactions = try await reopened.pool.read { try TransactionRecord.fetchAll($0) }
        let afterActivities = try await reopened.pool.read { try ActivityRecord.fetchAll($0) }
        let afterSends = try await reopened.pool.read { try SendRecord.fetchAll($0) }
        XCTAssertEqual(wallets, afterWallets); XCTAssertEqual(accounts, afterAccounts)
        XCTAssertEqual(balances, afterBalances); XCTAssertEqual(transactions, afterTransactions)
        XCTAssertEqual(activities, afterActivities); XCTAssertEqual(sends, afterSends)
        let payload = try XCTUnwrap(afterSends.first?.signedPayload)
        XCTAssertEqual(try JSONDecoder().decode(ThorchainSignedSend.self, from: payload), signed)
    }
    func testCorrectedPriceAndProviderOutagePreserveEveryWalletRecordAfterReopen() async throws {
        try await verifyPriceOnlyUpdate(Dictionary(uniqueKeysWithValues: zip(repairedPriceReferences, ["8.2246", "0.07168", "0.9986"])))
    }
    func testLiveCorrectedCatalogPreservesWalletBalancesHistoryAndSignedPayload() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THOR_ASSET_PRICE_LIVE"] == "1" else { throw XCTSkip("Opt-in public markets and disposable database") }
        let live = try await ThorchainClient().catalog()
        var prices: [String: String] = [:]
        for ref in repairedPriceReferences { prices[ref] = try XCTUnwrap(live.prices[ref]) }
        try await verifyPriceOnlyUpdate(prices)
        print("Live AVAX, DOGE and USDT prices persisted; all wallet/account/balance/history/send records and signed bytes survived reopen, stale response and unavailable quotes")
    }
}
