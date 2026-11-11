import XCTest
import OathAnkr
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private actor NativeBatchFeed: MarketTransport {
    let now: Date
    let live: Bool
    let scheduler = PublicMarketRequests(spacing: .zero)
    let http = URLSessionMarketTransport()
    private(set) var queries: [String] = []
    private(set) var payload: Data?

    init(now: Date, live: Bool) { self.now = now; self.live = live }

    func data(from url: URL) async throws -> Data {
        if url.host == "api.coingecko.com" {
            let response = try await scheduler.send(URLRequest(url: url)) { try await self.fetch(url) }
            return response.data
        }
        if !live, url.host == "li.quest" {
            return Data(#"{"chainId":100,"address":"0xe91d153e0b41518a2ce8dd3d7944fa863463a97d","decimals":18,"name":"Wrapped xDAI","symbol":"WXDAI","priceUSD":"0.997"}"#.utf8)
        }
        throw MarketDataError.notListed
    }

    private func fetch(_ url: URL) async throws -> PublicMarketRequests.Response {
        let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value ?? ""
        queries.append(ids)
        let data: Data
        if live {
            data = try await http.data(from: url)
        } else {
            guard ids == "ethereum,fantom,xdai" else { throw MarketDataError.rateLimited }
            data = try JSONSerialization.data(withJSONObject: [
                "ethereum": ["usd": "1800.75", "last_updated_at": now.timeIntervalSince1970 - 10],
                "xdai": ["usd": "4", "last_updated_at": now.timeIntervalSince1970 - 3600],
                "gnosis": ["usd": "200", "last_updated_at": now.timeIntervalSince1970]
            ])
        }
        payload = data
        return .init(data: data, status: 200)
    }
}

@MainActor final class NativeQuoteBatchTests: XCTestCase {
    private let networks = ["base", "ethereum", "fantom", "gnosis"]

    private func setup(at path: URL) async throws -> OathDatabase {
        let db = try await OathDatabase.open(at: path)
        try await db.seed(networks: networks.map {
            .init(id: $0, name: $0, family: "evm", symbol: "fixture", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)
        }, assets: networks.map {
            .init(id: $0 + ":native", networkID: $0, reference: "native", name: $0, symbol: "fixture", decimals: 18)
        })
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Public fixture", kind: "watchOnly", vaultReference: "test", createdAt: 1),
            accounts: networks.map { .init(id: $0, walletID: "wallet", networkID: $0, address: "0x0000000000000000000000000000000000000001", derivationPath: "") })
        try await db.saveBalances(networks.map { .init(accountID: $0, assetID: $0 + ":native", networkID: $0,
                                                      amountAtomic: "1250000000000000000", observedAt: 100, source: "fixture") })
        return db
    }

    func testOneBatchPreservesDistinctIdentitiesAndExistingPricesAcrossReopen() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try await setup(at: path), now = Date(timeIntervalSince1970: 1_800_000_000)
        try await db.savePrices([.init(assetID: "fantom:native", currency: "USD", value: "0.19", observedAt: 100, source: "fixture")])
        let feed = NativeBatchFeed(now: now, live: false)
        let service = MarketDataService(database: db, transport: feed, now: { now })
        await service.refreshNativeQuotes(networkIDs: networks + ["gnosis", "unseeded", "avalanche"])
        let queries = await feed.queries
        XCTAssertEqual(queries, ["ethereum,fantom,xdai"])
        let reopened = try await OathDatabase.open(at: path)
        for network in networks {
            let saved = try await reopened.latestPrice(assetID: network + ":native", currency: "USD")
            let price = try XCTUnwrap(saved)
            let expected = ["ethereum": "1800.75", "base": "1800.75", "gnosis": "0.997", "fantom": "0.19"]
            XCTAssertEqual(price.value, expected[network])
            if network == "fantom" { XCTAssertEqual(price.observedAt, 100) }
            if network == "gnosis" { XCTAssertEqual(price.source, "LI.FI (WXDAI)") }
            let balance = try await reopened.balance(accountID: network, assetID: network + ":native")
            XCTAssertEqual(balance?.amountAtomic, "1250000000000000000")
        }
    }

    func testRepeatedNativeRefreshDuringBackoffKeepsAvailabilityFailuresQuiet() async throws {
        struct Offline: MarketTransport {
            func data(from url: URL) async throws -> Data { throw URLError(.cannotConnectToHost) }
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try await setup(at: path), capture = MarketTestDiagnostics.shared
        let service = MarketDataService(database: db, transport: Offline())
        let operation = UUID()
        await OathDiagnostics.$operationID.withValue(operation) {
            for _ in 0..<6 { await service.refreshNativeQuotes(networkIDs: ["gnosis"]) }
        }
        try await Task.sleep(for: .milliseconds(500))
        let events = await capture.events(for: operation)
        // Ordinary network outages are intentionally excluded by the shared privacy/availability policy.
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(events.contains { $0.operation == "native_quote_refresh" })
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "gnosis" })
    }

    func testLiveBatchMatchesEveryExactPublicPriceAndTimestampAfterReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_BATCH_LIVE"] == "1" else { throw XCTSkip("Public CoinGecko read") }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try await setup(at: path)
        let feed = NativeBatchFeed(now: .now, live: true)
        await MarketDataService(database: db, transport: feed).refreshNativeQuotes(networkIDs: networks)
        let queries = await feed.queries, payload = await feed.payload
        XCTAssertEqual(queries, ["ethereum,fantom,xdai"])
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(payload)) as? [String: [String: NSNumber]])
        let reopened = try await OathDatabase.open(at: path)
        for network in networks {
            let id = try XCTUnwrap(MarketIdentity.native[network]?.gecko)
            let raw = try XCTUnwrap(rows[id])
            let saved = try await reopened.latestPrice(assetID: network + ":native", currency: "USD")
            let timestamp = try XCTUnwrap(raw["last_updated_at"]?.doubleValue)
            let age = Date().timeIntervalSince1970 - timestamp
            if (-120...900).contains(age) {
                let price = try XCTUnwrap(saved)
                XCTAssertEqual(Decimal(string: price.value), try XCTUnwrap(Decimal(string: XCTUnwrap(raw["usd"]).stringValue)))
                XCTAssertEqual(price.observedAt, timestamp)
                print("LIVE_NATIVE_BATCH network=\(network) price=\(price.value) observedAt=\(timestamp)")
            } else {
                XCTAssertNil(saved, "An out-of-window public observation was published")
                print("LIVE_NATIVE_BATCH network=\(network) rejectedAgeSeconds=\(Int(age))")
            }
            let balance = try await reopened.balance(accountID: network, assetID: network + ":native")
            XCTAssertEqual(balance?.amountAtomic, "1250000000000000000")
        }
    }
}
