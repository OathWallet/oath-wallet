import XCTest
import OathAnkr
import OathDiagnostics
import GRDB
@testable import OathDatabase

@MainActor final class HyperEVMLedgerTests: XCTestCase {
    private let owner = "0x1111111111111111111111111111111111111111"
    private let other = "0x2222222222222222222222222222222222222222"
    private let token = "0x3333333333333333333333333333333333333333"
    private func fixture() async throws -> (OathDatabase,URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperEVM-"+UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at:url)
        try await db.seed(networks:[.init(id:"hyperevm",name:"HyperEVM",family:"evm",symbol:"HYPE",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:0)],
            assets:[.init(id:"hyperevm:native",networkID:"hyperevm",reference:"native",name:"HyperEVM",symbol:"HYPE",decimals:18,logo:"local")])
        for id in ["wallet","second"] {
            try await db.importWalletIfNeeded(.init(id:id,name:id,kind:"hd",vaultReference:id,createdAt:1),
                accounts:[.init(id:id+":hyperevm",walletID:id,networkID:"hyperevm",address:owner,derivationPath:"m/44'/60'/0'/0/0")])
        }
        return (db,url)
    }
    private func inventory(amount:String? = "9007199254740993", complete:Bool = true, block:Int = 100) throws -> HyperEVMInventory {
        func holding(_ reference:String,_ units:String?,_ decimals:Int)->[String:Any] {
            ["token":["reference":reference,"name":reference == "native" ? "HYPE":"Token","symbol":"TKN","decimals":decimals],"amount":units as Any? ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject:["owner":owner,"block":block,"blockHash":"0x"+String(repeating:"a",count:64),
            "observedAt":Date().timeIntervalSinceReferenceDate,"holdings":[holding("native","1000000000000000000",18),holding(token,amount,6)],"complete":complete,"raw":Data("{\"index\":[]}".utf8).base64EncodedString()])
        return try JSONDecoder().decode(HyperEVMInventory.self,from:data)
    }
    func testPersistencePortfolioExactUnitsPricesAndWalletIsolation() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.savePrices([.init(assetID:"hyperevm:native",currency:"USD",value:"2500",observedAt:Date().timeIntervalSince1970,source:"Coinbase")])
        let reopened = try await OathDatabase.open(at:url), snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == "native"}?.name,"HyperEVM")
        XCTAssertEqual(snapshot.totalFiat,2500)
        let second = try await reopened.snapshot(walletID:"second",currency:"USD")
        XCTAssertNil(second.holdings.first?.amountAtomic)
        let balance = try await reopened.balance(accountID:"wallet:hyperevm",assetID:"hyperevm:"+token)
        XCTAssertEqual(balance?.amountAtomic,"9007199254740993")
    }
    func testPartialInventoryPreservesCachedTokenAndSuccessfulZeroReplacesIt() async throws {
        let (db,_) = try await fixture()
        var ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(amount:nil,complete:false,block:101),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        let complete = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT complete FROM hyperevmSync WHERE accountID='wallet:hyperevm'") }
        XCTAssertEqual(complete,0)
        ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(amount:"0",block:102),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"0")
    }
    func testUnlistedTokenHiddenUnlessExplicitlyAddedAndStaleRunRejected() async throws {
        let (db,_) = try await fixture()
        let old = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        do { try await db.commitHyperEVMInventory(inventory(),ticket:old,catalog:.empty); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertFalse(snapshot.holdings.contains{$0.reference == token})
        let stored = try await db.asset(networkID:"hyperevm",reference:token)
        let asset = try XCTUnwrap(stored)
        try await db.trackAsset(asset,walletID:"wallet")
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
    }
    func testHistoryCommitsCursorAndEventsTogetherThenResumesWithoutDuplicateActivity() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let cursors = try await db.hyperevmHistoryWork(ticket)
        let cursor = try XCTUnwrap(cursors.first{$0.stream == "transactions" && $0.lane == "recent"})
        let time = Date(timeIntervalSince1970:floor(cursor.endTime)-1).ISO8601Format(), hash = "0x"+String(repeating:"a",count:64)
        let row: [String:Any] = ["hash":hash,"block_number":100,"timestamp":time,"from":["hash":other],"to":["hash":owner],"status":"ok","value":"12345","fee":["value":"321"]]
        let raw = try JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":["block_number":99]])
        let page = try HyperEVMClient.decodeHistory(raw,owner:owner,stream:.transactions,from:cursor.startTime,through:cursor.endTime)
        try await db.commitHyperEVMPage(page,cursor:cursor,ticket:ticket)
        let reopened = try await OathDatabase.open(at:url)
        let nextTicket = try await reopened.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let resumed = try await reopened.hyperevmHistoryWork(nextTicket)
        let next = try XCTUnwrap(resumed.first{$0.stream == "transactions" && $0.lane == "recent"})
        XCTAssertEqual(next.cursor,page.next); XCTAssertEqual(next.endTime,cursor.endTime)
        let final = try HyperEVMClient.decodeHistory(JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull()]),owner:owner,stream:.transactions,from:next.startTime,through:next.endTime)
        try await reopened.commitHyperEVMPage(final,cursor:next,ticket:nextTicket)
        let history = try await reopened.assetHistory(walletID:"wallet",accountID:"wallet:hyperevm",assetID:"hyperevm:native")
        XCTAssertEqual(history.count,1); XCTAssertEqual(history.first?.amountAtomic,"12345")
        let counts = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(counts.holdings.first?.transactionCount,1)
    }
    func testResetErasesHyperEVMWalletDataButPreservesPublicMarketCache() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.saveMarketCache(.init(key:"hyperevm.catalog",source:"CoinGecko",payload:Data("{}".utf8),fetchedAt:Date().timeIntervalSince1970))
        let reset = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let rows = try await db.pool.read { db in try ["hyperevmSync","hyperevmHoldings","hyperevmHistoryCursors","hyperevmEvents","hyperevmPages"].map { try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($0)") ?? -1 } }
        XCTAssertEqual(rows,[0,0,0,0,0])
        let cache = try await db.marketCache(key:"hyperevm.catalog"); XCTAssertNotNil(cache)
    }

    func testExpiredCursorRestartsOnlyItsWindowAndRejectsStaleRun() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let initialWork = try await db.hyperevmHistoryWork(ticket)
        let initial = try XCTUnwrap(initialWork.first{$0.stream == "transfers" && $0.lane == "backfill"})
        let raw = try JSONSerialization.data(withJSONObject:["items":[],"next_page_params":["block_number":99]])
        let page = try HyperEVMClient.decodeHistory(raw,owner:owner,stream:.transfers,from:initial.startTime,through:initial.endTime)
        try await db.commitHyperEVMPage(page,cursor:initial,ticket:ticket)
        let continued = try await db.hyperevmHistoryWork(ticket)
        let saved = try XCTUnwrap(continued.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNotNil(saved.cursor)
        try await db.restartHyperEVMHistory(saved,ticket:ticket)
        let restarted = try await db.hyperevmHistoryWork(ticket)
        let fresh = try XCTUnwrap(restarted.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNil(fresh.cursor); XCTAssertEqual(fresh.startTime,initial.startTime); XCTAssertEqual(fresh.endTime,initial.endTime)
        XCTAssertEqual(restarted.filter{$0.stream != initial.stream}.map(\.cursor),initialWork.filter{$0.stream != initial.stream}.map(\.cursor))
        _ = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        do { try await db.restartHyperEVMHistory(saved,ticket:ticket); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }

    func testUnknownMetadataLogIsDurableWithoutInventingAssetUnits() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let work = try await db.hyperevmHistoryWork(ticket)
        let cursor = try XCTUnwrap(work.first{$0.stream == "transfers" && $0.lane == "recent"})
        let hash = "0x"+String(repeating:"a",count:64)
        let row:[String:Any] = ["transaction_hash":hash,"block_number":100,"timestamp":Date(timeIntervalSince1970:floor(cursor.endTime)-1).ISO8601Format(),
            "from":["hash":other],"to":["hash":owner],"token":["address_hash":token],"metadata_unavailable":true,"total":["value":"123"],"log_index":7]
        let raw = try JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull()])
        let page = try HyperEVMClient.decodeHistory(raw,owner:owner,stream:.transfers,from:cursor.startTime,through:cursor.endTime)
        try await db.commitHyperEVMPage(page,cursor:cursor,ticket:ticket)
        let stored = try await db.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM hyperevmEvents"),try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM activity"))
        }
        XCTAssertEqual(stored.0,1); XCTAssertEqual(stored.1,0)
        let remaining = try await db.hyperevmHistoryWork(ticket)
        XCTAssertFalse(remaining.contains{$0.stream == "transfers" && $0.lane == "recent"})
    }
    func testLiveSynchronizerPersistsRealPortfolioAndHistoryAcrossReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_HYPEREVM_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet read verification") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as! [String:String]
        let (db,url) = try await fixture()
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='wallet:hyperevm'",arguments:["0x8109ea0f4f8b4a63b97781b5a2bc58ff7a1aa26d"]) }
        let service = try HyperEVMSynchronizer(database:db,apiKey:XCTUnwrap(config["AnkrAPIKey"]))
        do { try await service.refresh(accountID:"wallet:hyperevm") }
        catch {
            // This public wallet contains contracts whose balanceOf can revert.
            // Accept partial status only with the actual saved RPC rejection;
            // a generic outage or incomplete discovery must still fail this test.
            guard (error as? ReportedDiagnosticFailure)?.underlying as? BalanceRefreshError == .incomplete else {
                await service.cancel(); throw error
            }
            let raw = try await db.pool.read { try Data.fetchOne($0, sql: "SELECT inventory FROM hyperevmSync WHERE accountID='wallet:hyperevm'") }
            let archive = try JSONDecoder().decode([String: [Data]].self, from: XCTUnwrap(raw))
            let replies = try (archive["state"] ?? []).flatMap { try JSONDecoder().decode(SolanaJSON.self, from: $0).array ?? [] }
            XCTAssertTrue(replies.contains { $0["error"]["code"].integer == 3 }, "Partial live snapshot must identify a real contract revert")
            let state = try await db.pool.read { db in
                (try Int.fetchOne(db, sql: "SELECT complete FROM hyperevmSync WHERE accountID='wallet:hyperevm'"),
                 try String.fetchOne(db, sql: "SELECT failure FROM hyperevmSync WHERE accountID='wallet:hyperevm'"))
            }
            XCTAssertEqual(state.0, 0); XCTAssertEqual(state.1, "incompleteInventory")
            print("HyperEVM live partial snapshot: saved RPC contract revert verified; unavailable balances stay unknown")
        }
        // A completed internal-events page can precede the page that produces
        // formatted activity. Wait for actual activity instead of stopping at
        // the first raw event, then explicitly track this public test portfolio.
        for _ in 0..<50 {
            let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity WHERE accountID='wallet:hyperevm'") ?? 0 }
            if count > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        await service.cancel()
        let publicAssets = try await db.pool.read { try AssetRecord.fetchAll($0, sql: "SELECT * FROM assets WHERE networkID='hyperevm'") }
        for asset in publicAssets where asset.reference != "native" { try await db.trackAsset(asset, walletID: "wallet") }
        let original = try await db.snapshot(walletID:"wallet",currency:"USD")
        let storedOriginal = try await hyperBalances(db)
        XCTAssertGreaterThan(storedOriginal.count, 2)
        let reopened = try await OathDatabase.open(at:url)
        let saved = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        let storedAfter = try await hyperBalances(reopened)
        XCTAssertEqual(storedOriginal, storedAfter, "All persisted token quantities and observation data survive reopen, including hidden tokens")
        XCTAssertNotNil(saved.holdings.first { $0.reference == "native" }); XCTAssertGreaterThan(saved.totalFiat,0)
        XCTAssertEqual(saved.totalFiat,original.totalFiat)
        XCTAssertEqual(saved.holdings.map(\.amountAtomic),original.holdings.map(\.amountAtomic))
        let counts = try await reopened.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM hyperevmEvents") ?? 0,try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM hyperevmHistoryCursors") ?? 0)
        }
        XCTAssertGreaterThan(counts.0,0); XCTAssertEqual(counts.1,6)
        try await assertActivityDetails(reopened, walletID: "wallet")
        print("HyperEVM live storage: \(storedAfter.count) stored balances, \(saved.holdings.count) visible portfolio assets, \(counts.0) durable events, six resumable history lanes")
    }

}

