import XCTest
@testable import OathAnkr

private actor DiscoveryProviderFeed: AnkrTransport {
    enum Response: Sendable { case http(Data, Int), timeout, cancelled }
    var primary: Response
    let fallback: Response
    var hosts: [String] = []
    init(primary: Response, fallback: Response) { self.primary = primary; self.fallback = fallback }
    func setPrimary(_ response: Response) { primary = response }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = request.url!.host!
        hosts.append(host)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-lifi-api-key"))
        XCTAssertNil(request.httpBody)
        try await Task.sleep(for: .milliseconds(10))
        switch host == "li.quest" ? primary : fallback {
        case let .http(data, status): return (data, status)
        case .timeout: throw URLError(.timedOut)
        case .cancelled: throw URLError(.cancelled)
        }
    }
}

final class TokenDiscoveryProviderTests: XCTestCase, @unchecked Sendable {
    private let address = "0x0000000000000000000000000000000000000001"
    private let second = "0x0000000000000000000000000000000000000002"
    private let gecko = Data(#"[{"id":"usd-coin","name":"USD Coin","symbol":"usdc","platforms":{"ethereum":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"}}]"#.utf8)
    private var lifi: Data { list([row(address: address)]) }

    private func row(address: String, chain: UInt64 = 1, name: String = "Fresh Token", symbol: String = "FRESH", decimals: Int = 6) -> [String: Any] {
        ["chainId": chain, "address": address, "name": name, "symbol": symbol, "decimals": decimals,
         "logoURI": "https://example.org/token.png", "coinKey": "not-a-coingecko-id",
         "priceUSD": "9999", "verificationStatus": "verified"]
    }
    private func list(_ rows: [[String: Any]], chain: String = "1") -> Data {
        try! JSONSerialization.data(withJSONObject: ["tokens": [chain: rows]])
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testColdStartWithoutUsableSeedOrDiskUsesLifiAndPersists() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let feed = DiscoveryProviderFeed(primary: .http(lifi, 200), fallback: .http(Data(), 503))
        let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
        let success = await catalog.refreshIfNeeded()
        XCTAssertTrue(success)
        let results = await catalog.search("fresh", networks: ["ethereum"])
        XCTAssertEqual(results.map(\.reference), [address])
        XCTAssertNil(results.first?.coinID, "Never invent a CoinGecko ID from coinKey")
        XCTAssertNil(results.first?.decimals, "New independent listings still resolve scale on-chain")
        XCTAssertEqual(results.first?.source, .lifi)
        XCTAssertEqual(results.first?.lifiPriceUSD, "9999")
        XCTAssertEqual(results.first?.lifiVerificationStatus, "verified")
        XCTAssertEqual(results.first?.lifiDecimals, 6)
        XCTAssertNotNil(results.first?.lifiFetchedAt)
        do { _ = try await catalog.resolve(network: "ethereum", reference: address); XCTFail("Scale must be resolved on-chain") }
        catch { XCTAssertEqual(error as? TokenDiscoveryError, .metadataMissing) }
        let reopened = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
        let saved = await reopened.search("fresh", networks: ["ethereum"])
        XCTAssertEqual(saved, results)
        let refreshed = await reopened.refreshIfNeeded()
        XCTAssertFalse(refreshed)
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["li.quest"], "Search/resolve/restart must not secretly call CoinGecko")
    }

