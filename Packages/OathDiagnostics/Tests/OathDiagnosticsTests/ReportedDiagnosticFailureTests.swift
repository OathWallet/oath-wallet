import Foundation
import XCTest
@testable import OathDiagnostics

private actor PropagationCapture: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}
final class ReportedDiagnosticFailureTests: XCTestCase, @unchecked Sendable {
    private struct Original: Error, Equatable { let code: Int }

    func testOriginalFailureAndMarkerSurviveResultPropagation() throws {
        let original = Original(code: -32602)
        let error = OathDiagnostics.recordedForPropagation(original)
        let marker = try XCTUnwrap(error as? ReportedDiagnosticFailure)
        XCTAssertEqual(marker.underlying as? Original, original)
        XCTAssertTrue(marker.isExpectedDiagnosticControlFlow)
        let second = OathDiagnostics.recordedForPropagation(marker)
        XCTAssertEqual((second as? ReportedDiagnosticFailure)?.underlying as? Original, original)
        let result: Result<Void, any Error> = .failure(second)
        do { try result.get(); XCTFail("A logged failure must not become success") }
        catch { XCTAssertEqual((error as? ReportedDiagnosticFailure)?.underlying as? Original, original) }
    }

    func testCancellationAndDeferralKeepTheirTypedIdentity() {
        XCTAssertTrue(OathDiagnostics.recordedForPropagation(CancellationError()) is CancellationError)
        XCTAssertEqual((OathDiagnostics.recordedForPropagation(URLError(.cancelled)) as? URLError)?.code, .cancelled)
        XCTAssertEqual(OathDiagnostics.recordedForPropagation(DiagnosticDeferral.publicMarketCooldown) as? DiagnosticDeferral, .publicMarketCooldown)
    }

    func testOuterRefreshReportsDoNotDuplicateTheOwningReportAndPrivacyIsPreserved() async throws {
        guard ProcessInfo.processInfo.environment["OATH_PROPAGATION_CAPTURE"] == "1" else {
            throw XCTSkip("Isolated process-wide recorder capture")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = PropagationCapture()
        OathDiagnostics.configure(file: folder.appendingPathComponent("reports.json"), transport: capture)
        let id = UUID(), sentinel = UUID()
        // Wait for configure before exercising the actual public recorder.
        for _ in 0..<100 {
            OathDiagnostics.$operationID.withValue(sentinel) { OathDiagnostics.record(Original(code: 1), operation: "ready") }
            try await Task.sleep(for: .milliseconds(20))
            if await capture.events.contains(where: { $0.operationID == sentinel }) { break }
        }
        // Exercise a retained validation failure. Routine TLS availability
        // failures are deliberately excluded by the shared recording policy.
        let original = NSError(domain: "Fixture.Provider", code: -32602, userInfo: [
            NSLocalizedDescriptionKey: "Response validation failed at https://rpc.ankr.com/multichain/SecretFixtureKey",
            "private": "must-not-upload-this-value"])
        XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(original,
            component: "provider", severity: "error", context: ["chain": "ethereum"], runtimeReport: nil))
        let propagated = OathDiagnostics.$operationID.withValue(id) {
            OathDiagnostics.recordedForPropagation(original, component: "provider", operation: "read",
                context: ["chain": "ethereum", "host": "rpc.ankr.com", "method": "ankr_getAccountBalance"])
        }
        // These are the actual APIs used by refreshAnkr, refreshAnkrResult,
        // automatic refresh and presentation; none should create another record.
        for operation in ["refreshAnkr", "refreshAnkrResult", "refresh_ankr", "startRefresh"] {
            OathDiagnostics.$operationID.withValue(id) { OathDiagnostics.record(propagated, operation: operation) }
        }
        _ = OathDiagnostics.recordedForPropagation(propagated)
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operationID == id }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await capture.events.filter { $0.operationID == id }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.domain, "Fixture.Provider")
        XCTAssertEqual(events.first?.error.code, -32602)
        XCTAssertEqual(events.first?.context["chain"], "ethereum")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SecretFixtureKey"))
        XCTAssertFalse(encoded.contains("must-not-upload-this-value"))
    }
}
