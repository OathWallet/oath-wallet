import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class XrplLedgerTests:XCTestCase {
    let owner = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
    let ref = "USD.rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
    var catalog:XrplCatalog { .init(ids:[ref:"fixture","native":"ripple"]) }
    func fixture(address:String? = nil) async throws -> (OathDatabase,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("XrplLedger-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"xrpl",name:"XRP Ledger",family:"account",symbol:"XRP",decimals:6,derivationPath:"m/44'/144'/0'/0/0",logo:"xrpl",sortOrder:0)],assets:[.init(id:"xrpl:native",networkID:"xrpl",reference:"native",name:"XRP",symbol:"XRP",decimals:6)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"fixture\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"xrpl",address:address ?? owner,derivationPath:"m/44'/144'/0'/0/0")]) }
        try await db.saveMarketCache(.init(key:"xrpl.catalog",source:"fixture verified catalog",payload:JSONEncoder().encode(catalog),fetchedAt:1))
        return (db,folder)
    }
    func inventory(time:Double = 100, amount:String = "1.234567890123456", includeToken:Bool = true) throws -> XrplInventory {
        let tokens:[XrplHolding] = includeToken ? [.init(reference:ref,token:try .issued(ref),amount:try XrplIdentity.issuedAmount(amount),raw:.null)]:[]
        return .init(owner:owner,ledger:.init(hash:String(repeating:"A",count:64),height:Int64(time),timestamp:time),exists:true,holdings:[.init(reference:"native",token:.native,amount:"12345678",raw:.null)]+tokens,observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    func tx(_ hash:String, height:Int64 = 100, reference:String? = nil, metadata:Bool = true) throws -> XrplTransaction {
        let r = reference ?? ref
        return .init(hash:hash,checkpoint:height,timestamp:100,failed:false,fee:"12",owner:owner,counterparty:nil,movements:[.init(reference:r,token:metadata ? try .issued(ref):nil,direction:"incoming",amount:try XrplIdentity.issuedAmount("0.1"))],raw:Data())
    }
    func page(_ hashes:[String], next:String? = nil, upper:Int64 = 100) throws -> XrplHistoryPage {
        .init(transactions:try hashes.map{try tx($0)},next:next,head:hashes.first,upperLedger:upper,raw:Data())
    }
    func testExactAmountsOfflineIsolationWhitelistAndLiability() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginXrplSync(accountID:"a1")
        try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"xrpl:"+ref,currency:"USD",value:"2",observedAt:100,source:"fixture")])
        let value = try await db.snapshot(walletID:"w1",currency:"USD")
        let holding = try XCTUnwrap(value.holdings.first{$0.reference == ref})
        XCTAssertEqual(holding.decimals,96); XCTAssertEqual(holding.amountAtomic,try XrplIdentity.issuedAmount("1.234567890123456"))
        XCTAssertNotNil(holding.nativeDisplayValue)
        let other = try await db.snapshot(walletID:"w2",currency:"USD"); XCTAssertNil(other.holdings.first?.amountAtomic)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let cached = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(value.holdings,cached.holdings)
        try await db.commitXrplInventory(inventory(time:200,amount:"-5"),ticket:ticket,catalog:catalog)
        let balance = try await db.balance(accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(balance?.amountAtomic,"0")
        let raw = try await db.xrplInventory(accountID:"a1"); XCTAssertEqual(raw?.holdings.last?.amount,try XrplIdentity.issuedAmount("-5"))
        try await db.commitXrplInventory(inventory(time:300),ticket:ticket,catalog:.empty)
        let hidden = try await db.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(hidden.holdings.count,2, "An unavailable catalog must retain previously verified assets")
    }
    func testFailureRetainsBalancesCompleteEmptySnapshotClearsAndStaleRejected() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginXrplSync(accountID:"a1")
        try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.failXrplSync(ticket,history:false,code:"transport")
        var balance = try await db.balance(accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(balance?.observedAt,100)
        try await db.commitXrplInventory(inventory(time:200,includeToken:false),ticket:ticket,catalog:catalog)
        balance = try await db.balance(accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(balance?.amountAtomic,"0")
        do { try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        _ = try await db.beginXrplSync(accountID:"a1")
        do { try await db.commitXrplInventory(inventory(time:300),ticket:ticket,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }
    func testPinnedCursorRestartDedupeAndSameLedgerHistory() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        var ticket = try await db.beginXrplSync(accountID:"a1")
        var cursor = try await db.xrplHistoryWork(ticket).first!
        try await db.commitXrplPage(page(["a","b"],next:"one"),cursor:cursor,ticket:ticket)
        cursor = try await db.xrplHistoryWork(ticket).first!; XCTAssertEqual(cursor.lane,"backfill"); XCTAssertEqual(cursor.upperLedger,100)
        ticket = try await db.beginXrplSync(accountID:"a1"); cursor = try await db.xrplHistoryWork(ticket).first!
        try await db.commitXrplPage(page(["new","a"],next:"recent",upper:200),cursor:cursor,ticket:ticket)
        cursor = try await db.xrplHistoryWork(ticket).first!; XCTAssertEqual(cursor.beforeCursor,"one"); XCTAssertEqual(cursor.upperLedger,100)
        try await db.restartXrplHistory(cursor,ticket:ticket)
        cursor = try await db.xrplHistoryWork(ticket).first!; XCTAssertEqual(cursor.upperLedger,100); XCTAssertNil(cursor.beforeCursor)
        try await db.commitXrplPage(page(["a","b","c"],upper:100),cursor:cursor,ticket:ticket)
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(history.count,4)
        let work = try await db.xrplHistoryWork(ticket); XCTAssertTrue(work.isEmpty)
    }
    func testWalletResetErasesXrplButKeepsPrices() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginXrplSync(accountID:"a1")
        try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"xrpl:native",currency:"USD",value:"1.4",observedAt:100,source:"fixture")])
        let reset = try await db.beginWalletReset(); try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let raw = try await db.xrplInventory(accountID:"a1"); XCTAssertNil(raw)
        do { try await db.commitXrplInventory(inventory(time:200),ticket:ticket,catalog:catalog); XCTFail() } catch {}
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM prices")!}; XCTAssertEqual(count,1)
    }
    func testRollingHistoryExpiryPreservesTransactionsAcrossReopenAndRejectsStaleWork() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginXrplSync(accountID:"a1")
        let recent = try await db.xrplHistoryWork(ticket).first!
        try await db.commitXrplPage(page(["saved"],next:"expired"),cursor:recent,ticket:ticket)
        let old = try await db.xrplHistoryWork(ticket).first!
        XCTAssertEqual(old.lane,"backfill")
        try await db.expireXrplHistoryWindow(old,ticket:ticket)
        do { try await db.expireXrplHistoryWindow(old,ticket:ticket); XCTFail("Stale cursor changed state") }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let work = try await reopened.xrplHistoryWork(ticket); XCTAssertTrue(work.isEmpty)
        let saved = try await reopened.assetHistory(walletID:"w1",accountID:"a1",assetID:"xrpl:"+ref)
        XCTAssertEqual(saved.count,1)
        let nextTicket = try await reopened.beginXrplSync(accountID:"a1")
        let next = try await reopened.xrplHistoryWork(nextTicket).first!
        XCTAssertEqual(next.lane,"recent"); XCTAssertNil(next.upperLedger); XCTAssertNil(next.beforeCursor)
        XCTAssertEqual(next.stopHash,"saved")
    }
    func testExpiredRecentLaneStartsFreshAndKeepsPreviouslySavedActivity() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        var ticket = try await db.beginXrplSync(accountID:"a1")
        var cursor = try await db.xrplHistoryWork(ticket).first!
        try await db.commitXrplPage(page(["saved"]),cursor:cursor,ticket:ticket)
        ticket = try await db.beginXrplSync(accountID:"a1")
        cursor = try await db.xrplHistoryWork(ticket).first!
        try await db.commitXrplPage(page(["fresh"],next:"aging",upper:200),cursor:cursor,ticket:ticket)
        cursor = try await db.xrplHistoryWork(ticket).first!
        XCTAssertEqual(cursor.lane,"recent"); XCTAssertFalse(cursor.complete)
        try await db.expireXrplHistoryWindow(cursor,ticket:ticket)
        let reset = try await db.xrplHistoryWork(ticket).first!
        XCTAssertNil(reset.beforeCursor); XCTAssertNil(reset.upperLedger); XCTAssertEqual(reset.stopHash,"fresh")
        try await db.commitXrplPage(page(["new"],upper:300),cursor:reset,ticket:ticket)
        let saved = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"xrpl:"+ref)
        XCTAssertEqual(saved.count,3)
        let work = try await db.xrplHistoryWork(ticket); XCTAssertTrue(work.isEmpty)
    }
    func testLiveProductionSyncAndOfflineRead() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_XRPL_DATABASE_KEY"] else { throw XCTSkip("Opt-in live XRP database test") }
        let address = "rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q"
        let (db,folder) = try await fixture(address:address); defer { try? FileManager.default.removeItem(at:folder) }
        let service = try XrplSynchronizer(database:db,apiKey:key)
        try await service.refresh(accountID:"a1")
        // Bound the test to committed pages; cancellation retains the backfill cursor.
        try await Task.sleep(for:.seconds(2)); await service.cancel()
        let inventory = try await db.xrplInventory(accountID:"a1"); XCTAssertGreaterThan(try XCTUnwrap(inventory).holdings.count,1)
        let current = try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertNotNil(current.holdings.first{$0.reference == "native"}?.usdPrice)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(current.holdings,offline.holdings)
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM xrplTransactions WHERE accountID='a1'")!}; XCTAssertGreaterThan(count,0)
        try await assertActivityDetails(db, walletID: "w1")
            print("XRPL production persisted \(inventory!.holdings.count) holdings and \(count) transactions; offline snapshot matches")
    }
}

