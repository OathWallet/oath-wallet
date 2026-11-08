import XCTest
import OathDatabase
import OathAnkr
@testable import OathMarketData

@MainActor final class GnosisNativePriceRecoveryTests: XCTestCase {
    private let asset = MarketAsset(id: "gnosis:native", networkID: "gnosis", reference: "native", decimals: 18)

    private func database(_ url: URL) async throws -> OathDatabase {
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "gnosis", name: "Gnosis", family: "evm", symbol: "XDAI", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)],
                          assets: [.init(id: asset.id, networkID: "gnosis", reference: "native", name: "xDai", symbol: "XDAI", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "watch", name: "Public fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "watch", networkID: "gnosis", address: "0x0000000000000000000000000000000000000001", derivationPath: "")])
        try await db.saveBalances([.init(accountID: "account", assetID: asset.id, networkID: "gnosis", amountAtomic: "1250000000000000000", observedAt: 100, source: "fixture")])
        return db
    }

    func testNativeOutageUsesCanonicalWrappedQuoteAndPreservesCacheAfterReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let db = try await database(url)
        let now = Date(timeIntervalSince1970: 2000)
        let transport = GnosisPriceTransport()
        let service = MarketDataService(database: db, transport: transport, now: { now })
        let quote = try await service.quote(for: asset)
        XCTAssertEqual(quote.value.code, "XDAI")
        XCTAssertEqual(quote.value.usd, "0.9977")
        XCTAssertEqual(quote.fetchedAt, now)
        for _ in 0..<20 { _ = try await service.quote(for: asset) }
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.host == "api.geckoterminal.com" }.count, 1)
        XCTAssertFalse(calls.contains { $0.host == "api.coinbase.com" })
        let saved = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(saved?.source, "GeckoTerminal (WXDAI)")
        await transport.setOffline()
        let reopened = try await OathDatabase.open(at: url)
        let offline = MarketDataService(database: reopened, transport: transport, now: { now.addingTimeInterval(3600) })
        let cached = try await offline.quote(for: asset, force: true)
        XCTAssertEqual(cached.value.usd, quote.value.usd)
        XCTAssertEqual(cached.fetchedAt, quote.fetchedAt)
        let retained = try await reopened.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(retained?.value, saved?.value)
        XCTAssertEqual(retained?.observedAt, saved?.observedAt)
        let holdings = try await reopened.snapshot(walletID: "watch", currency: "USD").holdings
        XCTAssertEqual(holdings.count, 1)
        XCTAssertEqual(holdings.first?.amountAtomic, "1250000000000000000")
        XCTAssertEqual(holdings.first?.balanceObservedAt, 100)
    }

    func testRejectsWrongIdentityInvalidPricesAndIlliquidQuotes() throws {
        let base = try XCTUnwrap(try JSONSerialization.jsonObject(with: GnosisPriceTransport.payload) as? [String: Any])
        let original = try XCTUnwrap(base["data"] as? [String: Any])
        let attributes = try XCTUnwrap(original["attributes"] as? [String: Any])
        for (key, value) in [("address", "0x0000000000000000000000000000000000000001"),
                             ("price_usd", "0"), ("price_usd", "-1"), ("price_usd", "NaN"),
                             ("total_reserve_in_usd", "9999")] {
            var changed = attributes; changed[key] = value
            var token = original; token["attributes"] = changed
            let data = try JSONSerialization.data(withJSONObject: ["data": token])
            XCTAssertThrowsError(try GnosisNativePrice.decode(data, for: asset, fetchedAt: .now), key)
        }
        var token = original; token["id"] = "eth_" + GnosisNativePrice.wrapped.reference
        XCTAssertThrowsError(try GnosisNativePrice.decode(JSONSerialization.data(withJSONObject: ["data": token]), for: asset, fetchedAt: .now))
        var changed = attributes; changed["decimals"] = 6
        token = original; token["attributes"] = changed
        XCTAssertThrowsError(try GnosisNativePrice.decode(JSONSerialization.data(withJSONObject: ["data": token]), for: asset, fetchedAt: .now))
        changed = attributes; changed["volume_usd"] = ["h24": "999"]
        token = original; token["attributes"] = changed
        XCTAssertThrowsError(try GnosisNativePrice.decode(JSONSerialization.data(withJSONObject: ["data": token]), for: asset, fetchedAt: .now))
        for invalid in [GnosisNativePrice.wrapped,
                        MarketAsset(id: "gnosis:native", networkID: "gnosis", reference: "native", decimals: 6),
                        MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)] {
            XCTAssertNil(GnosisNativePrice.request(for: invalid))
        }
    }

    func testLiveGnosisFallbackMatchesNativeQuoteAndSurvivesOfflineReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_GNOSIS_PRICE_LIVE"] == "1" else { throw XCTSkip("Opt-in public Gnosis market reads") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let db = try await database(url)
        let service = MarketDataService(database: db, transport: GnosisPriceLiveTransport())
        let quote = try await service.quote(for: asset)
        print("LIVE_GNOSIS fallback stage passed; checking independent native feed")
        let nativeRequest = try XCTUnwrap(ContractPriceRequest.requests(for: asset).first { $0.provider == .gecko })
        let nativeData = try await URLSessionMarketTransport().data(from: nativeRequest.url)
        let native = try ContractPriceDecoding.decode(nativeData, request: nativeRequest, asset: asset, now: .now)
        let actual = try XCTUnwrap(quote.value.decimal), comparison = try XCTUnwrap(native.quote.decimal)
        XCTAssertLessThan(abs(actual - comparison) / comparison, Decimal(string: "0.03")!)
        let saved = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(saved?.source, "GeckoTerminal (WXDAI)")
        let offline = GnosisPriceTransport(); await offline.setOffline()
        let reopened = try await OathDatabase.open(at: url)
        let cached = try await MarketDataService(database: reopened, transport: offline).quote(for: asset, force: true)
        XCTAssertEqual(cached.value.usd, quote.value.usd)
        XCTAssertEqual(cached.fetchedAt, quote.fetchedAt)
        let holdings = try await reopened.snapshot(walletID: "watch", currency: "USD").holdings
        XCTAssertEqual(holdings.first?.amountAtomic, "1250000000000000000")
        print("LIVE_GNOSIS native=\(native.quote.usd) wrapped=\(quote.value.usd) persisted=true offlineReopen=true balancePreserved=true")
    }
}

