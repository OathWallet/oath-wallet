import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

@MainActor final class IndependentNativePriceTests: XCTestCase {
    // Opera pricing is bound to its canonical wrapper; covered by FantomNativePriceRecoveryTests.
    private let chains = ["bitcoin", "bitcoincash", "litecoin", "dogecoin"]

    private func seed(_ db: OathDatabase) async throws {
        try await db.seed(networks: chains.enumerated().map { index, chain in
            .init(id: chain, name: chain, family: "fixture", symbol: MarketIdentity.native[chain]!.coinbase,
                  decimals: chain == "fantom" ? 18 : 8, derivationPath: "fixture", logo: "", sortOrder: index)
        }, assets: chains.map { chain in
            .init(id: chain + ":native", networkID: chain, reference: "native", name: chain,
                  symbol: MarketIdentity.native[chain]!.coinbase, decimals: chain == "fantom" ? 18 : 8)
        })
    }

    func testIndependentSourcePersistsWhenOtherProvidersFailAndOutagePreservesSavedPrices() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        try await seed(db)
        let now = Date(timeIntervalSince1970: 2000)
        let transport = IndependentNativeTransport()
        let capture = MarketTestDiagnostics.shared
        for chain in chains {
            let asset = MarketAsset(id: chain + ":native", networkID: chain, reference: "native", decimals: chain == "fantom" ? 18 : 8)
            await transport.setOutage(false)
            let service = MarketDataService(database: db, transport: transport, now: { now })
            async let a = service.quote(for: asset)
            async let b = service.quote(for: asset)
            let (first, second) = try await (a, b)
            XCTAssertEqual(first.value.usd, "123.456789")
            XCTAssertEqual(second.value.usd, first.value.usd)
            XCTAssertEqual(first.fetchedAt.timeIntervalSince1970, 1900)
            let saved = try await db.latestPrice(assetID: asset.id, currency: "USD")
            XCTAssertEqual(saved?.source, "CoinPaprika")
            XCTAssertEqual(saved?.value, first.value.usd)
            let before = await transport.count
            for _ in 0..<20 { _ = try await service.quote(for: asset) }
            let after = await transport.count
            XCTAssertEqual(before, after)

            await transport.setOutage(true)
            let outage = MarketDataService(database: db, transport: transport, now: { now })
            let operation = UUID()
            try await OathDiagnostics.$operationID.withValue(operation) {
                for _ in 0..<20 {
                    let cached = try await outage.quote(for: asset)
                    XCTAssertEqual(cached.value.usd, first.value.usd)
                    XCTAssertEqual(cached.fetchedAt, first.fetchedAt)
                }
            }
            for _ in 0..<100 {
                if await !capture.events(for: operation).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(100))
            let events = await capture.events(for: operation)
            // The shared availability policy excludes ordinary provider outages.
            XCTAssertTrue(events.isEmpty)
            XCTAssertFalse(events.contains { $0.operation == "quote_cache_fallback" })
            let retained = try await db.latestPrice(assetID: asset.id, currency: "USD")
            XCTAssertEqual(retained?.value, saved?.value)
            XCTAssertEqual(retained?.observedAt, saved?.observedAt)
        }
    }

    func testLiveIndependentNativeQuotesPersistWithAllOtherSourcesBlocked() async throws {
        guard ProcessInfo.processInfo.environment["OATH_INDEPENDENT_NATIVE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in anonymous public quotes")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        try await seed(db)
        let service = MarketDataService(database: db, transport: IndependentNativeLiveTransport())
        for chain in chains {
            let asset = MarketAsset(id: chain + ":native", networkID: chain, reference: "native", decimals: chain == "fantom" ? 18 : 8)
            let result = try await service.quote(for: asset)
            let saved = try await db.latestPrice(assetID: asset.id, currency: "USD")
            XCTAssertEqual(saved?.source, "CoinPaprika")
            XCTAssertEqual(saved?.value, result.value.usd)
            XCTAssertEqual(saved?.observedAt, result.fetchedAt.timeIntervalSince1970)
            XCTAssertGreaterThan(result.value.decimal ?? 0, 0)
            XCTAssertLessThanOrEqual(Date().timeIntervalSince(result.fetchedAt), 900)
            print("LIVE_INDEPENDENT chain=\(chain) source=CoinPaprika persisted=true")
        }
    }
}

private actor IndependentNativeTransport: MarketTransport {
    private var outage = false
    private(set) var count = 0
    func setOutage(_ value: Bool) { outage = value }
    func data(from url: URL) async throws -> Data {
        count += 1
        guard !outage, url.host == "api.coinpaprika.com",
              let identity = NativeCoinPrice.supported.values.first(where: { $0.identity.tickerURL == url })?.identity else {
            throw MarketDataError.unavailable
        }
        return try JSONSerialization.data(withJSONObject: ["id": identity.id, "name": identity.name,
            "symbol": identity.symbol, "last_updated": "1970-01-01T00:31:40Z",
            "quotes": ["USD": ["price": "123.456789"]]])
    }
}

private struct IndependentNativeLiveTransport: MarketTransport {
    private let base = URLSessionMarketTransport()
    func data(from url: URL) async throws -> Data {
        guard url.host == "api.coinpaprika.com" else { throw MarketDataError.unavailable }
        return try await base.data(from: url)
    }
}
