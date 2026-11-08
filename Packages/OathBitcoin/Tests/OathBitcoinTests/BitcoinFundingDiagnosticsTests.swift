import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

private actor BitcoinFundingReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class BitcoinFundingDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testInsufficientFundsRemainBlockedWithoutFailureReports() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_FUNDING_REPORTS"] == "1" else {
            throw XCTSkip("Run alone to isolate the shared diagnostics outbox")
        }
        let reports = BitcoinFundingReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let fixture = BitcoinSendTests()
        let coin = try fixture.coin(100_000)
        for coins in [[], [coin]] {
            do {
                _ = try fixture.plan(coins, amount: 200_000)
                XCTFail("An underfunded send must not produce a reviewable plan")
            } catch {
                XCTAssertEqual(error as? BitcoinSendError, .insufficientFunds)
                for operation in ["quote", "prepare"] {
                    OathDiagnostics.record(error, component: "send", operation: operation, context: ["chain": "bitcoin"])
                }
            }
        }
        XCTAssertNoThrow(try fixture.plan([coin], amount: 20_000))
        let failures: [BitcoinSendError] = [.feeUnavailable, .feeTooHigh, .invalidInput, .duplicateInput,
            .tooLarge, .changed, .expired, .signing, .submissionUnknown]
        for error in failures {
            OathDiagnostics.record(error, component: "send", operation: error.rawValue)
        }
        // Provider text cannot impersonate the local, typed funding outcome.
        OathDiagnostics.record(NSError(domain: "OathBitcoin.BitcoinSendError", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "insufficientFunds"]), component: "send", operation: "lookalike")
        for _ in 0..<200 {
            await OathDiagnostics.flush()
            if await reports.events.count >= failures.count + 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.count, failures.count + 1)
        XCTAssertEqual(Set(events.map(\.operation)), Set(failures.map(\.rawValue) + ["lookalike"]))
        XCTAssertTrue(events.allSatisfy(\.privacyFiltered))
    }
}