private actor XrplRefreshFeed: AnkrTransport {
    let owner: String, issuer: String
    var round = 1
    init(owner: String, issuer: String) { self.owner = owner; self.issuer = issuer }
    func advance() { round += 1 }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" { return (Data(#"{"data":{"base":"XRP","currency":"USD","amount":"2"}}"#.utf8), 200) }
        guard let body = request.httpBody else { return (Data("{}".utf8), 200) }
        let call = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        var result: [String: Any] = ["status": "success", "validated": true, "ledger_hash": String(repeating: "A", count: 64)]
        switch call["method"] as? String {
        case "server_info": result["info"] = ["network_id": 0, "complete_ledgers": "1-200"]
        case "ledger": result.merge(["validated": true, "ledger_hash": String(repeating: "A", count: 64), "ledger_index": 100 + round,
                                      "ledger": ["closed": true, "close_time": 800000000]], uniquingKeysWith: { _, new in new })
        case "account_info": result["account_data"] = ["Account": owner, "Balance": String(round * 1000000)]
        case "account_lines": result["account"] = owner; result["lines"] = [["currency": "USD", "account": issuer, "balance": String(round)]]
        case "account_objects": result["account"] = owner; result["account_objects"] = [Any]()
        case "account_tx": result.merge(["account": owner, "transactions": [Any](), "ledger_index_min": 1, "ledger_index_max": 100 + round, "validated": true], uniquingKeysWith: { _, new in new })
        default: throw XrplError.malformed
        }
        return (try JSONSerialization.data(withJSONObject: ["result": result]), 200)
    }
}
extension XrplLedgerTests {
    func testChangedNativeAndIssuedBalancesPublishWithoutReopening() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await db.saveMarketCache(.init(key: "xrpl.catalog", source: "fixture", payload: JSONEncoder().encode(catalog), fetchedAt: Date().timeIntervalSince1970))
        let feed = XrplRefreshFeed(owner: owner, issuer: String(ref.split(separator: ".")[1]))
        let service = XrplSynchronizer(database: db, client: try XrplClient(apiKey: "fixture", transport: feed), markets: XrplMarkets(transport: feed))
        let publication = RefreshPublicationProbe(db, wallet: "w1")
        defer { publication.stop() }
        try await service.refresh(accountID: "a1")
        try await publication.expect(amount: "1000000", network: "xrpl")
        await feed.advance()
        try await service.refresh(accountID: "a1")
        try await publication.expect(amount: "2000000", network: "xrpl")
        try await publication.expect(ref, amount: XrplIdentity.issuedAmount("2"), network: "xrpl")
        await service.cancel()
    }
}
