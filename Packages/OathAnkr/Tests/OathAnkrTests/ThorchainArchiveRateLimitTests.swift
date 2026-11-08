import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor ArchiveRateTransport: AnkrTransport {
    let status: Int
    init(status: Int = 429) { self.status = status }
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        return (Data(#"{"message":"errors.rateLimited","code":429,"value":60000}"#.utf8), status)
    }
}
private actor ArchiveReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
final class ThorchainArchiveRateLimitTests: XCTestCase {
    func testRateLimitAndCooldownStayQuietWhileAccessFailuresRemainPrivate() async throws {
        let reports = ArchiveReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let transport = ArchiveRateTransport(), client = ThorchainClient(transport: transport), operation = UUID()
        let owner = "thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2"
        do {
            _ = try await OathDiagnostics.$operationID.withValue(operation) {
                try await client.history(owner: owner, stream: "archive", height: 123)
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? ThorchainError, .http(429)) }
        for _ in 0..<100 {
            if await reports.events.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let initial = await reports.events
        XCTAssertTrue(initial.isEmpty, "Rate limits follow the shared availability policy")
        for _ in 0..<3 {
            do {
                _ = try await client.history(owner: owner, stream: "archive", height: 124)
                XCTFail()
            } catch {
                XCTAssertTrue((error as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow == true)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let final = await reports.events, calls = await transport.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(final.count, initial.count)
        XCTAssertTrue(final.allSatisfy { $0.operationID == operation && $0.privacyFiltered })
        let denied = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(denied) {
                try await ThorchainClient(transport: ArchiveRateTransport(status: 403))
                    .history(owner: owner, stream: "archive", height: 123)
            }
            XCTFail("Access failure must reject archive history")
        } catch { XCTAssertEqual(error as? ThorchainError, .http(403)) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operationID == denied }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let access = await reports.events.filter { $0.operationID == denied }
        XCTAssertFalse(access.isEmpty)
        XCTAssertTrue(access.allSatisfy { $0.context["chain"] == "thorchain" && $0.privacyFiltered })
        let serialized = String(decoding: try JSONEncoder().encode(access), as: UTF8.self)
        XCTAssertFalse(serialized.contains(owner))
        XCTAssertFalse(serialized.contains("/addresses/"))
        XCTAssertFalse(serialized.contains("errors.rateLimited"))
    }
    func testPacingWaitIsCancellable() async throws {
        let scheduler = ThorchainArchiveRequests(spacing: .seconds(60))
        try await scheduler.reserve()
        let task = Task { try await scheduler.reserve() }
        task.cancel()
        do { try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
