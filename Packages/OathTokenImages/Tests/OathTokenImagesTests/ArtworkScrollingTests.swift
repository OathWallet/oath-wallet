import XCTest
import ImageIO
import UniformTypeIdentifiers
import OathArtworkSource
import OathDiagnostics
@testable import OathTokenImages

/// Gates exercise the real pool/loader/resolver; no live provider timing or UI
/// timing threshold is used to decide correctness.
private actor ScrollImageGate: ArtworkTransport {
    let bytes: Data
    private(set) var started: [String] = []
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    init(_ bytes: Data) { self.bytes = bytes }
    func data(from url: URL) async throws -> Data {
        let key = url.absoluteString
        started.append(key)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()) }
                else { waiters[key] = c }
            }
        } onCancel: { Task { await self.cancel(key) } }
        return bytes
    }
    func cancel(_ key: String) { waiters.removeValue(forKey: key)?.resume(throwing: CancellationError()) }
    func release(_ key: String) { waiters.removeValue(forKey: key)?.resume() }
}
private struct EmptyScrollMetadata: TokenArtworkMetadata {
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] { [] }
}
private actor ScrollGate {
    private var waiters: [String: CheckedContinuation<Int, Never>] = [:]
    private(set) var started: [String] = []
    func wait(_ id: String) async -> Int {
        started.append(id)
        return await withCheckedContinuation { waiters[id] = $0 }
    }
    func release(_ id: String, value: Int = 1) { waiters.removeValue(forKey: id)?.resume(returning: value) }
}