private actor HyperEVMSnapshotRecoveryTransport: AnkrTransport {
    let recoverySucceeds: Bool
    let primaryStatus: Int?
    let tokenFails: Bool
    init(recoverySucceeds: Bool, primaryStatus: Int? = nil, tokenFails: Bool = false) {
        self.recoverySucceeds = recoverySucceeds; self.primaryStatus = primaryStatus; self.tokenFails = tokenFails
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "rpc.ankr.com", !tokenFails {
            if let primaryStatus { return (Data(), primaryStatus) }
            throw AnkrError.transport
        }
        let body: Any
        if request.url?.host == "trace.hypurrscan.io" {
            body = ["success": true, "last_aggregated_block": 101, "balances": [],
                    "results": ["0x1111111111111111111111111111111111111111": [
                        "transactions": [], "erc20_transfers": [], "internal_calls": [], "has_more": false, "next_cursor": NSNull()]]]
        } else if request.url?.host == "api.coingecko.com" {
            body = ["hyperliquid": ["usd": 1, "last_updated_at": Date().timeIntervalSince1970]]
        } else if request.url?.host == "api.dexscreener.com" {
            body = [Any]()
        } else {
            XCTAssertTrue(["hyperliquid-mainnet.g.alchemy.com", "rpc.ankr.com"].contains(request.url?.host ?? ""))
            guard recoverySucceeds else { throw AnkrError.transport }
            let calls = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [[String: Any]]
            body = calls.map { call -> [String: Any] in
                let result: Any
                switch call["method"] as? String {
                case "eth_chainId": result = "0x3e7"
                case "eth_getBlockByNumber": result = ["number": "0x65", "hash": "0x" + String(repeating: "b", count: 64)]
                case "eth_getBalance": result = tokenFails ? "0xde0b6b3a7640000" : "0x1bc16d674ec80000"
                case "eth_call":
                    let params = call["params"] as! [Any]
                    let data = (params[0] as! [String: Any])["data"] as! String
                    if tokenFails && data != "0x313ce567" {
                        return ["jsonrpc": "2.0", "id": call["id"]!, "error": ["code": -32000, "message": "fixture token failure"]]
                    }
                    result = data == "0x313ce567" ? "0x6" : "0x2a"
                default: XCTFail("Unexpected RPC"); result = NSNull()
                }
                return ["jsonrpc": "2.0", "id": call["id"]!, "result": result]
            }
        }
        return (try JSONSerialization.data(withJSONObject: body), 200)
    }
}

