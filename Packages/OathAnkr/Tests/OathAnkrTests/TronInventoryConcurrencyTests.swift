import Foundation
import XCTest
@testable import OathAnkr

private actor InventoryTransport: AnkrTransport {
    enum Stage: Hashable { case discovery, balance, metadata }
    let stalled: Stage?
    let inactive: Bool
    let discover: Bool
    let broken: Bool
    private var released = false
    private(set) var started: Set<Stage> = []
    private(set) var balanceReads = 0
    private var activeNodeRequests = 0
    private(set) var peakNodeRequests = 0
    private(set) var largestBalanceBatch = 0
    init(stalled: Stage? = nil, inactive: Bool = false, discover: Bool = true, broken: Bool = false) {
        self.stalled = stalled; self.inactive = inactive; self.discover = discover; self.broken = broken
    }
    func release() { released = true }
    private func enter(_ stage: Stage) async throws {
        started.insert(stage)
        while stalled == stage && !released { try await Task.sleep(for: .milliseconds(2)) }
        try Task.checkCancellation()
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let isIndex = request.url!.path.hasPrefix("/v1/accounts/")
        if !isIndex {
            activeNodeRequests += 1
            peakNodeRequests = max(peakNodeRequests, activeNodeRequests)
        }
        defer { if !isIndex { activeNodeRequests -= 1 } }
        try await Task.sleep(for: .milliseconds(2))
        let value: TronJSON
        if isIndex {
            try await enter(.discovery)
            value = .object(["success": .bool(true), "data": .array(discover ? [.object([
                "address": .string(TronTests.owner), "trc20": .array([.object([TronIdentity.usdt: .string("999")])])
            ])] : [])])
        } else if request.url!.path.hasSuffix("wallet/getaccount") {
            value = inactive ? .object([:]) : .object(["address": .string(TronTests.owner), "balance": .number("42")])
        } else {
            let calls = try JSONDecoder().decode(TronJSON.self, from: request.httpBody!).array!
            let balanceCount = calls.filter { $0["params"].array?.first?["data"].string?.hasPrefix("0x70a08231") == true }.count
            largestBalanceBatch = max(largestBalanceBatch, balanceCount)
            if balanceCount > 0 {
                try await enter(.balance)
            } else if calls.contains(where: { $0["method"].string == "eth_call" }) { try await enter(.metadata) }
            value = .array(calls.map { call in
                let data = call["params"].array?.first?["data"].string ?? ""
                let result: String
                if call["method"].string == "eth_chainId" { result = "0x2b6653dc" }
                else if data.hasPrefix("0x70a08231") {
                    balanceReads += 1
                    if broken { return .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object(["code": .number("-32000")])]) }
                    result = "0x" + String(repeating: "0", count: 59) + "1e240" // 123456; index's 999 must never be used.
                } else if data == "0x313ce567" { result = "0x" + String(repeating: "0", count: 63) + "6" }
                else { result = "0x55534454" + String(repeating: "0", count: 56) }
                return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": .string(result)])
            })
        }
        return (try JSONEncoder().encode(value), 200)
    }
}

final class TronInventoryConcurrencyTests: XCTestCase, @unchecked Sendable {
    private func waitFor(_ stage: InventoryTransport.Stage, in transport: InventoryTransport) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while await !transport.started.contains(stage), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        return await transport.started.contains(stage)
    }
    func testKnownTokenReadDoesNotWaitForDiscoveryAndIsNotRepeated() async throws {
        let transport = InventoryTransport(stalled: .discovery)
        let client = try TronClient(apiKey: "Fixture", transport: transport)
        let work = Task { try await client.inventory(owner: TronTests.owner, additionalTokens: [TronIdentity.usdt, TronIdentity.usdt]) }
        let started = try await waitFor(.balance, in: transport)
        await transport.release()
        let result = try await work.value
        XCTAssertTrue(started, "Known token balances must start while discovery is pending")
        XCTAssertEqual(result.holdings.first { $0.token.reference == TronIdentity.usdt }?.amount, "123456")
        let count = await transport.balanceReads
        XCTAssertEqual(count, 1, "A contract reported by both tracking and discovery is read once")
    }
    func testMetadataDoesNotWaitForBalanceRoundTrip() async throws {
        let transport = InventoryTransport(stalled: .balance)
        let client = try TronClient(apiKey: "Fixture", transport: transport)
        let work = Task { try await client.inventory(owner: TronTests.owner) }
        let started = try await waitFor(.metadata, in: transport)
        await transport.release()
        let result = try await work.value
        XCTAssertTrue(started, "Independent token metadata must overlap the balance read")
        XCTAssertTrue(result.failedReferences.isEmpty)
    }
    func testUnactivatedAccountWithUnindexedTrackedTokenKeepsNonzeroBalance() async throws {
        let transport = InventoryTransport(inactive: true, discover: false)
        let result = try await TronClient(apiKey: "Fixture", transport: transport)
            .inventory(owner: TronTests.owner, additionalTokens: [TronIdentity.usdt])
        XCTAssertEqual(result.holdings.first { $0.token.reference == "native" }?.amount, "0")
        XCTAssertEqual(result.holdings.first { $0.token.reference == TronIdentity.usdt }?.amount, "123456")
        XCTAssertTrue(result.failedReferences.isEmpty)
    }
    func testUnreadableTokenStaysFailedInsteadOfBecomingZeroOrUsingIndexAmount() async throws {
        let result = try await TronClient(apiKey: "Fixture", transport: InventoryTransport(broken: true))
            .inventory(owner: TronTests.owner, additionalTokens: [TronIdentity.usdt])
        XCTAssertEqual(result.failedReferences, [TronIdentity.usdt])
        XCTAssertEqual(result.holdings.map(\.token.reference), ["native"])
    }
    func testCancellationStopsOverlappingWorkWithoutPublishingInventory() async throws {
        let transport = InventoryTransport(stalled: .balance)
        let client = try TronClient(apiKey: "Fixture", transport: transport)
        let work = Task { try await client.inventory(owner: TronTests.owner, additionalTokens: [TronIdentity.usdt]) }
        _ = try await waitFor(.balance, in: transport)
        work.cancel()
        await transport.release()
        do { _ = try await work.value; XCTFail("Cancelled inventory must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLargeInventoryKeepsRequestBudgetAndBatchSize() async throws {
        let transport = InventoryTransport()
        let references = try (1...45).map { try TronSendCrypto.address(privateKey: Data(repeating: UInt8($0), count: 32)) }
        let result = try await TronClient(apiKey: "Fixture", transport: transport)
            .inventory(owner: TronTests.owner, additionalTokens: references + references)
        XCTAssertTrue(result.failedReferences.isEmpty)
        XCTAssertEqual(result.holdings.count, 47) // native, 45 tracked, one newly discovered
        let peak = await transport.peakNodeRequests, batch = await transport.largestBalanceBatch
        let reads = await transport.balanceReads
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(batch, 20)
        XCTAssertEqual(reads, 46)
    }
}
