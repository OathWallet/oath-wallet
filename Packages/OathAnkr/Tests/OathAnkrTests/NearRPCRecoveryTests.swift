import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private let recoveryBlock = NearBlock(hash: "HJcKVPta9MX2cZ2wQ9jZSRxa7f6WABptK6iv98DxA3U4", height: 123, timestamp: 1_700_000_000)

private actor NearRPCRecoveryFeed: AnkrTransport {
    enum Mode: Sendable { case outage, absent, invalid, malformed, wrongBlock, both, cancelled, httpThenRPC }
    let mode: Mode
    var requests: [URLRequest] = []
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let primary = request.url?.host == "primary.example"
        if primary, mode == .httpThenRPC { return (Data(), 503) }
        if primary || mode == .both || mode == .httpThenRPC {
            if mode == .cancelled { throw CancellationError() }
            if mode == .malformed { return (Data(#"{"jsonrpc":"2.0","id":99,"error":{"code":-32000}}"#.utf8), 200) }
            let error: [String: Any] = mode == .absent
                ? ["code": -32000, "message": "Server error", "data": "account empty.near does not exist while viewing"]
                : ["code": mode == .invalid ? -32602 : -32000, "message": "Server error"]
            return (try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "error": error]), 200)
        }
        return (try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": [
            "block_hash": recoveryBlock.hash, "block_height": mode == .wrongBlock ? 124 : 123,
            "amount": "9007199254740993", "locked": "0", "storage_usage": 0]]), 200)
    }
}

private actor NearRPCReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}

private actor NearLiveNodeFailure: AnkrTransport {
    let live = AnkrHTTPTransport()
    var injected = 0
    var fallbackQueries = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(NearJSON.self, from: XCTUnwrap(request.httpBody))
        if body["method"].string == "query", request.url?.host == "rpc.ankr.com" {
            injected += 1
            return (Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Server error"}}"#.utf8), 200)
        }
        if body["method"].string == "query", request.url?.host == "rpc.mainnet.near.org" { fallbackQueries += 1 }
        return try await live.send(request)
    }
}

final class NearRPCRecoveryTests: XCTestCase, @unchecked Sendable {
    private func client(_ feed: NearRPCRecoveryFeed) throws -> NearClient {
        try NearClient(endpoint: URL(string: "https://primary.example/private-fixture")!,
            fallback: URL(string: "https://backup.example")!, transport: feed)
    }
    func testHTTP200NodeErrorRecoversAtExactOriginalBlock() async throws {
        let feed = NearRPCRecoveryFeed(.outage)
        let state = try await client(feed).account(owner: "root.near", block: recoveryBlock)
        XCTAssertEqual(state["amount"].string, "9007199254740993")
        let requests = await feed.requests
        XCTAssertEqual(requests.count, 2)
        let first = try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? NSDictionary
        let last = try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? NSDictionary
        XCTAssertEqual(first, last)
        XCTAssertEqual(requests.last?.url?.absoluteString, "https://backup.example")
    }
    func testExpectedAbsenceInvalidParamsMalformedAndCancellationDoNotFailOver() async throws {
        for (mode, expected) in [(NearRPCRecoveryFeed.Mode.absent, NearError.accountMissing), (.invalid, .rpc(-32602)), (.malformed, .malformed)] {
            let feed = NearRPCRecoveryFeed(mode)
            do { _ = try await client(feed).account(owner: "empty.near", block: recoveryBlock); XCTFail() }
            catch { XCTAssertEqual(error as? NearError, expected) }
            let count = await feed.requests.count
            XCTAssertEqual(count, 1)
        }
        let cancelled = NearRPCRecoveryFeed(.cancelled)
        do { _ = try await client(cancelled).account(owner: "root.near", block: recoveryBlock); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await cancelled.requests.count
        XCTAssertEqual(count, 1)
    }
    func testFailedFallbackNeverBecomesZeroAndRemainsBounded() async throws {
        for (mode, expected) in [(NearRPCRecoveryFeed.Mode.both, NearError.rpc(-32000)), (.wrongBlock, .wrongBlock), (.httpThenRPC, .rpc(-32000))] {
            let feed = NearRPCRecoveryFeed(mode)
            do { _ = try await client(feed).account(owner: "root.near", block: recoveryBlock); XCTFail() }
            catch { XCTAssertEqual(error as? NearError, expected) }
            let count = await feed.requests.count
            XCTAssertEqual(count, 2)
        }
    }
    func testRecoveredNodeFailureKeepsOneSafeCorrelatedReport() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NEAR_RPC_CAPTURE"] == "1" else { throw XCTSkip("Isolated diagnostic recorder capture") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = NearRPCReports()
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: reports)
        let ready = UUID()
        for _ in 0..<100 {
            OathDiagnostics.$operationID.withValue(ready) {
                OathDiagnostics.record(DiagnosticFailure("ready"), component: "fixture", operation: "ready")
            }
            try await Task.sleep(for: .milliseconds(25))
            if await reports.events.contains(where: { $0.operationID == ready }) { break }
        }
        let id = UUID(), feed = NearRPCRecoveryFeed(.outage)
        _ = try await OathDiagnostics.$operationID.withValue(id) {
            try await client(feed).account(owner: "root.near", block: recoveryBlock)
        }
        for _ in 0..<100 {
            if await reports.events.contains(where: { $0.operationID == id }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await reports.events.filter { $0.operationID == id }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.operation, "near_rpc_recovery")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertTrue(encoded.contains("-32000"))
        XCTAssertFalse(encoded.contains("private-fixture"))
        XCTAssertFalse(encoded.contains("root.near"))
        XCTAssertFalse(encoded.contains(recoveryBlock.hash))
    }
    func testLivePinnedRecoveryMatchesIndependentPublicAccount() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NEAR_RPC_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only recovery") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
        let key = try XCTUnwrap(config["AnkrAPIKey"] as? String)
        let primary = try NearClient(apiKey: key)
        let block = try await primary.finalBlock()
        let feed = NearLiveNodeFailure()
        let recovered = try NearClient(apiKey: key, transport: feed)
        let state = try await recovered.account(owner: "root.near", block: block)
        let original = try await primary.account(owner: "root.near", block: block)
        XCTAssertEqual(try NearIdentity.amount(state["amount"]), try NearIdentity.amount(original["amount"]))
        XCTAssertEqual(state["block_hash"].string, block.hash)
        let injected = await feed.injected, fallback = await feed.fallbackQueries
        XCTAssertEqual(injected, 1); XCTAssertEqual(fallback, 1)
    }
    func testLiveFundedImplicitContractAndAbsentAccounts() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NEAR_RPC_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only account types") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
        let client = try NearClient(apiKey: XCTUnwrap(config["AnkrAPIKey"] as? String))
        let independent = try NearClient(endpoint: URL(string: "https://rpc.mainnet.near.org")!)
        let block = try await client.finalBlock()
        for owner in ["root.near", "wrap.near", String(repeating: "a", count: 64)] {
            async let actual = client.account(owner: owner, block: block)
            async let expected = independent.account(owner: owner, block: block)
            let (a, b) = try await (actual, expected)
            XCTAssertEqual(try NearIdentity.amount(a["amount"]), try NearIdentity.amount(b["amount"]))
        }
        do { _ = try await client.account(owner: "oath-rpc-check-unfunded-20261107.near", block: block); XCTFail() }
        catch { XCTAssertEqual(error as? NearError, .accountMissing) }
    }
}
