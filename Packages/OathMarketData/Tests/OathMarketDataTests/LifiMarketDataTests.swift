import XCTest
import OathAnkr
import OathDatabase
@testable import OathMarketData

private let lifiUSDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
private func lifiResponse(price: String? = "1.002", status: String? = "verified", chain: UInt64 = 1,
                          address: String = lifiUSDC, decimals: Int = 6) throws -> Data {
    var row: [String: Any] = ["chainId": chain, "address": address, "decimals": decimals,
                            "name": "USD Coin", "symbol": "USDC", "logoURI": "https://example.org/usdc.png"]
    row["priceUSD"] = price; row["verificationStatus"] = status
    return try JSONSerialization.data(withJSONObject: row)
}

private actor LifiFeed: MarketTransport {
    let response: Data
    let error: URLError?
    let delay: Duration
    var hosts: [String] = []
    init(_ response: Data, error: URLError? = nil, delay: Duration = .zero) {
        self.response = response; self.error = error; self.delay = delay
    }
    func data(from url: URL) async throws -> Data {
        hosts.append(url.host!)
        if url.host == "li.quest" {
            try await Task.sleep(for: delay)
            if let error { throw error }
            return response
        }
        if url.host == "api.geckoterminal.com" {
            return Data("{\"data\":{\"id\":\"eth_\(lifiUSDC)\",\"attributes\":{\"address\":\"\(lifiUSDC)\",\"decimals\":6,\"price_usd\":\"0.99\",\"total_reserve_in_usd\":\"100000\"}}}".utf8)
        }
        throw MarketDataError.notListed
    }
}

