import Foundation
import CoreFoundation
import OathAnkr

enum ExploreDecoding {
    typealias Object = [String: Any]
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
    static func object(_ data: Data) throws -> Object {
        guard let result = try JSONSerialization.jsonObject(with: data) as? Object else { throw MarketDataError.invalidResponse }; return result
    }
    static func rows(_ data: Data) throws -> [Object] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Object], rows.count <= 5000 else { throw MarketDataError.invalidResponse }; return rows
    }
    static let paprikaIDs: [String: String] = [
        "bitcoin":"btc-bitcoin", "ethereum":"eth-ethereum", "tether":"usdt-tether", "usd-coin":"usdc-usd-coin",
        "binancecoin":"bnb-binance-coin", "ripple":"xrp-xrp", "solana":"sol-solana", "tron":"trx-tron",
        "hyperliquid":"hype-hyperliquid", "dogecoin":"doge-dogecoin", "bitcoin-cash":"bch-bitcoin-cash",
        "stellar":"xlm-stellar", "near":"near-near-protocol", "litecoin":"ltc-litecoin", "avalanche-2":"avax-avalanche",
        "the-open-network":"toncoin-the-open-network", "sui":"sui-sui", "crypto-com-chain":"cro-cryptocom-chain",
        "okb":"okb-okb", "fantom":"ftm-fantom", "polkadot":"dot-polkadot", "aptos":"apt-aptos",
        "thorchain":"rune-thorchain", "telos":"tlos-telos", "filecoin":"fil-filecoin", "iotex":"iotx-iotex",
        "celo":"celo-celo", "chiliz":"chz-chiliz", "dai":"dai-dai", "chainlink":"link-chainlink",
        "uniswap":"uni-uniswap", "aave":"aave-new", "wrapped-bitcoin":"wbtc-wrapped-bitcoin", "weth":"weth-weth",
        "staked-ether":"steth-lido-staked-ether", "wrapped-steth":"wsteth-wrapped-liquid-staked-ether-20",
        "shiba-inu":"shib-shiba-inu", "pepe":"pepe-pepe", "ondo-finance":"ondo-ondo", "ethena":"ena-ethena",
        "ethena-usde":"usde-ethena-usde", "paypal-usd":"pyusd-paypal-usd"
    ]
    static let loreIDs: [String: String] = [
        "90":"btc-bitcoin", "80":"eth-ethereum", "518":"usdt-tether", "33285":"usdc-usd-coin",
        "2710":"bnb-binance-coin", "58":"xrp-xrp", "48543":"sol-solana", "2713":"trx-tron",
        "148109":"hype-hyperliquid", "2":"doge-dogecoin", "89":"xlm-stellar", "2321":"bch-bitcoin-cash",
        "48563":"near-near-protocol", "47305":"uni-uniswap", "44883":"avax-avalanche", "54683":"toncoin-the-open-network",
        "93845":"sui-sui", "33422":"wbtc-wrapped-bitcoin", "2751":"link-chainlink", "32417":"dai-dai", "32610":"weth-weth",
        "46971":"steth-lido-staked-ether", "65945":"wsteth-wrapped-liquid-staked-ether-20", "158405":"usde-ethena-usde"
    ]
    static let stablecoins: Set<String> = ["usdt-tether", "usdc-usd-coin", "dai-dai", "usde-ethena-usde", "pyusd-paypal-usd", "usds-usds", "usdd-usdd"]
    static func seed(entries: [TokenDiscoveryEntry]) -> [String: [ExploreAsset]] {
        var mapping: [String: [ExploreAsset]] = [:]
        for (network, identity) in MarketIdentity.native {
            if let id = paprikaIDs[identity.gecko], let asset = try? ExploreAsset(network: network, reference: "native") { mapping[id, default: []].append(asset) }
        }
        for entry in entries {
            guard let gecko = entry.coinID, let id = paprikaIDs[gecko],
                  let asset = try? ExploreAsset(network: entry.network, reference: entry.reference, decimals: entry.decimals) else { continue }
            mapping[id, default: []].append(asset)
        }
        return mapping.mapValues { Array(Set($0)).sorted { $0.id < $1.id } }
    }
    static func paprika(_ data: Data, identities: [String: [ExploreAsset]], now: Date, stablecoinIDs: Set<String> = stablecoins) throws -> [ExploreToken] {
        try rows(data).compactMap { row in
            guard let id = row["id"] as? String, let assets = identities[id], !assets.isEmpty,
                  let quotes = row["quotes"] as? Object, let usd = quotes["USD"] as? Object,
                  let price = number(usd["price"]), let name = row["name"] as? String, let symbol = row["symbol"] as? String else { return nil }
            return .init(id: id, name: name, symbol: symbol, assets: assets, image: "https://static.coinpaprika.com/coin/" + id + "/logo.png", price: price,
                change24h: number(usd["percent_change_24h"]), marketCap: number(usd["market_cap"]), volume24h: number(usd["volume_24h"]),
                observedAt: date(row["last_updated"]), stablecoin: stablecoinIDs.contains(id), rank: row["rank"] as? Int,
                circulatingSupply: number(row["circulating_supply"]), totalSupply: number(row["total_supply"]))
        }
    }
    static func lore(_ data: Data, identities: [String: [ExploreAsset]]) throws -> [ExploreToken] {
        let root = try object(data)
        let rows: [Object]
        if let items = root["data"] as? [Object] { rows = items }
        else if let lists = root["data"] as? Object { rows = (lists["winners"] as? [Object] ?? []) + (lists["losers"] as? [Object] ?? []) }
        else { throw MarketDataError.invalidResponse }
        guard rows.count <= 500 else { throw MarketDataError.invalidResponse }
        let observed = (root["info"] as? Object).flatMap { number($0["time"]) }.map(Date.init(timeIntervalSince1970:))
        return rows.compactMap { row in
            guard let loreID = row["id"] as? String, let id = loreIDs[loreID], let assets = identities[id],
                  let price = number(row["price_usd"]), let name = row["name"] as? String, let symbol = row["symbol"] as? String else { return nil }
            return .init(id: id, name: name, symbol: symbol, assets: assets, price: price,
                change24h: number(row["percent_change_24h"]), marketCap: number(row["market_cap_usd"]), volume24h: number(row["volume24"]),
                observedAt: observed, stablecoin: stablecoins.contains(id), rank: row["rank"] as? Int,
                circulatingSupply: number(row["csupply"]), totalSupply: number(row["tsupply"]))
        }
    }
    static func terminal(_ data: Data, now: Date) throws -> [ExploreToken] {
        let root = try object(data)
        guard let pools = root["data"] as? [Object], pools.count <= 100, let included = root["included"] as? [Object], included.count <= 500 else { throw MarketDataError.invalidResponse }
        var tokens: [String: Object] = [:]
        for item in included where item["type"] as? String == "token" { if let id = item["id"] as? String { tokens[id] = item["attributes"] as? Object } }
        let networks = Dictionary(ContractPriceRequest.terminalNetworks.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        return pools.compactMap { pool in
            guard let attrs = pool["attributes"] as? Object, let relationships = pool["relationships"] as? Object,
                  let base = (relationships["base_token"] as? Object)?["data"] as? Object, let baseID = base["id"] as? String,
                  let baseAttrs = tokens[baseID], let reference = baseAttrs["address"] as? String,
                  let networkID = ((relationships["network"] as? Object)?["data"] as? Object)?["id"] as? String,
                  let network = networks[networkID], baseID == networkID + "_" + reference,
                  let asset = try? ExploreAsset(network: network, reference: reference, decimals: baseAttrs["decimals"] as? Int),
                  let price = number(attrs["base_token_price_usd"]), let liquidity = number(attrs["reserve_in_usd"]), liquidity >= 100_000,
                  let volume = number((attrs["volume_usd"] as? Object)?["h24"]), volume >= 100_000,
                  let created = date(attrs["pool_created_at"]), now.timeIntervalSince(created) >= 86400,
                  let name = baseAttrs["name"] as? String, let symbol = baseAttrs["symbol"] as? String else { return nil }
            return .init(id: asset.id, name: name, symbol: symbol, assets: [asset], image: baseAttrs["image_url"] as? String,
                price: price, change24h: number((attrs["price_change_percentage"] as? Object)?["h24"]),
                marketCap: number(attrs["market_cap_usd"]), volume24h: volume, liquidity: liquidity)
        }
    }
    static func dexPaprika(_ data: Data, entries: [String: TokenDiscoveryEntry], now: Date) throws -> [ExploreToken] {
        guard let rows = try object(data)["results"] as? [Object], rows.count <= 100 else { throw MarketDataError.invalidResponse }
        let aliases = ["bsc":"bnb", "polygon":"polygon", "avalanche":"avalanche", "world-chain":"worldchain", "hyperliquid":"hyperevm"]
        return rows.compactMap { row in
            guard let chain = row["chain"] as? String, let address = row["address"] as? String,
                  let asset = try? ExploreAsset(network: aliases[chain] ?? chain, reference: address),
                  let entry = entries[asset.id], let price = number(row["price_usd"]),
                  let liquidity = number(row["liquidity_usd"]), liquidity >= 100_000,
                  let volume = number(row["volume_usd_24h"]), volume >= 100_000,
                  let created = date(row["created_at"]), now.timeIntervalSince(created) >= 86400 else { return nil }
            let catalogueAsset = try? ExploreAsset(network: asset.network, reference: asset.reference, decimals: entry.decimals)
            return .init(id: asset.id, name: entry.name, symbol: entry.symbol, assets: [catalogueAsset ?? asset], image: entry.logo, price: price,
                change24h: number(row["price_change_percentage_24h"]), volume24h: volume, liquidity: liquidity)
        }
    }
}
