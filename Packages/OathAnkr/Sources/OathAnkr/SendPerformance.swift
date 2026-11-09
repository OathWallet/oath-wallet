import Foundation

/// Bounded, process-local measurements. Never contains accounts, URLs, payloads,
/// credentials or signing material, and keeps measurements in memory.
public enum SendPerformance {
    public enum Stage: String, Sendable { case preparation, freshness, fee, simulation, publication }
    public struct Sample: Sendable {
        public let stage: Stage
        public let milliseconds: Double
        public let requests: Int
    }
    public final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var samples: [Sample] = []
        func append(_ sample: Sample) { lock.withLock { samples.append(sample); if samples.count > 128 { samples.removeFirst(samples.count - 128) } } }
        func read() -> [Sample] { lock.withLock { samples } }
    }
    private static let store = Store()
    @TaskLocal static var counter: Counter?
    public static func samples() -> [Sample] { store.read() }
    @MainActor public static func publish<T>(_ body: () throws -> T) rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        defer { record(.publication, elapsed: start.duration(to: clock.now), requests: 0) }
        return try body()
    }
    static func record(_ stage: Stage, elapsed: Duration, requests: Int) {
        let c = elapsed.components
        store.append(.init(stage: stage, milliseconds: Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15, requests: requests))
    }
    public static func measure<T: Sendable>(_ stage: Stage, body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock(), start = clock.now, counter = Counter()
        defer {
            let elapsed = start.duration(to: clock.now).components
            store.append(.init(stage: stage, milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, requests: counter.value))
        }
        // Select the four-argument API explicitly, excluding the deprecated
        // overload with a defaulted isolation parameter. Keep rethrows intact.
        return try await $counter.withValue(_:operation:file:line:)(counter, {
            try await body()
        }, #fileID, #line)
    }
}

struct SendMeasuredTransport: AnkrTransport {
    let base: any AnkrTransport
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        SendPerformance.counter?.increment()
        let clock = ContinuousClock(), start = clock.now
        let stage = Self.stage(request)
        defer { if let stage { SendPerformance.record(stage, elapsed: start.duration(to: clock.now), requests: 1) } }
        return try await base.send(request)
    }
    // Inspect operation names locally; never retain or report parameters/bodies.
    private static func stage(_ request: URLRequest) -> SendPerformance.Stage? {
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let calls = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
        let methods = calls.compactMap { $0["method"] as? String }
        let path = request.url?.lastPathComponent ?? ""
        if path == "simulate" || methods.contains(where: { ["simulateTransaction", "sui_dryRunTransactionBlock", "eth_estimateGas", "linea_estimateGas", "dryRunTransactionBlock"].contains($0) }) { return .simulation }
        if path == "estimate_gas_price" || methods.contains(where: { ["eth_gasPrice", "eth_feeHistory", "getFeeForMessage", "getRecentPrioritizationFees", "fee", "gas_price", "payment_queryInfo"].contains($0) }) { return .fee }
        if methods.contains(where: { ["eth_chainId", "eth_getBlockByNumber", "getLatestBlockhash", "getSlot", "chain_getFinalizedHead", "chain_getHeader", "state_getRuntimeVersion", "server_state", "server_info", "block"].contains($0) }) { return .freshness }
        return nil
    }
}
