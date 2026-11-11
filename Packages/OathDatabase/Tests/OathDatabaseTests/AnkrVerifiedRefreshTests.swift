import Foundation
import XCTest
import GRDB
import OathAnkr
import OathDiagnostics
@testable import OathDatabase

private let refreshOwner = "0x1111111111111111111111111111111111111111"
private let refreshToken = "0x2222222222222222222222222222222222222222"
private actor VerifiedRefreshFeed: AnkrTransport {
    let chain: AnkrChain
    let network: EVMSendNetwork
    var native = "0xde0b6b3a7640000", token = "0x1bc16d674ec80000"
    var failsToken = false, omitToken = false, delayed = false, missingStatus = false
    var historyFails = false
    var staleIndex = false, metadataConflict = false
    var nodeFailure = ""
    var discoveryFails = false, stalePrimary = false, reorg = false, wrongDecimals = false
    var cursorMode = ""
    var inventoryCalls: [String?] = []
    func cursorFailure(_ mode: String) { cursorMode = mode; inventoryCalls = [] }
    var height = 100
    var fallbackRequests = 0
    init(_ chain: AnkrChain) { self.chain = chain; self.network = EVMSendNetwork(rawValue: chain.networkID)! }
    func advance(failToken: Bool = false, omit: Bool = false) {
        native = "0x29a2241af62c0000"; token = "0x3782dace9d900000"; height += 1
        failsToken = failToken; omitToken = omit
    }
    func zero() { native = "0x0"; token = "0x0"; height += 1 }
    func mode(_ name: String) {
        historyFails = name == "history"
        nodeFailure = name.hasPrefix("node") ? name : ""
        delayed = name == "delayed"; missingStatus = name == "missing"
        staleIndex = name == "staleIndex"; metadataConflict = name == "metadataConflict"
        if name == "tokenFailure" { failsToken = true }
        discoveryFails = name == "discovery"; stalePrimary = name == "fallback"
        reorg = name == "reorg"; wrongDecimals = name == "decimals"
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let body = request.httpBody else { throw URLError(.notConnectedToInternet) }
        let object = try JSONSerialization.jsonObject(with: body)
        if let rows = object as? [[String: Any]] {
            if nodeFailure == "nodeTransport" { throw AnkrError.transport }
            if nodeFailure == "nodeRPC" {
                return (try JSONSerialization.data(withJSONObject: rows.map {
                    ["jsonrpc": "2.0", "id": $0["id"]!, "error": ["code": -32602, "message": "invalid fixture parameters"]]
                }), 200)
            }
            if request.url?.host == "fallback.fixture.test" { fallbackRequests += 1 }
            let result = rows.map { row -> [String: Any] in
                let method = row["method"] as! String, params = row["params"] as! [Any]
                let value: Any
                switch method {
                case "eth_chainId": value = "0x" + String(network.chainID, radix: 16)
                case "eth_getBlockByNumber":
                    let stale = stalePrimary && request.url?.host != "fallback.fixture.test"
                    let changed = reorg && params.first as? String != "latest"
                    value = ["number": "0x" + String(height, radix: 16), "hash": "0x" + String(repeating: changed ? "e" : "f", count: 64),
                             "timestamp": "0x" + String(Int(Date().timeIntervalSince1970) - (stale ? 3600 : 0), radix: 16)]
                case "eth_getBalance": value = native
                case "eth_call":
                    if failsToken { return ["jsonrpc": "2.0", "id": row["id"]!, "error": ["code": -32000, "message": "fixture token unavailable"]] }
                    let data = (params[0] as! [String: Any])["data"] as! String
                    value = data == "0x313ce567" ? (wrongDecimals ? "0x6" : "0x12") : token
                default: value = []
                }
                return ["jsonrpc": "2.0", "id": row["id"]!, "result": value]
            }
            return (try JSONSerialization.data(withJSONObject: result), 200)
        }
        let row = object as! [String: Any], method = row["method"] as! String
        if historyFails && method != "ankr_getAccountBalance" { return (Data(), 401) }
        if discoveryFails && method == "ankr_getAccountBalance" { return (Data(), 401) }
        var result: [String: Any]
        if method == "ankr_getAccountBalance" {
            let params = row["params"] as! [String: Any]
            let cursor = params["pageToken"] as? String
            inventoryCalls.append(cursor)
            if cursorMode == "firstRejected" || (!cursorMode.isEmpty && cursor != nil) {
                if cursorMode == "cursorTransport" { throw URLError(.secureConnectionFailed) }
                if cursorMode == "cursorDenied" { return (Data(), 401) }
                return (try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "error": ["code": -32602, "message": "invalid fixture page token"]]), 200)
            }
            let assets: [[String: Any]] = (omitToken ? [true] : [true, false]).map { native in
                ["blockchain": chain.rawValue, "tokenName": "Fixture", "tokenSymbol": native ? "COIN" : "TOKEN", "tokenDecimals": !native && metadataConflict ? 6 : 18,
                 "tokenType": native ? "NATIVE" : "ERC20", "contractAddress": native ? "0x" + String(repeating: "0", count: 40) : refreshToken,
                 "holderAddress": refreshOwner, "balanceRawInteger": "999", "balance": "999", "balanceUsd": "999", "tokenPrice": "2"]
            }
            result = ["assets": assets, "totalCount": assets.count, "totalBalanceUsd": "999"]
            if !cursorMode.isEmpty && (cursorMode != "cursorOnce" || inventoryCalls.count == 1) {
                result["assets"] = Array(assets.prefix(1))
                result["nextPageToken"] = "fixture-expired-cursor"
            }
        } else { result = [method == "ankr_getTokenTransfers" ? "transfers" : "transactions": []] }
        if !missingStatus {
            result["syncStatus"] = ["status": delayed ? "syncing" : "synced", "timestamp": Int(Date().timeIntervalSince1970) - (delayed || staleIndex ? 3600 : 0), "blockNumber": height]
        }
        return (try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": result]), 200)
    }
}

