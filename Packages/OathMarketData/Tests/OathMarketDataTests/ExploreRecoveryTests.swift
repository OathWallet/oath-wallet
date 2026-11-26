import Foundation
import Testing
@testable import OathDatabase
@testable import OathMarketData

private actor ExploreFeed: MarketTransport {
    var requests: [URL] = []
    let replies: [String: String]
    init(_ replies: [String: String] = [:]) { self.replies = replies }
    func data(from url: URL) throws -> Data {
        requests.append(url)
        guard let value = replies[url.host! + url.path] else { throw MarketDataError.unavailable }
        return Data(value.utf8)
    }
    func count() -> Int { requests.count }
}
private func exploreDatabase() async throws -> (OathDatabase, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite")), folder)
}

private func savedExploreSnapshot(_ db: OathDatabase, section: ExploreSection = .top,
                                  source: ExploreSource = .coinPaprika, date: Date,
                                  network: String = "ethereum", price: Double = 123) async throws -> ExploreSectionSnapshot {
    let asset = try ExploreAsset(network: network, reference: "native")
    let snapshot = ExploreSectionSnapshot(section: section, source: source,
        items: [.init(id: "eth-ethereum", name: "Ethereum", symbol: "ETH", assets: [asset], price: price,
                      change24h: section == .losers ? -5 : 5, marketCap: 2_000_000, volume24h: 200_000)],
        fetchedAt: date, coverage: 1)
    try await db.saveMarketCache(.init(key: "explore.v1." + section.rawValue + "." + network, source: source.rawValue,
                                      payload: JSONEncoder().encode(snapshot), fetchedAt: date.timeIntervalSince1970))
    return snapshot
}

private let validPaprikaFeed = #"[{"id":"eth-ethereum","name":"Ethereum","symbol":"ETH","quotes":{"USD":{"price":2500,"market_cap":900000000,"volume_24h":2000000,"percent_change_24h":5}}}]"#

@Test(arguments: ExploreSection.allCases)
func exploreEverySectionHydratesWithoutNetworkAndSurvivesOffline(_ section: ExploreSection) async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let time = Date()
    let saved = try await savedExploreSnapshot(db, section: section, source: section == .trending ? .geckoTerminal : .coinPaprika,
                                               date: time.addingTimeInterval(-7 * 86400))
    // A different pool and service model a cold launch, not an in-memory hit.
    let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
    let feed = ExploreFeed()
    let service = ExploreDataService(database: reopened, entries: [], personalDataAllowed: true, transport: feed)
    #expect(await service.cached(section, networks: ["ethereum"]) == saved)
    #expect(await feed.count() == 0)
    #expect(await service.load(section, networks: ["ethereum"]) == saved)
    #expect(await service.cached(section, networks: ["solana"]) == nil)
}

@Test(arguments: [ExploreSource.coinPaprika, .coinLore, .geckoTerminal, .dexPaprika])
func exploreEveryProviderRestoresItsOwnTimestamp(_ source: ExploreSource) async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let section: ExploreSection = [.geckoTerminal, .dexPaprika].contains(source) ? .trending : .top
    let snapshot = try await savedExploreSnapshot(db, section: section, source: source, date: Date().addingTimeInterval(-800))
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: ExploreFeed())
    #expect(await service.cached(section, networks: ["ethereum"]) == snapshot)
    let publicService = ExploreDataService(database: db, entries: [], personalDataAllowed: false, transport: ExploreFeed())
    let publicValue = await publicService.cached(section, networks: ["ethereum"])
    #expect(publicValue == (section == .trending ? snapshot : nil))
}

@Test func exploreSuccessfulRefreshReplacesTheDurableObservation() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let time = Date()
    let old = try await savedExploreSnapshot(db, date: time.addingTimeInterval(-800))
    let feed = ExploreFeed(["api.coinpaprika.com/v1/tickers": validPaprikaFeed])
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: feed, now: { time })
    #expect(await service.cached(.top, networks: ["ethereum"]) == old)
    let fresh = try #require(await service.load(.top, networks: ["ethereum"]))
    #expect(fresh.items.first?.price == 2500)
    #expect(fresh.fetchedAt == time)
    let offline = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: ExploreFeed())
    #expect(await offline.cached(.top, networks: ["ethereum"]) == fresh)
}

