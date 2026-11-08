import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor TonIndexClockFeed: AnkrTransport {
    private(set) var starts: [ContinuousClock.Instant] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        starts.append(.now)
        return (Data(#"{"metadata":{"address":"0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe","decimals":"6"}}"#.utf8), 200)
    }
}
final class TonIndexPacingTests: XCTestCase, @unchecked Sendable {
    func testSeparateProductionClientsShareAnonymousIndexAllowance() async throws {
        let feed = TonIndexClockFeed()
        let first = try TonClient(apiKey: "fixture", transport: feed)
        let second = try TonClient(apiKey: "fixture", transport: feed)
        async let a = first.indexed("jettons/" + TonIdentity.usdt)
        async let b = second.indexed("jettons/" + TonIdentity.usdt)
        _ = try await (a, b)
        let starts = await feed.starts
        XCTAssertEqual(starts.count, 2)
        XCTAssertGreaterThanOrEqual(starts[0].duration(to: starts[1]), .seconds(4),
            "Independent clients must not burst through the shared anonymous allowance")
    }
}

private actor TonIndexLimitFeed: AnkrTransport {
    let firstStatus: Int
    init(firstStatus: Int = 429) { self.firstStatus = firstStatus }
    private(set) var indexCalls = 0
    private(set) var nodeCalls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "tonapi.io" {
            indexCalls += 1
            if indexCalls == 1 { return (Data(), firstStatus) }
            return (Data(#"{"balances":[]}"#.utf8), 200)
        }
        nodeCalls += 1
        return (Data(#"{"jsonrpc":"2.0","id":1,"result":{"state":"active","balance":"42"}}"#.utf8), 200)
    }
}
private actor TonIndexReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
extension TonIndexPacingTests {
    func testCooldownStopsQueuedClientsAndLeavesNodeReadsAvailable() async throws {
        let feed = TonIndexLimitFeed(), limiter = TonIndexRequests()
        let clients = (0..<4).map { _ in TonClient(testTransport: feed, indexRequests: limiter) }
        let outcomes = await withTaskGroup(of: TonError?.self) { group in
            for client in clients { group.addTask {
                do { _ = try await client.indexed("accounts/fixture/jettons"); return nil }
                catch { return error as? TonError }
            } }
            var values: [TonError?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 == .http(429) }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .indexCooldown }.count, 3)
        let calls = await feed.indexCalls
        XCTAssertEqual(calls, 1)
        let state = try await clients[0].rpc("getAddressInformation")
        XCTAssertEqual(state["balance"].string, "42")
        let nodes = await feed.nodeCalls
        XCTAssertEqual(nodes, 1)
        let (_, _, complete, cause) = try await clients[1].discovery("fixture")
        XCTAssertFalse(complete)
        XCTAssertEqual(cause, .indexCooldown, "Deferral must survive partial discovery instead of becoming a new generic failure")
    }
    func testRequestsResumeAfterBoundedCooldown() async throws {
        let feed = TonIndexLimitFeed(), limiter = TonIndexRequests(cooldown: .milliseconds(40))
        let client = TonClient(testTransport: feed, indexRequests: limiter)
        do { _ = try await client.indexed("accounts/fixture/jettons"); XCTFail() }
        catch { XCTAssertEqual(error as? TonError, .http(429)) }
        try await Task.sleep(for: .milliseconds(60))
        let value = try await client.indexed("accounts/fixture/jettons")
        XCTAssertEqual(value["balances"].array?.count, 0)
        let calls = await feed.indexCalls
        XCTAssertEqual(calls, 2)
    }
    func testCancelledPacingWaitReleasesSharedPermit() async throws {
        let feed = TonIndexClockFeed(), limiter = TonIndexRequests(spacing: .milliseconds(150))
        let client = TonClient(testTransport: feed, indexRequests: limiter)
        _ = try await client.indexed("jettons/fixture")
        let waiting = Task { try await client.indexed("jettons/fixture") }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.indexed("jettons/fixture")
        let calls = await feed.starts.count
        XCTAssertEqual(calls, 2)
    }
    func testCooldownIsQuietAndAccessFailurePreservesSafeContext() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TON_INDEX_CAPTURE"] == "1" else { throw XCTSkip("Dedicated diagnostic capture") }
        let reports = TonIndexReports(), feed = TonIndexLimitFeed(), limiter = TonIndexRequests()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let client = TonClient(testTransport: feed, indexRequests: limiter), operation = UUID()
        await OathDiagnostics.$operationID.withValue(operation) {
            for _ in 0..<10 {
                do { _ = try await client.indexed("accounts/private-owner/jettons") }
                catch { /* Boundary already owns the original failure. */ }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        await OathDiagnostics.flush()
        let availability = await reports.events.filter { $0.operationID == operation }
        XCTAssertTrue(availability.isEmpty, "Rate limits and cooldowns follow the shared availability policy")
        let denied = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(denied) {
                try await TonClient(testTransport: TonIndexLimitFeed(firstStatus: 403), indexRequests: TonIndexRequests())
                    .indexed("accounts/private-owner/jettons")
            }
            XCTFail("Access failure must reject the request")
        } catch { XCTAssertEqual(error as? TonError, .http(403)) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operationID == denied }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == denied }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.message, "http(403)")
        XCTAssertEqual(events.first?.context["chain"], "ton")
        XCTAssertEqual(events.first?.context["host"], "tonapi.io")
        XCTAssertTrue(events.allSatisfy(\.privacyFiltered))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-owner"))
        XCTAssertFalse(encoded.contains("/jettons"))
    }
}

private actor TonIndexLiveFeed: AnkrTransport {
    private let http = AnkrHTTPTransport()
    private(set) var starts: [ContinuousClock.Instant] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "tonapi.io" { starts.append(.now) }
        return try await http.sendPreservingTransportError(request)
    }
}
extension TonIndexPacingTests {
    func testLiveSeparateClientsPaceRealBalanceHistoryAndTokenReads() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TON_INDEX_LIVE"] == "1" else { throw XCTSkip("Read-only public TON requests") }
        let owner = "0:8afbcb163358eb20be1ae9b610a2938038d84a1087e7f49cccbf8046f59c859f"
        let feed = TonIndexLiveFeed()
        // These indexed reads do not use ANKR or send any API credential.
        let balances = try TonClient(apiKey: "UnusedFixtureKey", transport: feed)
        let history = try TonClient(apiKey: "UnusedFixtureKey", transport: feed)
        let tokens = try TonClient(apiKey: "UnusedFixtureKey", transport: feed)
        async let a = balances.indexed("accounts/" + owner)
        async let b = history.history(owner: owner, stream: .native, limit: 5)
        async let c = tokens.indexed("jettons/" + TonIdentity.usdt)
        let (account, page, token) = try await (a, b, c)
        XCTAssertEqual(try TonIdentity.raw(XCTUnwrap(account["address"].string)), owner)
        XCTAssertGreaterThan(Decimal(string: try TonIdentity.amount(account["balance"])) ?? 0, 0)
        XCTAssertFalse(page.transactions.isEmpty)
        XCTAssertEqual(try TonIdentity.raw(XCTUnwrap(token["metadata"]["address"].string)), TonIdentity.usdt)
        XCTAssertEqual(token["metadata"]["decimals"].text, "6")
        let starts = await feed.starts
        XCTAssertEqual(starts.count, 3)
        for index in 1..<starts.count {
            XCTAssertGreaterThanOrEqual(starts[index-1].duration(to: starts[index]), .seconds(4))
        }
        let independent = try TonClient(apiKey: "UnusedFixtureKey", transport: TonIndependentBalanceFeed())
        let state = try await independent.rpc("getAddressInformation", ["address": .string(owner)])
        XCTAssertEqual(try TonIdentity.amount(state["balance"]), try TonIdentity.amount(account["balance"]))
        print("TON_INDEX_LIVE real balance/history/USDT reads across three clients; all starts spaced at least four seconds; native balance matches independent TON Center")
    }
}
private struct TonIndependentBalanceFeed: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        var independent = request
        independent.url = URL(string: "https://toncenter.com/api/v2/jsonRPC")!
        let (data, status) = try await AnkrHTTPTransport().sendPreservingTransportError(independent)
        // Normalize only this test comparator's documented legacy envelope.
        let value = try JSONDecoder().decode(TonJSON.self, from: data)
        guard status == 200, value["ok"] == .bool(true) else { throw TonError.http(status) }
        return (try JSONEncoder().encode(TonJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": value["result"]])), 200)
    }
}
