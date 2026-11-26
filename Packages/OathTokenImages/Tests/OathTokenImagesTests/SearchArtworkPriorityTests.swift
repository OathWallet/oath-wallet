import XCTest
@testable import OathTokenImages

/// An optional metadata read deliberately stays pending. A usable row image
/// must render without depending on that read, on any token network.
private actor SearchMetadataGate: TokenArtworkMetadata {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var calls = 0
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        calls += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return []
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor SearchImageTransport: ArtworkTransport {
    private(set) var calls = 0
    let catalog: Data
    init(catalog: Data = Data("{\"tokens\":[]}".utf8)) { self.catalog = catalog }
    func data(from url: URL) async throws -> Data {
        if url.host == "tokens.coingecko.com" { return catalog }
        calls += 1
        return Data("<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><rect width='24' height='24' fill='#00aabb'/></svg>".utf8)
    }
}

private actor SearchImageCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

final class SearchArtworkPriorityTests: XCTestCase, @unchecked Sendable {
    private func assertImageCompletesBeforeMetadata(network: String, source: String, decimals: Int?,
                                                   reference: String = "0x1234567890123456789012345678901234567890",
                                                   bytes: any ArtworkTransport = SearchImageTransport(),
                                                   waitLimit: Duration = .seconds(5)) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = SearchMetadataGate(), completion = SearchImageCompletion()
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: network, reference: reference, decimals: decimals))
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: dir.appendingPathComponent("bytes"),
            transport: bytes, fallbackCatalog: ArtworkFallbackCatalog(transport: bytes)),
            metadata: metadata, directory: dir.appendingPathComponent("identity"))
        let pending = Task {
            let image = await resolver.image(for: token, sources: [source], maxPixelSize: 128)
            await completion.finish()
            return image
        }
        let deadline = ContinuousClock.now + waitLimit
        while await !completion.finished, await metadata.calls == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let finished = await completion.finished
        let metadataCalls = await metadata.calls
        // Always release before assertions/awaiting completion, including on
        // the broken implementation, so this regression cannot hang the suite.
        await metadata.release()
        let image = await pending.value
        XCTAssertTrue(finished, "\(network): image delivery must finish while optional metadata is still pending")
        XCTAssertEqual(metadataCalls, 0, "\(network): valid artwork must not require token-information APIs")
        XCTAssertNotNil(image, network)
        let offline = await resolver.cached(for: token, sources: [], maxPixelSize: 128)
        XCTAssertNotNil(offline, "Resolved search artwork must remain shared with the other screens")
    }

    func testPublishedSearchLogoDoesNotWaitForMetadataAcrossTokenNetworks() async throws {
        let networks = TokenArtworkIdentity.evmNetworks.union(["solana", "tron", "ton", "aptos", "sui", "near", "xrpl", "stellar", "thorchain", "polkadot"])
        for network in networks.sorted() {
            for decimals: Int? in [nil, 6] {
                try await assertImageCompletesBeforeMetadata(network: network,
                    source: "https://cdn.example.org/\(network).svg", decimals: decimals)
            }
        }
    }

    func testWorkingDirectoryImageDoesNotWaitForTokenMetadataWhenCatalogIsEmpty() async throws {
        try await assertImageCompletesBeforeMetadata(network: "ethereum",
            source: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0x1234567890123456789012345678901234567890/logo.png",
            decimals: nil)
    }

    func testPublishedCatalogLogoDoesNotWaitForTokenMetadata() async throws {
        let catalog = Data("{\"tokens\":[{\"chainId\":1,\"address\":\"0x1234567890123456789012345678901234567890\",\"logoURI\":\"https://cdn.example.org/published.svg\"}]}".utf8)
        try await assertImageCompletesBeforeMetadata(network: "ethereum",
            source: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0x1234567890123456789012345678901234567890/logo.png",
            decimals: nil, bytes: SearchImageTransport(catalog: catalog))
    }

    func testLivePublicSearchLogosCompleteWithoutTokenMetadata() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_SEARCH_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in public artwork reads; no wallets or credentials")
        }
        let samples = [
            ("ethereum", "0xdAC17F958D2ee523a2206206994597C13D831ec7"),
            ("tron", "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"),
            ("solana", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
        ]
        for (network, reference) in samples {
            try await assertImageCompletesBeforeMetadata(network: network,
                source: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(network)/assets/\(reference)/logo.png",
                decimals: nil, reference: reference, bytes: ArtworkURLTransport(), waitLimit: .seconds(60))
        }
    }
}
