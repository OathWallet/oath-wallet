import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private final class CauseProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var code = URLError.Code.secureConnectionFailed
    private var remaining = 99
    private var calls = 0
    func reset(_ code: URLError.Code, failures: Int = 99) {
        lock.withLock { self.code = code; remaining = failures; calls = 0 }
    }
    func next() -> URLError.Code? {
        lock.withLock { calls += 1; if remaining > 0 { remaining -= 1; return code }; return nil }
    }
    var count: Int { lock.withLock { calls } }
}
private final class CauseHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = CauseProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let code = Self.state.next() { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Retry-After": "7"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SharedReadTransportCauseTests: XCTestCase, @unchecked Sendable {
    func testProductionTransportDoesNotTurnTLSOrOfflineIntoSameHostRetries() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted,
                     .serverCertificateHasBadDate, .notConnectedToInternet] {
            CauseHTTPProtocol.state.reset(code)
            do { _ = try await TonClient(testTransport: transport).indexed("accounts/fixture"); XCTFail() }
            catch { XCTAssertEqual(error as? TonError, .transport) }
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "TON index must not retry \(code)")

            CauseHTTPProtocol.state.reset(code)
            do { _ = try await NearClient(apiKey: "fixture", transport: transport).discovery(owner: "fixture.near"); XCTFail() }
            catch { XCTAssertEqual(error as? NearError, .transport) }
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "NEAR index must not retry \(code)")

            CauseHTTPProtocol.state.reset(code)
            do { _ = try await TronClient(apiKey: "fixture", network: .nile, transport: transport).batch([("eth_chainId", [])]); XCTFail() }
            catch { XCTAssertEqual(error as? TronError, .transport) }
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "TRON node must not retry \(code)")

            CauseHTTPProtocol.state.reset(code)
            do { _ = try await ThorchainClient(transport: transport).read(ThorchainClient.node, path: "thorchain/network"); XCTFail() }
            catch { XCTAssertEqual(error as? ThorchainError, .transport) }
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "THORChain node must not retry \(code)")

            CauseHTTPProtocol.state.reset(code)
            do {
                _ = try await IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport)
                    .history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions)
                XCTFail()
            } catch { XCTAssertEqual(error as? AnkrError, .transport) }
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "Indexed EVM must not retry \(code)")
        }
    }

    func testNativeConnectionLossStillRecoversAndHeadersSurvive() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        CauseHTTPProtocol.state.reset(.networkConnectionLost, failures: 1)
        _ = try await ThorchainClient(transport: transport).read(ThorchainClient.node, path: "thorchain/network")
        XCTAssertEqual(CauseHTTPProtocol.state.count, 2)
        let response = try await transport.sendResponsePreservingTransportError(URLRequest(url: URL(string: "https://fixture.invalid/rpc")!))
        XCTAssertEqual(response.retryAfter, "7")
        XCTAssertEqual(response.status, 200)
        CauseHTTPProtocol.state.reset(.networkConnectionLost, failures: 1)
        do {
            _ = try await IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport)
                .history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions)
            XCTFail()
        } catch { XCTAssertEqual(error as? AnkrError, .invalidResponse, "The second request must reach response validation") }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 2)
    }

    func testCancellationStillEscapesEveryReadClientWithoutRetry() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        CauseHTTPProtocol.state.reset(.cancelled)
        do { _ = try await TonClient(testTransport: transport).indexed("accounts/fixture"); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
        CauseHTTPProtocol.state.reset(.cancelled)
        do { _ = try await NearClient(apiKey: "fixture", transport: transport).discovery(owner: "fixture.near"); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
        CauseHTTPProtocol.state.reset(.cancelled)
        do { _ = try await TronClient(apiKey: "fixture", network: .nile, transport: transport).batch([("eth_chainId", [])]); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
        CauseHTTPProtocol.state.reset(.cancelled)
        do { _ = try await ThorchainClient(transport: transport).read(ThorchainClient.node, path: "thorchain/network"); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
        CauseHTTPProtocol.state.reset(.cancelled)
        do {
            _ = try await IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport)
                .history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions)
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
    }
}

/// Only the primary is intercepted. The independent TON Center and TonAPI
/// responses below traverse real HTTPS and the production decoder/identity gate.
private final class FailedPrimaryLiveProtocol: URLProtocol, @unchecked Sendable {
    static let state = CauseProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "rpc.ankr.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        _ = Self.state.next()
        client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
    }
    override func stopLoading() {}
}
extension SharedReadTransportCauseTests {
    func testLiveTONIndexAndIndependentRecoveryAfterNativeTLSFailure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SHARED_READ_LIVE"] == "1" else {
            throw XCTSkip("Read-only public TON index and independent-node check")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailedPrimaryLiveProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        FailedPrimaryLiveProtocol.state.reset(.secureConnectionFailed)
        let client = try TonClient(apiKey: "fixture", transport: AnkrHTTPTransport(session: session))
        try await client.verifyNetwork()
        XCTAssertEqual(FailedPrimaryLiveProtocol.state.count, 1, "One primary TLS attempt, then independently verified recovery")
        let account = try await client.indexed("accounts/" + TonTests.owner)
        XCTAssertEqual(account["address"].string, TonTests.owner)
        XCTAssertNotNil(account["balance"].text)
        print("LIVE_TON native TLS primary attempts=1; independent genesis verified; public TonAPI account decoded")
    }
}

