import XCTest
@testable import OathAnkr

private actor InterruptedArchive: AnkrTransport {
    enum Failure { case handshake, untrusted, nestedTrust, disconnected }
    var failures: [Failure]
    let live: Bool
    var requests: [URLRequest] = []
    init(_ failures: [Failure], live: Bool = false) { self.failures = failures; self.live = live }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if !failures.isEmpty {
            switch failures.removeFirst() {
            case .handshake:
                throw URLError(.secureConnectionFailed, userInfo: [NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: -1200)])
            case .untrusted: throw URLError(.serverCertificateUntrusted)
            case .nestedTrust:
                throw URLError(.secureConnectionFailed, userInfo: [NSUnderlyingErrorKey: URLError(.serverCertificateUntrusted)])
            case .disconnected: throw URLError(.notConnectedToInternet)
            }
        }
        if live { return try await AnkrHTTPTransport().sendPreservingTransportError(request) }
        return (Data(#"{"docs":[],"total":0,"pages":0,"page":0}"#.utf8), 200)
    }
}

final class ThorchainArchiveRecoveryTests: XCTestCase, @unchecked Sendable {
    private let owner = "thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2"

    func testArchiveRetriesSamePageOnceAndPreservesPublicErrorTypes() async throws {
        for (failures, expectedCalls, succeeds): ([InterruptedArchive.Failure], Int, Bool) in [
            ([.handshake], 2, true), ([.handshake, .handshake], 2, false),
            ([.untrusted], 1, false), ([.nestedTrust], 1, false), ([.disconnected], 1, false)
        ] {
            let transport = InterruptedArchive(failures)
            do {
                let page = try await ThorchainClient(transport: transport).history(owner: owner, stream: "archive", height: 100, page: 3)
                XCTAssertTrue(succeeds)
                XCTAssertTrue(page.events.isEmpty)
            } catch { XCTAssertFalse(succeeds); XCTAssertEqual(error as? ThorchainError, .transport) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, expectedCalls)
            XCTAssertEqual(Set(requests.compactMap(\.url)).count, 1)
            XCTAssertEqual(requests.first?.url?.query, "page=3")
            XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.httpMethod == "GET" && $0.httpBody == nil })
        }
    }

    func testPublicArchivePageAfterInterruptedTLSMatchesDirectRead() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THOR_ARCHIVE_TLS_LIVE"] == "1" else {
            throw XCTSkip("Read-only public THORChain archive")
        }
        let client = ThorchainClient()
        let height = try await client.latestHeight()
        let transport = InterruptedArchive([.handshake], live: true)
        let recovered = try await ThorchainClient(transport: transport).history(owner: owner, stream: "archive", height: height)
        try await Task.sleep(for: .seconds(2))
        let direct = try await client.history(owner: owner, stream: "archive", height: height)
        XCTAssertFalse(recovered.events.isEmpty)
        XCTAssertEqual(recovered.events.map(\.id), direct.events.map(\.id))
        XCTAssertEqual(recovered.events.map(\.amount), direct.events.map(\.amount))
        XCTAssertEqual(recovered.next, direct.next)
        XCTAssertEqual(recovered.rawCount, direct.rawCount)
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
        print("THOR archive public comparison rows=\(direct.rawCount) activities=\(direct.events.count)")
    }
}
