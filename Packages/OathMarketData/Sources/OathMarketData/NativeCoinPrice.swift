import Foundation
import OathAnkr

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

/// Gnosis documents this contract as the ERC-20 representation of native xDAI.
/// Use its actual market price, never a fixed USD peg or another chain's DAI.
/// https://docs.gnosischain.com/about/tokens/xdai#wrapped-xdai-wxdai
enum GnosisNativePrice {
    static let wrapped = MarketAsset(id: "gnosis:wxdai", networkID: "gnosis",
        reference: "0xe91d153e0b41518a2ce8dd3d7944fa863463a97d", decimals: 18)

    static func request(for asset: MarketAsset) -> ContractPriceRequest? {
        guard asset.isNative, asset.networkID == "gnosis", asset.decimals == 18 else { return nil }
        return ContractPriceRequest.requests(for: wrapped).first { $0.provider == .terminal }
    }

    static func lifiURL(for asset: MarketAsset) -> URL? {
        guard asset.isNative, asset.networkID == "gnosis", asset.decimals == 18 else { return nil }
        return LifiTokenMetadata.url(network: wrapped.networkID, reference: wrapped.reference)
    }

    static func decodeLifi(_ data: Data, for asset: MarketAsset, fetchedAt: Date) throws -> ResolvedMarketPrice {
        guard lifiURL(for: asset) != nil else { throw MarketDataError.invalidResponse }
        // Bind the response to the canonical wrapped contract, chain and scale.
        // LI.FI supplies a retrieval-time quote; never substitute a fixed peg.
        let value = try LifiTokenMetadata.decode(data, network: wrapped.networkID,
            reference: wrapped.reference, decimals: wrapped.decimals)
        guard let price = value.priceUSD else { throw MarketDataError.notListed }
        return .init(quote: .init(code: "XDAI", usd: price), date: fetchedAt, source: "LI.FI (WXDAI)")
    }

    static func decode(_ data: Data, for asset: MarketAsset, fetchedAt: Date) throws -> ResolvedMarketPrice {
        guard let request = request(for: asset), data.count <= 2_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["data"] as? [String: Any],
              let attributes = token["attributes"] as? [String: Any],
              attributes["decimals"] as? Int == 18 else { throw MarketDataError.invalidResponse }
        // A valid but inactive market is missing usable coverage, not a failure.
        guard let reserve = ContractPriceDecoding.positive(attributes["total_reserve_in_usd"]), reserve >= 10_000,
              let volume = attributes["volume_usd"] as? [String: Any],
              let traded = ContractPriceDecoding.positive(volume["h24"]), traded >= 1_000 else {
            throw MarketDataError.notListed
        }
        // Shared decoding checks exact contract + chain identity and positive price.
        // This endpoint has no observation timestamp: retain the retrieval time,
        // including after persistence/reopen, rather than inventing a market time.
        let resolved = try ContractPriceDecoding.decode(data, request: request, asset: wrapped, now: fetchedAt)
        return .init(quote: .init(code: "XDAI", usd: resolved.quote.usd), date: fetchedAt,
                     source: "GeckoTerminal (WXDAI)")
    }
}