extension SharedReadTransportCauseTests {
    func testReportedRefreshStillPreservesPartialFailureAndCancellationStates() throws {
        let partial = OathDiagnostics.recordedForPropagation(BalanceRefreshError.incomplete)
        let outcome = BalanceRefreshOutcome(.failure(partial))
        guard case .partial = outcome else { return XCTFail("Partial balance coverage became a total failure") }
        do { try outcome.get(); XCTFail("Partial coverage became success") }
        catch { XCTAssertEqual((error as? ReportedDiagnosticFailure)?.underlying as? BalanceRefreshError, .incomplete) }
        let failure = OathDiagnostics.recordedForPropagation(AnkrError.rpc(-32602))
        guard case .failed = BalanceRefreshOutcome(.failure(failure)) else { return XCTFail("Terminal failure was hidden") }
        guard case .cancelled = BalanceRefreshOutcome(.failure(OathDiagnostics.recordedForPropagation(CancellationError()))) else {
            return XCTFail("Cancellation became a failure")
        }
    }
}


extension SharedReadTransportCauseTests {
    func testRemainingReadClientsDoNotRetryNativeTLS() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .notConnectedToInternet] {
        CauseHTTPProtocol.state.reset(code)
        do { _ = try await AptosClient(testTransport: transport).indexed("query { fixture }"); XCTFail() }
        catch { XCTAssertEqual(error as? AptosError, .transport) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "Aptos index must not retry TLS")
        CauseHTTPProtocol.state.reset(code)
        do {
            _ = try await PolkadotClient(endpoints: [URL(string: "https://fixture.invalid")!], transport: transport).finalizedBlock()
            XCTFail()
        } catch { XCTAssertEqual((error as? URLError)?.code, code) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "Polkadot must not retry TLS")
        CauseHTTPProtocol.state.reset(code)
        do {
            _ = try await SolanaClient(apiKey: "fixture", transport: transport).signatures(address: String(repeating: "1", count: 32), limit: 1)
            XCTFail()
        } catch { XCTAssertEqual(error as? SolanaError, .transport) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 2, "One request per independent Solana endpoint, no same-host TLS retries")
        }
    }
}


extension SharedReadTransportCauseTests {
    func testRemainingReadClientsRetainTransientRetriesAndCancellation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        CauseHTTPProtocol.state.reset(.networkConnectionLost, failures: 1)
        do { _ = try await AptosClient(testTransport: transport).indexed("query { fixture }"); XCTFail() }
        catch { XCTAssertEqual(error as? AptosError, .indexer, "Second response must reach index validation") }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 2)
        CauseHTTPProtocol.state.reset(.networkConnectionLost, failures: 1)
        do { _ = try await PolkadotClient(endpoints: [URL(string: "https://fixture.invalid")!], transport: transport).finalizedBlock(); XCTFail() }
        catch { XCTAssertEqual(error as? PolkadotError, .malformed) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 2)
        CauseHTTPProtocol.state.reset(.networkConnectionLost, failures: 1)
        do { _ = try await SolanaClient(apiKey: "fixture", transport: transport).signatures(address: String(repeating: "1", count: 32), limit: 1); XCTFail() }
        catch { XCTAssertEqual(error as? SolanaError, .malformed) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 3, "Archive retries connection loss; malformed reply reaches the existing independent primary")
        for client in 0..<3 {
            CauseHTTPProtocol.state.reset(.cancelled)
            do {
                if client == 0 { _ = try await AptosClient(testTransport: transport).indexed("query { fixture }") }
                else if client == 1 { _ = try await PolkadotClient(endpoints: [URL(string: "https://fixture.invalid")!], transport: transport).finalizedBlock() }
                else { _ = try await SolanaClient(apiKey: "fixture", transport: transport).signatures(address: String(repeating: "1", count: 32), limit: 1) }
                XCTFail()
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
        }
    }
}

private actor AptosReadCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}
private actor MalformedAptosRead: AnkrTransport {
    var count = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        return (Data("{broken-json".utf8), 200)
    }
}

