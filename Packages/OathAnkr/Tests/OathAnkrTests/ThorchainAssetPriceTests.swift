import Foundation
import XCTest
@testable import OathAnkr

private actor ThorchainAssetPriceTransport: AnkrTransport {
    static let usdt = "ETH.USDT-0XDAC17F958D2EE523A2206206994597C13D831EC7"
    let oracle: Bool, fallback: Bool, stale: Bool
    private(set) var requestedAssets: [String] = []
    private(set) var fallbackKeys: [String] = []
    init(oracle: Bool = true, fallback: Bool = true, stale: Bool = false) {
        self.oracle = oracle; self.fallback = fallback; self.stale = stale
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(request.httpMethod ?? "GET", "GET"); XCTAssertNil(request.httpBody)
        var response: SolanaJSON
        if url.path.hasSuffix("/denoms_metadata") { response = .object(["metadatas": .array([]), "pagination": .object([:])]) }
        else if url.path.hasSuffix("/pools") {
            response = .array(zip(["AVAX.AVAX", "DOGE.DOGE", Self.usdt], ["7.7338", "0.07889", "0.9444"]).map {
                .object(["asset": .string($0.0), "assetPriceUSD": .string($0.1), "status": .string("available")])
            })
        } else if url.path.hasSuffix("/stats") { response = .object(["runePriceUSD": .string("0.6")]) }
        else if url.path.hasSuffix("/securedassets") {
            response = .array(["AVAX-AVAX", "DOGE-DOGE", Self.usdt.replacingOccurrences(of: "ETH.", with: "ETH-")].map {
                .object(["asset": .string($0), "supply": .string("100"), "depth": .string($0 == "AVAX-AVAX" ? "125" : "100")])
            })
        } else if url.host == "api.rujira.network" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            if query.contains("strategies") { response = .object(["data": .object(["rujira": .object(["strategies": .object(["edges": .array([]), "pageInfo": .object(["hasNextPage": .bool(false)])])])])]) }
            else {
                let start = try XCTUnwrap(query.range(of: "nodes(ids:")?.upperBound)
                let end = try XCTUnwrap(query[start...].range(of: "){...")?.lowerBound)
                let ids = try JSONDecoder().decode([String].self, from: Data(query[start..<end].utf8))
                let assets = try ids.map { String(try XCTUnwrap(String(data: try XCTUnwrap(Data(base64Encoded: $0)), encoding: .utf8)).dropFirst(6)) }
                requestedAssets += assets
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let prices = ["AVAX.AVAX": "8224600000000", "DOGE.DOGE": "71680000000", Self.usdt: "998600000000", "THOR.TCY": "20000000000", "X/RUJI": "100000000000"]
                response = .object(["data": .object(["nodes": .array(assets.map { asset in
                    guard oracle, let price = prices[asset] else { return .null }
                    return .object(["asset": .string(asset), "price": .object(["current": .string(price), "timestamp": .string(formatter.string(from: Date().addingTimeInterval(stale ? -901 : 0)))])])
                })])])
            }
        } else if url.host == "coins.llama.fi" {
            let keys = url.lastPathComponent.split(separator: ",").map(String.init); fallbackKeys += keys
            let values = ["coingecko:avalanche-2": "8.224", "coingecko:dogecoin": "0.07169", "coingecko:tether": "0.99878"]
            response = .object(["coins": .object(Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, SolanaJSON)? in
                guard fallback, let price = values[key] else { return nil }
                return (key, .object(["price": .number(price), "timestamp": .number(String(Int(Date().timeIntervalSince1970) - (stale ? 4000 : 0))), "confidence": .number("0.99")]))
            }))])
        } else if url.host == "api.coingecko.com" { response = .object([:]) }
        else { throw AnkrError.invalidResponse }
        return (try JSONEncoder().encode(response), 200)
    }
}

