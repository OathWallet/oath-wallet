import Foundation
import OathAnkr
import OathDiagnostics

/// Owns observation recovery and the final publication barrier, not provider
/// flights or UI timing. The app and host integration tests use this same code.
@MainActor public final class PortfolioRefreshCoordinator<Value: Sendable> {
    public typealias Pause = @Sendable (Duration) async throws -> Void
    private let pause: Pause
    private var observation: Task<Void, Never>?
    private var generation = UUID()
    public var isObserving: Bool { observation != nil }

    public init(pause: @escaping Pause = { try await Task.sleep(for: $0) }) { self.pause = pause }

    public func stop() {
        generation = UUID()
        observation?.cancel()
        observation = nil
    }

    public func observe(
        stream: @escaping @Sendable () -> AsyncThrowingStream<Value, any Error>,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        publish: @escaping @MainActor @Sendable (Value) async throws -> Void,
        exhausted: @escaping @MainActor @Sendable () -> Void
    ) {
        stop()
        let token = generation, pause = pause, operationID = UUID()
        observation = Task { [weak self] in
            await OathDiagnostics.$operationID.withValue(operationID) {
                defer { if self?.generation == token { self?.observation = nil } }
                for attempt in 0...3 {
                    guard !Task.isCancelled, self?.generation == token, isCurrent() else { return }
                    do {
                        for try await value in stream() {
                            try Task.checkCancellation()
                            guard self?.generation == token, isCurrent() else { return }
                            try await publish(value)
                        }
                        try Task.checkCancellation()
                        throw BalanceRefreshError.observationEnded
                    } catch {
                        // Lock, reset and replacement own this task's cancellation.
                        guard !Task.isCancelled, !(error is CancellationError),
                              self?.generation == token, isCurrent() else { return }
                        OathDiagnostics.record(error, component: "portfolio_refresh", operation: "observe",
                                               context: ["stage": "recovery", "attempt": String(attempt)])
                        guard attempt < 3 else { exhausted(); return }
                        do { try await pause(.seconds(1 << attempt)) }
                        catch is CancellationError { return } // Expected observation teardown.
                        catch {
                            OathDiagnostics.record(error, component: "portfolio_refresh", operation: "recovery_delay")
                            return
                        }
                    }
                }
            }
        }
    }

    /// Even a failed provider may have committed useful partial balances.
    /// Publish those before propagating the original outcome to existing callers.
    public func perform(
        work: @MainActor () async -> [BalanceRefreshOutcome],
        read: @Sendable () async throws -> Value,
        isCurrent: @MainActor () -> Bool,
        publish: @MainActor (Value) async throws -> Void
    ) async throws {
        let outcomes = await work()
        try Task.checkCancellation()
        guard isCurrent(), !outcomes.contains(where: { if case .cancelled = $0 { return true }; return false }) else { throw CancellationError() }
        do {
            let value = try await read()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await publish(value)
        } catch {
            if !Task.isCancelled && !(error is CancellationError) {
                OathDiagnostics.record(error, component: "portfolio_refresh", operation: "reconcile")
            }
            throw error
        }
        for outcome in outcomes { try outcome.get() }
    }
}