extension SharedReadTransportCauseTests {
    func testMalformedAptosResponseDoesNotMasqueradeAsTransportAndVisitOtherProviders() async throws {
        let transport = MalformedAptosRead()
        do { _ = try await AptosClient(testTransport: transport).node(""); XCTFail() }
        catch { XCTAssertEqual(error as? AptosError, .malformed) }
        let requests = await transport.count
        XCTAssertEqual(requests, 1, "Malformed content is not a connectivity outage")
    }
    func testAptosOriginalNativeFailureRecordedOnceWithoutRequestContents() async throws {
        guard ProcessInfo.processInfo.environment["OATH_APTOS_READ_CAPTURE"] == "1" else { throw XCTSkip("Dedicated shared-recorder process") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = AptosReadCapture()
        OathDiagnostics.configure(file: folder.appendingPathComponent("diagnostics.json"), transport: capture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let op = UUID()
        CauseHTTPProtocol.state.reset(.serverCertificateUntrusted)
        await OathDiagnostics.$operationID.withValue(op) {
            do { _ = try await AptosClient(testTransport: AnkrHTTPTransport(session: session)).indexed("query private_request_marker { fixture }"); XCTFail() }
            catch { XCTAssertEqual(error as? AptosError, .transport) }
        }
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operationID == op }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { $0.operationID == op }
        XCTAssertEqual(events.count, 1, "Permit cleanup must not duplicate the native request failure")
        XCTAssertEqual(events.first?.error.code, URLError.Code.serverCertificateUntrusted.rawValue)
        XCTAssertEqual(events.first?.context["chain"], "aptos")
        XCTAssertEqual(events.first?.context["stage"], "index")
        XCTAssertEqual(events.first?.operation, "aptos_read")
        let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(serialized.contains("private_request_marker"))
        XCTAssertFalse(serialized.contains("query "))
        XCTAssertFalse(serialized.contains("https://"))
    }
}

extension SharedReadTransportCauseTests {
    func testHyperEVMTLSIsNotRetried() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CauseHTTPProtocol.state.reset(.secureConnectionFailed)
        do {
            _ = try await HyperEVMClient(apiKey: "fixture", transport: AnkrHTTPTransport(session: session))
                .history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions)
            XCTFail()
        } catch { XCTAssertEqual(error as? AnkrError, .transport) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 1, "HyperEVM must not repeat the same TLS failure")
    }
    func testMalformedSuiResponseRemainsMalformedWithoutFallback() async throws {
        let transport = MalformedAptosRead()
        do { _ = try await SuiClient(apiKey: "fixture", transport: transport).checkpoint(); XCTFail() }
        catch { XCTAssertEqual(error as? SuiError, .malformed) }
        let count = await transport.count
        XCTAssertEqual(count, 1, "Malformed JSON is not a transport failure")
    }
}

extension SharedReadTransportCauseTests {
    func testSuiXrplAndHyperEVMCancellationStopsBeforeFallback() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        for kind in 0..<3 {
            CauseHTTPProtocol.state.reset(.cancelled)
            do {
                if kind == 0 { _ = try await SuiClient(apiKey: "fixture", transport: transport).checkpoint() }
                else if kind == 1 { _ = try await XrplClient(apiKey: "fixture", transport: transport).validatedLedger() }
                else { _ = try await HyperEVMClient(apiKey: "fixture", transport: transport).history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions) }
                XCTFail()
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
        }
    }
    func testHyperEVMConnectionLossRetriesOnceThenValidatesReply() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CauseHTTPProtocol.state.reset(.networkConnectionLost, failures: 1)
        do { _ = try await HyperEVMClient(apiKey: "fixture", transport: AnkrHTTPTransport(session: session)).history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        XCTAssertEqual(CauseHTTPProtocol.state.count, 2)
    }
    func testRemainingClientsRecordOriginalNativeFailureOncePerEndpoint() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FINAL_READ_CAPTURE"] == "1" else { throw XCTSkip("Dedicated shared-recorder process") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = AptosReadCapture()
        OathDiagnostics.configure(file: folder.appendingPathComponent("diagnostics.json"), transport: capture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CauseHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        for chain in ["xrpl", "sui", "hyperevm"] {
            let op = UUID()
            CauseHTTPProtocol.state.reset(.serverCertificateUntrusted)
            await OathDiagnostics.$operationID.withValue(op) {
                do {
                    if chain == "xrpl" { _ = try await XrplClient(endpoint: URL(string: "https://fixture.invalid/private_path_marker")!, transport: transport).validatedLedger() }
                    else if chain == "sui" { _ = try await SuiClient(publicProvider: true, transport: transport).checkpoint() }
                    else { _ = try await HyperEVMClient(apiKey: "fixture", transport: transport).history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions) }
                    XCTFail()
                } catch { XCTAssertFalse(error is CancellationError) }
            }
            for _ in 0..<100 {
                if await capture.events.contains(where: { $0.operationID == op }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            await OathDiagnostics.flush()
            let events = await capture.events.filter { $0.operationID == op }
            XCTAssertEqual(events.count, 1, chain)
            XCTAssertEqual(events.first?.error.code, URLError.Code.serverCertificateUntrusted.rawValue)
            XCTAssertEqual(events.first?.context["chain"], chain)
            XCTAssertEqual(CauseHTTPProtocol.state.count, 1)
            let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
            for forbidden in ["private_path_marker", "https://", "0x1111111111111111111111111111111111111111"] { XCTAssertFalse(serialized.contains(forbidden)) }
        }
    }
}
