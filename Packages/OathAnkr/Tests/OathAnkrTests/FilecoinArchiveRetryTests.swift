import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private final class ArchiveTLSCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
    func read() -> Int { lock.withLock { count } }
}
private final class ArchiveTLSProtocol: URLProtocol, @unchecked Sendable {
    static let calls = ArchiveTLSCount()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
    }
    override func stopLoading() {}
}
private actor ArchiveFailureFeed: AnkrTransport {
    let failure: URLError.Code
    let live: Bool
    var calls = 0
    let http = AnkrHTTPTransport()
    init(_ failure: URLError.Code, live: Bool = false) { self.failure = failure; self.live = live }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        if calls == 1 { throw URLError(failure) }
        if live { return try await http.sendPreservingTransportError(request) }
        return (try JSONSerialization.data(withJSONObject: ["ethTransactionHash": request.url!.lastPathComponent]), 200)
    }
}
private actor ArchiveReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}
final class FilecoinArchiveRetryTests: XCTestCase, @unchecked Sendable {
    private let fixtureHash = "0x" + String(repeating: "a", count: 64)
    private func tls() -> AnkrHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArchiveTLSProtocol.self]
        return AnkrHTTPTransport(session: URLSession(configuration: config))
    }
    func testProductionTLSFailureDoesNotBecomeFourTransportAttempts() async throws {
        ArchiveTLSProtocol.calls.reset()
        do { _ = try await FilecoinHistoryArchive(transport: tls()).messages(hashes: [fixtureHash]); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .transport) }
        XCTAssertEqual(ArchiveTLSProtocol.calls.read(), 1)
    }
    func testCertificateOfflineAndCancellationDoNotRetry() async throws {
        for code in [URLError.Code.serverCertificateUntrusted, .notConnectedToInternet, .cancelled] {
            let feed = ArchiveFailureFeed(code)
            do { _ = try await FilecoinHistoryArchive(transport: feed).messages(hashes: [fixtureHash]); XCTFail() }
            catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? AnkrError, .transport) }
            }
            let calls = await feed.calls; XCTAssertEqual(calls, 1)
        }
    }
    func testDroppedConnectionRecoversAndDoesNotCacheFailure() async throws {
        let feed = ArchiveFailureFeed(.networkConnectionLost), archive = FilecoinHistoryArchive(transport: feed)
        let first = try await archive.messages(hashes: [fixtureHash])
        let second = try await archive.messages(hashes: [fixtureHash])
        XCTAssertEqual(first, second); XCTAssertEqual(first[fixtureHash]?["ethTransactionHash"].string, fixtureHash)
        let calls = await feed.calls; XCTAssertEqual(calls, 2)
    }
    func testOriginalTLSIsReportedOnceWithoutPrivateRequestData() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_TLS_CAPTURE"] == "1" else { throw XCTSkip("Isolated local diagnostics capture") }
        let capture = ArchiveReports(), operation = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: capture)
        do { _ = try await OathDiagnostics.$operationID.withValue(operation) {
            try await FilecoinHistoryArchive(transport: tls()).messages(hashes: [fixtureHash])
        }; XCTFail() } catch { XCTAssertEqual(error as? AnkrError, .transport) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events.contains(where: { $0.operationID == operation }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events.filter { $0.operationID == operation }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.domain, NSURLErrorDomain)
        XCTAssertEqual(events.first?.error.code, -1200)
        XCTAssertEqual(events.first?.context["chain"], "filecoin")
        XCTAssertEqual(events.first?.context["host"], "filfox.info")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains(fixtureHash))
    }
    func testLiveArchiveRecoversDroppedConnectionAndCorroboratesPublicTransaction() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_ARCHIVE_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only archive check") }
        var request = URLRequest(url: URL(string: "https://filecoin.blockscout.com/api/v2/addresses/0xb74749b2213916b1da3b869e41c7c57f1db69393/transactions")!)
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        let (data, status) = try await AnkrHTTPTransport().send(request)
        XCTAssertEqual(status, 200)
        let json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        let row = try XCTUnwrap(json["items"].array?.first)
        let hash = try XCTUnwrap(row["hash"].string?.lowercased())
        let feed = ArchiveFailureFeed(.networkConnectionLost, live: true)
        let messages = try await FilecoinHistoryArchive(transport: feed).messages(hashes: [hash])
        let verified = try FilecoinHistoryArchive.corroborate(rows: [row], messages: messages, stream: .transactions)
        XCTAssertEqual(verified.count, 1)
        let calls = await feed.calls; XCTAssertEqual(calls, 2)
        print("LIVE_FILECOIN_ARCHIVE dropped connection recovered; public transaction amount, parties, height and receipt corroborated against independent explorer")
    }
}
