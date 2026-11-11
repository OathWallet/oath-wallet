import XCTest
@testable import OathDatabase
@testable import OathAnkr
@testable import OathMarketData

private actor FantomPriceFeed: MarketTransport {
    static let wrapped = "0x21be370d5312f44cb42ce377bc9b8a0cef1a4c83"
    let now: Date
    let live: Bool
    private var offline = false
    private(set) var requests: [URL] = []
    private(set) var wrappedPayload: Data?
    private let base = URLSessionMarketTransport()

    init(now: Date, live: Bool = false) { self.now = now; self.live = live }
    func goOffline() { offline = true }

    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        if url.host == "api.geckoterminal.com", url.lastPathComponent == Self.wrapped {
            let data: Data
            if live { data = try await base.data(from: url) }
            else {
                data = try JSONSerialization.data(withJSONObject: ["data": [
                    "id": "ftm_" + Self.wrapped,
                    "attributes": ["address": Self.wrapped, "decimals": 18, "price_usd": "0.055",
                                   "total_reserve_in_usd": "1400000", "volume_usd": ["h24": "2083"]]
                ]])
            }
            wrappedPayload = data
            return data
        }
        if url.host == "api.coinpaprika.com" {
            return try JSONSerialization.data(withJSONObject: [
                "id": "ftm-fantom", "name": "Fantom", "symbol": "FTM",
                "last_updated": ISO8601DateFormatter().string(from: now),
                "quotes": ["USD": ["price": "0.48022"]]
            ])
        }
        if url.host == "api.coinbase.com" {
            return Data(#"{"data":{"base":"FTM","currency":"USD","amount":"0.037"}}"#.utf8)
        }
        if url.host == "api.coingecko.com" {
            return try JSONSerialization.data(withJSONObject: ["fantom": ["usd": "0.037", "last_updated_at": now.timeIntervalSince1970 - 62_000]])
        }
        throw MarketDataError.notListed
    }
}

@MainActor final class FantomNativePriceRecoveryTests: XCTestCase {
    private let asset = MarketAsset(id: "fantom:native", networkID: "fantom", reference: "native", decimals: 18)

    private func database(_ path: URL, owner: String = "0x0000000000000000000000000000000000000001") async throws -> OathDatabase {
        let db = try await OathDatabase.open(at: path)
        try await db.seed(networks: [.init(id: "fantom", name: "Fantom", family: "evm", symbol: "FTM", decimals: 18, derivationPath: "", logo: "", sortOrder: 0)],
                          assets: [.init(id: asset.id, networkID: "fantom", reference: "native", name: "Fantom", symbol: "FTM", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "wallet", networkID: "fantom", address: owner, derivationPath: "")])
        try await db.saveBalances([.init(accountID: "account", assetID: asset.id, networkID: "fantom", amountAtomic: "1250000000000000000", observedAt: 100, source: "fixture")])
        return db
    }

