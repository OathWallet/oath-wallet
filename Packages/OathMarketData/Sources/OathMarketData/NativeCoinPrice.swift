import Foundation

/// Exact native identities for independent, timestamped USD coverage.
/// CoinGecko can be throttled and DefiLlama observations can become stale;
/// this independent ticker uses the same freshness limit, never a USDT peg.
/// https://docs.coinpaprika.com/api-reference/tickers/get-ticker-for-a-specific-coin
enum NativeCoinPrice {
    static let telos = NativeInformation.Identity(id: "tlos-telos", name: "Telos", symbol: "TLOS")
    static let supported: [String: (decimals: Int, identity: NativeInformation.Identity)] = [
        "telos": (18, telos), "xlayer": (18, NativeInformation.okb),
        "fantom": (18, .init(id: "ftm-fantom", name: "Fantom", symbol: "FTM")),
        "bitcoin": (8, NativeInformation.bitcoin), "bitcoincash": (8, NativeInformation.bitcoinCash),
        "dogecoin": (8, NativeInformation.doge),
        "litecoin": (8, .init(id: "ltc-litecoin", name: "Litecoin", symbol: "LTC"))
    ]

    static func identity(for asset: MarketAsset) -> NativeInformation.Identity? {
        guard asset.isNative, let entry = supported[asset.networkID], asset.decimals == entry.decimals else { return nil }
        return entry.identity
    }

    static func accepts(_ url: URL) -> Bool {
        supported.values.contains { url == $0.identity.tickerURL }
    }

    static func decode(_ data: Data, for asset: MarketAsset, now: Date) throws -> ResolvedMarketPrice {
        guard let identity = identity(for: asset), data.count <= 100_000,
              let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["id"] as? String == identity.id, row["name"] as? String == identity.name,
              row["symbol"] as? String == identity.symbol,
              let timestamp = row["last_updated"] as? String, timestamp.count <= 40,
              let observed = ISO8601DateFormatter().date(from: timestamp) else { throw MarketDataError.invalidResponse }
        let age = now.timeIntervalSince(observed)
        guard age.isFinite, age >= -60, age <= 900 else { throw MarketDataError.notListed }
        let quotes = row["quotes"] as? [String: Any]
        let usd = quotes?["USD"] as? [String: Any]
        guard let price = ContractPriceDecoding.positive(usd?["price"]) else { throw MarketDataError.notListed }
        return .init(quote: .init(code: identity.symbol, usd: NSDecimalNumber(decimal: price).stringValue),
            date: observed, source: "CoinPaprika")
    }
}