final class ArtworkScrollingTests: XCTestCase, @unchecked Sendable {
    private let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><path fill='#00aaee' d='M0 0h24v24H0z'/></svg>".utf8)
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func until(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let met = await condition()
        XCTAssertTrue(met, "Controlled work did not reach its gate", file: file, line: line)
    }
    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testLargeImageUsesDisplayPixelsAndRetainsOriginalForExportOffline() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try png(width: 4096, height: 2048)
        let transport = ScrollImageGate(original), url = "https://cdn.example.org/large.png"
        let loader = ArtworkLoader(directory: dir, transport: transport)
        let request = Task { await loader.image(for: [url], maxPixelSize: 128) }
        try await until { await transport.started.count == 1 }
        await transport.release(url)
        let downloaded = await request.value
        let small = try XCTUnwrap(downloaded)
        guard case .raster(let image, _) = small else { return XCTFail("Expected bitmap") }
        XCTAssertEqual(image.width, 128); XCTAssertEqual(image.height, 64)
        XCTAssertLessThanOrEqual(small.memoryCost, 128 * 128 * 4)
        let envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: dir.appendingPathComponent(ArtworkSource.key(url) + ".artwork")), format: nil) as? [String: Any])
        XCTAssertEqual(envelope["data"] as? Data, original)
        let offline = ArtworkLoader(directory: dir, transport: ScrollImageGate(Data()))
        let export = await offline.cached(for: [url])
        guard case .raster(let full, _) = export else { return XCTFail("Original missing after relaunch") }
        XCTAssertEqual(full.width, 4096); XCTAssertEqual(full.height, 2048)
        print("SCROLL bitmap decoded bytes: display=\(small.memoryCost), original=\(full.bytesPerRow * full.height)")
    }
    func testSharedWorkSurvivesOneConsumerCancellationAndBoundsConcurrency() async throws {
        let pool = ArtworkWorkPool<String, Int>(concurrency: 1), gate = ScrollGate()
        let one = Task { await pool.value(for: "same") { await gate.wait("same") } }
        try await until { await pool.consumerCount(for: "same") == 1 }
        let two = Task { await pool.value(for: "same") { XCTFail("Duplicate producer"); return 2 } }
        try await until { await pool.consumerCount(for: "same") == 2 }
        let next = Task { await pool.value(for: "next") { await gate.wait("next") } }
        try await until { await pool.queuedCount == 1 }
        one.cancel()
        let cancelled = await one.value; XCTAssertNil(cancelled)
        let before = await gate.started; XCTAssertEqual(before, ["same"])
        await gate.release("same", value: 7)
        let shared = await two.value; XCTAssertEqual(shared, 7)
        try await until { await gate.started == ["same", "next"] }
        await gate.release("next")
        _ = await next.value
    }
    func testCancelledQueuedRowsNeverStartAndOldCompletionCannotReplaceNewOwner() async throws {
        let pool = ArtworkWorkPool<String, Int>(concurrency: 1), gate = ScrollGate()
        // Deliberately non-cooperative producer: retain the slot until it exits.
        let old = Task { await pool.value(for: "same") { await gate.wait("old") } }
        try await until { await gate.started == ["old"] }
        let queued = (0..<24).map { n in Task { await pool.value(for: "old-\(n)") { XCTFail("Invisible queued work started"); return n } } }
        try await until { await pool.queuedCount == 24 }
        for task in queued { task.cancel() }
        for task in queued { let result = await task.value; XCTAssertNil(result) }
        old.cancel(); _ = await old.value
        let visible = Task { await pool.value(for: "same") { await gate.wait("new") } }
        try await until { await pool.consumerCount(for: "same") == 1 }
        await gate.release("old", value: 99)
        try await until { await gate.started == ["old", "new"] }
        await gate.release("new", value: 5)
        let result = await visible.value; XCTAssertEqual(result, 5)
    }
    func testQueueEvictionIsBoundedAndDoesNotEvictActiveWork() async throws {
        let pool = ArtworkWorkPool<String, Int>(concurrency: 1, queueLimit: 1), gate = ScrollGate()
        let active = Task { await pool.value(for: "active") { await gate.wait("active") } }
        try await until { await gate.started == ["active"] }
        let obsolete = Task { await pool.value(for: "obsolete") { XCTFail("Evicted work started"); return 0 } }
        try await until { await pool.queuedCount == 1 }
        let visible = Task { await pool.value(for: "visible") { 2 } }
        let evicted = await obsolete.value; XCTAssertNil(evicted)
        await gate.release("active")
        let a = await active.value, v = await visible.value
        XCTAssertEqual(a, 1); XCTAssertEqual(v, 2)
    }
    func testQueuedWorkRetainsItsOwnDiagnosticContext() async throws {
        let pool = ArtworkWorkPool<String, Int>(concurrency: 1), gate = ScrollGate()
        let firstID = UUID(), secondID = UUID()
        let active = Task {
            await OathDiagnostics.$chain.withValue("eth") {
                await OathDiagnostics.$operationID.withValue(firstID) {
                    await pool.value(for: "active") { await gate.wait("active") }
                }
            }
        }
        try await until { await gate.started == ["active"] }
        let queued = Task {
            await OathDiagnostics.$chain.withValue("solana") {
                await OathDiagnostics.$operationID.withValue(secondID) {
                    await pool.value(for: "queued") {
                        XCTAssertEqual(OathDiagnostics.chain, "solana")
                        XCTAssertEqual(OathDiagnostics.operationID, secondID)
                        return 2
                    }
                }
            }
        }
        try await until { await pool.queuedCount == 1 }
        await gate.release("active")
        _ = await active.value
        let result = await queued.value; XCTAssertEqual(result, 2)
    }
    func testLoaderCancelsInvisibleDownloadsWithoutWritingFailureCooldown() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = ScrollImageGate(svg), loader = ArtworkLoader(directory: dir, transport: transport)
        let urls = (0..<24).map { "https://cdn.example.org/\($0).svg" }
        let requests = urls.map { url in Task { await loader.image(for: [url], maxPixelSize: 128) } }
        try await until { await transport.started.count == 6 }
        for request in requests { request.cancel() }
        for request in requests { _ = await request.value }
        let visibleURL = "https://cdn.example.org/visible.svg"
        let visible = Task { await loader.image(for: [visibleURL], maxPixelSize: 128) }
        try await until { await transport.started.contains(visibleURL) }
        await transport.release(visibleURL)
        let result = await visible.value; XCTAssertNotNil(result)
        let calls = await transport.started
        XCTAssertEqual(calls.count, 7, "Queued invisible downloads must not delay the new visible row")
        let retry = Task { await loader.image(for: [calls[0]], maxPixelSize: 128) }
        try await until { await transport.started.count == 8 }
        await transport.release(calls[0]); let recovered = await retry.value
        XCTAssertNotNil(recovered, "Cancellation is not a failed-image cooldown")
    }
    func testResolverDoesNotRedeliverUnchangedWarmImages() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = ScrollImageGate(svg), url = "https://cdn.example.org/token.svg"
        let loader = ArtworkLoader(directory: dir.appendingPathComponent("images"), transport: transport)
        let resolver = TokenArtworkResolver(loader: loader, metadata: EmptyScrollMetadata(), directory: dir.appendingPathComponent("identity"))
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "near", reference: "fixture.near", decimals: 6))
        let prime = Task { await resolver.image(for: token, sources: [url], maxPixelSize: 128) }
        try await until { await transport.started.count == 1 }; await transport.release(url)
        let first = await prime.value; XCTAssertNotNil(first)
        let observer = UUID(), stream = await resolver.updates(for: token, observerID: observer, maxPixelSize: 128)
        let reader = Task { var count = 0; for await _ in stream { count += 1 }; return count }
        for _ in 0..<3 { _ = await resolver.image(for: token, sources: [url], maxPixelSize: 128) }
        await resolver.stopUpdates(for: token, observerID: observer)
        let deliveries = await reader.value, calls = await transport.started
        XCTAssertEqual(deliveries, 1); XCTAssertEqual(calls.count, 1)
    }
    func testDiskAccountingScansOnceAndEnforcesByteAndEntryLimits() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = ArtworkDiskIndex(directory: dir, extensions: ["artwork", "missing"], byteLimit: 100, countLimits: ["missing": 3])
        for n in 0..<40 {
            let file = dir.appendingPathComponent("\(n).artwork")
            try Data(repeating: 1, count: 10).write(to: file); index.wrote(file, bytes: 10)
        }
        for n in 0..<20 {
            let file = dir.appendingPathComponent("\(n).missing")
            try Data([1]).write(to: file); index.wrote(file, bytes: 1)
        }
        XCTAssertEqual(index.scans, 1, "No filesystem enumeration per logo completion")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        XCTAssertLessThanOrEqual(bytes, 100)
        XCTAssertEqual(files.filter { $0.pathExtension == "missing" }.count, 3)
    }
}
