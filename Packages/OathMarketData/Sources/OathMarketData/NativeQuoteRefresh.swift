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
        let networks = Set(networkIDs).intersection(MarketIdentity.native.keys)
        guard !networks.isEmpty, !Task.isCancelled else { return }
        let assets: [MarketAsset]
        do {
            assets = try await database.nativeAssets(networkIDs: networks).map {
                MarketAsset(id: $0.id, networkID: $0.networkID, reference: $0.reference, decimals: $0.decimals)
            }
        } catch {
            if !Task.isCancelled { OathDiagnostics.record(error, component: "market_price", operation: "native_quote_assets") }
            return
        }
        guard !assets.isEmpty else { return }
        // The existing HTTP scheduler coalesces this identical URL across
        // consumers and caches successful replies for the next refresh workers.
        let projects = Set(assets.compactMap { MarketIdentity.native[$0.networkID]?.gecko }).sorted()
        let batchURL = ContractPriceRequest.nativeGeckoURL(coinIDs: projects)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < assets.count, !Task.isCancelled else { return }
                let asset = assets[next]; next += 1
                group.addTask { await self.refreshNativeQuote(asset, batchURL: batchURL) }
            }
            // Each quote already races a bounded set of providers. Avoid
            // flooding their shared quotas when a wallet has many networks.
            for _ in 0..<min(2, assets.count) { enqueue() }
            for await _ in group { enqueue() }
        }
    }

    private func refreshNativeQuote(_ asset: MarketAsset, batchURL: URL) async {
        await OathDiagnostics.$chain.withValue(asset.networkID) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try Task.checkCancellation()
                    _ = try await quoteValue(for: asset, force: false, nativeBatchURL: batchURL, propagatingReportedFailures: true)
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
