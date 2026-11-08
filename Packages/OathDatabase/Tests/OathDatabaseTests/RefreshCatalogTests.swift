import Foundation
import XCTest
import GRDB
import OathAnkr
import OathDiagnostics
@testable import OathDatabase
private func fixtureJSON(_ object: Any) throws -> (Data, Int) { (try JSONSerialization.data(withJSONObject: object), 200) }
private actor RefreshFailureCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}
private actor CatalogGateFeed: AnkrTransport {
 var catalogEntered=false; var nativeRead=false; var pinnedRead=false
 var discoveryFails=false; var tokenReadFails=false; var failedBatchToken: String?
 func failBatch(_ reference: String) { failedBatchToken = reference }
 var ready: Bool { catalogEntered && nativeRead && pinnedRead }
 func failDiscovery() { discoveryFails=true; tokenReadFails=true }
 private var gate: CheckedContinuation<Void,Never>?
 func release() { gate?.resume(); gate=nil }
 func send(_ request: URLRequest) async throws -> (Data,Int) {
  let url=request.url!
  if url.host=="api.coingecko.com" && url.path=="/api/v3/coins/list" {
   catalogEntered=true
   await withCheckedContinuation { gate=$0 }
   return try fixtureJSON([["id":"fixture","platforms":["unichain":"0x2222222222222222222222222222222222222222"]]])
  }
  if url.host=="api.coinbase.com" { return try fixtureJSON(["data":["base":"ETH","currency":"USD","amount":"2"]]) }
  if discoveryFails && url.path.hasSuffix("/tokens") { throw URLError(.notConnectedToInternet) }
  if url.path.hasSuffix("/tokens") { return try fixtureJSON(["items":[["token":["type":"ERC-20","address_hash":"0x2222222222222222222222222222222222222222","name":"Fixture","symbol":"FIX","decimals":"18"]]],"next_page_params":NSNull()]) }
  if request.httpBody==nil { return try fixtureJSON(["items":[],"next_page_params":NSNull()]) }
  let object=try JSONSerialization.jsonObject(with:request.httpBody!)
  let rows=(object as? [[String:Any]]) ?? [object as! [String:Any]]
  if let failedBatchToken, rows.contains(where: { row in
    guard let params = row["params"] as? [Any], let call = params.first as? [String: Any] else { return false }
    return call["to"] as? String == failedBatchToken
  }) { return (Data(), 401) }
  let result=rows.map { req -> [String:Any] in
   let method=req["method"] as! String, params=req["params"] as! [Any]
   let value:Any
   switch method {
   case "eth_chainId": value="0x82"
   case "eth_getBlockByNumber":
    if params.first as? String == "0x64" { pinnedRead=true }
    value=["number":"0x64","hash":"0x"+String(repeating:"f",count:64),"timestamp":"0x"+String(Int(Date().timeIntervalSince1970),radix:16)]
   case "eth_getBalance": nativeRead=true; value="0xde0b6b3a7640000"
   case "eth_call":
    let call=params[0] as! [String:Any]
    if tokenReadFails { return ["jsonrpc":"2.0","id":req["id"]!,"error":["code":-32000,"message":"fixture unavailable"]] }
    value = (call["data"] as? String)=="0x313ce567" ? "0x12" : "0xa"
   default: value=[]
   }
   return ["jsonrpc":"2.0","id":req["id"]!,"result":value]
  }
  return try fixtureJSON(object is [[String:Any]] ? result : result[0])
 }
}

@MainActor final class RefreshCatalogTests: XCTestCase {
    func testHeldCatalogDoesNotBlockBalancesAndEnrichmentCannotReplayOldUnits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks: [.init(id: "unichain", name: "Unichain", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)],
            assets: [.init(id: "unichain:native", networkID: "unichain", reference: "native", name: "Ether", symbol: "ETH", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "wallet", networkID: "unichain", address: "0x1111111111111111111111111111111111111111", derivationPath: "")])
        let feed = CatalogGateFeed()
        let service = IndexedEVMSynchronizer(database: db, client: try IndexedEVMClient(chain: .unichain, apiKey: "fixture", transport: feed), markets: IndexedEVMMarkets(chain: .unichain, transport: feed))
        let publication = RefreshPublicationProbe(db, wallet: "wallet")
        defer { publication.stop() }
        let work = Task { try await service.refresh(accountID: "account") }
        for _ in 0..<400 { if await feed.ready { break }; try await Task.sleep(for: .milliseconds(5)) }
        let ready = await feed.ready
        XCTAssertTrue(ready)
        try await publication.expect(amount: "1000000000000000000", network: "unichain")
        let token = "0x2222222222222222222222222222222222222222"
        // Simulate a newer verified post-send quantity while the catalog is held.
        try await db.pool.write { database in
            try database.execute(sql: "UPDATE indexedEVMHoldings SET amountAtomic='77',checkpoint=101,observedAt=9999999999 WHERE accountID='account' AND reference=?", arguments: [token])
        }
        await feed.release()
        try await work.value
        let enriched = try await db.balance(accountID: "account", assetID: "unichain:" + token)
        XCTAssertEqual(enriched?.amountAtomic, "77")
        XCTAssertEqual(enriched?.observedAt, 9999999999)
        let verified = try await db.pool.read { try Bool.fetchOne($0, sql: "SELECT verified FROM indexedEVMHoldings WHERE accountID='account' AND reference=?", arguments: [token]) }
        XCTAssertEqual(verified, true)
        await service.cancel()
    }
}

