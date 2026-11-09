import XCTest
@testable import OathAnkr

private actor PreparationGate {
    var calls = 0
    var waiting: CheckedContinuation<Int, Never>?
    func read() async -> Int { calls += 1; return await withCheckedContinuation { waiting = $0 } }
    func release(_ value: Int) { waiting?.resume(returning: value); waiting = nil }
}
private final class PreparationClock: @unchecked Sendable {
    let lock = NSLock(); var instant = Date(timeIntervalSince1970: 100)
    func now() -> Date { lock.withLock { instant } }
    func advance(_ seconds: Double) { lock.withLock { instant += seconds } }
}
@MainActor final class SendBalancePreparationTests: XCTestCase {
    private func waitFor(_ gate: PreparationGate, calls: Int = 1) async throws {
        for _ in 0..<200 { if await gate.calls == calls { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Sender read did not start before navigation")
    }
    func testSelectionStartsBeforeReviewAndNavigationAndContinueJoinOneOperation() async throws {
        let gate = PreparationGate(), clock = PreparationClock()
        let flow = OathSendBalancePreparation<String, Int>(now: { clock.now() })
        let recipient = Task { try await flow.value(for: "wallet/account/asset") { await gate.read() } }
        try await waitFor(gate)
        recipient.cancel() // A view waiter goes away, not its flow-owned provider.
        do { _ = try await recipient.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        clock.advance(40) // A slow active operation must never be duplicated.
        let review = Task { try await flow.value(for: "wallet/account/asset", retry: true) { await gate.read() } }
        await Task.yield(); await gate.release(17)
        let reviewed = try await review.value; XCTAssertEqual(reviewed, 17)
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
    }
    func testDismissalOrIdentityChangeCannotPublishLateResultOrInvalidateNewFlight() async throws {
        let old = PreparationGate(), new = PreparationGate(), flow = OathSendBalancePreparation<String, Int>()
        let first = Task { try await flow.value(for: "old") { await old.read() } }
        try await waitFor(old)
        let second = Task { try await flow.value(for: "new") { await new.read() } }
        try await waitFor(new)
        await flow.invalidate(ifIdentity: "old") // Delayed lifecycle cleanup.
        await old.release(10); await new.release(20)
        do { _ = try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let result = try await second.value; XCTAssertEqual(result, 20)
    }
    func testFailureDoesNotBecomeZeroAndRetryIsBoundedAndShared() async throws {
        let flow = OathSendBalancePreparation<String, Int>()
        do { _ = try await flow.value(for: "asset") { throw URLError(.timedOut) }; XCTFail() } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        do { _ = try await flow.value(for: "asset") { XCTFail("Implicit retry"); return 0 }; XCTFail() } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let gate = PreparationGate()
        let retry = Task { try await flow.value(for: "asset", retry: true) { await gate.read() } }
        try await waitFor(gate)
        let join = Task { try await flow.value(for: "asset", retry: true) { XCTFail("Duplicate retry"); return 0 } }
        await Task.yield(); await gate.release(30)
        let retried = try await retry.value, joined = try await join.value; XCTAssertEqual(retried, 30); XCTAssertEqual(joined, 30)
    }
    func testReuseNeverRenewsObservationAndExpires() async throws {
        let clock = PreparationClock(), flow = OathSendBalancePreparation<String, Date>(now: { clock.now() })
        let first = try await flow.value(for: "a") { clock.now() }
        clock.advance(20)
        let cached = try await flow.value(for: "a") { XCTFail(); return clock.now() }
        XCTAssertEqual(first, cached)
        clock.advance(11)
        let fresh = try await flow.value(for: "a") { clock.now() }
        XCTAssertEqual(fresh.timeIntervalSince(first), 31)
    }
    func testSnapshotRequiresIdentityCurrentBlockAndOriginalTime() throws {
        let now = Date.now, block = SendSenderSnapshot.Block(height: 10, hash: "a")
        let value = try SendSenderSnapshot(chain: "ethereum", sender: "owner", reference: "native", decimals: 18, assetBalance: "100", nativeBalance: "100", observedAt: now, block: block)
        XCTAssertTrue(value.matches(chain: "ethereum", sender: "owner", reference: "native", decimals: 18, block: block, now: now))
        for age in [-1.0, 30, 40] { XCTAssertFalse(value.matches(chain: "ethereum", sender: "owner", reference: "native", decimals: 18, block: block, now: now.addingTimeInterval(age))) }
        XCTAssertFalse(value.matches(chain: "ethereum", sender: "owner", reference: "native", decimals: 18, block: .init(height: 10, hash: "reorg"), now: now))
        XCTAssertFalse(value.matches(chain: "base", sender: "owner", reference: "native", decimals: 18, block: block, now: now))
        XCTAssertThrowsError(try SendSenderSnapshot(chain: "x", sender: "owner", reference: "native", decimals: 8, assetBalance: "100", nativeBalance: "100", spendable: "101", observedAt: now))
    }
    func testFeeFailureReachesReviewBeforeSharedScanFinishes() async throws {
        let scan = PreparationGate(), fee = PreparationGate()
        let home = Task<Int, any Error> { await scan.read() }
        try await waitFor(scan)
        let review = Task { try await SendPreparationJoin.run(prepare: {
            _ = try await SendTaskValue.value(of: home)
        }, fee: { () async throws -> Int in
            _ = await fee.read(); throw URLError(.cannotConnectToHost)
        }) }
        try await waitFor(fee); await fee.release(0)
        // No release of scan occurs until Review has observed the error.
        do { _ = try await review.value; XCTFail() } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        XCTAssertFalse(home.isCancelled)
        await scan.release(7); let result = try await home.value; XCTAssertEqual(result, 7)
    }
    func testJoinPublishesOnlyAfterFeeAndSenderAreReady() async throws {
        let scan = PreparationGate(), fee = PreparationGate()
        let review = Task { try await SendPreparationJoin.run(prepare: { _ = await scan.read() }, fee: { await fee.read() }) }
        try await waitFor(scan); try await waitFor(fee)
        await scan.release(100); await fee.release(20)
        let result = try await review.value; XCTAssertEqual(result, 20)
    }

}
