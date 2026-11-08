import XCTest
import OathAnkr
import OathDatabase
@testable import OathMarketData

/// Real database and inventory projections; only the public HTTP boundary is
/// replaced in deterministic tests. No simulator, keys or real account data.
@MainActor final class NativeQuoteRefreshTests: XCTestCase {
    private let networks = ["telos", "xlayer"]
    private let address = "0x1111111111111111111111111111111111111111"

    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-quotes-" + UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: networks.enumerated().map { index, network in
            NetworkRecord(id: network, name: network, family: "evm", symbol: MarketIdentity.native[network]!.coinbase,
                decimals: 18, derivationPath: "fixture", logo: "", sortOrder: index)
        }, assets: networks.map { network in
            // Even an edited display symbol must not select a different coin.
            AssetRecord(id: network + ":native", networkID: network, reference: "native", name: network, symbol: "EDITED", decimals: 18)
        })
        try await db.importWalletIfNeeded(.init(id: "fixture", name: "fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: networks.map { .init(id: "fixture:" + $0, walletID: "fixture", networkID: $0, address: address, derivationPath: "fixture") })
        return (db, url)
    }

    private func inventory(_ db: OathDatabase, funded: Bool = false, price: String = "") async throws {
        for network in networks {
            let assets: [[String: Any]] = funded ? [[
                "blockchain": network, "tokenName": network, "tokenSymbol": MarketIdentity.native[network]!.coinbase,
                "tokenDecimals": 18, "tokenType": "NATIVE", "contractAddress": "0x" + String(repeating: "0", count: 40),
                "holderAddress": address, "balance": "1", "balanceRawInteger": "1000000000000000000",
                "balanceUsd": "", "tokenPrice": price
            ]] : []
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": [
                "assets": assets, "totalBalanceUsd": "0", "totalCount": assets.count
            ]])
            let client = try AnkrClient(apiKey: "fixture", transport: NativeInventoryTransport(data: data))
            let page = try await client.balances(chain: AnkrChain(networkID: network)!, address: address)
            let ticket = try await db.beginAnkrSync(accountID: "fixture:" + network, stream: "balances")
            try await db.commitAnkrBalances([page], ticket: ticket)
        }
    }

    func testEmptyInventoryStillPublishesBothNativePricesToHome() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await inventory(db)
        let before = try await db.snapshot(walletID: "fixture", currency: "USD")
        XCTAssertEqual(before.holdings.count, 2)
        XCTAssertTrue(before.holdings.allSatisfy { $0.price == nil })
        let now = Date()
        let transport = NativeQuoteTransport(date: now.addingTimeInterval(-120))
        let service = MarketDataService(database: db, transport: transport, now: { now })
        await service.refreshNativeQuotes(networkIDs: networks + networks + ["unsupported", "ethereum"])
        let snapshot = try await db.snapshot(walletID: "fixture", currency: "USD")
        for holding in snapshot.holdings {
            XCTAssertEqual(holding.price, holding.networkID == "telos" ? "0.0146" : "105.17")
            XCTAssertEqual(holding.amountAtomic, "0")
        }
        let urls = await transport.urls
        XCTAssertTrue(urls.allSatisfy { !$0.absoluteString.contains(address) && !$0.absoluteString.contains("EDITED") })
        XCTAssertFalse(urls.contains { $0.absoluteString.contains("ethereum") }, "Do not invent an asset for an unseeded network")
    }

    func testUnpricedFundedInventoryUsesQuotesAndLaterMissingPriceDoesNotEraseThem() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await inventory(db, funded: true)
        let service = MarketDataService(database: db, transport: NativeQuoteTransport(date: Date().addingTimeInterval(-120)))
        await service.refreshNativeQuotes(networkIDs: networks)
        // Ankr may report either an empty price or zero for missing valuation.
        // A later inventory must not replace a validated market quote with zero.
        for missing in ["", "0", "0.000"] {
            try await inventory(db, funded: true, price: missing)
            let snapshot = try await db.snapshot(walletID: "fixture", currency: "USD")
            XCTAssertEqual(snapshot.totalFiat, Decimal(string: "105.1846"))
            XCTAssertTrue(snapshot.holdings.allSatisfy { $0.price != nil && $0.price != "0" && $0.price != "0.000" })
        }
    }

    func testRepeatedAndConcurrentRefreshesSharePricesWithAssetDetails() async throws {
        let networks = self.networks
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        let transport = NativeQuoteTransport(date: now.addingTimeInterval(-120))
        let service = MarketDataService(database: db, transport: transport, now: { now })
        async let home: Void = service.refreshNativeQuotes(networkIDs: networks + networks)
        async let other: Void = service.refreshNativeQuotes(networkIDs: networks)
        async let detail = service.quote(for: MarketAsset(id: "telos:native", networkID: "telos", reference: "native", decimals: 18))
        _ = try await (home, other, detail)
        let before = await transport.urls.count
        for _ in 0..<5 { await service.refreshNativeQuotes(networkIDs: networks) }
        let after = await transport.urls.count
        XCTAssertEqual(before, after)
        let requests = await transport.urls.filter { $0.host == "coins.llama.fi" }
        XCTAssertEqual(requests.count, 2, "One request per native identity across concurrent consumers")
        for network in networks {
            let price = try await db.latestPrice(assetID: network + ":native", currency: "USD")
            XCTAssertEqual(try XCTUnwrap(price).observedAt, floor(now.addingTimeInterval(-120).timeIntervalSince1970))
        }
    }

    func testOfflineReopenPreservesQuoteAndItsObservationTime() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        await MarketDataService(database: db, transport: NativeQuoteTransport(date: now)).refreshNativeQuotes(networkIDs: networks)
        let reopened = try await OathDatabase.open(at: url)
        let offline = NativeQuoteTransport(date: now, offline: true)
        await MarketDataService(database: reopened, transport: offline, now: { now.addingTimeInterval(3600) }).refreshNativeQuotes(networkIDs: networks)
        for network in networks {
            let price = try await reopened.latestPrice(assetID: network + ":native", currency: "USD")
            XCTAssertGreaterThan(Decimal(string: try XCTUnwrap(price).value) ?? 0, 0)
            XCTAssertEqual(price?.observedAt, floor(now.timeIntervalSince1970))
        }
    }

    func testUnavailableCoinDoesNotCancelOtherCoinAndDoesNotInventZero() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = NativeQuoteTransport(date: Date(), unavailableTelos: true)
        await MarketDataService(database: db, transport: transport).refreshNativeQuotes(networkIDs: networks)
        let telos = try await db.latestPrice(assetID: "telos:native", currency: "USD")
        let xlayer = try await db.latestPrice(assetID: "xlayer:native", currency: "USD")
        XCTAssertNil(telos)
        XCTAssertEqual(xlayer?.value, "105.17")
    }

    func testWrongIdentityStaleAndInvalidQuotesRemainRejected() throws {
        let now = Date(timeIntervalSince1970: 2000)
        for network in networks {
            let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: 18)
            let request = try XCTUnwrap(ContractPriceRequest.requests(for: asset).first { $0.provider == .llama })
            for (key, price, time, confidence) in [
                ("coingecko:ethereum", "100", 2000, 0.99),
                (request.key, "100", 1000, 0.99),
                (request.key, "100", 2200, 0.99),
                (request.key, "0", 2000, 0.99),
                (request.key, "100", 2000, 0.5)
            ] {
                let data = try JSONSerialization.data(withJSONObject: ["coins": [key: ["price": price, "timestamp": time, "confidence": confidence]]])
                XCTAssertThrowsError(try ContractPriceDecoding.decode(data, request: request, asset: asset, now: now))
            }
        }
    }

    func testNativeRefreshDoesNotAssignCoinPriceToSameSymbolToken() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let token = "0x2222222222222222222222222222222222222222"
        try await db.saveAsset(.init(id: "telos:" + token, networkID: "telos", reference: token, name: "Telos", symbol: "TLOS", decimals: 18))
        await MarketDataService(database: db, transport: NativeQuoteTransport(date: Date())).refreshNativeQuotes(networkIDs: networks)
        let price = try await db.latestPrice(assetID: "telos:" + token, currency: "USD")
        XCTAssertNil(price)
    }

    func testCancelledRefreshDoesNotStartRequests() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = NativeQuoteTransport(date: Date())
        let service = MarketDataService(database: db, transport: transport)
        let task = Task { await service.refreshNativeQuotes(networkIDs: networks) }
        task.cancel()
        await task.value
        let requests = await transport.urls
        XCTAssertTrue(requests.isEmpty)
    }

    func testLiveNativeRecoveryPersistsToHomeWithPrimaryProvidersBlocked() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TELOS_XLAYER_LIVE"] == "1" else { throw XCTSkip("Opt-in anonymous public price check") }
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await inventory(db)
        await MarketDataService(database: db, transport: NativeLiveRecoveryTransport()).refreshNativeQuotes(networkIDs: networks)
        let snapshot = try await db.snapshot(walletID: "fixture", currency: "USD")
        for holding in snapshot.holdings {
            XCTAssertGreaterThan(try XCTUnwrap(holding.price.flatMap { Decimal(string: $0) }), 0)
            let saved = try await db.latestPrice(assetID: holding.assetID, currency: "USD")
            let price = try XCTUnwrap(saved)
            XCTAssertEqual(price.source, "CoinPaprika")
            XCTAssertLessThan(Date().timeIntervalSince1970 - price.observedAt, 900)
            print("LIVE_NATIVE_QUOTE network=\(holding.networkID) usd=\(price.value) source=\(price.source) persisted=true zeroBalance=true")
        }
    }
}

