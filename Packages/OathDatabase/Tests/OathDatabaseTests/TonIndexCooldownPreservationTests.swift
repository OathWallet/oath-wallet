import XCTest
import Foundation
import GRDB
import OathDiagnostics
@testable import OathAnkr
@testable import OathDatabase

private actor TonIndexCooldownFeed: AnkrTransport {
    private(set) var indexCalls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" {
            return (Data(#"{"data":{"base":"TON","currency":"USD","amount":"2"}}"#.utf8), 200)
        }
        if request.url?.host == "tonapi.io" { indexCalls += 1; return (Data(), 429) }
        let call = try JSONDecoder().decode(TonJSON.self, from: XCTUnwrap(request.httpBody))
        let result: TonJSON
        switch call["method"].string {
        case "getMasterchainInfo": result = .object(["init": .object(["root_hash": .string(TonIdentity.genesis)])])
        case "getAddressInformation": result = .object(["state": .string("active"), "balance": .string("42")])
        default: throw TonError.malformed
        }
        return (try JSONEncoder().encode(TonJSON.object(["jsonrpc": .string("2.0"), "id": .string("1"), "result": result])), 200)
    }
}
extension TonLedgerTests {
    func testIndexCooldownPreservesTokensHistoryAndCursorAcrossRepeatedRefreshesAndReopen() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginTonSync(accountID: "a1")
        try await db.commitTonInventory(inventory(), ticket: ticket)
        for cursor in try await db.tonHistoryWork(ticket) {
            try await db.commitTonPage(page([tx(lt: 100, native: cursor.stream == "native")], next: 100), cursor: cursor, ticket: ticket)
        }
        let wallets = try await db.pool.read { try WalletRecord.fetchAll($0) }
        let accounts = try await db.pool.read { try AccountRecord.fetchAll($0) }
        let tokens = try await db.pool.read { try BalanceRecord.fetchAll($0, sql: "SELECT * FROM balances WHERE assetID <> 'ton:native' ORDER BY assetID") }
        let transactions = try await db.pool.read { try TransactionRecord.fetchAll($0) }
        let activities = try await db.pool.read { try ActivityRecord.fetchAll($0) }
        let feed = TonIndexCooldownFeed()
        let sync = TonSynchronizer(database: db, client: TonClient(testTransport: feed), markets: TonMarkets(transport: feed))
        for _ in 0..<3 {
            do { try await sync.refresh(accountID: "a1"); XCTFail("Unavailable discovery cannot become complete") }
            catch {
                let cause = (error as? ReportedDiagnosticFailure)?.underlying ?? error
                XCTAssertTrue(cause as? TonError == .http(429) || cause as? TonError == .indexCooldown)
            }
            await sync.waitForHistory(accountID: "a1")
        }
        await sync.cancel()
        let calls = await feed.indexCalls
        XCTAssertEqual(calls, 1, "One rejection must defer discovery and both history streams")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let afterWallets = try await reopened.pool.read { try WalletRecord.fetchAll($0) }
        let afterAccounts = try await reopened.pool.read { try AccountRecord.fetchAll($0) }
        let afterTokens = try await reopened.pool.read { try BalanceRecord.fetchAll($0, sql: "SELECT * FROM balances WHERE assetID <> 'ton:native' ORDER BY assetID") }
        let afterTransactions = try await reopened.pool.read { try TransactionRecord.fetchAll($0) }
        let afterActivities = try await reopened.pool.read { try ActivityRecord.fetchAll($0) }
        XCTAssertEqual(wallets, afterWallets); XCTAssertEqual(accounts, afterAccounts)
        XCTAssertEqual(tokens, afterTokens); XCTAssertEqual(transactions, afterTransactions)
        XCTAssertEqual(activities, afterActivities)
        let native = try await reopened.balance(accountID: "a1", assetID: "ton:native")
        XCTAssertEqual(native?.amountAtomic, "42", "Independent verified native balance must still update")
        let nextTicket = try await reopened.beginTonSync(accountID: "a1")
        let pending = try await reopened.tonHistoryWork(nextTicket)
        XCTAssertEqual(Set(pending.map(\.stream)), ["native", "jettons"])
        XCTAssertTrue(pending.allSatisfy { $0.lane == "recent" && $0.stopLT == 100 })
        let backfill = try await reopened.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tonHistoryCursors WHERE accountID='a1' AND lane='backfill' AND beforeLT=100 AND complete=0")
        }
        XCTAssertEqual(backfill, 2, "Failed refresh must retain resumable older history")
    }
}