@Test func exploreConcurrentLoadsShareOneProviderRequest() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let feed = ExploreFeed(["api.coinpaprika.com/v1/tickers": validPaprikaFeed])
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: feed)
    await withTaskGroup(of: ExploreSectionSnapshot?.self) { group in
        for _ in 0..<12 { group.addTask { await service.load(.top, networks: ["ethereum"]) } }
        for await value in group { #expect(value?.items.first?.price == 2500) }
    }
    #expect(await feed.count() == 1)
}

@Test func exploreCorruptSnapshotDoesNotPreventFreshRecovery() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    try await db.saveMarketCache(.init(key: "explore.v1.top.ethereum", source: "coinPaprika", payload: Data("bad data".utf8), fetchedAt: Date().addingTimeInterval(3600).timeIntervalSince1970))
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true,
        transport: ExploreFeed(["api.coinpaprika.com/v1/tickers": validPaprikaFeed]))
    #expect(await service.cached(.top, networks: ["ethereum"]) == nil)
    #expect(await service.load(.top, networks: ["ethereum"])?.items.first?.price == 2500)
}

@Test func exploreCorruptCacheEvictionCannotDeleteAConcurrentRefresh() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let bad = MarketCacheEntry(key: "explore.v1.top.ethereum", source: "coinPaprika", payload: Data("bad data".utf8), fetchedAt: Date().addingTimeInterval(-800).timeIntervalSince1970)
    try await db.saveMarketCache(bad)
    let fresh = try await savedExploreSnapshot(db, date: Date())
    try await db.discardMarketCache(matching: bad)
    #expect(try await db.marketCache(key: bad.key)?.fetchedAt == fresh.fetchedAt.timeIntervalSince1970)
}

@Test func exploreMalformedRefreshKeepsLastGoodData() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let old = try await savedExploreSnapshot(db, date: Date().addingTimeInterval(-800))
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true,
        transport: ExploreFeed(["api.coinpaprika.com/v1/tickers": "{}", "api.coinlore.net/api/tickers": "{\"data\":[]}"]))
    #expect(await service.load(.top, networks: ["ethereum"]) == old)
    #expect(try await db.marketCache(key: "explore.v1.top.ethereum")?.fetchedAt == old.fetchedAt.timeIntervalSince1970)
}

private actor ExploreRacingFeed: MarketTransport {
    let database: OathDatabase, newerDate: Date
    init(_ database: OathDatabase, newerDate: Date) { self.database = database; self.newerDate = newerDate }
    func data(from url: URL) async throws -> Data {
        _ = try await savedExploreSnapshot(database, date: newerDate, price: 3000)
        return Data(validPaprikaFeed.utf8)
    }
}

private actor ExploreCancellationFeed: MarketTransport {
    private var requests = 0
    private var started: CheckedContinuation<Void, Never>?
    func data(from url: URL) async throws -> Data {
        requests += 1
        if requests == 1 {
            started?.resume(); started = nil
            try await Task.sleep(for: .seconds(60))
        }
        return Data(validPaprikaFeed.utf8)
    }
    func waitUntilStarted() async {
        if requests > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
}

@Test(.timeLimit(.minutes(1))) func exploreReturningScreenDoesNotJoinCancelledRefresh() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let feed = ExploreCancellationFeed()
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: feed)
    let leaving = Task { await service.load(.top, networks: ["ethereum"]) }
    await feed.waitUntilStarted()
    leaving.cancel()
    let returning = await service.load(.top, networks: ["ethereum"])
    #expect(returning?.items.first?.price == 2500)
    _ = await leaving.value
}

@Test(arguments: ["-1", "null", "not-json"])
func exploreInvalidTVLDoesNotReplaceSavedValue(_ response: String) async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let date = Date().addingTimeInterval(-86400)
    try await db.saveMarketCache(.init(key: "explore.v1.tvl.uniswap", source: "defillama", payload: Data("123456".utf8), fetchedAt: date.timeIntervalSince1970))
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true,
        transport: ExploreFeed(["api.llama.fi/tvl/uniswap": response]))
    #expect(await service.loadTVL(DAppDescriptor.catalogue[0])?.value == 123456)
    #expect(try await db.marketCache(key: "explore.v1.tvl.uniswap")?.fetchedAt == date.timeIntervalSince1970)
}

@Test func exploreSlowerResponseCannotReplaceNewerDatabaseResult() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let time = Date()
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true,
        transport: ExploreRacingFeed(db, newerDate: time.addingTimeInterval(1)), now: { time })
    let result = await service.load(.top, networks: ["ethereum"])
    #expect(result?.items.first?.price == 3000)
    #expect(result?.fetchedAt == time.addingTimeInterval(1))
}

