import Foundation
import OathDiagnostics

public enum MarketHistoryRange: Int, CaseIterable, Sendable {
    case day = 1, week = 7, month = 30, quarter = 90, halfYear = 180, year = 365

    public var label: String {
        switch self {
        case .day: "1D"
        case .week: "1W"
        case .month: "1M"
        case .quarter: "3M"
        case .halfYear: "6M"
        case .year: "1Y"
        }
    }
    var duration: TimeInterval { Double(rawValue) * 86_400 }
    public var cacheLifetime: TimeInterval { self == .day ? 300 : 3_600 }
    var poolInterval: (unit: String, aggregate: Int, seconds: Double, count: Int) {
        switch self {
        case .day, .week: ("hour", 1, 3600, rawValue * 24)
        case .month: ("hour", 4, 14_400, rawValue * 6)
        default: ("day", 1, 86_400, rawValue)
        }
    }
}

/// Rankings use verified CoinPaprika project IDs (including CoinLore mappings).
/// Catalogue/DEX results use a chain and contract, never a displayed ticker.
public struct ExploreHistoryRequest: Hashable, Sendable {
    let asset: ExploreAsset
    let paprikaID: String?
    let geckoID: String?

    public init?(token: ExploreToken, source: ExploreSource?, catalogueCoinID: String? = nil) {
        guard let asset = token.detailAsset else { return nil }
        self.asset = asset
        let ranked = source == .coinPaprika || source == .coinLore
        paprikaID = ranked && Self.validProjectID(token.id) ? token.id : nil
        if let catalogueCoinID, Self.validProjectID(catalogueCoinID) {
            geckoID = catalogueCoinID
        } else {
            geckoID = paprikaID.flatMap { id in ExploreDecoding.paprikaIDs.first { $0.value == id }?.key }
        }
    }

    private static func validProjectID(_ id: String) -> Bool {
        id.utf8.count <= 128 && id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
    }

    var geckoPath: String {
        get throws { try geckoID ?? MarketIdentity.geckoPath(network: asset.network, reference: asset.reference) }
    }

    func cacheKey(_ range: MarketHistoryRange) -> String {
        let identity = paprikaID.map { "paprika." + $0 } ?? ("contract." + asset.id)
        return "v1.explore.history.USD." + String(range.rawValue) + "." + identity
    }
}

public struct ExplorePriceHistory: Codable, Sendable {
    public let chart: MarketChart
    public let source: String
}

extension MarketDataService {
    public func cachedExploreQuote(for asset: MarketAsset) async throws -> CachedMarketValue<MarketQuote>? {
        let discovery: CachedMarketValue<MarketQuote>? = try await cached("v1.explore.spot." + asset.cacheIdentity)
        let portfolio = try await cachedQuote(for: asset)
        return [discovery, portfolio].compactMap { $0 }.max { $0.fetchedAt < $1.fetchedAt }
    }

    /// Inspecting a catalogue entry must work before it is added to the wallet.
    /// A discovery-only quote never inserts an asset or a portfolio price record.
    public func exploreQuote(for asset: MarketAsset) async throws -> CachedMarketValue<MarketQuote> {
        if let saved = try await cachedExploreQuote(for: asset), saved.isFresh(at: now(), lifetime: 60) { return saved }
        let entry = try await load(key: "v1.explore.spot." + asset.cacheIdentity, source: "Explore",
                                   lifetime: 60, force: false, propagatingReportedFailures: true) {
            let result = try await self.fetchQuote(for: asset)
            return (try JSONEncoder().encode(result.quote), result.date.timeIntervalSince1970, nil)
        }
        return try decoded(entry)
    }

    /// Some catalogue entries omit decimals. Project metadata and price history
    /// can still be resolved without inventing wallet precision for that asset.
    public func cachedDiscoveryInformation(_ request: ExploreHistoryRequest) async throws -> CachedMarketValue<AssetInformation>? {
        try await cached("v1.explore.info." + request.asset.id)
    }

    public func discoveryInformation(_ request: ExploreHistoryRequest) async throws -> CachedMarketValue<AssetInformation> {
        let transport = transport, now = now
        let entry = try await load(key: "v1.explore.info." + request.asset.id, source: "CoinGecko",
                                   lifetime: 3_600, force: false, propagatingReportedFailures: true) {
            let data = try await transport.data(from: MarketIdentity.informationURL(path: request.geckoPath))
            let info = try MarketDecoding.discoveryInformation(data, request: request)
            return (try JSONEncoder().encode(info), now().timeIntervalSince1970, nil)
        }
        return try decoded(entry)
    }

    public func cachedHistory(_ request: ExploreHistoryRequest, range: MarketHistoryRange) async throws -> CachedMarketValue<ExplorePriceHistory>? {
        try await cached(request.cacheKey(range))
    }

    public func history(_ request: ExploreHistoryRequest, range: MarketHistoryRange) async throws -> CachedMarketValue<ExplorePriceHistory> {
        let transport = transport, now = now
        return try await OathDiagnostics.withChain(request.asset.network) {
            let entry = try await load(key: request.cacheKey(range), source: "Explore", lifetime: range.cacheLifetime,
                                       force: false, propagatingReportedFailures: true) {
                let date = now()
                let result = try await Self.fetchHistory(request, range: range, date: date, transport: transport)
                return (try JSONEncoder().encode(result), date.timeIntervalSince1970, nil)
            }
            return try decoded(entry)
        }
    }

