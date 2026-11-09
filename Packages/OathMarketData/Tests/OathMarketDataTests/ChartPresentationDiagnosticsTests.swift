import XCTest
@testable import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private actor InvalidDisplayChart: MarketTransport {
    var candles = 0
    func data(from url: URL) async throws -> Data {
        if url.path.hasSuffix("/candles") {
            candles += 1
            return Data("[[1,2,3]]".utf8)
        }
        throw MarketDataError.notListed
    }
}

@MainActor final class ChartPresentationDiagnosticsTests: XCTestCase {
    private let asset = MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)

    func testInvalidProviderIsRecordedOnceAcrossConcurrentScreensAndBackoff() async throws {
        let capture = MarketTestDiagnostics.shared, operation = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = InvalidDisplayChart(), target = asset
        let service = MarketDataService(database: db, transport: feed)
        await OathDiagnostics.$operationID.withValue(operation) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        do { _ = try await service.chartForPresentation(for: target); XCTFail("Invalid chart accepted") }
                        catch { OathDiagnostics.record(error, component: "asset_details", operation: "display_chart") }
                    }
                }
            }
            for _ in 0..<3 {
                do { _ = try await service.chartForPresentation(for: target, force: true); XCTFail("Backoff accepted") }
                catch { OathDiagnostics.record(error, component: "asset_details", operation: "display_chart") }
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        let events = await capture.events(for: operation), calls = await feed.candles
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(events.count, 1, "One original failure, no display/backoff copies")
        XCTAssertEqual(events.first?.operation, "market_load")
        XCTAssertEqual(events.first?.error.message, "invalidResponse")
    }

    func testCacheDecodeFailureStillReachesDisplayReporter() async throws {
        let capture = MarketTestDiagnostics.shared, operation = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        try await db.saveMarketCache(.init(key: "v1.chart." + asset.cacheIdentity, source: "fixture", payload: Data("{}".utf8), fetchedAt: Date().timeIntervalSince1970))
        let service = MarketDataService(database: db, transport: InvalidDisplayChart())
        await OathDiagnostics.$operationID.withValue(operation) {
            do { _ = try await service.chartForPresentation(for: asset); XCTFail("Corrupt cache accepted") }
            catch {
                XCTAssertTrue(error is DecodingError)
                OathDiagnostics.record(error, component: "asset_details", operation: "display_chart")
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        let events = await capture.events(for: operation)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.operation, "display_chart")
    }

    func testNewCacheReadFailureIsReportedEvenDuringProviderBackoff() async throws {
        let capture = MarketTestDiagnostics.shared, operation = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let service = MarketDataService(database: db, transport: InvalidDisplayChart())
        await OathDiagnostics.$operationID.withValue(operation) {
            do { _ = try await service.chartForPresentation(for: asset); XCTFail("Invalid chart accepted") }
            catch { OathDiagnostics.record(error, operation: "display_chart") }
        }
        // Only this disposable database is damaged. A new storage failure must
        // not disappear behind the previous provider's cooldown.
        try await db.pool.write { try $0.execute(sql: "DROP TABLE publicMarketCache") }
        await OathDiagnostics.$operationID.withValue(operation) {
            do { _ = try await service.chartForPresentation(for: asset); XCTFail("Missing cache table accepted") }
            catch { OathDiagnostics.record(error, operation: "display_chart") }
        }
        try await Task.sleep(for: .milliseconds(500))
        let events = await capture.events(for: operation)
        XCTAssertEqual(events.filter { $0.operation == "market_load" }.count, 2)
        XCTAssertTrue(events.contains { $0.error.domain.contains("GRDB") })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("DROP TABLE"))
        XCTAssertFalse(events.contains { $0.operation == "display_chart" })
    }

    func testRawCallerKeepsDomainErrorWhenSharingDisplayFlight() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let service = MarketDataService(database: db, transport: InvalidDisplayChart()), target = asset
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { _ = try await service.chart(for: target); return false }
                catch { return error as? MarketDataError == .invalidResponse }
            }
            group.addTask {
                do { _ = try await service.chartForPresentation(for: target); return false }
                catch { return error is ReportedMarketLoadFailure }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes, [true, true])
    }

    func testReportedTimeoutStillRecoversThroughIndependentChart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let date = Date(), doge = MarketAsset(id: "dogecoin:native", networkID: "dogecoin", reference: "native", decimals: 8)
        let feed = UnavailableExchangeChart(URLError(.timedOut), date: date)
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let value = try await service.chartForPresentation(for: doge)
        XCTAssertEqual(value.value.points.map(\.close), [0.2, 0.22])
    }

    func testCancellationAndMissingCoverageKeepTheirOriginalMeaning() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        for failure in [CancellationError() as any Error, URLError(.cancelled)] {
            let feed = UnavailableExchangeChart(failure, date: Date())
            do { _ = try await MarketDataService(database: db, transport: feed).chartForPresentation(for: asset); XCTFail("Cancelled request accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
            let calls = await feed.requests
            XCTAssertFalse(calls.contains { $0.host == "api.coingecko.com" })
        }
        XCTAssertEqual(ReportedMarketLoadFailure.mark(MarketDataError.notListed) as? MarketDataError, .notListed)
        XCTAssertEqual(ReportedMarketLoadFailure.mark(DiagnosticDeferral.publicMarketCooldown) as? DiagnosticDeferral, .publicMarketCooldown)
    }

    func testLivePresentationFallbackMatchesPublicChart() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CHART_PRESENTATION_LIVE"] == "1" else { throw XCTSkip("Opt-in public market read") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite"), date = Date()
        let db = try await OathDatabase.open(at: path)
        let doge = MarketAsset(id: "dogecoin:native", networkID: "dogecoin", reference: "native", decimals: 8)
        let feed = UnavailableExchangeChart(URLError(.timedOut), date: date, live: true)
        let actual = try await MarketDataService(database: db, transport: feed, now: { date }).chartForPresentation(for: doge)
        let raw = await feed.chart, source = await feed.chartSource
        let expected = try source == "Kraken" ? KrakenNativeChart.decode(XCTUnwrap(raw), market: .dogecoin, at: date) : MarketDecoding.geckoChart(XCTUnwrap(raw), now: date)
        XCTAssertEqual(actual.value, expected)
        XCTAssertGreaterThanOrEqual(actual.value.points.count, 24)
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened).cachedChart(for: doge)
        XCTAssertEqual(saved?.value, actual.value)
        XCTAssertEqual(saved?.fetchedAt, actual.fetchedAt)
        print("LIVE_CHART_PRESENTATION source=\(source ?? "unknown") points=\(actual.value.points.count) reopenPreserved=true")
    }
}
