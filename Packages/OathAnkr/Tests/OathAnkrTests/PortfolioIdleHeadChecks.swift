import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

/// Rewrite only “latest” to a real recently mined block to replay a quiet period.
private actor PortfolioReplayFeed: AnkrTransport {
    let tag: SolanaJSON
    let parent: SolanaJSON
    var ankrLatestReads = 0
    init(tag: SolanaJSON, parent: SolanaJSON) {
        self.tag = tag
        self.parent = parent
    }
    let http = AnkrHTTPTransport()
    func send(_ original: URLRequest) async throws -> (Data, Int) {
        guard var calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(original.httpBody)).array else {
            throw EVMSendError.malformed
        }
        var request = original
        for index in calls.indices {
            XCTAssertNotEqual(calls[index]["method"].string, "eth_sendRawTransaction")
            if calls[index]["method"].string == "eth_getBlockByNumber",
               calls[index]["params"].array?.first == .string("latest"), case .object(var call) = calls[index] {
                var replay = tag
                if request.url?.host == "rpc.ankr.com" {
                    ankrLatestReads += 1
                    if ankrLatestReads == 1 { replay = parent }
                }
                call["params"] = .array([replay, .bool(false)])
                calls[index] = .object(call)
            }
        }
        request.httpBody = try JSONEncoder().encode(SolanaJSON.array(calls))
        return try await http.sendPreservingTransportError(request)
    }
}

private struct PortfolioHeadFixture: AnkrTransport {
    let network: EVMSendNetwork
    let age: Int
    var disagree = false
    var wrongChain = false
    let now = Int(Date.now.timeIntervalSince1970)
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let third = request.url?.host == network.portfolioRecoveryEndpoints.last?.host
        let hash = "0x" + String(repeating: third && disagree ? "b" : "a", count: 64)
        let block: SolanaJSON = .object(["hash": .string(hash), "number": .string("0x64"),
            "timestamp": .string("0x" + String(now - age, radix: 16))])
        return (try JSONEncoder().encode(SolanaJSON.array([
            .object(["id": .number("0"), "jsonrpc": .string("2.0"), "result": .string(third && wrongChain ? "0x1" : "0x" + String(network.chainID, radix: 16))]),
            .object(["id": .number("1"), "jsonrpc": .string("2.0"), "result": block])
        ])), 200)
    }
}

enum PortfolioIdleHeadChecks {
    static func waitForFreshBackup(_ network: EVMSendNetwork, endpoint: URL) async throws {
        let reader = try EVMSendClient(network: network, endpoints: [endpoint])
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while true {
            let block = try await reader.block(.string("latest"))
            let age = Date.now.timeIntervalSince1970 - Double(try EVMSendClient.uint(block["timestamp"]))
            if (0...25).contains(age) { return }
            guard ContinuousClock.now < deadline else { throw XCTSkip("No fresh fallback tip for " + network.rawValue) }
            try await Task.sleep(for: .seconds(8))
        }
    }

    static func verifyPolicy(_ network: EVMSendNetwork) async throws {
        let endpoints = [URL(string: "https://rpc.ankr.com/\(network.rawValue)/fixture")!] + network.portfolioRecoveryEndpoints
        for (fixture, count, mode, accepted) in [
            (PortfolioHeadFixture(network: network, age: 120), 3, EVMSendClient.HeadValidation.freshForWalletSync, true),
            (.init(network: network, age: 120, disagree: true), 3, .freshForWalletSync, false),
            (.init(network: network, age: 120, wrongChain: true), 3, .freshForWalletSync, false),
            (.init(network: network, age: 120), 2, .freshForWalletSync, false),
            (.init(network: network, age: 301), 3, .freshForWalletSync, false),
            (.init(network: network, age: -90), 3, .freshForWalletSync, false),
            (.init(network: network, age: 120), 3, .fresh, false)
        ] {
            let reader = try EVMSendClient(network: network, endpoints: Array(endpoints.prefix(count)), transport: fixture)
            do {
                let head = try await reader.rpc("eth_getBlockByNumber", [.string("latest"), .bool(false)], headValidation: mode)
                XCTAssertTrue(accepted)
                XCTAssertEqual(head["number"].string, "0x64")
            } catch {
                XCTAssertFalse(accepted, "Matching independent wallet heads must pass: \(error)")
            }
        }
    }

