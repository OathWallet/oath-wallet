import Foundation
import Testing
import OathAnkr
@testable import OathMarketData

@Test func exploreRankingFiltersAndPreservesCoverage() throws {
    let asset = try ExploreAsset(network: "ethereum", reference: "native")
    func token(_ id: String, _ change: Double, cap: Double = 2_000_000, stable: Bool = false) -> ExploreToken {
        .init(id: id, name: id, symbol: id, assets: [asset], price: 1, change24h: change, marketCap: cap, volume24h: 200_000, stablecoin: stable)
    }
    let rows = [token("up", 20), token("down", -30), token("dust", 10000, cap: 2), token("stable", 0.2, stable: true), token("up", 20)]
    #expect(ExploreRanking.ranked(rows, section: .gainers, networks: ["ethereum"], now: .now).map(\.id) == ["up"])
    #expect(ExploreRanking.ranked(rows, section: .losers, networks: ["ethereum"], now: .now).map(\.id) == ["down"])
    #expect(ExploreRanking.ranked(rows, section: .top, networks: ["solana"], now: .now).isEmpty)
}
@Test func paprikaNeverMapsTickerCollisions() throws {
    let data = Data(#"[{"id":"fake-ethereum","name":"Ethereum","symbol":"ETH","quotes":{"USD":{"price":10,"market_cap":1000000}}}]"#.utf8)
    #expect(try ExploreDecoding.paprika(data, identities: ExploreDecoding.seed(entries: []), now: .now).isEmpty)
}
@Test func trendingDoesNotReplaceMissingMarketCapWithFDV() throws {
    let address = "0x1111111111111111111111111111111111111111"
    let json: [String: Any] = ["data": [["attributes": ["base_token_price_usd": "2", "quote_token_price_usd": "5000", "reserve_in_usd": "200000", "volume_usd": ["h24": "300000"], "fdv_usd": "50000000", "pool_created_at": "2020-01-01T00:00:00Z"], "relationships": ["base_token": ["data": ["id": "eth_" + address]], "network": ["data": ["id": "eth"]]]]], "included": [["id": "eth_" + address, "type": "token", "attributes": ["address": address, "name": "Test", "symbol": "T", "decimals": 18]]]]
    let rows = try ExploreDecoding.terminal(JSONSerialization.data(withJSONObject: json), now: .now)
    #expect(rows.count == 1)
    #expect(rows.first?.price == 2)
    #expect(rows.first?.marketCap == nil)
    #expect(rows.first?.assets.first?.reference == address)
}
@Test func staleRankingsRemainDisplayableButAreNotFresh() {
    let now = Date()
    let snapshot = ExploreSectionSnapshot(section: .trending, source: .dexPaprika, items: [], fetchedAt: now.addingTimeInterval(-3601), coverage: 0)
    #expect(snapshot.activeOnChain)
    #expect(snapshot.isUsable(at: now))
    #expect(!snapshot.isFresh(at: now))
}

@Test func explorerNumbersRejectBooleanPrices() {
    #expect(ExploreDecoding.number(true) == nil)
    #expect(ExploreDecoding.number("nan") == nil)
    #expect(ExploreDecoding.number("1.25") == 1.25)
}

@Test func paprikaMetadataRequiresMatchingPlatformAndContract() throws {
    let address = "0x1111111111111111111111111111111111111111"
    let entries = try JSONDecoder().decode([TokenDiscoveryEntry].self, from: Data("[{\"network\":\"ethereum\",\"reference\":\"\(address)\",\"name\":\"Token\",\"symbol\":\"T\",\"decimals\":18}]".utf8))
    let exact: [String: Any] = ["id":"t-test", "contracts":[["platform":"eth-ethereum","contract":address]], "tags":[["id":"stablecoin"]]]
    let known = [entries[0].id: entries[0]]
    let value = try ExploreIdentityMetadata.decode(JSONSerialization.data(withJSONObject: exact), id: "t-test", entries: known, now: .now)
    #expect(value.assets.count == 1); #expect(value.stablecoin)
    #expect(throws: (any Error).self) { try ExploreIdentityMetadata.decode(JSONSerialization.data(withJSONObject: exact), id: "other", entries: known, now: .now) }
    var wrong = exact; wrong["contracts"] = [["platform":"bnb-bnb","contract":address]]
    #expect(try ExploreIdentityMetadata.decode(JSONSerialization.data(withJSONObject: wrong), id: "t-test", entries: known, now: .now).assets.isEmpty)
}

@Test func exploreProviderTimestampsAcceptFractionalSeconds() {
    #expect(ExploreDecoding.date("2026-11-21T08:00:00Z") != nil)
    #expect(ExploreDecoding.date("2026-11-21T08:00:00.123456Z") != nil)
    #expect(ExploreDecoding.date("not-a-date") == nil)
}