@MainActor final class AnkrVerifiedRefreshTests: XCTestCase {
    private func fixture(_ chain: AnkrChain = .eth) async throws -> (OathDatabase, AnkrSynchronizer, VerifiedRefreshFeed, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
        try await db.seed(networks: [.init(id: chain.networkID, name: chain.networkID, family: "evm", symbol: "COIN", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)],
            assets: [.init(id: chain.networkID + ":native", networkID: chain.networkID, reference: "native", name: chain.networkID, symbol: "COIN", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1), accounts: [.init(id: "account", walletID: "wallet", networkID: chain.networkID, address: refreshOwner, derivationPath: "")])
        let feed = VerifiedRefreshFeed(chain)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey: "fixture", transport: feed), catalogTransport: feed, balanceClient: { network in
            try EVMSendClient(network: EVMSendNetwork(rawValue: network)!, endpoints: [URL(string: "https://primary.fixture.test")!, URL(string: "https://fallback.fixture.test")!], transport: feed)
        })
        return (db, sync, feed, folder)
    }
    func testAllSixteenChainsPublishChangedNativeTokenAndFiatWithoutReopening() async throws {
        let chains = AnkrChain.allCases.filter(\.supportsAdvancedAPI)
        XCTAssertEqual(chains.count, 16)
        for chain in chains {
            let (db, sync, feed, folder) = try await fixture(chain)
            let observer = PortfolioRefreshCoordinator<WalletSnapshot>()
            var shown = try await db.snapshot(walletID: "wallet", currency: "USD")
            observer.observe(stream: { db.observeWallet(walletID: "wallet", currency: "USD") }, isCurrent: { true }, publish: { shown = $0 }, exhausted: { XCTFail(chain.networkID) })
            let first = try await sync.refreshBalances(walletID: "wallet")
            XCTAssertTrue(first.allSatisfy(\.success), chain.networkID)
            let before = try await db.snapshot(walletID: "wallet", currency: "USD")
            // Fantom native quotes from this legacy feed are deliberately rejected.
            // Its verified token balance still contributes to the portfolio.
            XCTAssertEqual(before.totalFiat, chain == .fantom ? 4 : 6, chain.networkID)
            await feed.advance()
            let second = try await sync.refreshBalances(walletID: "wallet")
            XCTAssertTrue(second.allSatisfy(\.success), chain.networkID)
            let expected: Decimal = chain == .fantom ? 8 : 14
            for _ in 0..<200 where shown.totalFiat != expected { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(shown.totalFiat, expected, chain.networkID)
            XCTAssertEqual(shown.holdings.first { $0.reference == "native" }?.amountAtomic, "3000000000000000000", chain.networkID)
            XCTAssertEqual(shown.holdings.first { $0.reference == refreshToken }?.amountAtomic, "4000000000000000000", chain.networkID)
            observer.stop(); await sync.cancel(); try? FileManager.default.removeItem(at: folder)
        }
    }
    func testPartialTokenFailureRetainsTimestampThenOmittedTokenRecoversThroughRPC() async throws {
        let (db, sync, feed, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await sync.refreshBalances(walletID: "wallet")
        let old = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        await feed.advance(failToken: true)
        let result = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertFalse(result.allSatisfy(\.success))
        let native = try await db.balance(accountID: "account", assetID: "ethereum:native")
        let unchanged = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        XCTAssertEqual(native?.amountAtomic, "3000000000000000000")
        XCTAssertEqual(old, unchanged)
        await feed.advance(omit: true)
        let recovered = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertTrue(recovered.allSatisfy(\.success))
        let token = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        XCTAssertEqual(token?.amountAtomic, "4000000000000000000")
    }
    func testDelayedMissingOrFailedIndexerStillPublishesNativeWithoutClaimingComplete() async throws {
        for mode in ["delayed", "missing", "discovery"] {
            let (db, sync, feed, folder) = try await fixture()
            await feed.mode(mode)
            let result = try await sync.refreshBalances(walletID: "wallet")
            XCTAssertFalse(result.allSatisfy(\.success), mode)
            let value = try await db.balance(accountID: "account", assetID: "ethereum:native")
            XCTAssertEqual(value?.amountAtomic, "1000000000000000000", mode)
            let status = try await db.ankrStatus(accountID: "account").first { $0.stream == "balances" }
            XCTAssertNotEqual(status?.complete, true); XCTAssertNil(status?.lastSuccess)
            await sync.cancel(); try? FileManager.default.removeItem(at: folder)
        }
    }
    func testStaleHeadUsesFreshFallbackAndReorgCannotPublish() async throws {
        let (db, sync, feed, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        await feed.mode("fallback")
        let result = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertTrue(result.allSatisfy(\.success))
        let requests = await feed.fallbackRequests
        XCTAssertGreaterThan(requests, 0)
        let before = try await db.balance(accountID: "account", assetID: "ethereum:native")
        await feed.advance(); await feed.mode("reorg")
        let failed = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertFalse(failed.allSatisfy(\.success))
        let after = try await db.balance(accountID: "account", assetID: "ethereum:native")
        XCTAssertEqual(before, after)
    }
}

extension AnkrVerifiedRefreshTests {
    func testIncompleteInventoryRetainsChainAndReasonWithoutRepeatedReportsOrDataLoss() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_PARTIAL_CAPTURE"] == "1" else { throw XCTSkip("Dedicated incomplete-inventory diagnostics process") }
        let capture = VerifiedRefreshReports()
        let reportFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: reportFile) }
        OathDiagnostics.configure(file: reportFile, transport: capture)
        for mode in ["delayed", "missing", "staleIndex", "metadataConflict", "tokenFailure"] {
            let (db, sync, feed, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try await sync.refreshBalances(walletID: "wallet")
            let before = try await db.pool.read { try BalanceRecord.fetchAll($0) }
            let wallets = try await db.pool.read { try WalletRecord.fetchAll($0) }
            let accounts = try await db.pool.read { try AccountRecord.fetchAll($0) }
            await feed.mode(mode)
            let outcomes = try await sync.refreshBalances(walletID: "wallet")
            guard case .partial(let error) = outcomes.first?.outcome else { XCTFail("Incomplete discovery must remain partial"); continue }
            let marker = error as? ReportedDiagnosticFailure
            XCTAssertNotNil(marker, "Record the known chain before the error reaches the wallet")
            XCTAssertEqual((marker?.underlying ?? error) as? BalanceRefreshError, .incomplete)
            OathDiagnostics.record(error, operation: "partial_wallet_duplicate")
            do { try AnkrSyncOutcome.requireCompleteBalances(outcomes); XCTFail() }
            catch { OathDiagnostics.record(error, operation: "partial_result_duplicate") }
            await sync.cancel()
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
            let after = try await reopened.pool.read { try BalanceRecord.fetchAll($0) }
            // A verified observation can update its timestamp, but not its exact quantity.
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: before.map { ($0.assetID, $0.amountAtomic) }),
                           Dictionary(uniqueKeysWithValues: after.map { ($0.assetID, $0.amountAtomic) }))
            let afterWallets = try await reopened.pool.read { try WalletRecord.fetchAll($0) }
            let afterAccounts = try await reopened.pool.read { try AccountRecord.fetchAll($0) }
            XCTAssertEqual(wallets, afterWallets); XCTAssertEqual(accounts, afterAccounts)
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events.filter({ $0.operation == "verified_balances" }).count >= 5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { ["verified_balances", "partial_wallet_duplicate", "partial_result_duplicate"].contains($0.operation) }
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(events.allSatisfy { $0.operation == "verified_balances" && $0.context["chain"] == "ethereum" && $0.context["stage"] == "inventory" && $0.operationID != nil && $0.privacyFiltered })
        XCTAssertEqual(Set(events.compactMap { $0.context["reason"] }), ["index_sync_pending", "index_sync_missing", "index_sync_stale", "metadata_conflict", "balance_unavailable"])
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(refreshOwner)); XCTAssertFalse(encoded.contains(refreshToken))
    }
    func testDecimalMismatchPreservesTokenTimestampAndVerifiedZeroClearsIt() async throws {
        let (db, sync, feed, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await sync.refreshBalances(walletID: "wallet")
        let before = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        await feed.advance(); await feed.mode("decimals")
        let partial = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertFalse(partial.allSatisfy(\.success))
        let unchanged = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        XCTAssertEqual(unchanged, before)
        await feed.mode(""); await feed.zero()
        let recovered = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertTrue(recovered.allSatisfy(\.success))
        let zero = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        XCTAssertEqual(zero?.amountAtomic, "0")
        XCTAssertGreaterThan(zero!.observedAt, before!.observedAt)
        await sync.cancel()
    }
    func testOlderSnapshotCannotReplaceNewerPostSendBalancesOrWriteAfterReset() async throws {
        let (db, sync, feed, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://primary.fixture.test")!], transport: feed)
        let ticket = try await db.beginAnkrSync(accountID: "account", stream: "balances")
        let older = try await client.portfolioBalances(owner: refreshOwner, assets: [])
        try await db.pool.write { database in
            try BalanceRecord(accountID: "account", assetID: "ethereum:native", networkID: "ethereum", amountAtomic: "7", observedAt: older.observedAt.timeIntervalSince1970 + 10, blockHeight: older.height + 1, source: "rpc").upsert(database)
        }
        try await db.commitVerifiedAnkrBalances(older, ticket: ticket, discoveryComplete: false, final: false)
        let retained = try await db.balance(accountID: "account", assetID: "ethereum:native")
        XCTAssertEqual(retained?.amountAtomic, "7")
        XCTAssertEqual(retained?.blockHeight, older.height + 1)
        _ = try await db.beginWalletReset()
        do { try await db.commitVerifiedAnkrBalances(older, ticket: ticket, discoveryComplete: true, final: true); XCTFail("Reset must reject late data") }
        catch { XCTAssertTrue(error is CancellationError) }
        await sync.cancel()
    }
}

extension AnkrVerifiedRefreshTests {
    func testHistoryFailureDoesNotChangeSuccessfulBalanceOutcome() async throws {
        let (db, sync, feed, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        await feed.mode("history")
        let results = try await sync.refresh(walletID: "wallet")
        XCTAssertTrue(results.contains { $0.stream != "balances" && !$0.success })
        try AnkrSyncOutcome.requireCompleteBalances(results)
        let snapshot = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == "native" }?.amountAtomic, "1000000000000000000")
        await sync.cancel()
    }
}