private actor PartialOracleTransport: AnkrTransport {
    private let base = ThorchainAssetPriceTransport()
    private(set) var batches = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.rujira.network", request.url?.query?.contains("nodes") == true {
            batches += 1
            if batches == 2 { return (Data("{}".utf8), 400) }
        }
        let response = try await base.send(request)
        if request.url?.path.hasSuffix("/pools") == true {
            let original = try JSONDecoder().decode(SolanaJSON.self, from: response.0)
            let extra: [SolanaJSON] = (0..<9).map { .object(["asset": .string("B0\($0).TOKEN"), "assetPriceUSD": .string("1"), "status": .string("available")]) }
            return (try JSONEncoder().encode(SolanaJSON.array((original.array ?? []) + extra)), 200)
        }
        return response
    }
}

final class ThorchainAssetPriceTests: XCTestCase {
    let usdtRef = "eth-usdt-0xdac17f958d2ee523a2206206994597c13d831ec7"
    func testFreshOracleOverridesDivergentPoolsAndConvertsSharesExactlyOnce() async throws {
        let transport = ThorchainAssetPriceTransport()
        let catalog = try await ThorchainClient(transport: transport).catalog()
        XCTAssertEqual(catalog.prices["avax/avax"], "8.2246")
        XCTAssertEqual(catalog.prices["avax-avax"], "10.28075")
        XCTAssertEqual(catalog.prices["doge-doge"], "0.07168")
        XCTAssertEqual(catalog.prices[usdtRef], "0.9986")
        let assets = await transport.requestedAssets, keys = await transport.fallbackKeys
        XCTAssertTrue(Set(["AVAX.AVAX", "DOGE.DOGE", ThorchainAssetPriceTransport.usdt]).isSubset(of: Set(assets)))
        XCTAssertFalse(keys.contains("coingecko:avalanche-2"))
    }
    func testMissingOracleUsesExactMarketIdentitiesRatherThanPoolPrices() async throws {
        let transport = ThorchainAssetPriceTransport(oracle: false)
        let catalog = try await ThorchainClient(transport: transport).catalog()
        XCTAssertEqual(catalog.prices["avax-avax"], "10.28")
        XCTAssertEqual(catalog.prices["doge-doge"], "0.07169")
        XCTAssertEqual(catalog.prices[usdtRef], "0.99878")
        let keys = await transport.fallbackKeys
        XCTAssertTrue(Set(["coingecko:avalanche-2", "coingecko:dogecoin", "coingecko:tether"]).isSubset(of: Set(keys)))
    }
    func testLaterBatchFailurePreservesEarlierFreshOracleAndRecoversOnlyMissingAssets() async throws {
        let transport = PartialOracleTransport()
        let catalog = try await ThorchainClient(transport: transport).catalog()
        XCTAssertEqual(catalog.prices["avax-avax"], "10.28075", "First oracle batch must survive a later provider failure")
        XCTAssertEqual(catalog.prices["doge-doge"], "0.07169")
        XCTAssertEqual(catalog.prices[usdtRef], "0.99878")
        let batches = await transport.batches; XCTAssertEqual(batches, 2)
    }
    func testOracleRejectsDuplicateAndForeignIdentities() throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row: SolanaJSON = .object(["asset": .string("DOGE.DOGE"), "price": .object(["current": .string("71680000000"), "timestamp": .string(formatter.string(from: .now))])])
        XCTAssertThrowsError(try ThorchainClient.decodeOracle([row, row], expected: ["DOGE.DOGE", "AVAX.AVAX"]))
        XCTAssertThrowsError(try ThorchainClient.decodeOracle([row], expected: ["AVAX.AVAX"]))
    }
    func testUnavailableOrExpiredMarketQuotesNeverRepublishDivergentPools() async throws {
        for stale in [false, true] {
            let catalog = try await ThorchainClient(transport: ThorchainAssetPriceTransport(oracle: stale, fallback: stale, stale: stale)).catalog()
            XCTAssertNil(catalog.prices["avax-avax"])
            XCTAssertNil(catalog.prices["doge-doge"])
            XCTAssertNil(catalog.prices[usdtRef])
        }
    }
}
