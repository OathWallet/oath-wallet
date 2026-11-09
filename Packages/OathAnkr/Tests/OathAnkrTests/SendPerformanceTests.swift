import XCTest
@testable import OathAnkr

private struct MeasuredFixtureTransport: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        await Task.yield()
        return (Data(), 200)
    }
}

@MainActor final class SendPerformanceTests: XCTestCase {
    func testTaskLocalCountsChildRequestsAndRestoresNestedScope() async throws {
        let transport = SendMeasuredTransport(base: MeasuredFixtureTransport())
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://fixture.invalid")))
        XCTAssertNil(SendPerformance.counter)

        let result = try await SendPerformance.measure(.preparation) { @Sendable in
            let outer = try XCTUnwrap(SendPerformance.counter)
            _ = try await transport.send(request)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<3 {
                    group.addTask {
                        XCTAssertTrue(SendPerformance.counter === outer)
                        _ = try await transport.send(request)
                    }
                }
                try await group.waitForAll()
            }
            XCTAssertEqual(outer.value, 4)

            try await SendPerformance.measure(.fee) { @Sendable in
                let inner = try XCTUnwrap(SendPerformance.counter)
                XCTAssertFalse(inner === outer)
                _ = try await transport.send(request)
                XCTAssertEqual(inner.value, 1)
            }
            XCTAssertTrue(SendPerformance.counter === outer)
            XCTAssertEqual(outer.value, 4)
            return 42
        }

        XCTAssertEqual(result, 42)
        XCTAssertNil(SendPerformance.counter)
    }

    func testOriginalErrorPropagatesAndTaskLocalIsCleared() async {
        do {
            try await SendPerformance.measure(.preparation) { @Sendable in
                XCTAssertNotNil(SendPerformance.counter)
                throw URLError(.timedOut)
            }
            XCTFail("The measured operation must propagate its error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertNil(SendPerformance.counter)
    }

    func testCancellationPropagatesAndTaskLocalIsCleared() async {
        let operation = Task {
            do {
                try await SendPerformance.measure(.preparation) { @Sendable in
                    XCTAssertNotNil(SendPerformance.counter)
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
                XCTFail("The measured operation must propagate cancellation")
                return false
            } catch {
                return error is CancellationError && SendPerformance.counter == nil
            }
        }
        let cancelled = await operation.value
        XCTAssertTrue(cancelled)
        XCTAssertNil(SendPerformance.counter)
    }
}
