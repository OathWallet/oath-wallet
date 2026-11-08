import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor NativeAnkrFailure: AnkrTransport {
    let code: URLError.Code
    let failures: Int
    var calls = 0
    init(_ code: URLError.Code, failures: Int = 1) { self.code = code; self.failures = failures }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        if calls <= failures { throw URLError(code) }
        return (Data(#"{"jsonrpc":"2.0","id":1,"result":{"assets":[],"totalBalanceUsd":"0","totalCount":0}}"#.utf8), 200)
    }
}

private final class AnkrTLSProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)) }
    override func stopLoading() {}
}

private actor AnkrTLSCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}

final class AnkrFailureRecoveryTests: XCTestCase, @unchecked Sendable {
    private let owner = "0x1111111111111111111111111111111111111111"

    func testEveryStoryAdvancedEntryRejectsBeforeNetworkEvenWithSavedCursor() async throws {
        let feed = NativeAnkrFailure(.timedOut)
        let client = try AnkrClient(apiKey: "fixture", transport: feed)
        for cursor in [nil, "old-story-cursor"] as [String?] {
            do { _ = try await client.balances(chain: .story, address: owner, cursor: cursor); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError, .wrongChain) }
            do { _ = try await client.transactions(chain: .story, address: owner, cursor: cursor); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError, .wrongChain) }
            do { _ = try await client.transfers(chain: .story, address: owner, cursor: cursor); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError, .wrongChain) }
        }
        let calls = await feed.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(AnkrChain(rawValue: "story_mainnet"), .story, "Saved data must remain decodable")
    }

    func testTLSCertificateAndOfflineFailuresAreNotRetried() async throws {
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted,
                     .serverCertificateHasBadDate, .notConnectedToInternet] {
            let feed = NativeAnkrFailure(code, failures: 10)
            let client = try AnkrClient(apiKey: "fixture", transport: feed)
            do { _ = try await client.balances(chain: .eth, address: owner); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError, .transport) }
            let calls = await feed.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testTransientReadsRetryAndBudgetRemainsBounded() async throws {
        let feed = NativeAnkrFailure(.timedOut, failures: 2)
        let client = try AnkrClient(apiKey: "fixture", transport: feed)
        let page = try await client.balances(chain: .eth, address: owner)
        XCTAssertTrue(page.value.assets.isEmpty)
        let calls = await feed.calls
        XCTAssertEqual(calls, 3)
        let exhausted = NativeAnkrFailure(.networkConnectionLost, failures: 10)
        do { _ = try await AnkrClient(apiKey: "fixture", transport: exhausted).balances(chain: .eth, address: owner); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .transport) }
        let attempts = await exhausted.calls
        XCTAssertEqual(attempts, 3)
    }

    func testCancellationReleasesPermitsAndNeverRetries() async throws {
        let feed = NativeAnkrFailure(.cancelled, failures: 10)
        let client = try AnkrClient(apiKey: "fixture", transport: feed)
        for _ in 0..<6 {
            do { _ = try await client.balances(chain: .eth, address: owner); XCTFail() }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let calls = await feed.calls
        XCTAssertEqual(calls, 6)
    }

    func testProductionTransportPreservesTLSForAdvancedRetryClassification() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnkrTLSProtocol.self]
        let transport = AnkrHTTPTransport(session: URLSession(configuration: config))
        let request = URLRequest(url: URL(string: "https://fixture.example/multichain/private-key")!)
        do { _ = try await transport.sendPreservingTransportError(request); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .secureConnectionFailed) }
        do { _ = try await transport.send(request); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .transport, "Other chain clients keep their existing fallback contract") }
    }

    func testTLSRecordsOriginalOnceWithSafeChainContext() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_TLS_CAPTURE"] == "1" else {
            throw XCTSkip("Isolated recorder capture")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = AnkrTLSCapture()
        OathDiagnostics.configure(file: folder.appendingPathComponent("reports.json"), transport: capture)
        let ready = UUID()
        for _ in 0..<100 {
            OathDiagnostics.$operationID.withValue(ready) {
                OathDiagnostics.record(DiagnosticFailure("ready"), component: "fixture", operation: "ready")
            }
            try await Task.sleep(for: .milliseconds(25))
            if await capture.events.contains(where: { $0.operationID == ready }) { break }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnkrTLSProtocol.self]
        let client = try AnkrClient(apiKey: "SecretFixtureKey", transport: AnkrHTTPTransport(session: URLSession(configuration: config)))
        let id = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(id) {
                try await client.balances(chain: .eth, address: owner)
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? AnkrError, .transport) }
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operationID == id }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { $0.operationID == id }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.domain, NSURLErrorDomain)
        XCTAssertEqual(events.first?.error.code, URLError.secureConnectionFailed.rawValue)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertTrue(encoded.contains("ethereum"))
        XCTAssertTrue(encoded.contains("rpc.ankr.com"))
        XCTAssertFalse(encoded.contains("SecretFixtureKey"))
        XCTAssertFalse(encoded.contains(owner))
    }
}
