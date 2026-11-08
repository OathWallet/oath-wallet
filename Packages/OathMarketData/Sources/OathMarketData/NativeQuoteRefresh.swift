import Foundation
import OathDatabase
import OathDiagnostics

extension MarketDataService {
    /// Native quotes must not depend on owning a positive balance or on an
    /// account inventory including a price. Use the same validated providers,
    /// coalescing and persistent price table as asset details. Only public
    /// network/asset identities leave the device, never an account address.
    public func refreshNativeQuotes(networkIDs: [String]) async {
        // Intersect with the supported catalogue before scheduling work. This
        // also bounds the queue and deduplicates networks across accounts.
        let requested = Set(networkIDs)
        let networks = MarketIdentity.native.keys.filter { requested.contains($0) }.sorted()
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < networks.count, !Task.isCancelled else { return }
                let network = networks[next]; next += 1
                group.addTask { await self.refreshNativeQuote(networkID: network) }
            }
            // Each quote already races a bounded set of providers. Avoid
            // flooding their shared quotas when a wallet has many networks.
            for _ in 0..<min(2, networks.count) { enqueue() }
            for await _ in group { enqueue() }
        }
    }

    private func refreshNativeQuote(networkID: String) async {
        await OathDiagnostics.$chain.withValue(networkID) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try Task.checkCancellation()
                    // Read the canonical native asset, not a token with the
                    // same symbol or a guessed asset identifier/decimal scale.
                    guard let asset = try await nativeMarketAsset(networkID: networkID) else { return }
                    try Task.checkCancellation()
                    _ = try await quote(for: asset)
                } catch is CancellationError {
                    // Expected wallet switch/lock or refresh cancellation.
                } catch {
                    // No trading coverage is expected for some assets. Real
                    // storage/provider failures retain their shared diagnostics;
                    // one unavailable coin must not cancel the other quotes.
                    if error as? MarketDataError != .notListed, !Task.isCancelled {
                        OathDiagnostics.record(error, component: "market_price", operation: "native_quote_refresh")
                    }
                }
            }
        }
    }
}
