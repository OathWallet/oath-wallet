import Foundation

/// Public DEX fallback for exact token contracts. The provider belongs to
/// CoinGecko, but this public endpoint has a separate host quota. It is not an
/// independent provider against a CoinGecko-wide outage.
/// https://api.geckoterminal.com/docs/index.html
enum TokenPoolChart {
    struct Selection: Sendable {
        let network: String
        let pool: String
        let base: String
        let quote: String
    }

    static func network(for asset: MarketAsset) -> String? {
        guard !asset.isNative, asset.evm, address(asset.reference),
              (0...255).contains(asset.decimals) else { return nil }
        return ContractPriceRequest.terminalNetworks[asset.networkID]
    }
    private static func poolAsset(_ asset: MarketAsset) throws -> ExploreAsset {
        guard network(for: asset) != nil else { throw MarketDataError.notListed }
        return try ExploreAsset(network: asset.networkID, reference: asset.reference, decimals: asset.decimals)
    }
    static func network(for asset: ExploreAsset) -> String? {
        guard asset.reference != "native", address(asset.reference, network: asset.network) else { return nil }
        return ContractPriceRequest.terminalNetworks[asset.network]
    }
    private static func address(_ text: String, network: String = "") -> Bool {
        let pattern = network == "solana" ? "^[1-9A-HJ-NP-Za-km-z]{32,44}$" : "^0x[0-9a-fA-F]{40}$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    private static func poolReference(_ text: String, network: String) -> Bool {
        if network == "solana" { return address(text, network: network) }
        return text.range(of: "^0x(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$", options: .regularExpression) != nil
    }
    private static func normalized(_ address: String, network: String) -> String {
        network == "solana" ? address : address.lowercased()
    }
    private static func matchesID(_ id: String, network: String, address: String) -> Bool {
        guard id.hasPrefix(network + "_") else { return false }
        return normalized(String(id.dropFirst(network.count + 1)), network: network) == normalized(address, network: network)
    }
    static func poolsURL(for asset: MarketAsset) throws -> URL { try poolsURL(for: poolAsset(asset)) }
    static func poolsURL(for asset: ExploreAsset) throws -> URL {
        guard let network = network(for: asset) else { throw MarketDataError.notListed }
        return URL(string: "https://api.geckoterminal.com/api/v2/networks/\(network)/tokens/\(asset.reference)/pools?include=base_token,quote_token&page=1")!
    }
    static func candlesURL(for asset: MarketAsset, selection: Selection, at date: Date) throws -> URL {
        try candlesURL(for: poolAsset(asset), selection: selection, at: date, range: .day)
    }
    static func candlesURL(for asset: ExploreAsset, selection: Selection, at date: Date, range: MarketHistoryRange) throws -> URL {
        guard network(for: asset) == selection.network, poolReference(selection.pool, network: selection.network),
              asset.matches(selection.base) || asset.matches(selection.quote),
              date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0,
              date.timeIntervalSince1970 < Double(Int64.max) else { throw MarketDataError.invalidResponse }
        let bucket = range.poolInterval
        var url = URLComponents(string: "https://api.geckoterminal.com/api/v2/networks/\(selection.network)/pools/\(selection.pool)/ohlcv/\(bucket.unit)")!
        let end = floor(date.timeIntervalSince1970 / bucket.seconds) * bucket.seconds
        url.queryItems = [.init(name: "aggregate", value: String(bucket.aggregate)), .init(name: "limit", value: String(bucket.count + 1)),
            .init(name: "before_timestamp", value: String(Int64(end))),
            .init(name: "currency", value: "usd"), .init(name: "token", value: asset.reference)]
        return url.url!
    }