extension HyperEVMLedgerTests {
    func testRefreshRecoversProviderFailureAndCommitsVerifiedBalances() async throws {
        let (db, _) = try await fixture()
            let publication = RefreshPublicationProbe(db, wallet: "wallet")
            defer { publication.stop() }
        let ticket = try await db.beginHyperEVMSync(accountID: "wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(), ticket: ticket, catalog: .init(ids: [token: "fixture"]))
        try await db.saveMarketCache(.init(key: "hyperevm.catalog", source: "CoinGecko",
            payload: JSONEncoder().encode(HyperEVMCatalog(ids: [token: "fixture"])), fetchedAt: Date().timeIntervalSince1970))
        let transport = HyperEVMSnapshotRecoveryTransport(recoverySucceeds: true)
        let service = HyperEVMSynchronizer(database: db,
            client: try HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport),
            markets: HyperEVMMarkets(transport: transport))
        try await service.refresh(accountID: "wallet:hyperevm")
        await service.waitForHistory(accountID: "wallet:hyperevm")
        let native = try await db.balance(accountID: "wallet:hyperevm", assetID: "hyperevm:native")
        let erc20 = try await db.balance(accountID: "wallet:hyperevm", assetID: "hyperevm:" + token)
        XCTAssertEqual(native?.amountAtomic, "2000000000000000000")
        XCTAssertEqual(erc20?.amountAtomic, "42")
        let untouched = try await db.balance(accountID: "second:hyperevm", assetID: "hyperevm:native")
        XCTAssertNil(untouched)
        try await publication.expect(amount: "2000000000000000000", network: "hyperevm")
            try await publication.expect(token, amount: "42", network: "hyperevm")
            await service.cancel()
    }