@Test func exploreDatabaseFailureStillDisplaysFreshMarketAndMetricData() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    try await db.pool.write { try $0.execute(sql: "DROP TABLE publicMarketCache") }
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true,
        transport: ExploreFeed(["api.coinpaprika.com/v1/tickers": validPaprikaFeed, "api.llama.fi/tvl/uniswap": "123456"]))
    #expect(await service.load(.top, networks: ["ethereum"])?.items.first?.price == 2500)
    #expect(await service.loadTVL(DAppDescriptor.catalogue[0])?.value == 123456)
}

@Test func exploreTVLReadsDiskFirstThenRefreshesAndKeepsOfflineFallback() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let time = Date(), app = DAppDescriptor.catalogue[0], oldDate = time.addingTimeInterval(-30 * 86400)
    try await db.saveMarketCache(.init(key: "explore.v1.tvl.uniswap", source: "defillama", payload: Data("123456".utf8), fetchedAt: oldDate.timeIntervalSince1970))
    let offline = ExploreFeed()
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: offline)
    let cached = try #require(await service.cachedTVL(app))
    #expect(cached.value == 123456 && abs(cached.fetchedAt.timeIntervalSince(oldDate)) < 0.001 && !cached.isFresh(at: time))
    #expect(await offline.count() == 0)
    #expect(await service.loadTVL(app) == cached)
    let online = ExploreDataService(database: db, entries: [], personalDataAllowed: true,
        transport: ExploreFeed(["api.llama.fi/tvl/uniswap": "234567"]), now: { time })
    let fresh = try #require(await online.loadTVL(app))
    #expect(fresh.value == 234567 && abs(fresh.fetchedAt.timeIntervalSince(time)) < 0.001)
    let reopened = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: offline)
    #expect(await reopened.cachedTVL(app) == fresh)
}
@Test func exploreFallbackIsWholeSnapshotAndPersistsForOfflineDisplay() async throws {
    let (db, folder) = try await exploreDatabase()
    defer { try? FileManager.default.removeItem(at: folder) }
    let feed = ExploreFeed(["api.coinlore.net/api/tickers": #"{"data":[{"id":"80","name":"Ethereum","symbol":"ETH","price_usd":"1200","market_cap_usd":"900000000","volume24":2000000}]}"#])
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: feed)
    let value = await service.load(.top, networks: ["ethereum"])
    #expect(value?.source == .coinLore); #expect(value?.items.first?.price == 1200)
    #expect(try await db.marketCache(key: "explore.v1.top.ethereum")?.source == "coinLore")
    let count = await feed.count(); _ = await service.load(.top, networks: ["ethereum"])
    #expect(await feed.count() == count)
    let offline = ExploreFeed()
    let restored = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: offline)
    #expect(await restored.cached(.top, networks: ["ethereum"]) == value)
    #expect(await offline.count() == 0)
}
@Test func explorePublicBuildDoesNotFetchPersonalUseRankings() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let feed = ExploreFeed()
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: false, transport: feed)
    #expect(await service.load(.top, networks: ["ethereum"]) == nil)
    #expect(await service.load(.gainers, networks: ["ethereum"]) == nil)
    #expect(await feed.count() == 0)
}
@Test func exploreStaleSnapshotKeepsTimestampAcrossOfflineLaunches() async throws {
    let (db, folder) = try await exploreDatabase(); defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date(), asset = try ExploreAsset(network: "ethereum", reference: "native")
    let snapshot = ExploreSectionSnapshot(section: .top, source: .coinPaprika,
        items: [.init(id: "eth-ethereum", name: "Ethereum", symbol: "ETH", assets: [asset], price: 123, marketCap: 1000)], fetchedAt: now.addingTimeInterval(-700), coverage: 1)
    try await db.saveMarketCache(.init(key: "explore.v1.top.ethereum", source: "coinPaprika", payload: JSONEncoder().encode(snapshot), fetchedAt: snapshot.fetchedAt.timeIntervalSince1970))
    let service = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: ExploreFeed(), now: { now })
    #expect(await service.load(.top, networks: ["ethereum"]) == snapshot)
    let offline = ExploreFeed()
    let restored = ExploreDataService(database: db, entries: [], personalDataAllowed: true, transport: offline, now: { now.addingTimeInterval(30 * 86400) })
    #expect(await restored.cached(.top, networks: ["ethereum"]) == snapshot)
    #expect(await offline.count() == 0)
    #expect(await restored.load(.top, networks: ["ethereum"]) == snapshot)
}