private actor VerifiedRefreshReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}

extension AnkrVerifiedRefreshTests {
    func testVerifiedDiscoveryRestartsRejectedCursorOnceWithoutMixingPages() async throws {
        let (db, sync, feed, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        await feed.cursorFailure("cursorOnce")
        let results = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertTrue(results.allSatisfy(\.success), "A rejected later cursor must restart discovery once")
        let calls = await feed.inventoryCalls
        XCTAssertEqual(calls, [nil, "fixture-expired-cursor", nil])
        let token = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        XCTAssertEqual(token?.amountAtomic, "2000000000000000000")
        let status = try await db.ankrStatus(accountID: "account").first { $0.stream == "balances" }
        XCTAssertEqual(status?.complete, true)
        await sync.cancel()
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
        let cached = try await reopened.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
        XCTAssertEqual(cached, token)
    }
    func testVerifiedDiscoveryReportsOnceAcrossPresentationAndPreservesCause() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_VERIFIED_CAPTURE"] == "1" else { throw XCTSkip("Dedicated diagnostics process") }
        let (db, sync, feed, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = VerifiedRefreshReports()
        OathDiagnostics.configure(file: folder.appendingPathComponent("reports.json"), transport: capture)
        await feed.mode("discovery")
        let result = try await sync.refreshBalances(walletID: "wallet")
        guard case .partial(let error) = result.first?.outcome else { return XCTFail("Verified native balance must remain partial") }
        XCTAssertEqual((error as? ReportedDiagnosticFailure)?.underlying as? AnkrError, .http(401))
        OathDiagnostics.record(error, operation: "verified_presentation_duplicate")
        do { try AnkrSyncOutcome.requireCompleteBalances(result); XCTFail() }
        catch { OathDiagnostics.record(error, operation: "verified_result_duplicate") }
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operation == "discovery" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { ["discovery", "verified_presentation_duplicate", "verified_result_duplicate"].contains($0.operation) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.context["chain"], "ethereum")
        XCTAssertNotNil(events.first?.operationID)
        let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(serialized.contains(refreshOwner))
        XCTAssertFalse(serialized.contains("fixture-expired-cursor"))
        let native = try await db.balance(accountID: "account", assetID: "ethereum:native")
        XCTAssertEqual(native?.amountAtomic, "1000000000000000000")
        await sync.cancel()
    }
}

extension AnkrVerifiedRefreshTests {
    func testVerifiedDiscoveryBoundsRestartAndNeverRestartsTransportOrAuthorization() async throws {
        for (mode, expectedCalls) in [("cursorAlways", 4), ("firstRejected", 1), ("cursorDenied", 2), ("cursorTransport", 2)] {
            let (db, sync, feed, folder) = try await fixture()
            _ = try await sync.refreshBalances(walletID: "wallet")
            let before = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
            await feed.advance(failToken: true)
            await feed.cursorFailure(mode)
            let results = try await sync.refreshBalances(walletID: "wallet")
            guard case .partial(let error) = results.first?.outcome else { return XCTFail(mode) }
            let cause = (error as? ReportedDiagnosticFailure)?.underlying as? AnkrError
            XCTAssertEqual(cause, mode == "cursorDenied" ? .http(401) : mode == "cursorTransport" ? .transport : .rpc(-32602), mode)
            let calls = await feed.inventoryCalls
            XCTAssertEqual(calls.count, expectedCalls, mode)
            let token = try await db.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
            XCTAssertEqual(token, before, "Failed discovery/contract reads cannot erase the saved amount or timestamp")
            let native = try await db.balance(accountID: "account", assetID: "ethereum:native")
            XCTAssertEqual(native?.amountAtomic, "3000000000000000000")
            let status = try await db.ankrStatus(accountID: "account").first { $0.stream == "balances" }
            XCTAssertEqual(status?.failure, "incompleteInventory")
            XCTAssertFalse(status?.complete ?? true)
            await sync.cancel()
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
            let offline = try await reopened.balance(accountID: "account", assetID: "ethereum:" + refreshToken)
            XCTAssertEqual(offline, before)
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

private actor LiveVerifiedCursorFeed: AnkrTransport {
    let http = AnkrHTTPTransport()
    var attempts = 0
    var injectedPage = false
    var rejectionCode: Int?
    var rejectionStatus: Int?
    var finalReferences = Set<String>()
    var delayedIndex = false
    func delayIndex() { delayedIndex = true }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let call = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        guard call["method"] as? String == "ankr_getAccountBalance" else { return try await http.sendPreservingTransportError(request) }
        attempts += 1
        if attempts == 1 { throw URLError(.networkConnectionLost) }
        if (call["params"] as? [String: Any])?["pageToken"] != nil {
            // This live balance endpoint currently ignores an invalid page token.
            // Inject rejection here; AnkrParameterLiveTests separately reproduces
            // the real -32602 response on an invalid history cursor.
            rejectionStatus = 200; rejectionCode = -32602
            return (Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"injected expired page token"}}"#.utf8), 200)
        }
        let (data, status) = try await http.sendPreservingTransportError(request)
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard status == 200, var result = envelope["result"] as? [String: Any],
              let assets = result["assets"] as? [[String: Any]] else { throw AnkrError.invalidResponse }
        if !injectedPage {
            injectedPage = true
            // The transport/cursor failures are injected. Every successful
            // discovery and pinned balance response comes from real HTTPS.
            result["assets"] = Array(assets.prefix(1))
            result["nextPageToken"] = "oath-invalid-public-cursor"
            envelope["result"] = result
            return (try JSONSerialization.data(withJSONObject: envelope), status)
        }
        finalReferences = Set(assets.map { $0["tokenType"] as? String == "NATIVE" ? "native" : ($0["contractAddress"] as! String).lowercased() })
        if delayedIndex {
            var state = result["syncStatus"] as? [String: Any] ?? [:]
            state["status"] = "syncing"
            result["syncStatus"] = state; envelope["result"] = result
            return (try JSONSerialization.data(withJSONObject: envelope), status)
        }
        return (data, status)
    }
}

extension AnkrVerifiedRefreshTests {
    func testLiveVerifiedRefreshRecoversConnectionLossAndRejectedCursorWithoutLosingData() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_VERIFIED_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only recovery") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try XCTUnwrap(config["AnkrAPIKey"])
        let (db, unused, _, folder) = try await fixture(.flare)
        defer { try? FileManager.default.removeItem(at: folder) }
        await unused.cancel()
        let owner = "0x85d134f68c3c564bb935479490e5c8df5f4f1124"
        try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id='account'", arguments: [owner]) }
        let feed = LiveVerifiedCursorFeed()
        let endpoint = URL(string: "https://rpc.ankr.com/flare")!.appendingPathComponent(key)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey: key, transport: feed), balanceClient: { _ in
            try EVMSendClient(network: .flare, endpoints: [endpoint])
        })
        let results = try await sync.refreshBalances(walletID: "wallet")
        for result in results where !result.success {
            if let marker = result.failure as? ReportedDiagnosticFailure { print("LIVE_ANKR recovery failure type=\(type(of: marker.underlying))") }
            else if let error = result.failure { print("LIVE_ANKR recovery failure type=\(type(of: error))") }
        }
        let status = await feed.rejectionStatus
        print("LIVE_ANKR cursor response HTTP=\(status ?? -1)")
        XCTAssertTrue(results.allSatisfy(\.success), "A current RPC-verified inventory must recover both failure triggers")
        let attempts = await feed.attempts, rejection = await feed.rejectionCode
        XCTAssertEqual(attempts, 4, "Connection loss, first page, injected rejected cursor, fresh discovery")
        XCTAssertEqual(rejection, -32602)
        let saved = try await db.snapshot(walletID: "wallet", currency: "USD")
        let refs = await feed.finalReferences
        XCTAssertEqual(Set(saved.holdings.map(\.reference)), refs)
        XCTAssertGreaterThan(refs.count, 1)
        let independent = AnkrHTTPTransport()
        func rpc(_ method: String, _ params: [Any]) async throws -> Any {
            var request = URLRequest(url: URL(string: "https://flare-api.flare.network/ext/C/rpc")!)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let (data, status) = try await independent.send(request)
            XCTAssertEqual(status, 200)
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertNil(value["error"])
            return try XCTUnwrap(value["result"])
        }
        let chain = try await rpc("eth_chainId", []) as? String
        XCTAssertEqual(chain, "0xe")
        func assertPinnedBalances(_ snapshot: WalletSnapshot) async throws {
            let nativeRecord = try await db.balance(accountID: "account", assetID: "flare:native")
            let native = try XCTUnwrap(nativeRecord)
            let height = "0x" + String(try XCTUnwrap(native.blockHeight), radix: 16)
            for holding in snapshot.holdings {
                let params: [Any] = holding.reference == "native" ? [owner, height] : [["to": holding.reference, "data": "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)], height]
                let raw = try await rpc(holding.reference == "native" ? "eth_getBalance" : "eth_call", params) as? String
                XCTAssertEqual(try AnkrQuantity.decimal(XCTUnwrap(raw)), holding.amountAtomic)
            }
        }
        try await assertPinnedBalances(saved)
        // Keep every price, asset and RPC quantity real; force only the index
        // completeness flag to exercise partial publication on a live account.
        await feed.delayIndex()
        let partial = try await sync.refreshBalances(walletID: "wallet")
        guard case .partial(let error) = partial.first?.outcome else { XCTFail("Delayed index must remain partial"); return }
        let marker = try XCTUnwrap(error as? ReportedDiagnosticFailure)
        XCTAssertEqual(marker.underlying as? BalanceRefreshError, .incomplete)
        let retained = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(Set(retained.holdings.map(\.reference)), refs)
        try await assertPinnedBalances(retained)
        await sync.cancel()
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
        let cached = try await reopened.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(cached.holdings, retained.holdings)
        print("LIVE_ANKR_VERIFIED injected connection loss and cursor -32602 recovered in 4 requests; injected index delay remains partial; all \(refs.count) balances match official Flare at each snapshot block; exact holdings preserved after reopen")
    }
}


extension AnkrVerifiedRefreshTests {
    func testNodeFailuresRetainChainAndAreNotReportedAgainByWalletCallers() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_NODE_CAPTURE"] == "1" else { throw XCTSkip("Dedicated node failure diagnostics process") }
        let capture = VerifiedRefreshReports()
        let reportFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: reportFile) }
        OathDiagnostics.configure(file: reportFile, transport: capture)
        for mode in ["nodeRPC", "nodeTransport"] {
            let (db, sync, feed, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try await sync.refreshBalances(walletID: "wallet")
            let before = try await db.pool.read { try BalanceRecord.fetchAll($0) }
            let wallets = try await db.pool.read { try WalletRecord.fetchAll($0) }
            let accounts = try await db.pool.read { try AccountRecord.fetchAll($0) }
            await feed.mode(mode)
            let outcomes = try await sync.refreshBalances(walletID: "wallet")
            guard case .failed(let error) = outcomes.first?.outcome else { XCTFail("Node failure cannot become a complete or empty snapshot"); continue }
            let marker = error as? ReportedDiagnosticFailure
            XCTAssertNotNil(marker, "Owning sync boundary must mark the error before shared callers propagate it")
            let cause = marker?.underlying ?? error
            if mode == "nodeRPC" { XCTAssertEqual(cause as? EVMSendError, .rpc(-32602)) }
            else { XCTAssertEqual(cause as? AnkrError, .transport) }
            OathDiagnostics.record(error, operation: "node_wallet_duplicate")
            do { try AnkrSyncOutcome.requireCompleteBalances(outcomes); XCTFail() }
            catch { OathDiagnostics.record(error, operation: "node_result_duplicate") }
            await sync.cancel()
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
            let after = try await reopened.pool.read { try BalanceRecord.fetchAll($0) }
            let afterWallets = try await reopened.pool.read { try WalletRecord.fetchAll($0) }
            let afterAccounts = try await reopened.pool.read { try AccountRecord.fetchAll($0) }
            XCTAssertEqual(before, after); XCTAssertEqual(wallets, afterWallets); XCTAssertEqual(accounts, afterAccounts)
        }
        for _ in 0..<100 {
            if await capture.events.filter({ $0.operation == "verified_balances" }).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { ["verified_balances", "node_wallet_duplicate", "node_result_duplicate"].contains($0.operation) }
        XCTAssertEqual(events.count, 2, "One sync report per actual failure, no presentation/result copies")
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "ethereum" && $0.operationID != nil && $0.privacyFiltered })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(refreshOwner)); XCTAssertFalse(encoded.contains(refreshToken))
    }
}