    func testRefreshPersistentOutagePreservesCachedBalancesAndThrows() async throws {
        let (db, _) = try await fixture()
        let ticket = try await db.beginHyperEVMSync(accountID: "wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(), ticket: ticket, catalog: .init(ids: [token: "fixture"]))
        try await db.saveMarketCache(.init(key: "hyperevm.catalog", source: "CoinGecko",
            payload: JSONEncoder().encode(HyperEVMCatalog(ids: [token: "fixture"])), fetchedAt: Date().timeIntervalSince1970))
        let transport = HyperEVMSnapshotRecoveryTransport(recoverySucceeds: false)
        let service = HyperEVMSynchronizer(database: db,
            client: try HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport),
            markets: HyperEVMMarkets(transport: transport))
        do { try await service.refresh(accountID: "wallet:hyperevm"); XCTFail("Outage must remain visible") }
        catch { XCTAssertEqual((error as? ReportedDiagnosticFailure)?.underlying as? AnkrError, .transport) }
        await service.waitForHistory(accountID: "wallet:hyperevm")
        let native = try await db.balance(accountID: "wallet:hyperevm", assetID: "hyperevm:native")
        let erc20 = try await db.balance(accountID: "wallet:hyperevm", assetID: "hyperevm:" + token)
        XCTAssertEqual(native?.amountAtomic, "1000000000000000000")
        XCTAssertEqual(erc20?.amountAtomic, "9007199254740993")
        await service.cancel()
    }
}


