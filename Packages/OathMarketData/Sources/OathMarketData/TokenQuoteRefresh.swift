import Foundation
import OathDatabase
import OathDiagnostics

extension MarketDataService {
    /// Refresh only actual holdings/tracked tokens; never download a quote per
    /// catalog listing. Balances publish independently while this bounded work runs.
    public func refreshTokenQuotes(walletID: String, accountIDs: Set<String>? = nil) async {
        guard accountIDs?.isEmpty != true, !Task.isCancelled else { return }
        await OathDiagnostics.attempt("refresh_token_quotes") {
            let snapshot = try await self.database.snapshot(walletID: walletID, currency: "USD")
            let assets = Array(Set(snapshot.holdings.filter { $0.reference != "native" && (accountIDs?.contains($0.accountID) ?? true) }.map {
                MarketAsset(id: $0.assetID, networkID: $0.networkID, reference: $0.reference, decimals: $0.decimals)
            }))
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func enqueue() {
                    guard next < assets.count, !Task.isCancelled else { return }
                    let asset = assets[next]; next += 1
                    group.addTask {
                        await OathDiagnostics.withChain(asset.networkID) {
                            do { _ = try await self.quote(for: asset) }
                            catch {
                                // diagnostics: token-quote-refresh-recovery
                                // Quote/load already records original provider errors.
                                // Optional coverage and lifecycle cancellation are expected.
                            }
                        }
                    }
                }
                for _ in 0..<min(3, assets.count) { enqueue() }
                for await _ in group { enqueue() }
            }
        }
    }
}
