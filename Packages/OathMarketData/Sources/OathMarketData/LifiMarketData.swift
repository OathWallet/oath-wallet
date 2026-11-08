import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

extension MarketDataService {
    private func lifiKey(_ asset: MarketAsset) -> String { "v1.lifi." + asset.cacheIdentity }

    public func cachedLifiToken(for asset: MarketAsset) async throws -> CachedMarketValue<LifiTokenMetadata>? {
        if let saved: CachedMarketValue<LifiTokenMetadata> = try await cached(lifiKey(asset)),
           saved.value.network == asset.networkID, saved.value.reference == asset.reference,
           saved.value.decimals == asset.decimals { return saved }
        if let (metadata, date) = await tokenCatalog?.cachedLifiMetadata(network: asset.networkID,
            reference: asset.reference, decimals: asset.decimals) {
            return .init(value: metadata, fetchedAt: date)
        }
        return nil
    }

    /// One response supplies the quote, logo, name and verification. Coalesced
    /// across detail/refresh callers and cached on disk. LI.FI supplies no price
    /// observation timestamp, so fetchedAt is explicitly the local retrieval time.
    /// Never renew a catalog quote's age when reading it from disk.
    public func lifiToken(for asset: MarketAsset, force: Bool = false) async throws -> CachedMarketValue<LifiTokenMetadata> {
        try await OathDiagnostics.withChain(asset.networkID) {
            try await lifiTokenValue(for: asset, force: force)
        }
    }

    private func lifiTokenValue(for asset: MarketAsset, force: Bool) async throws -> CachedMarketValue<LifiTokenMetadata> {
        guard let url = LifiTokenMetadata.url(network: asset.networkID, reference: asset.reference) else { throw MarketDataError.notListed }
        let catalog = try await cachedLifiToken(for: asset)
        let transport = transport, now = now
        let entry = try await load(key: lifiKey(asset), source: "LI.FI", lifetime: 60, force: force) {
            let metadata: LifiTokenMetadata
            let date: Date
            if !force, let catalog, catalog.isFresh(at: now(), lifetime: 60) {
                metadata = catalog.value; date = catalog.fetchedAt
            } else {
                // Stamp the start, so a late response never displaces a newer read.
                date = now()
                let data = try await transport.data(from: url)
                metadata = try LifiTokenMetadata.decode(data, network: asset.networkID,
                    reference: asset.reference, decimals: asset.decimals)
            }
            try Task.checkCancellation()
            return (try JSONEncoder().encode(metadata), date.timeIntervalSince1970, nil)
        }
        let metadata: CachedMarketValue<LifiTokenMetadata> = try decoded(entry)
        try Task.checkCancellation()
        // A preview can cache metadata before the asset is tracked. Publish its
        // still-fresh price on the next read after tracking, without another HTTP
        // request or a fabricated new observation timestamp.
        if let value = metadata.value.priceUSD,
           let saved = try await database.asset(networkID: asset.networkID, reference: asset.reference),
           saved.id == asset.id, saved.decimals == asset.decimals {
            let price = PriceRecord(assetID: asset.id, currency: "USD", value: value, observedAt: entry.fetchedAt, source: "LI.FI")
            let committed = try await database.saveMarketCache(entry, price: price)
            return try decoded(committed)
        }
        return metadata
    }

    public func cachedInformation(for asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        let secondary = try await cachedSecondaryInformation(for: asset)
        if let primary = try await cachedLifiToken(for: asset) { return Self.information(primary, enriching: secondary?.value) }
        return secondary
    }

    /// LI.FI has no descriptions/supply/charts. Preserve the existing sources
    /// for those fields, after primary metadata has already been published.
    public func enrichTokenInformation(for asset: MarketAsset, force: Bool = false) async throws -> CachedMarketValue<AssetInformation>? {
        guard !asset.isNative, let primary = try await cachedLifiToken(for: asset) else { return nil }
        let secondary = try await enrichedInformation(for: asset, force: force)
        return Self.information(primary, enriching: secondary.value)
    }

    static func information(_ primary: CachedMarketValue<LifiTokenMetadata>, enriching secondary: AssetInformation?) -> CachedMarketValue<AssetInformation> {
        let token = primary.value
        return .init(value: .init(providerID: "lifi:" + token.network + ":" + token.reference,
            name: token.name, symbol: token.symbol, description: secondary?.description ?? "",
            imageURL: token.logo ?? secondary?.imageURL, website: secondary?.website, providerURL: "https://li.fi",
            marketCaps: secondary?.marketCaps, totalSupply: secondary?.totalSupply,
            circulatingSupply: secondary?.circulatingSupply), fetchedAt: primary.fetchedAt)
    }

    /// Refresh only actual holdings/tracked tokens; never download a quote per
    /// catalog listing. Balances publish independently while this bounded work runs.
    public func refreshTokenQuotes(walletID: String) async {
        await OathDiagnostics.attempt("refresh_token_quotes") {
            let snapshot = try await self.database.snapshot(walletID: walletID, currency: "USD")
            let assets = Array(Set(snapshot.holdings.filter { $0.reference != "native" }.map {
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
                                // diagnostics: lifi-provider-recovery
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