    func testRetiredCentralizedMarketsCannotOverwriteTheOperaPrice() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try await database(path), now = Date()
        let feed = FantomPriceFeed(now: now)
        let quote = try await MarketDataService(database: db, transport: feed, now: { now }).quote(for: asset)
        XCTAssertEqual(quote.value.usd, "0.055")
        let requests = await feed.requests
        XCTAssertFalse(requests.contains { ["api.coinbase.com", "api.coinpaprika.com"].contains($0.host) })
        let price = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(price?.source, "GeckoTerminal (WFTM)")
        await feed.goOffline()
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened, transport: feed).quote(for: asset, force: true)
        XCTAssertEqual(saved.value, quote.value)
        XCTAssertEqual(saved.fetchedAt, quote.fetchedAt)
        let balance = try await reopened.balance(accountID: "account", assetID: asset.id)
        XCTAssertEqual(balance?.amountAtomic, "1250000000000000000")
    }

    func testLegacyAndVerifiedInventoryKeepUnitsAndTokenQuotesWithoutRepricingOpera() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try await database(path), now = Date(), owner = "0x0000000000000000000000000000000000000001"
        let token = "0x3333333333333333333333333333333333333333"
        let before = now.addingTimeInterval(-3).timeIntervalSince1970
        // Older installations can have recent, durable quotes from all three sources.
        let old = ["ankr", "CoinPaprika", "Coinbase"].enumerated().map { index, source in
            PriceRecord(assetID: asset.id, currency: "USD", value: "0.48", observedAt: before + Double(index), source: source)
        }
        try await db.savePrices(old)
        let archived = MarketCacheEntry(key: "v2.quote." + asset.cacheIdentity, source: "CoinPaprika",
            payload: try JSONEncoder().encode(MarketQuote(code: "FTM", usd: "0.48")), fetchedAt: before)
        try await db.saveMarketCache(archived)
        let feed = FantomPriceFeed(now: now)
        let service = MarketDataService(database: db, transport: feed, now: { now })
        let oldDisplay = try await service.cachedQuote(for: asset)
        XCTAssertNil(oldDisplay)
        let recovered = try await service.quote(for: asset)
        XCTAssertEqual(recovered.value.usd, "0.055")
        func item(_ native: Bool) -> [String: Any] {
            ["blockchain": "fantom", "tokenName": native ? "Fantom" : "Other", "tokenSymbol": native ? "FTM" : "TEST",
             "tokenDecimals": 18, "tokenType": native ? "NATIVE" : "ERC20",
             "contractAddress": native ? "0x" + String(repeating: "0", count: 40) : token,
             "holderAddress": owner, "balance": "2", "balanceRawInteger": "2000000000000000000",
             "balanceUsd": "2", "tokenPrice": native ? "0.9058732036828172" : "2.2"]
        }
        for verified in [false, true] {
            let stamp = now.addingTimeInterval(verified ? 2 : 1)
            let result: [String: Any] = ["assets": [item(true), item(false)], "totalBalanceUsd": "2", "totalCount": 2,
                "syncStatus": ["timestamp": stamp.timeIntervalSince1970, "blockNumber": 12, "status": "synced"]]
            let raw = try JSONSerialization.data(withJSONObject: ["id": 1, "jsonrpc": "2.0", "result": result])
            let page = try AnkrPage(value: JSONDecoder().decode(AnkrBalanceResult.self, from: JSONSerialization.data(withJSONObject: result)), raw: raw, fetchedAt: stamp)
            let ticket = try await db.beginAnkrSync(accountID: "account", stream: "balances")
            if verified {
                let snapshot = EVMPortfolioBalances(networkID: "fantom", owner: owner, height: 12,
                    blockHash: "0x" + String(repeating: "1", count: 64), observedAt: stamp,
                    amounts: ["native": "2000000000000000000", token: "2000000000000000000"], failedReferences: [], corroboratedIdleTip: false)
                try await db.commitVerifiedAnkrBalances(snapshot, ticket: ticket, pages: [page], verifiedReferences: [token], discoveryComplete: true, final: true)
            } else { try await db.commitAnkrBalances([page], ticket: ticket) }
            let snapshot = try await db.snapshot(walletID: "wallet", currency: "USD")
            XCTAssertEqual(snapshot.holdings.first { $0.assetID == asset.id }?.price, "0.055")
            XCTAssertEqual(snapshot.holdings.first { $0.assetID == asset.id }?.amountAtomic, "2000000000000000000")
            let tracked = try await db.latestPrice(assetID: "fantom:" + token, currency: "USD")
            XCTAssertEqual(tracked?.value, "2.2")
        }
        let reopened = try await OathDatabase.open(at: path)
        let history = try await reopened.priceHistory(assetID: asset.id, currency: "USD")
        XCTAssertEqual(history.filter { $0.value == "0.48" }.count, 3)
        XCTAssertFalse(history.contains { $0.value == "0.9058732036828172" })
        let original = try await reopened.marketCache(key: archived.key)
        XCTAssertEqual(original, archived)
    }

    func testLiveFundedOperaInventoryAndNativeMarketSurvivePortfolioReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FANTOM_PRICE_LIVE"] == "1",
              let config = ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"] else { throw XCTSkip("Public Opera inventory read") }
        let settings = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: config)))
        let client = try AnkrClient(apiKey: XCTUnwrap(settings["AnkrAPIKey"]))
        let owner = "0xf977814e90da44bfa03b6295a0616a897441acec"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try await database(path, owner: owner)
        var pages: [AnkrPage<AnkrBalanceResult>] = [], cursors = Set<String>()
        var cursor: String?
        repeat {
            let page = try await client.balances(chain: .fantom, address: owner, cursor: cursor)
            pages.append(page)
            cursor = page.value.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let cursor { guard cursors.insert(cursor).inserted, cursors.count < 20 else { throw AnkrError.incompleteInventory } }
        } while cursor != nil
        let items = pages.flatMap { $0.value.assets }
        let native = try XCTUnwrap(items.first { $0.reference == "native" })
        let service = MarketDataService(database: db)
        await service.refreshNativeQuotes(networkIDs: ["fantom"])
        let marketPrice = try await db.latestPrice(assetID: asset.id, currency: "USD")
        let price = try XCTUnwrap(marketPrice)
        XCTAssertTrue(["GeckoTerminal (WFTM)", "CoinGecko", "DefiLlama"].contains(price.source))
        let ticket = try await db.beginAnkrSync(accountID: "account", stream: "balances")
        try await db.commitAnkrBalances(pages, ticket: ticket)
        let reopened = try await OathDatabase.open(at: path)
        let retained = try await reopened.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(retained, price)
        for item in items {
            let balance = try await reopened.balance(accountID: "account", assetID: "fantom:" + item.reference)
            XCTAssertEqual(balance?.amountAtomic, try AnkrQuantity.decimal(item.balanceRawInteger))
        }
        let snapshot = try await reopened.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first { $0.assetID == asset.id }?.price, price.value)
        print("LIVE_FTM_PORTFOLIO holdings=\(items.count) inventoryUSD=\(native.tokenPrice) marketUSD=\(price.value) source=\(price.source)")
    }

    func testLiveOperaWrappedMarketMatchesPublishedQuoteExactly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FANTOM_PRICE_LIVE"] == "1" else { throw XCTSkip("Read-only public WFTM market") }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let db = try await database(path), now = Date(), feed = FantomPriceFeed(now: Date(), live: true)
        await MarketDataService(database: db, transport: feed, now: { now }).refreshNativeQuotes(networkIDs: ["fantom"])
        let payload = await feed.wrappedPayload
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(payload)) as? [String: Any])
        let attrs = try XCTUnwrap((root["data"] as? [String: Any])?["attributes"] as? [String: Any])
        let expected = try XCTUnwrap(ContractPriceDecoding.positive(attrs["price_usd"]))
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await reopened.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(saved?.source, "GeckoTerminal (WFTM)")
        XCTAssertEqual(saved.flatMap { Decimal(string: $0.value) }, expected)
        let balance = try await reopened.balance(accountID: "account", assetID: asset.id)
        XCTAssertEqual(balance?.amountAtomic, "1250000000000000000")
        print("LIVE_FANTOM_NATIVE wrappedUSD=\(expected) savedExactly=true balancePreserved=true")
    }
}