private struct NativeInventoryTransport: AnkrTransport {
    let data: Data
    func send(_ request: URLRequest) async throws -> (Data, Int) { (data, 200) }
}

private actor NativeQuoteTransport: MarketTransport {
    let date: Date
    let offline: Bool
    let unavailableTelos: Bool
    private(set) var urls: [URL] = []
    init(date: Date, offline: Bool = false, unavailableTelos: Bool = false) {
        self.date = date; self.offline = offline; self.unavailableTelos = unavailableTelos
    }
    func data(from url: URL) async throws -> Data {
        urls.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        guard url.host == "coins.llama.fi" else { throw MarketDataError.notListed }
        let key = url.lastPathComponent
        guard ["coingecko:telos", "coingecko:okb"].contains(key) else { throw MarketDataError.notListed }
        if unavailableTelos, key == "coingecko:telos" { return Data(#"{"coins":{}}"#.utf8) }
        try await Task.sleep(for: .milliseconds(20))
        return try JSONSerialization.data(withJSONObject: ["coins": [key: [
            "price": key == "coingecko:telos" ? "0.0146" : "105.17",
            "timestamp": floor(date.timeIntervalSince1970), "confidence": 0.99
        ]]])
    }
}

private struct NativeLiveRecoveryTransport: MarketTransport {
    let base = URLSessionMarketTransport()
    func data(from url: URL) async throws -> Data {
        if url.host == "api.coingecko.com" || url.host == "coins.llama.fi" { throw MarketDataError.rateLimited }
        return try await base.data(from: url)
    }
}