private actor GnosisPriceTransport: MarketTransport {
    private var offline = false
    private(set) var calls: [URL] = []
    static let payload = Data(#"{"data":{"id":"xdai_0xe91d153e0b41518a2ce8dd3d7944fa863463a97d","attributes":{"address":"0xe91d153e0b41518a2ce8dd3d7944fa863463a97d","decimals":18,"price_usd":"0.9977","total_reserve_in_usd":"700000","volume_usd":{"h24":"300000"}}}}"#.utf8)
    func setOffline() { offline = true }
    func data(from url: URL) async throws -> Data {
        calls.append(url)
        guard !offline, url.absoluteString == "https://api.geckoterminal.com/api/v2/networks/xdai/tokens/0xe91d153e0b41518a2ce8dd3d7944fa863463a97d" else { throw MarketDataError.unavailable }
        return Self.payload
    }
}

private struct GnosisPriceLiveTransport: MarketTransport {
    let base = URLSessionMarketTransport()
    func data(from url: URL) async throws -> Data {
        guard url == GnosisNativePrice.request(for: .init(id: "gnosis:native", networkID: "gnosis", reference: "native", decimals: 18))?.url else { throw MarketDataError.unavailable }
        return try await base.data(from: url)
    }
}

private actor GnosisLifiOnlyTransport: MarketTransport {
    var offline = false
    var calls = 0
    let live: Bool
    let base = URLSessionMarketTransport()
    init(live: Bool = false) { self.live = live }
    static let payload = Data(#"{"chainId":100,"address":"0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d","decimals":18,"name":"Wrapped xDAI","symbol":"WXDAI","priceUSD":"0.91"}"#.utf8)
    func setOffline() { offline = true }
    func data(from url: URL) async throws -> Data {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        guard url == LifiTokenMetadata.url(network: "gnosis", reference: GnosisNativePrice.wrapped.reference) else { throw MarketDataError.rateLimited }
        calls += 1
        return live ? try await base.data(from: url) : Self.payload
    }
}

extension GnosisNativePriceRecoveryTests {
    func testLifiWrappedFallbackSurvivesOtherProviderOutageWithoutGuessingPeg() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let db = try await database(url), now = Date(timeIntervalSince1970: 2000)
        let transport = GnosisLifiOnlyTransport()
        let service = MarketDataService(database: db, transport: transport, now: { now })
        let target = asset
        async let first = service.quote(for: target)
        async let second = service.quote(for: target)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.value.usd, "0.91"); XCTAssertEqual(a.value.usd, b.value.usd)
        XCTAssertEqual(a.fetchedAt, now)
        for _ in 0..<10 { _ = try await service.quote(for: asset) }
        let count = await transport.calls; XCTAssertEqual(count, 1)
        let saved = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(saved?.source, "LI.FI (WXDAI)")
        await transport.setOffline()
        let reopened = try await OathDatabase.open(at: url)
        let offline = MarketDataService(database: reopened, transport: transport, now: { now.addingTimeInterval(3600) })
        let retained = try await offline.quote(for: asset, force: true)
        XCTAssertEqual(retained.value.usd, a.value.usd); XCTAssertEqual(retained.fetchedAt, a.fetchedAt)
        let holdings = try await reopened.snapshot(walletID: "watch", currency: "USD").holdings
        XCTAssertEqual(holdings.first?.amountAtomic, "1250000000000000000")
        XCTAssertEqual(holdings.first?.balanceObservedAt, 100)
    }

    func testLiveLifiGnosisFallbackMatchesWrappedMarketAndPreservesWallet() async throws {
        guard ProcessInfo.processInfo.environment["OATH_GNOSIS_LIFI_LIVE"] == "1" else { throw XCTSkip("Opt-in public quote reads") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite"), db = try await database(url)
        let transport = GnosisLifiOnlyTransport(live: true)
        let quote = try await MarketDataService(database: db, transport: transport).quote(for: asset)
        let request = try XCTUnwrap(GnosisNativePrice.request(for: asset))
        let data = try await URLSessionMarketTransport().data(from: request.url)
        let comparison = try GnosisNativePrice.decode(data, for: asset, fetchedAt: .now)
        let actual = try XCTUnwrap(quote.value.decimal), expected = try XCTUnwrap(comparison.quote.decimal)
        XCTAssertLessThan(abs(actual - expected) / expected, Decimal(string: "0.03")!)
        await transport.setOffline()
        let reopened = try await OathDatabase.open(at: url)
        let cached = try await MarketDataService(database: reopened, transport: transport).quote(for: asset, force: true)
        XCTAssertEqual(cached.value.usd, quote.value.usd); XCTAssertEqual(cached.fetchedAt, quote.fetchedAt)
        let holdings = try await reopened.snapshot(walletID: "watch", currency: "USD").holdings
        XCTAssertEqual(holdings.first?.amountAtomic, "1250000000000000000")
        print("LIVE_GNOSIS_LIFI quote=\(quote.value.usd) comparison=\(comparison.quote.usd) offlineReopen=true balancePreserved=true")
    }
}

extension GnosisNativePriceRecoveryTests {
    func testLifiWrappedIdentityAndPriceValidation() throws {
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: GnosisLifiOnlyTransport.payload) as? [String: Any])
        for (key, bad) in [("chainId", 1 as Any), ("address", "0x0000000000000000000000000000000000000001"),
                           ("decimals", 6), ("priceUSD", "0"), ("priceUSD", "-1"), ("priceUSD", "NaN"), ("priceUSD", NSNull())] {
            var value = original; value[key] = bad
            XCTAssertThrowsError(try GnosisNativePrice.decodeLifi(JSONSerialization.data(withJSONObject: value), for: asset, fetchedAt: .now), key)
        }
        for invalid in [GnosisNativePrice.wrapped,
                        MarketAsset(id: "gnosis:native", networkID: "gnosis", reference: "native", decimals: 6),
                        MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)] {
            XCTAssertNil(GnosisNativePrice.lifiURL(for: invalid))
            XCTAssertThrowsError(try GnosisNativePrice.decodeLifi(GnosisLifiOnlyTransport.payload, for: invalid, fetchedAt: .now))
        }
        XCTAssertTrue(PublicMarketRequests.accepts(URLRequest(url: try XCTUnwrap(GnosisNativePrice.lifiURL(for: asset)))))
    }
}