    private static func fetchHistory(_ request: ExploreHistoryRequest, range: MarketHistoryRange, date: Date,
                                     transport: any MarketTransport) async throws -> ExplorePriceHistory {
        if let project = request.paprikaID {
            var url = URLComponents(string: "https://api.coinpaprika.com/v1/tickers/" + project + "/historical")!
            // The free API serves hourly data for the past day and daily data
            // for the past year. Allow for travel time at those rolling limits.
            let start = Int(date.timeIntervalSince1970 - range.duration) + 60
            url.queryItems = [.init(name: "start", value: String(start)), .init(name: "interval", value: range == .day ? "1h" : "1d")]
            do {
                let data = try await transport.data(from: url.url!)
                let chart = try paprikaHistory(data, range: range, date: date)
                return .init(chart: chart, source: "CoinPaprika")
            } catch where canTryAnotherProvider(after: error) {
                if error as? MarketDataError != .notListed {
                    OathDiagnostics.record(error, component: "explore", operation: "history_fallback", context: ["source": "CoinPaprika"])
                }
            }
        }
        do {
            let path = try request.geckoPath
            let data = try await transport.data(from: MarketIdentity.chartURL(path: path, range: range))
            let chart = try MarketDecoding.geckoChart(data, now: date, range: range)
            let interval: TimeInterval = range.rawValue > 90 ? 86_400 : range == .day ? 300 : 3600
            return .init(chart: try checkedHistory(chart, range: range, date: date, interval: interval), source: "CoinGecko")
        } catch where TokenPoolChart.network(for: request.asset) != nil && canTryAnotherProvider(after: error) {
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "explore", operation: "history_fallback", context: ["source": "CoinGecko"])
            }
        }

        let asset = request.asset
        let pools = try await transport.data(from: TokenPoolChart.poolsURL(for: asset))
        var longest: MarketChart?
        for selection in try TokenPoolChart.rankedPools(pools, for: asset) {
            try Task.checkCancellation()
            do {
                let url = try TokenPoolChart.candlesURL(for: asset, selection: selection, at: date, range: range)
                let data = try await transport.data(from: url)
                let chart = try TokenPoolChart.decode(data, for: asset, selection: selection, at: date, range: range)
                if chart.changePercent != nil { return .init(chart: chart, source: "GeckoTerminal") }
                // The deepest pool may be newly opened. Prefer the verified pool
                // covering more of the selected period, without mixing their prices.
                if let first = chart.points.first, first.time < (longest?.points.first?.time ?? .infinity) {
                    longest = chart
                }
            } catch MarketDataError.notListed {
                // diagnostics: optional-market-absence
                // A verified pool can have no trades in the selected window.
                continue
            } catch where longest != nil && canTryAnotherProvider(after: error) {
                OathDiagnostics.record(error, component: "explore", operation: "history_fallback", context: ["source": "GeckoTerminal"])
                break
            }
        }
        if let longest { return .init(chart: longest, source: "GeckoTerminal") }
        throw MarketDataError.notListed
    }

    private static func canTryAnotherProvider(after error: any Error) -> Bool {
        guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return false }
        return error is URLError || error is DiagnosticDeferral ||
            [.notListed, .rateLimited, .unavailable].contains(error as? MarketDataError)
    }

    static func paprikaHistory(_ data: Data, range: MarketHistoryRange, date: Date) throws -> MarketChart {
        struct Tick: Decodable { let timestamp: Date; let price: Double }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticks = try decoder.decode([Tick].self, from: data)
        guard ticks.count <= 400 else { throw MarketDataError.invalidResponse }
        let end = date.timeIntervalSince1970
        var prices: [Double: MarketCandle] = [:]
        for tick in ticks {
            let time = tick.timestamp.timeIntervalSince1970
            guard tick.price.isFinite, tick.price > 0, time > 0 else { throw MarketDataError.invalidResponse }
            if (end - range.duration...end + 60).contains(time) {
                prices[time] = .init(time: time, close: tick.price)
            }
        }
        let points = prices.values.sorted { $0.time < $1.time }
        guard points.count >= 2, let first = points.first, let last = points.last else { throw MarketDataError.notListed }
        let change = (last.close / first.close - 1) * 100
        return try checkedHistory(.init(points: points, changePercent: change.isFinite ? change : nil),
                                  range: range, date: date, interval: range == .day ? 3600 : 86_400)
    }

    private static func checkedHistory(_ chart: MarketChart, range: MarketHistoryRange, date: Date,
                                       interval: TimeInterval) throws -> MarketChart {
        let end = date.timeIntervalSince1970
        guard let first = chart.points.first, let last = chart.points.last,
              end - last.time <= 2 * interval + 300 else { throw MarketDataError.notListed }
        // Newly listed assets can have less history than the selected window.
        // Show those real points with their dates, without calling it a full-period return.
        let covered = first.time <= end - range.duration + interval + 300
        return .init(points: chart.points, changePercent: covered ? chart.changePercent : nil)
    }
}