    private struct Pools: Decodable {
        let data: [Pool]
        let included: [Token]?
    }
    private struct Pool: Decodable {
        let id: String
        let type: String
        let attributes: Attributes
        let relationships: Relationships
        struct Attributes: Decodable { let address: String; let reserve_in_usd: String? }
        struct Relationships: Decodable {
            let base_token: Relationship
            let quote_token: Relationship
            struct Relationship: Decodable {
                let data: Identity
                struct Identity: Decodable { let id: String; let type: String }
            }
        }
    }
    private struct Token: Decodable {
        let id: String
        let type: String
        let attributes: Attributes
        struct Attributes: Decodable { let address: String; let decimals: Int? }
    }
    static func rankedPools(_ data: Data, for asset: MarketAsset) throws -> [Selection] {
        try rankedPools(data, for: poolAsset(asset))
    }
    static func rankedPools(_ data: Data, for asset: ExploreAsset) throws -> [Selection] {
        guard data.count <= 2_000_000, let network = network(for: asset) else { throw MarketDataError.invalidResponse }
        let response = try JSONDecoder().decode(Pools.self, from: data)
        guard response.data.count <= 100, (response.included?.count ?? 0) <= 200 else { throw MarketDataError.invalidResponse }
        guard !response.data.isEmpty else { throw MarketDataError.notListed }
        let tokens = (response.included ?? []).filter { asset.matches($0.attributes.address) }
        guard tokens.count == 1, let token = tokens.first, token.type == "token",
              matchesID(token.id, network: network, address: token.attributes.address),
              asset.decimals == nil || token.attributes.decimals == asset.decimals else { throw MarketDataError.invalidResponse }
        var candidates: [(depth: Decimal, selection: Selection)] = []
        var seen = Set<String>()
        for pool in response.data {
            guard pool.type == "pool", poolReference(pool.attributes.address, network: network),
                  matchesID(pool.id, network: network, address: pool.attributes.address),
                  seen.insert(normalized(pool.attributes.address, network: network)).inserted else { throw MarketDataError.invalidResponse }
            let base = pool.relationships.base_token.data, quote = pool.relationships.quote_token.data
            guard base.type == "token", quote.type == "token", base.id.hasPrefix(network + "_"), quote.id.hasPrefix(network + "_") else {
                throw MarketDataError.invalidResponse
            }
            let baseAddress = String(base.id.dropFirst(network.count + 1)), quoteAddress = String(quote.id.dropFirst(network.count + 1))
            guard address(baseAddress, network: network), address(quoteAddress, network: network),
                  normalized(baseAddress, network: network) != normalized(quoteAddress, network: network),
                  asset.matches(baseAddress) || asset.matches(quoteAddress) else { throw MarketDataError.invalidResponse }
            // Exclude dust pools before ranking eligible markets.
            guard let depth = ContractPriceDecoding.positive(pool.attributes.reserve_in_usd), depth >= 10_000 else { continue }
            let selection = Selection(network: network, pool: pool.attributes.address, base: baseAddress, quote: quoteAddress)
            candidates.append((depth, selection))
        }
        guard !candidates.isEmpty else { throw MarketDataError.notListed }
        return candidates.sorted { $0.depth > $1.depth }.prefix(2).map(\.selection)
    }

    private struct Candles: Decodable {
        let data: Body
        let meta: Metadata
        struct Body: Decodable {
            let type: String
            let attributes: Attributes
            struct Attributes: Decodable { let ohlcv_list: [[Double]] }
        }
        struct Metadata: Decodable {
            let base: TokenAddress
            let quote: TokenAddress
            struct TokenAddress: Decodable { let address: String }
        }
    }
    static func decode(_ data: Data, for asset: MarketAsset, selection: Selection, at now: Date) throws -> MarketChart {
        try decode(data, for: poolAsset(asset), selection: selection, at: now, range: .day)
    }
    static func decode(_ data: Data, for asset: ExploreAsset, selection: Selection, at now: Date, range: MarketHistoryRange) throws -> MarketChart {
        guard data.count <= 200_000, network(for: asset) == selection.network,
              asset.matches(selection.base) || asset.matches(selection.quote) else { throw MarketDataError.invalidResponse }
        let response = try JSONDecoder().decode(Candles.self, from: data)
        // With token=<address>, OHLCV metadata orients `base` to the requested
        // token even when it was the pool's quote side. Verify the actual chart
        // identity and its counter-asset rather than reusing pool orientation.
        let counterAsset = asset.matches(selection.base) ? selection.quote : selection.base
        guard response.data.type == "ohlcv_request_response",
              asset.matches(response.meta.base.address),
              normalized(response.meta.quote.address, network: selection.network) == normalized(counterAsset, network: selection.network) else { throw MarketDataError.invalidResponse }
        let rows = response.data.attributes.ohlcv_list
        let bucket = range.poolInterval
        guard rows.count <= bucket.count + 1 else { throw MarketDataError.invalidResponse }
        let end = floor(now.timeIntervalSince1970 / bucket.seconds) * bucket.seconds
        guard end.isFinite, end > 0 else { throw MarketDataError.invalidResponse }
        var previous = Double.infinity
        for row in rows {
            guard row.count == 6, row.allSatisfy(\.isFinite), row[0] > 0,
                  row[0].truncatingRemainder(dividingBy: bucket.seconds) == 0, row[0] <= end, row[0] < previous,
                  row[1...4].allSatisfy({ $0 > 0 }), row[5] >= 0,
                  row[2] >= max(row[1], row[4]), row[3] <= min(row[1], row[4]), row[2] >= row[3] else {
                throw MarketDataError.invalidResponse
            }
            previous = row[0]
        }
        // An in-progress candle is not a completed observation. Do not fill
        // missing trading intervals, or present stale prices as a fresh chart.
        let closed = rows.reversed().filter { $0[0] >= end - range.duration && $0[0] < end }
        guard closed.count >= 2, let first = closed.first, let last = closed.last, last[0] + bucket.seconds == end else {
            throw MarketDataError.notListed
        }
        let change = (last[4] / first[1] - 1) * 100
        guard change.isFinite else { throw MarketDataError.invalidResponse }
        return .init(points: closed.map { .init(time: $0[0] + bucket.seconds, close: $0[4]) },
                     changePercent: closed.count == bucket.count ? change : nil)
    }
}

private extension ExploreAsset {
    func matches(_ address: String) -> Bool {
        network == "solana" ? reference == address : reference.caseInsensitiveCompare(address) == .orderedSame
    }
}
