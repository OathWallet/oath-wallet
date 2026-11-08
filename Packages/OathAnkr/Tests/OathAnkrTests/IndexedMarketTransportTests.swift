import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

/// Models the production transport's legacy normalization separately from its
/// cause-preserving entry point. No wallet or authenticated request is used.
private actor IndexedMarketFailureFeed: AnkrTransport {
    let code: URLError.Code
    var remaining: Int
    let live: Bool
    let transport = AnkrHTTPTransport()
    private(set) var calls = 0
    private(set) var legacyCalls = 0
    init(_ code: URLError.Code, failures: Int = 99, live: Bool = false) {
        self.code = code; remaining = failures; self.live = live
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        legacyCalls += 1
        do { return try await sendPreservingTransportError(request) }
        catch { throw AnkrError.transport }
    }
    func sendPreservingTransportError(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        if remaining > 0 { remaining -= 1; throw URLError(code) }
        if live { return try await transport.sendPreservingTransportError(request) }
        return (Data(#"[{"id":"fixture","platforms":{"monad":"0x1111111111111111111111111111111111111111"}}]"#.utf8), 200)
    }
}

private final class IndexedCertificateProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var attempts = 0
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.attempts } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "api.coinbase.com" {
            Self.state.lock.withLock { Self.state.attempts += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let payload: [String: Any] = ["coins": [request.url!.lastPathComponent: ["price": 2.5, "confidence": 0.99, "timestamp": Date().timeIntervalSince1970]]]
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor IndexedMarketReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class IndexedMarketTransportTests: XCTestCase, @unchecked Sendable {
    func testTLSCertificateAndOfflineDoNotRetrySameEndpoint() async throws {
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted,
                     .serverCertificateHasBadDate, .notConnectedToInternet] {
            let feed = IndexedMarketFailureFeed(code)
            do { _ = try await IndexedEVMMarkets(chain: .monad, transport: feed).catalog(); XCTFail("Expected outage") }
            catch { XCTAssertEqual(error as? AnkrError, .transport) }
            let calls = await feed.calls, legacy = await feed.legacyCalls
            XCTAssertEqual(calls, 1); XCTAssertEqual(legacy, 0)
            let hyper = IndexedMarketFailureFeed(code)
            do { _ = try await HyperEVMMarkets(transport: hyper).catalog(); XCTFail("Expected outage") }
            catch { XCTAssertEqual(error as? AnkrError, .transport) }
            let hyperCalls = await hyper.calls, hyperLegacy = await hyper.legacyCalls
            XCTAssertEqual(hyperCalls, 1); XCTAssertEqual(hyperLegacy, 0)
        }
    }
    func testTransientConnectionLossRecoversAndPersistentFailureIsBounded() async throws {
        for failures in [1, 99] {
            let feed = IndexedMarketFailureFeed(.networkConnectionLost, failures: failures)
            do {
                let result = try await IndexedEVMMarkets(chain: .monad, transport: feed).catalog()
                XCTAssertEqual(failures, 1); XCTAssertEqual(result.ids.count, 1)
            } catch { XCTAssertEqual(failures, 99); XCTAssertEqual(error as? AnkrError, .transport) }
            let calls = await feed.calls, legacy = await feed.legacyCalls
            XCTAssertEqual(calls, failures == 1 ? 2 : 3); XCTAssertEqual(legacy, 0)
        }
    }
    func testURLCancellationDoesNotRetryOrStartFallback() async throws {
        let feed = IndexedMarketFailureFeed(.cancelled)
        do { _ = try await IndexedEVMMarkets(chain: .monad, transport: feed).nativePrice(); XCTFail("Cancellation returned price") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await feed.calls
        XCTAssertEqual(calls, 1)
    }
    func testProductionTransportCertificateFailureUsesFallbackAfterOneAttempt() async throws {
        guard ProcessInfo.processInfo.environment["OATH_INDEXED_MARKET_CAPTURE"] == "1" else {
            throw XCTSkip("Isolated shared market pool and diagnostic recorder")
        }
        let reports = IndexedMarketReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IndexedCertificateProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let operation = UUID()
        let quote = try await OathDiagnostics.$operationID.withValue(operation) {
            try await IndexedEVMMarkets(chain: .monad, transport: AnkrHTTPTransport(session: session)).nativePrice()
        }
        XCTAssertEqual(quote.source, "DefiLlama"); XCTAssertEqual(quote.usd, "2.5")
        XCTAssertEqual(IndexedCertificateProtocol.count, 1)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operation == "market_read" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == operation && $0.operation == "market_read" }
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.error.domain, NSURLErrorDomain)
        XCTAssertEqual(event.error.code, URLError.serverCertificateUntrusted.rawValue)
        XCTAssertEqual(event.context["chain"], "monad")
        XCTAssertEqual(event.context["host"], "api.coinbase.com")
        XCTAssertTrue(event.privacyFiltered)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("https://")); XCTAssertFalse(encoded.contains("MON-USD"))
    }
    func testLiveQuoteRecoversConnectionLossAndMatchesIndependentPrice() async throws {
        guard ProcessInfo.processInfo.environment["OATH_INDEXED_MARKET_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only public market request")
        }
        for chain in [IndexedEVMChain.monad, .unichain] {
            let feed = IndexedMarketFailureFeed(.networkConnectionLost, failures: 1, live: true)
            let quote = try await IndexedEVMMarkets(chain: chain, transport: feed).nativePrice()
            XCTAssertEqual(quote.chain, chain); XCTAssertEqual(quote.source, "Coinbase")
            let calls = await feed.calls, legacy = await feed.legacyCalls
            XCTAssertEqual(calls, 2); XCTAssertEqual(legacy, 0)
            let key = "coingecko:" + (chain == .monad ? "monad" : "ethereum")
            let (data, status) = try await AnkrHTTPTransport().sendPreservingTransportError(URLRequest(url: URL(string: "https://coins.llama.fi/prices/current/" + key)!))
            XCTAssertEqual(status, 200)
            let independent = try NativePriceFallback.decodeLlama(JSONDecoder().decode(SolanaJSON.self, from: data), key: key)
            let a = try XCTUnwrap(Double(quote.usd)), b = try XCTUnwrap(Double(independent.usd))
            XCTAssertGreaterThan(a, 0); XCTAssertLessThan(abs(a-b)/b, 0.15)
            print("LIVE_MARKET \(chain.rawValue): injected connection loss recovered; Coinbase and DefiLlama verified within 15 percent")
        }
    }
}