private actor HyperEVMRefreshReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}

extension HyperEVMLedgerTests {
    func testTerminalFailuresAreReportedOnceBySyncAndPreserveWalletHistoryOnReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_HYPEREVM_FAILURE_CAPTURE"] == "1" else {
            throw XCTSkip("Dedicated diagnostics capture process")
        }
        let capture = HyperEVMRefreshReports()
        let reportFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: reportFile) }
        OathDiagnostics.configure(file: reportFile, transport: capture)
        for mode in ["transport", "forbidden", "partial"] {
            let status: Int? = mode == "forbidden" ? 403 : nil
            let (db, url) = try await fixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let ticket = try await db.beginHyperEVMSync(accountID: "wallet:hyperevm")
            try await db.commitHyperEVMInventory(inventory(), ticket: ticket, catalog: .init(ids: [token: "fixture"]))
            try await db.saveMarketCache(.init(key: "hyperevm.catalog", source: "fixture",
                payload: JSONEncoder().encode(HyperEVMCatalog(ids: [token: "fixture"])), fetchedAt: Date().timeIntervalSince1970))
            let work = try await db.hyperevmHistoryWork(ticket)
            let cursor = try XCTUnwrap(work.first { $0.stream == "transactions" && $0.lane == "recent" })
            let row: [String: Any] = ["hash": "0x" + String(repeating: "c", count: 64), "block_number": 100,
                "timestamp": Date(timeIntervalSince1970: floor(cursor.endTime) - 1).ISO8601Format(),
                "from": ["hash": other], "to": ["hash": owner], "status": "ok", "value": "12345", "fee": ["value": "321"]]
            let page = try HyperEVMClient.decodeHistory(JSONSerialization.data(withJSONObject: ["items": [row], "next_page_params": NSNull()]),
                owner: owner, stream: .transactions, from: cursor.startTime, through: cursor.endTime)
            try await db.commitHyperEVMPage(page, cursor: cursor, ticket: ticket)
            let balances = try await hyperBalances(db)
            XCTAssertEqual(balances.count, 2)
            let wallets = try await db.pool.read { try WalletRecord.fetchAll($0) }
            let accounts = try await db.pool.read { try AccountRecord.fetchAll($0) }
            let history = try await db.assetHistory(walletID: "wallet", accountID: "wallet:hyperevm", assetID: "hyperevm:native")
            XCTAssertEqual(history.count, 1)
            let transport = HyperEVMSnapshotRecoveryTransport(recoverySucceeds: mode == "partial", primaryStatus: status, tokenFails: mode == "partial")
            let service = HyperEVMSynchronizer(database: db,
                client: try HyperEVMClient(apiKey: "SecretFixtureKey", transport: transport), markets: HyperEVMMarkets(transport: transport))
            do { try await service.refresh(accountID: "wallet:hyperevm"); XCTFail("Failure must remain a failure") }
            catch {
                let marker = error as? ReportedDiagnosticFailure
                XCTAssertNotNil(marker)
                if mode == "partial" { XCTAssertEqual((marker?.underlying ?? error) as? BalanceRefreshError, .incomplete) }
                else { XCTAssertEqual((marker?.underlying ?? error) as? AnkrError, status.map(AnkrError.http) ?? .transport) }
                OathDiagnostics.record(error, operation: "hyperevm_wallet_duplicate")
                OathDiagnostics.record(error, operation: "hyperevm_result_duplicate")
            }
            await service.waitForHistory(accountID: "wallet:hyperevm")
            await service.cancel()
            let reopened = try await OathDatabase.open(at: url)
            let afterBalances = try await hyperBalances(reopened)
            let afterWallets = try await reopened.pool.read { try WalletRecord.fetchAll($0) }
            let afterAccounts = try await reopened.pool.read { try AccountRecord.fetchAll($0) }
            let afterHistory = try await reopened.assetHistory(walletID: "wallet", accountID: "wallet:hyperevm", assetID: "hyperevm:native")
            if mode == "partial" {
                XCTAssertEqual(balances.filter { $0.assetID != "hyperevm:native" }, afterBalances.filter { $0.assetID != "hyperevm:native" })
                XCTAssertEqual(balances.map(\.amountAtomic), afterBalances.map(\.amountAtomic))
                let failure = try await reopened.pool.read { try String.fetchOne($0, sql: "SELECT failure FROM hyperevmSync WHERE accountID='wallet:hyperevm'") }
                XCTAssertEqual(failure, "incompleteInventory")
            } else { XCTAssertEqual(balances, afterBalances) }
            XCTAssertEqual(wallets, afterWallets); XCTAssertEqual(accounts, afterAccounts)
            XCTAssertEqual(history, afterHistory)
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events.filter({ $0.sourceFile == "OathDatabase/HyperEVMSynchronizer.swift" && $0.operation == "refreshAccountaccountID:" }).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { ($0.sourceFile == "OathDatabase/HyperEVMSynchronizer.swift" && $0.operation == "refreshAccountaccountID:") ||
            ["hyperevm_wallet_duplicate", "hyperevm_result_duplicate"].contains($0.operation) }
        XCTAssertEqual(events.count, 3, "Exactly one terminal sync report per failure, without wallet/result copies")
        XCTAssertTrue(events.contains { $0.context["stage"] == "inventory" && $0.context["reason"] == "balance_unavailable" })
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "hyperevm" && $0.operationID != nil && $0.privacyFiltered })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in [owner, other, token, "SecretFixtureKey"] { XCTAssertFalse(encoded.contains(secret)) }
    }
}


private func hyperBalances(_ database: OathDatabase) async throws -> [BalanceRecord] {
    try await database.pool.read { db in
        try BalanceRecord.fetchAll(db, sql: """
            SELECT accountID,assetID,'hyperevm' AS networkID,amountAtomic,observedAt,
                   checkpoint AS blockHeight,'hyperevm' AS source
            FROM hyperevmHoldings ORDER BY accountID,assetID
            """)
    }
}
