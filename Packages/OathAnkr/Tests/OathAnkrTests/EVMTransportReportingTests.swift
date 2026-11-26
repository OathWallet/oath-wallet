import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private final class EVMNativeTLSProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)) }
    override func stopLoading() {}
}
private actor EVMTransportReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}
private actor EVMNativeFailureFeed: AnkrTransport {
    let code: URLError.Code
    let live: Bool
    var hosts: [String] = []
    let http = AnkrHTTPTransport()
    init(_ code: URLError.Code, live: Bool = false) { self.code = code; self.live = live }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        hosts.append(request.url!.host!)
        if request.url?.host == "failure.example" { throw URLError(code) }
        if live { return try await http.sendPreservingTransportError(request) }
        return (Data(#"[{"jsonrpc":"2.0","id":0,"result":"0x1"},{"jsonrpc":"2.0","id":1,"result":"0x2a"}]"#.utf8), 200)
    }
}
final class EVMTransportReportingTests: XCTestCase, @unchecked Sendable {
    private let owner = "0x1111111111111111111111111111111111111111"

    func testProductionTLSIsReportedOnceWithMethodAndNoPrivateRequestData() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_TRANSPORT_CAPTURE"] == "1" else { throw XCTSkip("Isolated local capture") }
        let capture = EVMTransportReports(), operation = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: capture)
        let ready = UUID()
        for _ in 0..<100 {
            OathDiagnostics.$operationID.withValue(ready) {
                OathDiagnostics.record(DiagnosticFailure("ready"), component: "fixture", operation: "ready")
            }
            try await Task.sleep(for: .milliseconds(25))
            if await capture.events.contains(where: { $0.operationID == ready }) { break }
        }
        let readyEvents = await capture.events
        XCTAssertTrue(readyEvents.contains { $0.operationID == ready })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EVMNativeTLSProtocol.self]
        let client = try EVMSendClient(network: .ethereum,
            endpoints: [URL(string: "https://rpc.ankr.com/eth/PrivateFixtureKey")!],
            transport: AnkrHTTPTransport(session: URLSession(configuration: config)))
        do { _ = try await OathDiagnostics.$operationID.withValue(operation) {
            try await client.balance(owner: owner, reference: "native")
        }; XCTFail() } catch { XCTAssertEqual(error as? AnkrError, .transport) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            // Drain late caller copies too; seeing the first report alone does
            // not establish that this failure was reported only once.
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events.filter { $0.operationID == operation }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.domain, NSURLErrorDomain)
        XCTAssertEqual(events.first?.error.code, -1200)
        XCTAssertEqual(events.first?.operation, "eth_getBalance")
        XCTAssertEqual(events.first?.context["method"], "eth_getBalance")
        XCTAssertEqual(events.first?.context["chain"], "ethereum")
        XCTAssertEqual(events.first?.context["host"], "rpc.ankr.com")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(owner)); XCTAssertFalse(encoded.contains("PrivateFixtureKey"))
    }

    func testTLSAndConnectionLossCanUseIndependentChainVerifiedFallback() async throws {
        for code in [URLError.Code.secureConnectionFailed, .networkConnectionLost] {
            let feed = EVMNativeFailureFeed(code)
            let client = try EVMSendClient(network: .ethereum,
                endpoints: [URL(string: "https://failure.example")!, URL(string: "https://backup.example")!], transport: feed)
            let value = try await client.balance(owner: owner, reference: "native")
            XCTAssertEqual(value, "42")
            let hosts = await feed.hosts
            XCTAssertEqual(hosts, ["failure.example", "backup.example"])
        }
    }

    func testNativeCancellationStopsBeforeFallbackAndReleasesPermits() async throws {
        let feed = EVMNativeFailureFeed(.cancelled)
        let client = try EVMSendClient(network: .ethereum,
            endpoints: [URL(string: "https://failure.example")!, URL(string: "https://backup.example")!], transport: feed)
        for _ in 0..<6 {
            do { _ = try await client.balance(owner: owner, reference: "native"); XCTFail("Cancelled read must not return fallback data") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, Array(repeating: "failure.example", count: 6))
    }

    func testLiveTLSFallbackMatchesIndependentPinnedPublicBalance() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_TRANSPORT_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only comparison") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let endpoint = URL(string: "https://rpc.ankr.com/flare")!.appendingPathComponent(try XCTUnwrap(config["AnkrAPIKey"]))
        let oracle = try EVMSendClient(network: .flare, endpoints: [URL(string: "https://flare-api.flare.network/ext/C/rpc")!])
        let head = try await oracle.rpc("eth_blockNumber", [])
        let publicOwner = "0x85d134f68c3c564bb935479490e5c8df5f4f1124"
        let params: [SolanaJSON] = [.string(publicOwner), head]
        let expected = try await oracle.rpc("eth_getBalance", params)
        let feed = EVMNativeFailureFeed(.secureConnectionFailed, live: true)
        let client = try EVMSendClient(network: .flare,
            endpoints: [URL(string: "https://failure.example")!, endpoint], transport: feed)
        let actual = try await client.rpc("eth_getBalance", params)
        XCTAssertEqual(actual, expected)
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["failure.example", "rpc.ankr.com"])
        print("LIVE_EVM_TLS injected primary TLS failure; real ANKR fallback matched independent Flare balance at the same block")
    }
}
