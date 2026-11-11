import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private struct AllPriceProvidersMalformed: MarketTransport {
    func data(from url: URL) async throws -> Data { throw MarketDataError.invalidResponse }
}

@MainActor final class PriceFailureCorrelationTests: XCTestCase {
    func testParallelProviderCausesShareChainAndLoadOperation() async throws {
        let capture = MarketTestDiagnostics.shared, operation = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let target = MarketAsset(id: "gnosis:native", networkID: "gnosis", reference: "native", decimals: 18)
        let service = MarketDataService(database: db, transport: AllPriceProvidersMalformed())
        await OathDiagnostics.$operationID.withValue(operation) {
            // Deliberately supply no task-local chain: the public API owns it.
            for _ in 0..<3 {
                do { _ = try await service.quote(for: target, force: true); XCTFail("Invented quote") }
                catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        let events = await capture.events(for: operation)
        let providers = events.filter { $0.operation == "provider_quote" }
        XCTAssertGreaterThanOrEqual(providers.count, 3, "Provider causes must remain attached to the failing quote")
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "gnosis" })
        XCTAssertEqual(events.filter { $0.operation == "market_load" }.count, 1)
        XCTAssertEqual(events.first { $0.operation == "market_load" }?.context["source"], "Market providers")
        XCTAssertEqual(Set(providers.compactMap { $0.context["stage"] }).count, providers.count)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(json.contains("https://"))
        XCTAssertFalse(json.contains(WrappedNativePrice.gnosis.reference))
        let saved = try await db.latestPrice(assetID: target.id, currency: "USD")
        XCTAssertNil(saved)
    }
}
