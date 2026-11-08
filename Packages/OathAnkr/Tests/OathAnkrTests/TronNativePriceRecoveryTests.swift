import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private func trxQuote(key: String = "coingecko:tron", symbol: String = "TRX", price: Double = 0.32,
                      confidence: Double = 0.99, age: Double = 0) -> Data {
    try! JSONSerialization.data(withJSONObject: ["coins": [key: ["symbol": symbol, "price": String(price),
        "confidence": confidence, "timestamp": Date().timeIntervalSince1970 - age]]])
}

private actor TronNativeQuoteReplies: AnkrTransport {
    enum Mode: Sendable { case unavailable, healthy, cancelled, wrapped, liveRecovery, invalidPrimary }
    let mode: Mode
    let fallback: Data
    private(set) var hosts: [String] = []
    init(_ mode: Mode = .unavailable, fallback: Data = trxQuote()) { self.mode = mode; self.fallback = fallback }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = try XCTUnwrap(request.url?.host)
        hosts.append(host)
        switch host {
        case "api.coinbase.com":
            if mode == .healthy { return (Data(#"{"data":{"base":"TRX","currency":"USD","amount":"0.31"}}"#.utf8), 200) }
            if mode == .cancelled { throw URLError(.cancelled) }
            if mode == .invalidPrimary { throw AnkrError.invalidResponse }
            throw AnkrError.transport
        case "api.dexscreener.com":
            if mode == .wrapped {
                return (Data(#"[{"chainId":"tron","baseToken":{"address":"TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR"},"priceUsd":"0.33","liquidity":{"usd":1000000}}]"#.utf8), 200)
            }
            return (Data("[]".utf8), 200)
        case "api.geckoterminal.com": return (Data(#"{"data":{"type":"simple_token_price","attributes":{"token_prices":{}}}}"#.utf8), 200)
        case "api.coingecko.com": return (Data("{}".utf8), 200)
        case "coins.llama.fi":
            XCTAssertEqual(request.url?.path, "/prices/current/coingecko:tron")
            XCTAssertNil(request.url?.query)
            if mode == .liveRecovery { return try await AnkrHTTPTransport().send(request) }
            return (fallback, 200)
        default: XCTFail("Unexpected provider"); throw AnkrError.invalidResponse
        }
    }
}

final class TronNativePriceRecoveryTests: XCTestCase, @unchecked Sendable {
    func testNativeQuoteRecoversWhenPrimaryFailsAndWrappedFeedsAreEmpty() async throws {
        let transport = TronNativeQuoteReplies()
        let quote = try await TronMarkets(transport: transport).nativePrice()
        XCTAssertEqual(quote.mint, "native"); XCTAssertEqual(quote.usd, "0.32")
        XCTAssertEqual(quote.source, "DefiLlama")
        let hosts = await transport.hosts
        XCTAssertEqual(hosts.count, 5)
        XCTAssertEqual(hosts.last, "coins.llama.fi")
    }
    func testHealthyPrimaryAndWrappedRecoveryKeepExistingBehavior() async throws {
        for mode in [TronNativeQuoteReplies.Mode.healthy, .wrapped] {
            let transport = TronNativeQuoteReplies(mode)
            let quote = try await TronMarkets(transport: transport).nativePrice()
            XCTAssertEqual(quote.source, mode == .healthy ? "Coinbase" : "DEX Screener")
            let hosts = await transport.hosts
            XCTAssertFalse(hosts.contains("coins.llama.fi"))
        }
    }
    func testCancellationStopsAllFallbacks() async throws {
        let transport = TronNativeQuoteReplies(.cancelled)
        do { _ = try await TronMarkets(transport: transport).nativePrice(); XCTFail("Cancellation swallowed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, ["api.coinbase.com"])
    }
    func testInvalidNativeQuotesNeverBecomePrices() async throws {
        for payload in [trxQuote(key: "coingecko:ethereum"), trxQuote(symbol: "ETH"), trxQuote(price: 0),
                        trxQuote(price: -1), trxQuote(confidence: 0.89), trxQuote(confidence: 1.01), trxQuote(age: -120)] {
            do { _ = try await TronMarkets(transport: TronNativeQuoteReplies(fallback: payload)).nativePrice(); XCTFail("Invalid native quote accepted") }
            catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        }
    }
    func testMissingAndExpiredQuotesRemainUnavailable() async throws {
        for payload in [Data(#"{"coins":{}}"#.utf8), trxQuote(age: 901)] {
            do { _ = try await TronMarkets(transport: TronNativeQuoteReplies(fallback: payload)).nativePrice(); XCTFail("Missing quote accepted") }
            catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketQuoteUnavailable) }
        }
        let quote = try await TronMarkets(transport: TronNativeQuoteReplies(fallback: trxQuote(age: 120))).nativePrice()
        XCTAssertEqual(Date().timeIntervalSince(quote.fetchedAt), 120, accuracy: 10)
    }
    func testLiveNativeRecoveryAgainstIndependentCoinbaseQuote() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_TRON_QUOTES"] == "1" else { throw XCTSkip("Opt-in read-only public prices") }
        async let primary = TronMarkets().nativePrice()
        async let fallback = TronMarkets(transport: TronNativeQuoteReplies(.liveRecovery)).nativePrice()
        let (a, b) = try await (primary, fallback)
        XCTAssertEqual(a.source, "Coinbase"); XCTAssertEqual(b.source, "DefiLlama")
        let pa = try XCTUnwrap(Double(a.usd)), pb = try XCTUnwrap(Double(b.usd))
        XCTAssertGreaterThan(pa, 0); XCTAssertGreaterThan(pb, 0)
        XCTAssertLessThan(abs(pa - pb) / pa, 0.05)
        print("TRX_LIVE_PRICE Coinbase=\(pa) DefiLlama=\(pb) injected_primary_outage=true empty_wrapped_feeds=true read_only=true")
    }
}

private actor TronNativePriceReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class TronNativePriceDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // The recorder configures once, so this class runs in its own test process.
    func testRecoveredFailureReportedOnceWithChainAndOperationAndCancellationQuiet() async throws {
        let reports = TronNativePriceReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let id = UUID()
        try await OathDiagnostics.$operationID.withValue(id) {
            try await OathDiagnostics.$chain.withValue("ethereum") {
                _ = try await TronMarkets(transport: TronNativeQuoteReplies()).nativePrice()
                _ = try await TronMarkets(transport: TronNativeQuoteReplies(.invalidPrimary)).nativePrice()
                XCTAssertEqual(OathDiagnostics.chain, "ethereum")
            }
        }
        do { _ = try await TronMarkets(transport: TronNativeQuoteReplies(.cancelled)).nativePrice(); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<200 {
            await OathDiagnostics.flush()
            if await reports.events.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.operation, "tron_native_fallback")
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "tron" && $0.operationID == id && $0.privacyFiltered })
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(payload.contains("https://")); XCTAssertFalse(payload.contains("coingecko:tron"))
        XCTAssertFalse(payload.contains("TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR"))
        XCTAssertNil(OathDiagnostics.chain); XCTAssertNil(OathDiagnostics.operationID)
    }
}
