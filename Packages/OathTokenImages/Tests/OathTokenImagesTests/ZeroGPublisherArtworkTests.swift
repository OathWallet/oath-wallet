import XCTest
import OathArtworkSource
@testable import OathTokenImages

private struct ZeroGPublisherMetadata: TokenArtworkMetadata {
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        ["https://ascend.finance/imgs/a0g.svg"]
    }
}

private actor ZeroGPublisherFeed: ArtworkTransport {
    let live: Bool
    var offline = false
    var calls: [URL] = []
    init(live: Bool) { self.live = live }
    func goOffline() { offline = true; calls.removeAll() }
    func data(from url: URL) async throws -> Data {
        calls.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        if live { return try await ArtworkURLTransport().data(from: url) }
        if url.absoluteString == "https://tokens.coingecko.com/0g/all.json" {
            return try JSONSerialization.data(withJSONObject: ["tokens": [
                ["chainId": 16661, "address": ZeroGPublisherArtworkTests.contract,
                 "logoURI": "https://cdn.example.org/a0g.svg"]
            ]])
        }
        if url.absoluteString == "https://cdn.example.org/a0g.svg" {
            return Data("<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><circle cx='4' cy='4' r='4' fill='teal'/></svg>".utf8)
        }
        throw ArtworkDecodeFailure(stage: .svgSafety)
    }
}

final class ZeroGPublisherArtworkTests: XCTestCase, @unchecked Sendable {
    fileprivate static let contract = "0x4b3c2f55fa67679b382c979a082df1b32079b4cb"
    private let source = "https://ascend.finance/imgs/a0g.svg"

    func testReportedSourceUsesExactPublishedContractAndReopensOffline() async throws {
        try await check(live: false)
    }
    func testLiveReportedSourceUsesPublishedPNGAndReopensOffline() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ZEROG_PUBLISHER_IMAGES_LIVE"] == "1" else {
            throw XCTSkip("Public 0G token list and image reads")
        }
        let original = try await ArtworkURLTransport().data(from: URL(string: source)!)
        XCTAssertThrowsError(try ArtworkImage.decode(original)) { error in
            XCTAssertEqual((error as? ArtworkDecodeFailure)?.stage, .svgSafety)
        }
        try await check(live: true)
    }
    private func check(live: Bool) async throws {
        XCTAssertEqual(String(ArtworkSource.key(source).prefix(12)), "3f324a860967")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = ZeroGPublisherFeed(live: live)
        func resolver() -> TokenArtworkResolver {
            TokenArtworkResolver(loader: ArtworkLoader(directory: root.appendingPathComponent("images"),
                transport: feed, fallbackCatalog: ArtworkFallbackCatalog(transport: feed)),
                metadata: ZeroGPublisherMetadata(), directory: root.appendingPathComponent("identities"))
        }
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "zerog", reference: Self.contract, decimals: 18))
        let image = await resolver().image(for: token, sources: [source])
        XCTAssertNotNil(image)
        let calls = await feed.calls
        XCTAssertFalse(calls.contains { $0.absoluteString == source })
        if live { XCTAssertTrue(calls.contains { $0.host == "assets.coingecko.com" }) }
        await feed.goOffline()
        let reopened = await resolver().image(for: token, sources: [])
        XCTAssertNotNil(reopened)
        let offlineCalls = await feed.calls
        XCTAssertTrue(offlineCalls.isEmpty)
    }
    func testDifferentContractCannotBorrowAscendArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = ZeroGPublisherFeed(live: false)
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: root.appendingPathComponent("images"),
            transport: feed, fallbackCatalog: ArtworkFallbackCatalog(transport: feed)),
            metadata: ZeroGPublisherMetadata(), directory: root.appendingPathComponent("identities"))
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "zerog", reference: "0x" + String(repeating: "1", count: 40)))
        let image = await resolver.image(for: token, sources: [source])
        XCTAssertNil(image)
        let calls = await feed.calls
        XCTAssertFalse(calls.contains { $0.host == "cdn.example.org" })
    }
}