@MainActor final class LifiMarketDataTests: XCTestCase {
    private let asset = MarketAsset(id: "ethereum:" + lifiUSDC, networkID: "ethereum", reference: lifiUSDC, decimals: 6)
    private func fixture() async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lifi-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18,
            derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [.init(id: asset.id, networkID: asset.networkID,
            reference: asset.reference, name: "Old name", symbol: "EDITED", decimals: 6)])
        try await db.importWalletIfNeeded(.init(id: "fixture", name: "fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "fixture", networkID: "ethereum",
                address: "0x1111111111111111111111111111111111111111", derivationPath: "fixture")])
        try await db.trackAsset(.init(id: asset.id, networkID: asset.networkID,
            reference: asset.reference, name: "Old name", symbol: "EDITED", decimals: 6), walletID: "fixture")
        return (db, folder)
    }

    func testEveryVerificationStateAndUnknownValuesRemainDistinct() throws {
        for (raw, expected) in [("verified", LifiVerificationStatus.verified), ("unverified", .unverified),
                                ("flagged", .flagged), ("new-provider-status", .unknown), ("VERIFIED", .unknown)] {
            let value = try LifiTokenMetadata.decode(lifiResponse(status: raw), network: "ethereum", reference: lifiUSDC, decimals: 6)
            XCTAssertEqual(value.status, expected)
            XCTAssertEqual(value.isVerified, expected == .verified)
            XCTAssertEqual(try JSONDecoder().decode(LifiTokenMetadata.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertEqual(try LifiTokenMetadata.decode(lifiResponse(status: nil), network: "ethereum", reference: lifiUSDC, decimals: 6).status, .unknown)
        XCTAssertEqual(Set(LifiVerificationStatus.allCases), [.verified, .unverified, .flagged, .unknown])
    }

    func testExactNetworkContractAndPrecisionRequired() throws {
        for data in [try lifiResponse(chain: 8453), try lifiResponse(address: "0x0000000000000000000000000000000000000001"),
                     try lifiResponse(decimals: 18), try lifiResponse(decimals: -1)] {
            XCTAssertThrowsError(try LifiTokenMetadata.decode(data, network: "ethereum", reference: lifiUSDC, decimals: 6))
        }
        XCTAssertNil(LifiTokenMetadata.url(network: "stellar", reference: "USDC"))
        XCTAssertNil(LifiTokenMetadata.url(network: "ethereum", reference: "USDC"))
        XCTAssertNil(LifiTokenMetadata.url(network: "cronos", reference: lifiUSDC))
        XCTAssertNil(LifiTokenMetadata.url(network: "ethereum", reference: "native"))
    }

    func testInvalidPricesNeverBecomeZeroOrInvalidateVerification() throws {
        for price: String? in [nil, "0", "-1", "NaN", "Infinity", "1,23", "1e999", "true"] {
            let value = try LifiTokenMetadata.decode(lifiResponse(price: price, status: "flagged"), network: "ethereum", reference: lifiUSDC, decimals: 6)
            XCTAssertNil(value.priceUSD)
            XCTAssertEqual(value.status, .flagged)
        }
    }

    func testPrimaryPriceAndMetadataShareOneRequestAndPersistAcrossReopen() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(), feed = LifiFeed(try lifiResponse(), delay: .milliseconds(40))
        let service = MarketDataService(database: db, transport: feed, now: { now }, tokenCatalog: nil)
        let asset = self.asset
        async let price = service.quote(for: asset)
        async let info = service.information(for: asset)
        async let metadata = service.lifiToken(for: asset)
        let results = try await (price, info, metadata)
        XCTAssertEqual(results.0.value.usd, "1.002")
        XCTAssertEqual(results.1.value.name, "USD Coin")
        XCTAssertEqual(results.1.value.imageURL, "https://example.org/usdc.png")
        XCTAssertEqual(results.2.value.status, .verified)
        let hosts = await feed.hosts; XCTAssertEqual(hosts, ["li.quest"])
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let offline = LifiFeed(Data(), error: URLError(.notConnectedToInternet))
        let restored = MarketDataService(database: reopened, transport: offline, now: { now.addingTimeInterval(30) }, tokenCatalog: nil)
        let saved = try await restored.quote(for: asset)
        XCTAssertEqual(saved.value.usd, "1.002"); XCTAssertEqual(saved.fetchedAt, results.0.fetchedAt)
        let savedInfo = try await restored.cachedInformation(for: asset)
        XCTAssertEqual(savedInfo?.value.imageURL, results.1.value.imageURL)
        let offlineCalls = await offline.hosts; XCTAssertTrue(offlineCalls.isEmpty)
    }

    func testOutageAndAbsentPriceUseExistingFallbacksWithoutLosingStatus() async throws {
        for fail in [false, true] {
            let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
            let feed = LifiFeed(try lifiResponse(price: nil, status: "unverified"), error: fail ? URLError(.timedOut) : nil)
            let service = MarketDataService(database: db, transport: feed, tokenCatalog: nil)
            let quote = try await service.quote(for: asset)
            XCTAssertEqual(quote.value.usd, "0.99")
            let hosts = await feed.hosts
            XCTAssertEqual(hosts.first, "li.quest"); XCTAssertTrue(hosts.contains("api.geckoterminal.com"))
            let metadata = try await service.cachedLifiToken(for: asset)
            XCTAssertEqual(metadata?.value.status, fail ? nil : .unverified)
        }
    }

    func testExpiredQuoteRefetchesAndNewStatusReplacesVerified() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let old = Date().addingTimeInterval(-120)
        _ = try await MarketDataService(database: db, transport: LifiFeed(try lifiResponse()), now: { old }, tokenCatalog: nil).quote(for: asset)
        let feed = LifiFeed(try lifiResponse(price: "1.01", status: "flagged"))
        let service = MarketDataService(database: db, transport: feed, tokenCatalog: nil)
        let quote = try await service.quote(for: asset)
        XCTAssertEqual(quote.value.usd, "1.01")
        let metadata = try await service.cachedLifiToken(for: asset)
        XCTAssertEqual(metadata?.value.status, .flagged)
        let calls = await feed.hosts; XCTAssertEqual(calls, ["li.quest"])
    }

    func testFallbackReadAndHomeAgreeWhilePreviousPrimaryIsStillFresh() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let prior = Date().addingTimeInterval(-20)
        _ = try await MarketDataService(database: db, transport: LifiFeed(try lifiResponse()), now: { prior }, tokenCatalog: nil).quote(for: asset)
        let outage = MarketDataService(database: db, transport: LifiFeed(Data(), error: URLError(.timedOut)), tokenCatalog: nil)
        let detail = try await outage.quote(for: asset, force: true)
        let home = try await db.snapshot(walletID: "fixture", currency: "USD")
        XCTAssertEqual(detail.value.usd, "1.002")
        XCTAssertEqual(detail.value.usd, home.holdings.first(where: { $0.assetID == asset.id })?.usdPrice)
        XCTAssertEqual(detail.fetchedAt.timeIntervalSince1970, prior.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testFreshPrimaryWinsIncidentalInventoryPriceInHomeThenExpires() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let stamp = Date().timeIntervalSince1970
        try await db.savePrices([.init(assetID: asset.id, currency: "USD", value: "1.002", observedAt: stamp, source: "LI.FI"),
            .init(assetID: asset.id, currency: "USD", value: "5", observedAt: stamp + 0.1, source: "ankr")])
        var snapshot = try await db.snapshot(walletID: "fixture", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first(where: { $0.assetID == asset.id })?.priceSource, "LI.FI")
        let selected = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(selected?.value, "1.002")
        // Separate database with expired primary and recent fallback.
        let (other, otherFolder) = try await fixture(); defer { try? FileManager.default.removeItem(at: otherFolder) }
        try await other.savePrices([.init(assetID: asset.id, currency: "USD", value: "1.002", observedAt: stamp - 61, source: "LI.FI"),
            .init(assetID: asset.id, currency: "USD", value: "0.99", observedAt: stamp, source: "ankr")])
        snapshot = try await other.snapshot(walletID: "fixture", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first(where: { $0.assetID == asset.id })?.usdPrice, "0.99")
    }

    func testCancellationStartsNoFallbackOrCacheAndNextReadCanRecover() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let feed = LifiFeed(try lifiResponse(), delay: .seconds(2))
        let service = MarketDataService(database: db, transport: feed, tokenCatalog: nil)
        let work = Task { try await service.quote(for: asset) }
        try await Task.sleep(for: .milliseconds(25)); work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled work succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await service.cachedLifiToken(for: asset); XCTAssertNil(saved)
        let calls = await feed.hosts; XCTAssertEqual(calls, ["li.quest"])
        let recovered = try await MarketDataService(database: db, transport: LifiFeed(try lifiResponse()), tokenCatalog: nil).quote(for: asset)
        XCTAssertEqual(recovered.value.usd, "1.002")
    }

    func testWalletRefreshPublishesPrimaryTokenPriceWithoutReopening() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await db.saveBalances([.init(accountID: "account", assetID: asset.id, networkID: "ethereum",
            amountAtomic: "2000000", observedAt: Date().timeIntervalSince1970, source: "fixture")])
        let service = MarketDataService(database: db, transport: LifiFeed(try lifiResponse(price: "1.015")), tokenCatalog: nil)
        await service.refreshTokenQuotes(walletID: "fixture")
        let snapshot = try await db.snapshot(walletID: "fixture", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first(where: { $0.assetID == asset.id })?.usdPrice, "1.015")
        XCTAssertEqual(snapshot.holdings.first(where: { $0.assetID == asset.id })?.fiatDisplayValue, Decimal(string: "2.03"))
        XCTAssertEqual(snapshot.totalFiat, Decimal(string: "2.03"))
    }

    func testDailyCatalogDoesNotRenewPriceAgeAndFreshCatalogAvoidsDuplicateHTTP() async throws {
        for age: TimeInterval in [20, 120] {
            let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
            let now = Date(), stamp = now.addingTimeInterval(-age)
            let entry: [String: Any] = ["network": "ethereum", "reference": lifiUSDC, "name": "USD Coin", "symbol": "USDC",
                "source": "lifi", "lifiDecimals": 6, "lifiPriceUSD": "1.1", "lifiVerificationStatus": "verified",
                "lifiFetchedAt": stamp.timeIntervalSinceReferenceDate]
            let seed = try JSONSerialization.data(withJSONObject: ["format": 1, "entries": [entry]])
            let catalog = TokenDiscoveryCatalog(directory: folder.appendingPathComponent("catalog"), seed: seed)
            let feed = LifiFeed(try lifiResponse(price: "1.2", status: "flagged"))
            let service = MarketDataService(database: db, transport: feed, now: { now }, tokenCatalog: catalog)
            let quote = try await service.quote(for: asset)
            XCTAssertEqual(quote.value.usd, age < 60 ? "1.1" : "1.2")
            XCTAssertEqual(quote.fetchedAt.timeIntervalSince1970, (age < 60 ? stamp : now).timeIntervalSince1970, accuracy: 0.000001)
            let calls = await feed.hosts; XCTAssertEqual(calls.count, age < 60 ? 0 : 1)
        }
    }

    func testPublicRouteAdmissionRejectsKeysWalletRoutesAndSymbolLookups() throws {
        let url = try XCTUnwrap(LifiTokenMetadata.url(network: "ethereum", reference: lifiUSDC))
        XCTAssertTrue(LifiTokenMetadata.accepts(url))
        XCTAssertTrue(PublicMarketRequests.accepts(URLRequest(url: url)))
        for path in ["/v1/quote", "/v1/token?chain=1&token=USDC", "/v1/token?chain=1&token=USDC&apiKey=secret"] {
            XCTAssertFalse(LifiTokenMetadata.accepts(URL(string: "https://li.quest" + path)!))
        }
        var authenticated = URLRequest(url: url); authenticated.setValue("fixture", forHTTPHeaderField: "x-lifi-api-key")
        XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
    }

    func testLateOlderResponseCannotRestoreOldPriceOrVerifiedStatus() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(), asset = self.asset
        let slow = MarketDataService(database: db, transport: LifiFeed(try lifiResponse(price: "2"), delay: .milliseconds(100)),
            now: { date.addingTimeInterval(-10) }, tokenCatalog: nil)
        let work = Task { try await slow.lifiToken(for: asset, force: true) }
        try await Task.sleep(for: .milliseconds(25))
        let fast = MarketDataService(database: db, transport: LifiFeed(try lifiResponse(price: "3", status: "flagged")),
            now: { date }, tokenCatalog: nil)
        let winner = try await fast.lifiToken(for: asset, force: true)
        let late = try await work.value
        XCTAssertEqual(late.value, winner.value)
        XCTAssertEqual(late.value.status, .flagged)
        let price = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(price?.value, "3"); XCTAssertEqual(price?.observedAt, date.timeIntervalSince1970)
    }

    func testCachedPreviewPricePublishesWhenAssetIsLaterAdded() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let reference = "0x0000000000000000000000000000000000000001"
        let preview = MarketAsset(id: "ethereum:" + reference, networkID: "ethereum", reference: reference, decimals: 6)
        let feed = LifiFeed(try lifiResponse(price: "2", address: reference))
        let service = MarketDataService(database: db, transport: feed, tokenCatalog: nil)
        _ = try await service.lifiToken(for: preview)
        let absent = try await db.latestPrice(assetID: preview.id, currency: "USD"); XCTAssertNil(absent)
        _ = try await db.trackAsset(.init(id: preview.id, networkID: "ethereum", reference: reference,
            name: "Token", symbol: "TKN", decimals: 6), walletID: "fixture")
        _ = try await service.quote(for: preview)
        let price = try await db.latestPrice(assetID: preview.id, currency: "USD"); XCTAssertEqual(price?.value, "2")
        let calls = await feed.hosts; XCTAssertEqual(calls, ["li.quest"])
    }

    func testLiveLifiTokenResponseAndDiskCache() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIFI_MARKET_LIVE"] == "1" else { throw XCTSkip("Opt-in anonymous public token check") }
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = MarketDataService(database: db, tokenCatalog: nil)
        // Call the primary explicitly: a fallback cannot make this test pass.
        let metadata = try await service.lifiToken(for: asset)
        XCTAssertEqual(metadata.value.reference, lifiUSDC)
        XCTAssertNotNil(metadata.value.priceUSD)
        XCTAssertNotNil(metadata.value.verificationStatus)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let restored = try await MarketDataService(database: reopened, tokenCatalog: nil).cachedLifiToken(for: asset)
        XCTAssertEqual(restored?.value, metadata.value)
        XCTAssertEqual(restored?.fetchedAt, metadata.fetchedAt)
    }
}