extension RefreshCatalogTests {
    func testFailedExtraTokenBatchDoesNotDiscardNativeAndOtherTokenUpdates() async throws {
        let capture = ProcessInfo.processInfo.environment["OATH_INDEXED_REFRESH_CAPTURE"] == "1" ? RefreshFailureCapture() : nil
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let owner = "0x1111111111111111111111111111111111111111"
        try await db.seed(networks: [.init(id: "unichain", name: "Unichain", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)],
            assets: [.init(id: "unichain:native", networkID: "unichain", reference: "native", name: "Ether", symbol: "ETH", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "wallet", networkID: "unichain", address: owner, derivationPath: "")])
        let refs = (1...18).map { "0x" + String(format: "%040x", $0) }
        let catalog = IndexedEVMCatalog(chain: .unichain, ids: Dictionary(uniqueKeysWithValues: refs.map { ($0, "fixture") }))
        let holdings = (["native"] + refs).map { reference in
            ["token": ["reference": reference, "name": "Fixture", "symbol": "FIX", "decimals": 18], "amount": "7"] as [String: Any]
        }
        let raw = try JSONSerialization.data(withJSONObject: ["chain": "unichain", "owner": owner, "block": 50,
            "blockHash": "0x" + String(repeating: "a", count: 64), "observedAt": 1, "holdings": holdings, "complete": true, "raw": ""])
        let old = try JSONDecoder().decode(IndexedEVMInventory.self, from: raw)
        let ticket = try await db.beginIndexedEVMSync(accountID: "account")
        try await db.commitIndexedEVMInventory(old, ticket: ticket, catalog: catalog)
        try await db.saveMarketCache(.init(key: "unichain.catalog", source: "fixture", payload: JSONEncoder().encode(catalog), fetchedAt: Date().timeIntervalSince1970))
        let before = try await db.balance(accountID: "account", assetID: "unichain:" + refs.last!)
        if let capture {
            OathDiagnostics.configure(file: folder.appendingPathComponent("reports.json"), transport: capture)
        }
        let feed = CatalogGateFeed()
        await feed.failBatch(refs.last!)
        let service = IndexedEVMSynchronizer(database: db, client: try IndexedEVMClient(chain: .unichain, apiKey: "fixture", transport: feed), markets: IndexedEVMMarkets(chain: .unichain, transport: feed))
        let publication = RefreshPublicationProbe(db, wallet: "wallet")
        defer { publication.stop() }
        do { try await service.refresh(accountID: "account"); XCTFail("Failed batch must remain partial") }
        catch {
            XCTAssertEqual((error as? ReportedDiagnosticFailure)?.underlying as? BalanceRefreshError, .incomplete)
            guard case .partial = BalanceRefreshOutcome(.failure(error)) else { return XCTFail("Reported failures must retain partial coverage") }
            OathDiagnostics.record(error, operation: "presentation_duplicate")
        }
        let failure = try await db.pool.read { try String.fetchOne($0, sql: "SELECT failure FROM indexedEVMSync WHERE accountID='account'") }
        XCTAssertEqual(failure, "incompleteInventory", "A partial provider response is not a storage failure")
        if let capture {
            for _ in 0..<100 {
                if await capture.events.contains(where: { $0.error.message == "incomplete" }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            await OathDiagnostics.flush()
            let events = await capture.events.filter { $0.error.message == "incomplete" }
            XCTAssertEqual(events.count, 1, "One original report, no cleanup or presentation copies")
            XCTAssertEqual(events.first?.context["chain"], "unichain")
            XCTAssertEqual(events.first?.context["reason"], "balance_unavailable")
        }
        try await publication.expect(amount: "1000000000000000000", network: "unichain")
        try await publication.expect(refs[0], amount: "10", network: "unichain")
        let retained = try await db.balance(accountID: "account", assetID: "unichain:" + refs.last!)
        XCTAssertEqual(retained, before, "Both quantity and observation time survive a failed batch")
        await service.cancel()
    }
}
