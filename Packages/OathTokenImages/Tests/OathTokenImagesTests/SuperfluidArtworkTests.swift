import XCTest
import CoreGraphics
import SwiftDraw
import OathArtworkSource
@testable import OathTokenImages

private actor SuperfluidFeed: ArtworkTransport {
    let live: Bool
    var calls = 0
    var offline = false
    init(live: Bool) { self.live = live }
    func goOffline() { offline = true; calls = 0 }
    func data(from url: URL) async throws -> Data {
        calls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        if live { return try await ArtworkURLTransport().data(from: url) }
        return try Data(contentsOf: Bundle.module.url(forResource: "superfluid-usdc", withExtension: "svg", subdirectory: "Fixtures")!)
    }
}

final class SuperfluidArtworkTests: XCTestCase, @unchecked Sendable {
    private let source = "https://tokenlist.superfluid.org/icons/usdc.svg"
    private func document(_ body: String) -> Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'>\(body)</svg>".utf8)
    }
    private func pixels(_ image: ArtworkImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard case .vector(let svg, _) = image else { throw ArtworkError.invalidImage }
        context.draw(svg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return Data(bytes: try XCTUnwrap(context.data), count: 64 * 256)
    }
    func testMissingRectangleDimensionsPreserveVisibleShapes() throws {
        let visible = "<circle cx='32' cy='32' r='24' fill='#2775ca'/>"
        let expected = try pixels(ArtworkImage.decode(document(visible)))
        for attributes in ["", "width='12'", "height='12'"] {
            let data = document("<rect \(attributes) fill='red'/>" + visible)
            XCTAssertEqual(try pixels(ArtworkImage.decode(data)), expected, attributes)
        }
        let reference = document("<rect width='12' height='12' fill='red'/>" + visible)
        XCTAssertNotEqual(try pixels(ArtworkImage.decode(reference)), expected)
    }
    func testDefaultsPreserveInternalReferencesAndEscapedAttributes() throws {
        let data = document("""
        <defs><g id='one'><rect/><circle cx='32' cy='32' r='24' fill='blue'/></g></defs>
        <title>A &amp; B &lt; C</title><use xmlns:xlink='http://www.w3.org/1999/xlink' xlink:href='#one'/>
        """)
        let expected = document("<circle cx='32' cy='32' r='24' fill='blue'/>")
        XCTAssertEqual(try pixels(ArtworkImage.decode(data)), try pixels(ArtworkImage.decode(expected)))
    }
    func testInvalidAndUnsafeSVGStillFail() {
        for body in ["<rect width='invalid'/>", "<rect width='-1'/>", "<rect/><script>bad()</script>",
                     "<rect/><image href='data:image/png;base64,AA=='/>",
                     "<rect/><use href='https://example.org/icon.svg'/>",
                     "<rect/><g id='loop'><use href='#loop'/></g>"] {
            XCTAssertThrowsError(try ArtworkImage.decode(document(body)))
        }
    }
    func testReportedPublisherSVGDecodesAndReopensOffline() async throws {
        try await check(live: false)
    }
    func testLiveReportedPublisherSVGDecodesAndReopensOffline() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SUPERFLUID_ARTWORK_LIVE"] == "1" else {
            throw XCTSkip("Public Superfluid image read")
        }
        try await check(live: true)
    }
    private func check(live: Bool) async throws {
        XCTAssertEqual(String(ArtworkSource.key(source).prefix(12)), "2df01f9a32ae")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = SuperfluidFeed(live: live)
        let first = await ArtworkLoader(directory: root, transport: feed).image(for: [source])
        let image = try XCTUnwrap(first)
        let decoded = try pixels(image)
        XCTAssertTrue(decoded.contains { $0 != 0 })
        await feed.goOffline()
        let reopened = await ArtworkLoader(directory: root, transport: feed).image(for: [source])
        XCTAssertEqual(try pixels(XCTUnwrap(reopened)), decoded)
        let offlineRequests = await feed.calls
        XCTAssertEqual(offlineRequests, 0)
    }
}
