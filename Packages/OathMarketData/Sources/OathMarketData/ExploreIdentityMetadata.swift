import Foundation
import CoreFoundation
import OathAnkr

struct ExploreIdentityMetadata: Codable, Sendable {
    let assets: [ExploreAsset]
    let stablecoin: Bool
    let fetchedAt: Date
    static let platforms = ["eth-ethereum":"ethereum", "bnb-bnb":"bnb", "bnb-binance-coin":"bnb", "trx-tron":"tron",
        "avax-avalanche":"avalanche", "matic-polygon":"polygon", "pol-polygon-ecosystem-token":"polygon",
        "sol-solana":"solana", "toncoin-the-open-network":"ton", "op-optimism":"optimism", "arb-arbitrum":"arbitrum",
        "base-base":"base", "linea-linea":"linea", "celo-celo":"celo", "sui-sui":"sui", "apt-aptos":"aptos",
        "near-near-protocol":"near", "ftm-fantom":"fantom", "xdai-xdai":"gnosis"]
    static func decode(_ data: Data, id: String, entries: [String: TokenDiscoveryEntry], now: Date) throws -> Self {
        let root = try ExploreDecoding.object(data)
        guard root["id"] as? String == id else { throw MarketDataError.invalidResponse }
        let contracts = root["contracts"] as? [[String: Any]] ?? []
        guard contracts.count <= 100 else { throw MarketDataError.invalidResponse }
        let assets: [ExploreAsset] = contracts.compactMap { row in
            guard let platform = row["platform"] as? String, let network = platforms[platform], let contract = row["contract"] as? String,
                  let canonical = try? TokenDiscoveryNetworks.canonical(contract, network: network),
                  let entry = entries[network + ":" + canonical] else { return nil }
            return try? ExploreAsset(network: network, reference: canonical, decimals: entry.decimals)
        }
        let tags = root["tags"] as? [[String: Any]] ?? []
        return .init(assets: Array(Set(assets)), stablecoin: tags.contains { ($0["id"] as? String)?.contains("stablecoin") == true }, fetchedAt: now)
    }
}