    static func verifyArchive(_ network: EVMSendNetwork, token: EVMBalanceAsset, emptyOwner: String) async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let primary = URL(string: "https://rpc.ankr.com/\(network.rawValue)")!.appendingPathComponent(try XCTUnwrap(config["AnkrAPIKey"]))
        let oracle = try EVMSendClient(network: network, endpoints: [primary])
        var block = try await oracle.block(.string("latest"))
        // Binary-search for a real block roughly two minutes old.
        let latest = try EVMSendClient.uint(block["number"])
        var low = latest - 2048, high = latest
        let cutoff = Date.now.timeIntervalSince1970 - 100
        while low < high {
            let mid = low + (high - low + 1) / 2
            let value = try await oracle.block(.string("0x" + String(mid, radix: 16)))
            if Double(try EVMSendClient.uint(value["timestamp"])) <= cutoff { low = mid } else { high = mid - 1 }
        }
        // A long gap between Opera blocks can put the last block before the
        // target outside the five-minute window even when its child is eligible.
        let before = try await oracle.block(.string("0x" + String(low, radix: 16)))
        if Date.now.timeIntervalSince1970 - Double(try EVMSendClient.uint(before["timestamp"])) > 230, low < latest {
            let child = try await oracle.block(.string("0x" + String(low + 1, radix: 16)))
            let age = Date.now.timeIntervalSince1970 - Double(try EVMSendClient.uint(child["timestamp"]))
            if (65...230).contains(age) { low += 1 }
        }
        let tag = SolanaJSON.string("0x" + String(low, radix: 16))
        block = try await oracle.block(tag)
        let stamp = Double(try EVMSendClient.uint(block["timestamp"]))
        guard (62...280).contains(Date.now.timeIntervalSince1970 - stamp) else {
            throw XCTSkip("No historical block in the bounded wallet idle window for this archive replay")
        }
        let prior = try await oracle.block(.string("0x" + String(low - 1, radix: 16)))
        let priorAge = Int(Date.now.timeIntervalSince1970 - Double(try EVMSendClient.uint(prior["timestamp"])))
        print("PUBLIC_QUIET_HEAD chain=\(network.rawValue) height=\(low) age=\(Int(Date.now.timeIntervalSince1970 - stamp)) parentAge=\(priorAge) parentMatches=\(block["parentHash"].string == prior["hash"].string)")
        let replay = PortfolioReplayFeed(tag: tag, parent: .string("0x" + String(low - 1, radix: 16)))
        let client = try EVMSendClient(network: network, endpoints: [primary] + network.portfolioRecoveryEndpoints, transport: replay)
        for owner in ["0xf977814e90da44bfa03b6295a0616a897441acec", emptyOwner] {
            let snapshot = try await client.portfolioBalances(owner: owner, assets: [token], propagateReportedHeadFailure: true)
            if owner != emptyOwner {
                let reads = await replay.ankrLatestReads
                XCTAssertEqual(reads, 2, "The third vote must trigger an independent latest reread on the lagging host")
            }
            XCTAssertEqual(snapshot.height, Int64(low))
            XCTAssertEqual(snapshot.blockHash, block["hash"].string)
            XCTAssertEqual(snapshot.observedAt.timeIntervalSince1970, stamp)
            XCTAssertTrue(snapshot.failedReferences.isEmpty)
            for reference in ["native", token.reference] {
                let expected = try await oracle.balance(owner: owner, reference: reference, tag: tag)
                XCTAssertEqual(snapshot.amounts[reference], expected)
            }
            try await client.validatePortfolioBalances(snapshot)
        }
    }
}

private struct InterruptedIdleHeadFeed: AnkrTransport {
    let network: EVMSendNetwork
    let interruption: URLError.Code

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == network.portfolioRecoveryEndpoints.last?.host {
            throw URLError(interruption)
        }
        return try await PortfolioHeadFixture(network: network, age: 120).send(request)
    }
}

private actor IdleHeadReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ records: [DiagnosticEvent]) async throws { events += records }
}