@Test func exploreHistoryKeepsEachRangeAndAssetSeparateAcrossOfflineLaunches() async throws {
    let (db, folder) = try await exploreDatabase()
    defer { try? FileManager.default.removeItem(at: folder) }
    let end = Date(timeIntervalSince1970: 1_795_392_000)
    let asset = try ExploreAsset(network: "bitcoin", reference: "native")
    let token = ExploreToken(id: "btc-bitcoin", name: "Bitcoin", symbol: "BTC", assets: [asset], price: 100)
    let request = try #require(ExploreHistoryRequest(token: token, source: .coinPaprika))
    let formatter = ISO8601DateFormatter()
    for period in MarketHistoryRange.allCases {
        let key = "api.coinpaprika.com/v1/tickers/btc-bitcoin/historical"
        let first = formatter.string(from: end.addingTimeInterval(-period.duration + 3600))
        let last = formatter.string(from: end.addingTimeInterval(-120))
        let json = #"[{"timestamp":"\#(last)","price":110},{"timestamp":"\#(first)","price":100}]"#
        let feed = ExploreFeed([key: json])
        let market = MarketDataService(database: db, transport: feed, now: { end })
        #expect(try await market.cachedHistory(request, range: period) == nil)
        let result = try await market.history(request, range: period)
        #expect(result.value.source == "CoinPaprika")
        #expect(result.value.chart.points.map(\.close) == [100, 110])
        #expect(abs(try #require(result.value.chart.changePercent) - 10) < 0.0001)
        let url = try #require(await feed.requests.first)
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(params.contains(.init(name: "interval", value: period == .day ? "1h" : "1d")))
        #expect(params.contains(.init(name: "start", value: String(Int(end.timeIntervalSince1970 - period.duration) + 60))))
    }

    let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
    let noNetwork = ExploreFeed()
    let offlineDate = end.addingTimeInterval(172_800)
    let offline = MarketDataService(database: reopened, transport: noNetwork, now: { offlineDate })
    for period in MarketHistoryRange.allCases {
        let saved = try #require(try await offline.cachedHistory(request, range: period))
        #expect(saved.fetchedAt == end)
        #expect(saved.value.chart.points.first?.time == end.timeIntervalSince1970 - period.duration + 3600)
    }
    #expect(await noNetwork.count() == 0)
    await #expect(throws: (any Error).self) { try await offline.history(request, range: .year) }
    #expect(try await offline.cachedHistory(request, range: .year)?.fetchedAt == end)
    let other = ExploreToken(id: "unrelated", name: "Bitcoin", symbol: "BTC", assets: [asset], price: 100)
    let otherRequest = try #require(ExploreHistoryRequest(token: other, source: .coinPaprika))
    #expect(try await offline.cachedHistory(otherRequest, range: .year) == nil)
}

@Test func exploreChartRespectsContractAndRealCoverage() async throws {
    let (db, folder) = try await exploreDatabase()
    defer { try? FileManager.default.removeItem(at: folder) }
    let end = Date(timeIntervalSince1970: 1_795_392_000)
    let contract = "0x1111111111111111111111111111111111111111"
    let asset = try ExploreAsset(network: "ethereum", reference: contract)
    let token = ExploreToken(id: "btc-bitcoin", name: "Different token", symbol: "BTC", assets: [asset], price: 0)
    let request = try #require(ExploreHistoryRequest(token: token, source: .geckoTerminal))
    #expect(request.paprikaID == nil)
    let data = #"{"prices":[[\#(Int(end.timeIntervalSince1970-3600)*1000),1],[\#(Int(end.timeIntervalSince1970)*1000),2]]}"#
    let feed = ExploreFeed(["api.coingecko.com/api/v3/coins/ethereum/contract/" + contract + "/market_chart": data])
    let market = MarketDataService(database: db, transport: feed, now: { end })
    let chart = try await market.history(request, range: .month)
    #expect(chart.value.source == "CoinGecko")
    #expect(chart.value.chart.points.count == 2)
    #expect(chart.value.chart.changePercent == nil)
    let url = try #require(await feed.requests.first)
    #expect(url.query?.contains("days=30") == true)
    #expect(await feed.count() == 1)

    let hourly = (0...2160).map { [1000 * (end.timeIntervalSince1970 - Double($0) * 3600), 1.0] }
    let quarterly = try MarketDecoding.geckoChart(JSONSerialization.data(withJSONObject: ["prices": hourly]), now: end, range: .quarter)
    #expect(quarterly.points.count == 2161)
    #expect(quarterly.changePercent == 0)
}

