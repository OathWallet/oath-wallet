import Foundation

/// Public, read-only sender evidence. This is neither a quote nor an authorization.
/// Quantities are atomic strings; spendable excludes reserves but not a future fee.
public struct SendSenderSnapshot: Sendable, Equatable {
    /// Only production clients can construct pinned provider evidence. Callers
    /// may carry it between screens, but cannot manufacture a validated read.
    public struct Evidence: Sendable, Equatable {
        let polkadotStorage: [String: Data]
        let xrplAccount: XrplJSON?
        init(polkadotStorage: [String: Data] = [:], xrplAccount: XrplJSON? = nil) {
            self.polkadotStorage = polkadotStorage; self.xrplAccount = xrplAccount
        }
    }
    public struct Block: Sendable, Equatable {
        public let height: UInt64
        public let hash: String
        public init(height: UInt64, hash: String) { self.height = height; self.hash = hash }
    }
    public let chain: String
    public let sender: String
    public let reference: String
    public let decimals: Int
    public let assetBalance: String
    public let nativeBalance: String
    public let spendable: String
    public let observedAt: Date
    public let block: Block?
    let evidence: Evidence?

    public init(chain: String, sender: String, reference: String, decimals: Int,
                assetBalance: String, nativeBalance: String, spendable: String? = nil,
                observedAt: Date, block: Block? = nil, evidence: Evidence? = nil) throws {
        for value in [assetBalance, nativeBalance, spendable ?? assetBalance] {
            guard !value.isEmpty, value.count <= 256, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  value == "0" || value.first != "0" else { throw EVMSendError.malformed }
        }
        guard (0...255).contains(decimals), !chain.isEmpty, !sender.isEmpty,
              !EVMSendAmount.less(assetBalance, spendable ?? assetBalance) else { throw EVMSendError.malformed }
        self.chain = chain; self.sender = sender; self.reference = reference; self.decimals = decimals
        self.assetBalance = assetBalance; self.nativeBalance = nativeBalance; self.spendable = spendable ?? assetBalance
        self.observedAt = observedAt; self.block = block; self.evidence = evidence
    }

    /// Age is only an upper bound. Anchored reuse additionally requires exactly
    /// the current chain-verified head. Unanchored data never passes this check.
    public func matches(chain: String, sender: String, reference: String, decimals: Int,
                        block: Block, now: Date = .now) -> Bool {
        self.chain == chain && self.sender == sender && self.reference == reference && self.decimals == decimals &&
        self.block == block && (0..<30).contains(now.timeIntervalSince(observedAt))
    }
}

/// A cancellable subscriber to an independently owned task. Cancelling a screen
/// or a quote must not cancel a shared Home scan or provider single-flight.
public enum SendTaskValue {
    public static func value<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        let waiter = Waiter<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task { waiter.finish(await task.result) }
            }
        } onCancel: { waiter.finish(.failure(CancellationError())) }
    }

    private final class Waiter<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var result: Result<T, any Error>?
        func install(_ continuation: CheckedContinuation<T, any Error>) {
            let result: Result<T, any Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil as Result<T, any Error>?
            }
            if let result { continuation.resume(with: result) }
        }
        func finish(_ result: Result<T, any Error>) {
            let continuation = lock.withLock {
                guard self.result == nil else { return nil as CheckedContinuation<T, any Error>? }
                self.result = result
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }
}

/// Owned by one Send flow, not by a Recipient/Amount/Review view. Identity is
/// supplied by the app and includes wallet generation, account and asset policy.
/// A failed attempt can be retried explicitly. Successful reuse never renews time.
public actor OathSendBalancePreparation<Identity: Hashable & Sendable, Snapshot: Sendable> {
    private enum State { case running, succeeded, failed }
    private struct Flight {
        let identity: Identity
        let generation: UUID
        let started: Date
        let task: Task<Snapshot, any Error>
        var state: State = .running
    }
    private var flight: Flight?
    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { .now }) { self.now = now }

    public func value(for identity: Identity, retry: Bool = false,
                      prepare: @escaping @Sendable () async throws -> Snapshot) async throws -> Snapshot {
        let current: Flight
        if let flight, flight.identity == identity,
           flight.state == .running || (flight.state == .failed && !retry) ||
           (flight.state == .succeeded && (0..<30).contains(now().timeIntervalSince(flight.started))) {
            current = flight
        } else {
            invalidate()
            let generation = UUID()
            current = Flight(identity: identity, generation: generation, started: now(), task: Task {
                do {
                    let result = try await SendPerformance.measure(.preparation, body: prepare)
                    self.finished(generation, state: .succeeded)
                    return result
                } catch {
                    // diagnostics: preparation-owner-rethrows
                    // The provider boundary reports the original error once.
                    self.finished(generation, state: .failed)
                    throw error
                }
            })
            flight = current
        }
        let value = try await SendTaskValue.value(of: current.task)
        try Task.checkCancellation()
        guard flight?.generation == current.generation else { throw CancellationError() }
        return value
    }

    private func finished(_ generation: UUID, state: State) {
        guard flight?.generation == generation else { return }
        flight?.state = state
    }

    public func invalidate(ifIdentity identity: Identity) {
        guard flight?.identity == identity else { return }
        invalidate()
    }

    public func invalidate() {
        flight?.task.cancel()
        flight = nil
    }
}

/// Both prerequisites start together. A failed fee lookup must not wait for a
/// separately owned wallet scan. Cancelling this join only cancels its waiters.
public enum SendPreparationJoin {
    private enum Part<Fee: Sendable>: Sendable { case ready, fee(Fee) }
    public static func run<Fee: Sendable>(prepare: @escaping @Sendable () async throws -> Void,
                                         fee: @escaping @Sendable () async throws -> Fee) async throws -> Fee {
        let preparation = Task { try await prepare() }
        let lookup = Task { try await SendPerformance.measure(.fee, body: fee) }
        defer { preparation.cancel(); lookup.cancel() }
        return try await withThrowingTaskGroup(of: Part<Fee>.self) { group in
            group.addTask { try await SendTaskValue.value(of: preparation); return .ready }
            group.addTask { .fee(try await SendTaskValue.value(of: lookup)) }
            var value: Fee?
            while let result = try await group.next() { if case .fee(let fee) = result { value = fee } }
            try Task.checkCancellation()
            guard let value else { throw CancellationError() }
            return value
        }
    }
}
