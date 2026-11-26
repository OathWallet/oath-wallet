import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor UnactivatedDiscoveryTransport: AnkrTransport {
    enum Failure { case none, unavailable, wrongOwner, malformed, repeatedCursor, secondPage, stalled }
    let failure: Failure
    let activated: Bool
    let paginated: Bool
    private(set) var transferRequests = 0
    private(set) var balanceReads: [String: Int] = [:]
    private(set) var queries: [[String: String]] = []
    private(set) var discoveryChain: String?
    private(set) var discoveryOperation: UUID?
    static let otherToken = "TQguVRm3tDmZG7AeZ47Mk6qi6GTF1ZDqkZ"
    init(_ failure: Failure = .none, activated: Bool = false, paginated: Bool = false) {
        self.failure = failure; self.activated = activated; self.paginated = paginated
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        let value: TronJSON
        if url.path.hasSuffix("/transactions/trc20") {
            transferRequests += 1
            discoveryChain = OathDiagnostics.chain
            discoveryOperation = OathDiagnostics.operationID
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            queries.append(query)
            if failure == .stalled { try await Task.sleep(for: .seconds(60)) }
            if failure == .unavailable || failure == .secondPage && transferRequests == 2 {
                return (Data("{}".utf8), 403)
            }
            let recipient = failure == .wrongOwner ? Self.otherToken : TronTests.owner
            func transfer(_ reference: String, type: String = "Transfer") -> TronJSON {
                .object(["transaction_id": .string(String(repeating: "a", count: 64)),
                         "from": .string(Self.otherToken), "to": .string(recipient), "type": .string(type),
                         "token_info": .object(["address": .string(reference)]), "value": .string("999")])
            }
            let token = paginated && transferRequests > 1 ? Self.otherToken : TronIdentity.usdt
            let rows = failure == .malformed ? [TronJSON.object([:])] : [transfer(token), transfer(token), transfer(Self.otherToken, type: "Approval")]
            let next = failure == .repeatedCursor || (paginated && transferRequests == 1) ? "page2" : nil
            value = .object(["success": .bool(true), "data": .array(rows),
                             "meta": .object(["fingerprint": next.map(TronJSON.string) ?? .null])])
        } else if url.path.hasPrefix("/v1/accounts/") {
            value = .object(["success": .bool(true), "data": .array([])])
        } else if url.path.hasSuffix("/getaccount") {
            value = activated ? .object(["address": .string(TronTests.owner)]) : .object([:])
        } else {
            let calls = try JSONDecoder().decode(TronJSON.self, from: XCTUnwrap(request.httpBody)).array!
            value = .array(try calls.map { call in
                let input = call["params"].array?.first
                let data = input?["data"].string ?? ""
                let result: String
                if call["method"].string == "eth_chainId" { result = "0x2b6653dc" }
                else if data.hasPrefix("0x70a08231") {
                    let reference = try TronIdentity.address(XCTUnwrap(input?["to"].string))
                    balanceReads[reference, default: 0] += 1
                    result = "0x" + String(repeating: "0", count: 57) + "5f5e100" // 100 USDT, not the event's 999.
                } else if data == "0x313ce567" { result = "0x" + String(repeating: "0", count: 63) + "6" }
                else { result = "0x55534454" + String(repeating: "0", count: 56) }
                return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": .string(result)])
            })
        }
        return (try JSONEncoder().encode(value), 200)
    }
}

final class TronUnactivatedDiscoveryTests: XCTestCase, @unchecked Sendable {
    func testFreshUnactivatedImportDiscoversUSDTWithoutTrackedTokensOrTRX() async throws {
        let feed = UnactivatedDiscoveryTransport()
        let result = try await TronClient(apiKey: "fixture", transport: feed).inventory(owner: TronTests.owner)
        XCTAssertEqual(result.holdings.first { $0.token.reference == "native" }?.amount, "0")
        XCTAssertEqual(result.holdings.first { $0.token.reference == TronIdentity.usdt }?.amount, "100000000")
        XCTAssertEqual(result.holdings.count, 2, "Approvals must not discover a holding")
        XCTAssertTrue(result.discoveryComplete)
        XCTAssertTrue(result.failedReferences.isEmpty)
        let reads = await feed.balanceReads
        XCTAssertEqual(reads[TronIdentity.usdt], 1, "Duplicate transfers must not duplicate balance reads")
        let chain = await feed.discoveryChain, operation = await feed.discoveryOperation
        XCTAssertEqual(chain, "tron")
        XCTAssertNotNil(operation, "Discovery and its retries must share a diagnostic operation")
    }

    func testPaginationDiscoversOtherTokensAndDeduplicatesTrackedContracts() async throws {
        let feed = UnactivatedDiscoveryTransport(paginated: true)
        let result = try await TronClient(apiKey: "fixture", transport: feed)
            .inventory(owner: TronTests.owner, additionalTokens: [TronIdentity.usdt])
        XCTAssertEqual(result.holdings.count, 3)
        XCTAssertTrue(result.discoveryComplete)
        let reads = await feed.balanceReads, queries = await feed.queries
        XCTAssertEqual(reads.values.sorted(), [1, 1])
        XCTAssertEqual(queries.count, 2)
        if queries.count == 2 {
            var second = queries[1]
            XCTAssertEqual(second.removeValue(forKey: "fingerprint"), "page2")
            XCTAssertEqual(second, queries[0], "Pagination must keep its time window and filters")
        }
    }

    func testFailuresNeverClaimCompleteDiscoveryOrDiscardReadableTrackedBalance() async throws {
        for failure in [UnactivatedDiscoveryTransport.Failure.unavailable, .wrongOwner, .malformed, .repeatedCursor] {
            let feed = UnactivatedDiscoveryTransport(failure)
            let result = try await TronClient(apiKey: "fixture", transport: feed)
                .inventory(owner: TronTests.owner, additionalTokens: [TronIdentity.usdt])
            XCTAssertFalse(result.discoveryComplete)
            XCTAssertEqual(result.holdings.first { $0.token.reference == TronIdentity.usdt }?.amount, "100000000")
        }
    }

    func testLaterPageFailurePreservesAlreadyDiscoveredContracts() async throws {
        let result = try await TronClient(apiKey: "fixture", transport: UnactivatedDiscoveryTransport(.secondPage, paginated: true))
            .inventory(owner: TronTests.owner)
        XCTAssertFalse(result.discoveryComplete)
        XCTAssertEqual(result.holdings.first { $0.token.reference == TronIdentity.usdt }?.amount, "100000000")
    }

    func testActivatedAccountDoesNotScanTransferHistoryForInventory() async throws {
        let feed = UnactivatedDiscoveryTransport(activated: true)
        let result = try await TronClient(apiKey: "fixture", transport: feed).inventory(owner: TronTests.owner)
        XCTAssertTrue(result.discoveryComplete)
        let count = await feed.transferRequests
        XCTAssertEqual(count, 0)
    }

    func testCancellationDuringFallbackDoesNotPublishInventory() async throws {
        let feed = UnactivatedDiscoveryTransport(.stalled)
        let client = try TronClient(apiKey: "fixture", transport: feed)
        let task = Task { try await client.inventory(owner: TronTests.owner) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await feed.transferRequests == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let count = await feed.transferRequests
        task.cancel()
        XCTAssertEqual(count, 1)
        do { _ = try await task.value; XCTFail("Cancelled discovery must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