@Test func exploreSolanaPoolUsesExactMintAndSelectedTimeframe() throws {
    let mint = "So11111111111111111111111111111111111111112"
    let counter = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let asset = try ExploreAsset(network: "solana", reference: mint)
    let selection = TokenPoolChart.Selection(network: "solana", pool: String(repeating: "B", count: 44), base: counter, quote: mint)
    let date = Date(timeIntervalSince1970: 1_795_392_000)
    let url = try TokenPoolChart.candlesURL(for: asset, selection: selection, at: date, range: .year)
    #expect(url.path.hasSuffix("/ohlcv/day"))
    #expect(url.query?.contains("limit=366") == true)
    #expect(url.query?.contains("token=" + mint) == true)
    let end = floor(date.timeIntervalSince1970 / 86400) * 86400
    let rows: [[Double]] = [[end-86400, 2, 3, 1, 3, 50], [end-172800, 2, 3, 1, 2, 50]]
    func candles(_ base: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["meta": ["base": ["address": base], "quote": ["address": counter]],
            "data": ["type": "ohlcv_request_response", "attributes": ["ohlcv_list": rows]]])
    }
    let result = try TokenPoolChart.decode(candles(mint), for: asset, selection: selection, at: date, range: .year)
    #expect(result.points.map(\.close) == [2, 3])
    #expect(result.changePercent == nil)
    #expect(throws: MarketDataError.invalidResponse) {
        try TokenPoolChart.decode(candles(mint.lowercased()), for: asset, selection: selection, at: date, range: .year)
    }
}

