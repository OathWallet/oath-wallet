import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

final class ThorchainVaultValidationTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let config: SolanaJSON = .object(["denom": .string("rune")])
    private func status(time: String = "9990000000000", shares: String = "100", ratio: String = "1.25") -> SolanaJSON {
        .object(["last_updated": .string(time), "deposit_pool": .object(["shares": .string(shares), "ratio": .string(ratio)])])
    }
    func testExpiredValidQuoteIsUnavailableAndNeverPublished() throws {
        for time in ["6400000000000", "1000000000"] {
            XCTAssertThrowsError(try ThorchainClient.decodeNodeVault(config: config, status: status(time: time), now: now)) {
                XCTAssertEqual($0 as? DiagnosticDeferral, .publicMarketQuoteUnavailable)
            }
        }
        let fresh = try ThorchainClient.decodeNodeVault(config: config, status: status(time: "6401000000000"), now: now)
        XCTAssertFalse(fresh.isNull)
    }
    func testEmptyPoolStillRequiresValidIdentityAndIntegerShares() throws {
        XCTAssertTrue(try ThorchainClient.decodeNodeVault(config: config, status: status(shares: "0", ratio: "0"), now: now).isNull)
        XCTAssertThrowsError(try ThorchainClient.decodeNodeVault(config: .null, status: status(shares: "0"), now: now))
        for shares in ["0.5", "-1", "1e3", "NaN", "340282366920938463463374607431768211456"] {
            XCTAssertThrowsError(try ThorchainClient.decodeNodeVault(config: config, status: status(shares: shares), now: now))
        }
    }
    func testUint128MaximumSharesRemainValid() throws {
        let row = try ThorchainClient.decodeNodeVault(config: config, status: status(shares: "340282366920938463463374607431768211455"), now: now)
        XCTAssertEqual(row["status"]["depositPool"]["shares"].string, "340282366920938463463374607431768211455")
    }
    func testReportedValidationReasonsStaySpecificAndExpiredQuotesStayQuiet() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THOR_VAULT_CAPTURE"] == "1" else { throw XCTSkip("Isolated diagnostics recorder") }
        let reports = VaultValidationReports(), id = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        await OathDiagnostics.$operationID.withValue(id) {
            await OathDiagnostics.withChain("thorchain") {
                for _ in 0..<28 {
                    let value = OathDiagnostics.attempt("thorchain_vault_node_read") {
                        try ThorchainClient.decodeNodeVault(config: config, status: status(time: "1000000000"), now: now)
                    }
                    XCTAssertNil(value)
                }
                let value = OathDiagnostics.attempt("thorchain_vault_node_read") {
                    try ThorchainClient.decodeNodeVault(config: config, status: status(time: "10061000000000"), now: now)
                }
                XCTAssertNil(value)
            }
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await !reports.events.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == id }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.message, "futureTimestamp")
        XCTAssertEqual(events.first?.context["chain"], "thorchain")
        XCTAssertEqual(events.first?.privacyFiltered, true)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("10061000000000")); XCTAssertFalse(encoded.contains("rune"))
    }
    func testInvalidOrFutureTimeAndInvalidRatioRemainFailures() throws {
        for time in ["0", "-1", "9990000000000.5", "NaN", "18446744073709551616", "10061000000000"] {
            XCTAssertThrowsError(try ThorchainClient.decodeNodeVault(config: config, status: status(time: time), now: now)) {
                XCTAssertFalse($0 is DiagnosticDeferral)
            }
        }
        for ratio in ["0", "-1", "NaN", "1e999"] {
            // Expiry must not disguise invalid quote data as normal absence.
            XCTAssertThrowsError(try ThorchainClient.decodeNodeVault(config: config, status: status(time: "1000000000", ratio: ratio), now: now)) {
                XCTAssertFalse($0 is DiagnosticDeferral)
            }
        }
    }
    func testFreshRatioKeepsExactScalingAndUnavailableRowsPreserveExistingPrice() throws {
        let row = try ThorchainClient.decodeNodeVault(config: config, status: status(), now: now)
        var catalog = ThorchainCatalog()
        catalog.tokens["x/ghost-vault/rune"] = .init(reference: "x/ghost-vault/rune", name: "Fixture", symbol: "LEND", decimals: 8)
        catalog.prices["native"] = "2"
        try ThorchainClient.applyVaultMarkets([row], to: &catalog, now: now)
        XCTAssertEqual(catalog.prices["x/ghost-vault/rune"], "2.5")
        try ThorchainClient.applyVaultMarkets([.null], to: &catalog, now: now)
        XCTAssertEqual(catalog.prices["x/ghost-vault/rune"], "2.5")
    }
}

private actor VaultValidationReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
