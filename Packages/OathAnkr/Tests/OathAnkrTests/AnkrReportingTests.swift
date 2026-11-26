import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor AnkrReportCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}
private actor InvalidParametersTransport: AnkrTransport {
    var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        return (Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"private-provider-message-should-not-be-uploaded"}}"#.utf8), 200)
    }
}
final class AnkrReportingTests: XCTestCase, @unchecked Sendable {
    func testInvalidParametersAreNotRetriedOrReportedByPermitCleanup() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_REPORT_CAPTURE"] == "1" else {
            throw XCTSkip("Dedicated process for shared recorder capture")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = AnkrReportCapture()
        OathDiagnostics.configure(file: folder.appendingPathComponent("reports.json"), transport: capture)
        let ready = UUID()
        for _ in 0..<100 {
            OathDiagnostics.$operationID.withValue(ready) {
                OathDiagnostics.record(DiagnosticFailure("ready"), component: "fixture", operation: "ready")
            }
            try await Task.sleep(for: .milliseconds(25))
            if await capture.events.contains(where: { $0.operationID == ready }) { break }
        }
        let transport = InvalidParametersTransport(), client = try AnkrClient(apiKey: "SecretFixtureKey", transport: transport)
        let id = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(id) {
                try await client.balances(chain: .eth, address: "0x1111111111111111111111111111111111111111")
            }
            XCTFail("The original failure must reach the caller")
        } catch { XCTAssertEqual(error as? AnkrError, .rpc(-32602)) }
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operationID == id }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { $0.operationID == id }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.message, "rpc(-32602)")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SecretFixtureKey"))
        XCTAssertFalse(encoded.contains("private-provider-message"))
        let count = await transport.calls
        XCTAssertEqual(count, 1, "Invalid parameters are permanent; never retry the same request")
        // More than the four available permits verifies failures release them.
        for _ in 0..<5 {
            do { _ = try await client.balances(chain: .eth, address: "0x1111111111111111111111111111111111111111"); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError, .rpc(-32602)) }
        }
        let after = await transport.calls
        XCTAssertEqual(after, 6)
    }
}