@Test(arguments: [0, 2, 8, 365])
func exploreChoosesTheLongestVerifiedPoolHistory(_ otherPoolDays: Int) async throws {
    let (db, folder) = try await exploreDatabase()
    defer { try? FileManager.default.removeItem(at: folder) }
    let date = Date(timeIntervalSince1970: 1_795_392_000)
    let address = "0x3333333333333333333333333333333333333333"
    let otherPool = "0x4444444444444444444444444444444444444444"
    let asset = try ExploreAsset(network: "ethereum", reference: address, decimals: 18)
    let request = try #require(ExploreHistoryRequest(token: .init(id: asset.id, name: "Test", symbol: "T", assets: [asset], price: 10), source: .geckoTerminal))
    let marketAsset = MarketAsset(id: asset.id, networkID: asset.network, reference: address, decimals: 18)
    let original = try TokenChartFixtures.pools(marketAsset, network: "eth")
    var catalog = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    let first = try #require((catalog["data"] as? [[String: Any]])?.first)
    var second = first
    second["id"] = "eth_" + otherPool
    second["attributes"] = ["address": otherPool, "reserve_in_usd": "100000"]
    catalog["data"] = [first, second]
    let prefix = "api.geckoterminal.com/api/v2/networks/eth/"
    func prices(days: Int, close: Double) throws -> String {
        let today = floor(date.timeIntervalSince1970 / 86_400) * 86_400
        let rows = (1...days).map { [today - Double($0) * 86_400, close, close, close, close, 1] }
        let json: [String: Any] = ["data": ["type": "ohlcv_request_response", "attributes": ["ohlcv_list": rows]],
                                   "meta": ["base": ["address": address], "quote": ["address": TokenChartFixtures.other]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
    var replies = [prefix + "tokens/" + address + "/pools": String(decoding: try JSONSerialization.data(withJSONObject: catalog), as: UTF8.self),
                   prefix + "pools/" + TokenChartFixtures.pool + "/ohlcv/day": try prices(days: 4, close: 10)]
    if otherPoolDays > 0 { replies[prefix + "pools/" + otherPool + "/ohlcv/day"] = try prices(days: otherPoolDays, close: 11) }
    let service = MarketDataService(database: db, transport: ExploreFeed(replies), now: { date })
    let chart = try await service.history(request, range: .year).value.chart
    #expect(chart.points.count == max(4, otherPoolDays))
    #expect(chart.points.allSatisfy { $0.close == (otherPoolDays > 4 ? 11 : 10) })
    #expect(chart.changePercent == (otherPoolDays == 365 ? 0 : nil))
}

@Test func exploreDenseChartPreservesRealExtremesAndScrubsEveryObservation() {
    let values = (0..<2161).map { i in MarketCandle(time: Double(i), close: i == 899 ? 500 : i == 900 ? 1 : 20) }
    let chart = MarketChart(points: values, changePercent: 0)
    let plot = chart.plotPoints(limit: 240)
    #expect(plot.count <= 240)
    #expect(plot.first == values.first && plot.last == values.last)
    #expect(plot.contains(values[899]) && plot.contains(values[900]))
    #expect(plot.map(\.time) == plot.map(\.time).sorted())
    #expect(chart.nearestPointIndex(to: 899.5) == 899)
    #expect(chart.nearestPointIndex(to: 1201.8) == 1202)
    #expect(chart.nearestPointIndex(to: -1) == 0)
    #expect(chart.nearestPointIndex(to: 9999) == 2160)
}

@Test func exploreCatalogueMetadataWorksWithoutWalletDecimalsAndPersists() async throws {
    let (db, folder) = try await exploreDatabase()
    defer { try? FileManager.default.removeItem(at: folder) }
    let address = "0x1111111111111111111111111111111111111111"
    let asset = try ExploreAsset(network: "ethereum", reference: address)
    let token = ExploreToken(id: asset.id, name: "Example", symbol: "EX", assets: [asset], price: 0)
    let request = try #require(ExploreHistoryRequest(token: token, source: nil))
    let data = #"{"id":"example","name":"Example","symbol":"ex","description":{"en":"A description."},"detail_platforms":{"ethereum":{"contract_address":"\#(address)","decimal_place":6}},"market_data":{"market_cap":{"usd":1500},"circulating_supply":900,"total_supply":1000}}"#
    let feed = ExploreFeed(["api.coingecko.com/api/v3/coins/ethereum/contract/" + address: data])
    let service = MarketDataService(database: db, transport: feed)
    let result = try await service.discoveryInformation(request)
    #expect(result.value.description == "A description.")
    #expect(result.value.marketCaps?["usd"] == 1500)
    #expect(result.value.totalSupply == 1000)
    #expect(try await service.cachedDiscoveryInformation(request)?.value == result.value)
    let wrong = data.replacingOccurrences(of: address, with: "0x2222222222222222222222222222222222222222")
    #expect(throws: MarketDataError.invalidResponse) { try MarketDecoding.discoveryInformation(Data(wrong.utf8), request: request) }
    #expect(try await db.asset(networkID: asset.network, reference: address) == nil)
}

@Test func exploreSpotQuoteForUnownedContractNeverWritesAPortfolioPrice() async throws {
    let (db, folder) = try await exploreDatabase()
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date(timeIntervalSince1970: 1_795_392_000)
    let address = "0x1111111111111111111111111111111111111111"
    let asset = MarketAsset(id: "ethereum:" + address, networkID: "ethereum", reference: address, decimals: 6)
    let feed = ExploreFeed(["api.coingecko.com/api/v3/simple/token_price/ethereum":
        #"{ "\#(address)": { "usd": 1.25, "last_updated_at": 1795392000 } }"#])
    let service = MarketDataService(database: db, transport: feed, now: { now }, tokenCatalog: nil)
    let current = try await service.exploreQuote(for: asset)
    #expect(current.value.decimal == 1.25)
    #expect(try await service.cachedExploreQuote(for: asset)?.value == current.value)
    #expect(try await db.asset(networkID: asset.networkID, reference: asset.reference) == nil)
    #expect(try await db.latestPrice(assetID: asset.id, currency: "USD") == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OATH_LIVE_EXPLORE_HISTORY"] == "1"))
func exploreLiveBitcoinHistoryThroughProductionTransport() async throws {
    let (db, folder) = try await exploreDatabase()
    defer { try? FileManager.default.removeItem(at: folder) }
    let service = MarketDataService(database: db)
    let asset = try ExploreAsset(network: "bitcoin", reference: "native")
    let request = try #require(ExploreHistoryRequest(token: .init(id: "btc-bitcoin", name: "Bitcoin", symbol: "BTC",
        assets: [asset], price: 0), source: .coinPaprika))
    for period in MarketHistoryRange.allCases {
        let result = try await service.history(request, range: period)
        let points = result.value.chart.points
        #expect(points.count >= 2)
        #expect(points.allSatisfy { $0.close.isFinite && $0.close > 0 })
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(try await service.cachedHistory(request, range: period)?.value.chart == result.value.chart)
    }
}