    func testPrimarySuccessCoalescesAndPreservesIndependentCoverage() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let feed = DiscoveryProviderFeed(primary: .http(lifi, 200), fallback: .http(Data(), 503))
        let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: gecko)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { await catalog.refreshIfNeeded() } }
            for await success in group { XCTAssertTrue(success) }
        }
        let known = await catalog.search("USDC", networks: ["ethereum"])
        XCTAssertEqual(known.first?.coinID, "usd-coin")
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["li.quest"])
    }

    func testLifiHTTPFailuresImmediatelyUseCoinGecko() async throws {
        for status in [403, 408, 429, 500, 503] {
            let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let feed = DiscoveryProviderFeed(primary: .http(Data(), status), fallback: .http(gecko, 200))
            let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
            let success = await catalog.refreshIfNeeded()
            XCTAssertTrue(success)
            let results = await catalog.search("USDC", networks: ["ethereum"])
            XCTAssertEqual(results.first?.coinID, "usd-coin")
            let hosts = await feed.hosts
            XCTAssertEqual(hosts, ["li.quest", "api.coingecko.com"])
            let retried = await catalog.refreshIfNeeded()
            XCTAssertFalse(retried, "Provider failure cooldown must also apply after recovery")
        }
    }

    func testTimeoutAndInvalidPrimaryPayloadUseFallback() async throws {
        for primary in [DiscoveryProviderFeed.Response.timeout, .http(Data("invalid".utf8), 200), .http(Data(#"{"tokens":{}}"#.utf8), 200)] {
            let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let feed = DiscoveryProviderFeed(primary: primary, fallback: .http(gecko, 200))
            let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
            let success = await catalog.refreshIfNeeded()
            XCTAssertTrue(success)
            let hosts = await feed.hosts
            XCTAssertEqual(hosts, ["li.quest", "api.coingecko.com"])
        }
    }

    func testBothProvidersFailWithoutClearingBundledData() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let feed = DiscoveryProviderFeed(primary: .http(Data(), 429), fallback: .http(Data(), 503))
        let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: gecko)
        let success = await catalog.refreshIfNeeded()
        XCTAssertFalse(success)
        let results = await catalog.search("USDC", networks: ["ethereum"])
        XCTAssertEqual(results.first?.coinID, "usd-coin")
        let reopened = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: gecko)
        let retried = await reopened.refreshIfNeeded()
        XCTAssertFalse(retried)
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["li.quest", "api.coingecko.com"])
    }

    func testCancellationDoesNotContactFallbackOrStartCooldown() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let feed = DiscoveryProviderFeed(primary: .cancelled, fallback: .http(gecko, 200))
        let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: gecko)
        let cancelled = await catalog.refreshIfNeeded()
        XCTAssertFalse(cancelled)
        await feed.setPrimary(.http(lifi, 200))
        let success = await catalog.refreshIfNeeded()
        XCTAssertTrue(success)
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["li.quest", "li.quest"])
    }

    func testSameContractOnDifferentChainsIsDistinctAndUnknownChainsAreExcluded() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["tokens": [
            "1": [row(address: address)], "56": [row(address: address, chain: 56)],
            "25": [row(address: address, chain: 25)], "11155111": [row(address: address, chain: 11155111)]
        ]])
        let entries = try LifiTokenDiscovery.decode(payload)
        XCTAssertEqual(Set(entries.map(\.id)), ["ethereum:" + address, "bnb:" + address])
    }

    func testChainMismatchAndInvalidPrecisionRejectPayload() throws {
        XCTAssertThrowsError(try LifiTokenDiscovery.decode(list([row(address: address, chain: 56)])))
        XCTAssertThrowsError(try LifiTokenDiscovery.decode(list([row(address: address, decimals: 256)])))
        XCTAssertThrowsError(try LifiTokenDiscovery.decode(list([row(address: address, decimals: -1)])))
    }

    func testConflictingDuplicateCannotChooseArbitraryMetadata() throws {
        let entries = try LifiTokenDiscovery.decode(list([row(address: address), row(address: address, decimals: 18), row(address: second)]))
        XCTAssertEqual(entries.map(\.reference), [second])
    }

    func testNativePlaceholdersAndUnsafeArtworkAreNotImported() throws {
        var safe = row(address: address); safe["logoURI"] = "https://user:password@example.org/image.png"
        let entries = try LifiTokenDiscovery.decode(list([
            safe, row(address: "0x" + String(repeating: "0", count: 40)),
            row(address: "0x" + String(repeating: "e", count: 40)), row(address: "not-a-contract")
        ]))
        XCTAssertEqual(entries.map(\.reference), [address])
        XCTAssertNil(entries.first?.logo)
    }

    func testSolanaSuiTronUseTheirOwnCanonicalIdentities() throws {
        let solana = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        let tron = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        let payload = try JSONSerialization.data(withJSONObject: ["tokens": [
            "1151111081099710": [row(address: solana, chain: 1_151_111_081_099_710), row(address: "11111111111111111111111111111111", chain: 1_151_111_081_099_710)],
            "9270000000000000": [row(address: "0x3::test::TOKEN", chain: 9_270_000_000_000_000), row(address: SuiIdentity.coin, chain: 9_270_000_000_000_000)],
            "728126428": [row(address: tron, chain: 728_126_428), row(address: "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb", chain: 728_126_428)]
        ]])
        let entries = try LifiTokenDiscovery.decode(payload)
        XCTAssertEqual(Set(entries.map(\.id)), ["solana:" + solana, "sui:0x3::test::TOKEN", "tron:" + tron])
    }

    func testLifiRecoveryAfterFallbackCooldownAndRestart() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let feed = DiscoveryProviderFeed(primary: .http(Data(), 503), fallback: .http(gecko, 200))
        let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
        _ = await catalog.refreshIfNeeded()
        let path = directory.appendingPathComponent("catalog-v1.json")
        var disk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        // Advance the persisted retry deadline without sleeping or changing the OS clock.
        disk["retryAt"] = Date.distantPast.timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: disk).write(to: path)
        await feed.setPrimary(.http(lifi, 200))
        let reopened = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
        let success = await reopened.refreshIfNeeded()
        XCTAssertTrue(success)
        let fresh = await reopened.search("FRESH", networks: ["ethereum"])
        let known = await reopened.search("USDC", networks: ["ethereum"])
        XCTAssertEqual(fresh.first?.reference, address)
        XCTAssertEqual(known.first?.coinID, "usd-coin")
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["li.quest", "api.coingecko.com", "li.quest"])
    }
}

private actor LifiLiveDiscoveryFeed: AnkrTransport {
    let transport = AnkrHTTPTransport()
    var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "li.quest" else { throw TokenDiscoveryError.unavailable }
        calls += 1
        return try await transport.send(request)
    }
}

final class TokenDiscoveryProviderLiveTests: XCTestCase, @unchecked Sendable {
    func testLiveLifiColdStartAndOfflineReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIFI_DISCOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in public catalog request") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = LifiLiveDiscoveryFeed()
        let catalog = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
        let success = await catalog.refreshIfNeeded()
        XCTAssertTrue(success, "Live LI.FI must succeed; CoinGecko cannot satisfy this test")
        let networks: Set<String> = ["ethereum", "bnb", "solana", "sui", "tron"]
        let results = await catalog.search("USDC", networks: networks)
        XCTAssertTrue(results.contains { $0.network == "ethereum" && $0.reference == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" })
        XCTAssertTrue(results.contains { $0.network == "solana" && $0.reference == "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" })
        let reopened = TokenDiscoveryCatalog(transport: feed, directory: directory, seed: Data())
        let saved = await reopened.search("USDC", networks: networks)
        XCTAssertEqual(saved, results)
        let calls = await feed.calls
        XCTAssertEqual(calls, 1)
        print("LI.FI live: \(results.count) USDC matches; cold-start catalog persisted and searched after reopening without another request")
    }
}