final class InterruptedIdleHeadTests: XCTestCase, @unchecked Sendable {
    func testCancelledWitnessDiscardsProvisionalVotesAndUnreachableWitnessReportsThem() async throws {
        guard ProcessInfo.processInfo.environment["OATH_IDLE_HEAD_CAPTURE"] == "1" else {
            throw XCTSkip("Dedicated diagnostics recorder")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = IdleHeadReports()
        OathDiagnostics.configure(file: directory.appendingPathComponent("outbox.json"), transport: reports)
        var cancelled = Set<UUID>(), unreachable = Set<UUID>()
        for network in [EVMSendNetwork.fantom, .scroll] {
            for interruption in [URLError.Code.cancelled, .cannotConnectToHost] {
                let operation = UUID()
                let endpoints = [URL(string: "https://rpc.ankr.com/\(network.rawValue)/fixture")!] + network.portfolioRecoveryEndpoints
                let client = try EVMSendClient(network: network, endpoints: endpoints,
                                               transport: InterruptedIdleHeadFeed(network: network, interruption: interruption))
                do {
                    _ = try await OathDiagnostics.$operationID.withValue(operation) {
                        try await client.rpc("eth_getBlockByNumber", [.string("latest"), .bool(false)], headValidation: .freshForWalletSync)
                    }
                    XCTFail("Incomplete consensus returned a block")
                } catch {
                    if interruption == .cancelled {
                        XCTAssertTrue(error is CancellationError)
                        cancelled.insert(operation)
                    } else {
                        XCTAssertFalse(error is CancellationError)
                        unreachable.insert(operation)
                    }
                }
            }
        }
        for _ in 0..<200 {
            let events = await reports.events
            if events.filter({ $0.context["reason"] == "head_timestamp_stale" && $0.operationID.map(unreachable.contains) == true }).count == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.filter { $0.operationID.map(cancelled.contains) == true }.count, 0)
        for operation in unreachable {
            let failures = events.filter { $0.operationID == operation }
            XCTAssertEqual(failures.filter { $0.context["reason"] == "head_timestamp_stale" }.count, 2)
            XCTAssertTrue(failures.contains { $0.error.domain == NSURLErrorDomain })
        }
    }
}

private actor CatchingUpPortfolioNode: AnkrTransport {
    enum Outcome { case catchesUp, staysBehind, fork, wrongChainOnRetry, wrongParentOnRetry }
    let network: EVMSendNetwork
    let laggingHost: String
    let outcome: Outcome
    let now = Int(Date.now.timeIntervalSince1970)
    var calls: [String: Int] = [:]
    init(network: EVMSendNetwork, host: String, outcome: Outcome) {
        self.network = network
        self.laggingHost = host
        self.outcome = outcome
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = try XCTUnwrap(request.url?.host)
        calls[host, default: 0] += 1
        let second = calls[host, default: 0] == 2
        let behind = host == laggingHost && (!second || outcome == .staysBehind)
        let wrongChain = host == laggingHost && second && outcome == .wrongChainOnRetry
        let parent = "0x" + String(repeating: "a", count: 64)
        let hash = behind ? parent : "0x" + String(repeating: "b", count: 64)
        let wrongParent = outcome == .fork || (outcome == .wrongParentOnRetry && second)
        let header: SolanaJSON = .object([
            "number": .string(behind ? "0x63" : "0x64"), "hash": .string(hash),
            "parentHash": .string(wrongParent ? "0x" + String(repeating: "c", count: 64) : parent),
            "timestamp": .string("0x" + String(now - (behind ? 420 : 120), radix: 16))
        ])
        return (try JSONEncoder().encode(SolanaJSON.array([
            .object(["id": .number("0"), "jsonrpc": .string("2.0"), "result": .string(wrongChain ? "0x1" : "0x" + String(network.chainID, radix: 16))]),
            .object(["id": .number("1"), "jsonrpc": .string("2.0"), "result": header])
        ])), 200)
    }
}

final class PortfolioHeadConvergenceTests: XCTestCase, @unchecked Sendable {
    func testOnlyMatchingRereadOfSingleParentCanCompleteTheWalletQuorum() async throws {
        for network in [EVMSendNetwork.fantom, .scroll] {
            let endpoints = [URL(string: "https://rpc.ankr.com/\(network.rawValue)/fixture")!] + network.portfolioRecoveryEndpoints
            for endpoint in endpoints {
                let host = try XCTUnwrap(endpoint.host)
                for outcome in [CatchingUpPortfolioNode.Outcome.catchesUp, .staysBehind, .fork, .wrongChainOnRetry, .wrongParentOnRetry] {
                    let feed = CatchingUpPortfolioNode(network: network, host: host, outcome: outcome)
                    let client = try EVMSendClient(network: network, endpoints: endpoints, transport: feed)
                    do {
                        let proof = try await client.rpcWithHeadEvidence("eth_getBlockByNumber", [.string("latest"), .bool(false)], headValidation: .freshForWalletSync)
                        XCTAssertEqual(outcome, .catchesUp)
                        XCTAssertTrue(proof.corroboratedIdleTip)
                        XCTAssertEqual(proof.value["number"].string, "0x64")
                    } catch {
                        XCTAssertNotEqual(outcome, .catchesUp)
                    }
                    let calls = await feed.calls
                    XCTAssertEqual(calls[host], outcome == .fork ? 1 : 2)
                    XCTAssertEqual(calls.filter { $0.key != host }.values.sorted(), [1, 1])
                }
            }
            let host = try XCTUnwrap(endpoints.first?.host)
            let feed = CatchingUpPortfolioNode(network: network, host: host, outcome: .catchesUp)
            let client = try EVMSendClient(network: network, endpoints: endpoints, transport: feed)
            do {
                _ = try await client.block(.string("latest"), requireFresh: true)
                XCTFail("Stale heads must not authorize a send quote")
            } catch { XCTAssertEqual(error as? EVMSendError, .expired) }
            let counts = await feed.calls
            XCTAssertEqual(counts.values.sorted(), [1, 1, 1])
        }
    }
}
