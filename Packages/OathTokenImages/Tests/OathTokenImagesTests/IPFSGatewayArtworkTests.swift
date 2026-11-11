import CryptoKit
import OathArtworkSource
import XCTest
@testable import OathTokenImages

private actor GatewayFeed: ArtworkTransport {
    var hosts: [String] = []
    var digest: String?
    let live: Bool
    init(live: Bool = false) { self.live = live }

    func data(from url: URL) async throws -> Data {
        hosts.append(url.host ?? "")
        if live {
            let bytes = try await ArtworkURLTransport().data(from: url)
            digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return bytes
        }
        if url.host == "ipfs.io" { throw ArtworkRateLimit(retryAfter: "120") }
        return Data("<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><rect width='8' height='8' fill='blue'/></svg>".utf8)
    }
}

final class IPFSGatewayArtworkTests: XCTestCase, @unchecked Sendable {
    private let cid = "QmRUogM7aVpy4Ywg7t4zmm6WosfKSgo7T2yzvLRFtYELNL"

    func testOnlyPublicRootCIDIsEligible() throws {
        let base = "https://ipfs.io/ipfs/" + cid
        XCTAssertEqual(ArtworkLoader.gatewayCID(try XCTUnwrap(URL(string: base))), cid)
        for source in [base + "?signature=abc", base + "#section", base + "/file", base + "%2Ffile",
                       "https://u:p@ipfs.io/ipfs/" + cid, "https://ipfs.io:8443/ipfs/" + cid,
                       "https://example.org/ipfs/" + cid, "https://ipfs.io/ipfs/Qm0invalid"] {
            XCTAssertNil(ArtworkLoader.gatewayCID(try XCTUnwrap(URL(string: source))))
        }
    }

    func testCooldownCoversOtherCIDsAndKeepsOfflineOriginal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = GatewayFeed(), loader = ArtworkLoader(directory: folder, transport: feed)
        let first = "https://ipfs.io/ipfs/" + cid
        for source in [first, "https://ipfs.io/ipfs/Qm" + String(repeating: "a", count: 44)] {
            let image = await loader.image(for: [source])
            XCTAssertNotNil(image)
        }
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["ipfs.io", "gateway.pinata.cloud", "gateway.pinata.cloud"])
        let reopened = await ArtworkLoader(directory: folder, transport: feed).image(for: [first])
        XCTAssertNotNil(reopened)
        let finalHosts = await feed.hosts
        XCTAssertEqual(finalHosts, hosts)
    }

    func testLiveReported51DImageAndOfflineReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_IPFS_IMAGES_LIVE"] == "1" else { throw XCTSkip("Public IPFS gateway reads") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = GatewayFeed(live: true), source = "https://ipfs.io/ipfs/" + cid
        XCTAssertEqual(String(ArtworkSource.key(source).prefix(12)), "89c06fddd0b3")
        let image = await ArtworkLoader(directory: folder, transport: feed).image(for: [source], maxPixelSize: 64)
        guard case .raster = image else { return XCTFail("Expected decoded 51D artwork") }
        let digest = await feed.digest, hosts = await feed.hosts
        XCTAssertEqual(digest, "bf84a504247604a7c92bb2f83a02c596392ea9424573ceea50eaf7e9dfb4d53d")
        print("Live 51D image hosts", hosts)
        let offline = GatewayFeed()
        let reopened = await ArtworkLoader(directory: folder, transport: offline).image(for: [source])
        guard case .raster = reopened else { return XCTFail("Expected disk-cached original") }
        let calls = await offline.hosts
        XCTAssertTrue(calls.isEmpty)
    }
}
