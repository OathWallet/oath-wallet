import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor DiscoveryCount {
    var count = 0
    func increment() { count += 1 }
}
final class ExploreTransportTests: XCTestCase, @unchecked Sendable {
    func testNoStoreResponseDoesNotEnterSharedCache() async throws {
        let pool = PublicMarketRequests(spacing: .zero), count = DiscoveryCount()
        let request = URLRequest(url: URL(string: "https://api.coinlore.net/api/tickers/?start=0&limit=100")!)
        XCTAssertTrue(PublicMarketRequests.accepts(request))
        for _ in 0..<2 {
            _ = try await pool.send(request) { await count.increment(); return .init(data: Data("fixture".utf8), status: 200, cacheAllowed: false) }
        }
        let actual = await count.count; XCTAssertEqual(actual, 2)
    }
    func testQuotaExhaustionStopsHostBeforeAnotherEndpoint() async throws {
        let pool = PublicMarketRequests(spacing: .zero), count = DiscoveryCount()
        let url = URL(string: "https://api.dexpaprika.com/tokens/search?limit=100")!
        _ = try await pool.send(URLRequest(url: url)) { .init(data: Data(), status: 402) }
        do {
            _ = try await pool.send(URLRequest(url: URL(string: url.absoluteString + "&chains=ethereum")!)) { await count.increment(); return .init(data: Data(), status: 200) }
            XCTFail("Exhausted host must defer")
        } catch { XCTAssertTrue(error is DiagnosticDeferral) }
        let actual = await count.count; XCTAssertEqual(actual, 0)
    }
    func testBrowserJournalNamespaceKeepsRelayAndRejectsRawIDs() {
        XCTAssertTrue(DAppEVMRequestID.isValid("browser:" + String(repeating: "a", count: 64)))
        XCTAssertTrue(DAppEVMRequestID.isValid("wc:" + String(repeating: "a", count: 64)))
        for bad in ["browser:one", "browser:" + String(repeating: "z", count: 64), "wc:" + String(repeating: "a", count: 63), String(repeating: "a", count: 64)] { XCTAssertFalse(DAppEVMRequestID.isValid(bad)) }
    }
    func testInteractiveQueueRunsBeforeWaitingDiscovery() async throws {
        let gate = PublicMarketPermit()
        try await gate.acquire(priority: .discovery)
        let order = DiscoveryOrder()
        let low = Task { try await gate.acquire(priority: .discovery); await order.add("discovery"); await gate.release() }
        try await Task.sleep(for: .milliseconds(20))
        let high = Task { try await gate.acquire(priority: .interactive); await order.add("interactive"); await gate.release() }
        try await Task.sleep(for: .milliseconds(20))
        await gate.release(); try await high.value; try await low.value
        let values = await order.values; XCTAssertEqual(values, ["interactive", "discovery"])
    }
}
private actor DiscoveryOrder { var values: [String] = []; func add(_ value: String) { values.append(value) } }
