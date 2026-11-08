import Foundation
import XCTest
import GRDB
import OathDiagnostics
@testable import OathAnkr
@testable import OathDatabase

private actor SuiCancellationFeed: AnkrTransport {
    let owner: String
    let malformedHistory: Bool
    private var holdFirstHistory = true
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var historyReads = 0
    init(owner: String, malformedHistory: Bool = false) {
        self.owner = owner; self.malformedHistory = malformedHistory
    }
    func release() { holdFirstHistory = false; waiter?.resume(); waiter = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" {
            return (Data(#"{"data":{"base":"SUI","currency":"USD","amount":"2"}}"#.utf8), 200)
        }
        if request.url?.host == "api.coingecko.com" {
            return (Data(#"[]"#.utf8), 200)
        }
        let call = try JSONDecoder().decode(SuiJSON.self, from: XCTUnwrap(request.httpBody))
        let query = try XCTUnwrap(call["query"].string)
        var value: [String: SuiJSON] = ["chainIdentifier": .string(SuiIdentity.mainnet)]
        if query.contains("transactions") {
            historyReads += 1
            if historyReads == 1, holdFirstHistory {
                // Model a response that completes after cancellation. No real
                // network, wallet, signing or diagnostic upload is involved.
                await withCheckedContinuation { waiter = $0 }
            }
            value["transactions"] = .object(["edges": malformedHistory ? .null : .array([]),
                "pageInfo": .object(["hasPreviousPage": .bool(false), "startCursor": .null])])
        } else if query.contains("balances(first") {
            value["address"] = .object(["address": .string(owner), "balances": .object([
                "nodes": .array([.object(["coinType": .object(["repr": .string(SuiIdentity.coin)]),
                    "totalBalance": .string("42"), "coinBalance": .string("42"), "addressBalance": .string("0")])]),
                "pageInfo": .object(["hasNextPage": .bool(false), "endCursor": .null])])])
        } else if query.contains("checkpoint") {
            value["checkpoint"] = .object(["sequenceNumber": .number("123")])
        } else { throw SuiError.malformed }
        return (try JSONEncoder().encode(SuiJSON.object(["data": .object(value)])), 200)
    }
}

extension SuiLedgerTests {
    private func waitForHeldHistory(_ feed: SuiCancellationFeed) async throws {
        for _ in 0..<200 {
            if await feed.historyReads > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("History did not reach the controlled response")
    }
    func testSupersededSuiHistoryCannotReportFailureForItsOldTicket() async throws {
        await DatabaseDiagnosticProbe.shared.configure()
        let operationID = UUID()
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = SuiCancellationFeed(owner: owner)
        let sync = SuiSynchronizer(database: db, client: try SuiClient(apiKey: "fixture", transport: feed), markets: SuiMarkets(transport: feed))
        try await OathDiagnostics.$operationID.withValue(operationID) { try await sync.refresh(accountID: "a1") }
        try await waitForHeldHistory(feed)
        try await sync.refresh(accountID: "a1")
        await sync.waitForHistory(accountID: "a1")
        await feed.release()
        // Drain the canceled worker's error boundary and the real local outbox.
        try await Task.sleep(for: .milliseconds(200)); await OathDiagnostics.flush()
        let errors = await DatabaseDiagnosticProbe.shared.events().filter { $0.operationID == operationID }
        XCTAssertFalse(errors.contains { $0.error.message == "staleSync" || $0.operation == "failSuiSync" }, "Expected old-task cancellation must not become a stale-ticket error")
        let inventory = try await db.suiInventory(accountID: "a1")
        XCTAssertEqual(inventory?.holdings.first?.amount, "42")
        let historyFailure = try await db.pool.read { try String.fetchOne($0, sql: "SELECT historyFailure FROM suiSync WHERE accountID='a1'") }
        XCTAssertNil(historyFailure)
        await sync.cancel()
    }
    func testCanceledSuiHistoryDoesNotPersistFailureButRealMalformedHistoryDoes() async throws {
        for malformed in [false, true] {
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let feed = SuiCancellationFeed(owner: owner, malformedHistory: malformed)
            let sync = SuiSynchronizer(database: db, client: try SuiClient(apiKey: "fixture", transport: feed), markets: SuiMarkets(transport: feed))
            try await sync.refresh(accountID: "a1")
            try await waitForHeldHistory(feed)
            if malformed {
                await feed.release(); await sync.waitForHistory(accountID: "a1")
            } else {
                let cancellation = Task { await sync.cancel() }
                try await Task.sleep(for: .milliseconds(20))
                await feed.release(); await cancellation.value
            }
            let failure = try await db.pool.read { try String.fetchOne($0, sql: "SELECT historyFailure FROM suiSync WHERE accountID='a1'") }
            XCTAssertEqual(failure, malformed ? "malformed" : nil)
            await sync.cancel()
        }
    }
}
