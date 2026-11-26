import Foundation
import OathAnkr

/// Public discovery identities only; never a wallet balance or signing authority.
public struct ExploreAsset: Codable, Hashable, Sendable, Identifiable {
    public let network: String
    public let reference: String
    public let decimals: Int?
    public var id: String { network + ":" + reference }
    public init(network: String, reference: String, decimals: Int? = nil) throws {
        guard MarketIdentity.native[network] != nil || TokenDiscoveryNetworks.platforms[network] != nil else { throw MarketDataError.invalidResponse }
        self.network = network
        self.reference = reference == "native" ? reference : try TokenDiscoveryNetworks.canonical(reference, network: network)
        self.decimals = decimals.flatMap { (0...255).contains($0) ? $0 : nil }
    }
}

public struct ExploreToken: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let symbol: String
    public var assets: [ExploreAsset]
    public let image: String?
    public let price: Double
    public let change24h: Double?
    public let marketCap: Double?
    public let volume24h: Double?
    public let liquidity: Double?
    public let observedAt: Date?
    public let stablecoin: Bool
    public let rank: Int?
    public let circulatingSupply: Double?
    public let totalSupply: Double?
    public init(id: String, name: String, symbol: String, assets: [ExploreAsset], image: String? = nil,
                price: Double, change24h: Double? = nil, marketCap: Double? = nil, volume24h: Double? = nil,
                liquidity: Double? = nil, observedAt: Date? = nil, stablecoin: Bool = false,
                rank: Int? = nil, circulatingSupply: Double? = nil, totalSupply: Double? = nil) {
        self.id = id; self.name = String(name.prefix(100)); self.symbol = String(symbol.prefix(20)); self.assets = assets
        self.image = image; self.price = price; self.change24h = change24h; self.marketCap = marketCap
        self.volume24h = volume24h; self.liquidity = liquidity; self.observedAt = observedAt; self.stablecoin = stablecoin
        self.rank = rank.flatMap { $0 > 0 ? $0 : nil }
        self.circulatingSupply = circulatingSupply.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.totalSupply = totalSupply.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Prefer the project's main network or an exact Ethereum contract when several
    /// representations share a ranking. The remaining networks stay available in detail.
    public var detailAsset: ExploreAsset? {
        assets.first { $0.network == "ethereum" && $0.reference == "native" }
            ?? assets.first { $0.network == "ethereum" }
            ?? assets.first { $0.reference == "native" }
            ?? assets.first
    }
}

public enum ExploreSection: String, CaseIterable, Codable, Sendable { case top, trending, gainers, losers }
public enum ExploreSource: String, Codable, Sendable {
    case coinPaprika, coinLore, geckoTerminal, dexPaprika
    public var title: String { switch self {
    case .coinPaprika: "CoinPaprika"; case .coinLore: "CoinLore"
    case .geckoTerminal: "GeckoTerminal"; case .dexPaprika: "DexPaprika"
    } }
}
public struct ExploreSectionSnapshot: Codable, Sendable, Equatable {
    public let section: ExploreSection
    public let source: ExploreSource
    public let items: [ExploreToken]
    public let fetchedAt: Date
    public let coverage: Int
    public var activeOnChain: Bool { section == .trending && source == .dexPaprika }
    public var refreshInterval: TimeInterval { section == .trending ? 120 : 600 }
    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(fetchedAt) >= -300 && now.timeIntervalSince(fetchedAt) < refreshInterval }
    /// A saved observation remains displayable offline. Freshness controls
    /// refresh and the cached label, never deletion of the last good result.
    public func isUsable(at now: Date) -> Bool {
        fetchedAt.timeIntervalSince1970.isFinite && fetchedAt.timeIntervalSince1970 > 0 &&
            now.timeIntervalSince(fetchedAt) >= -300
    }
    public init(section: ExploreSection, source: ExploreSource, items: [ExploreToken], fetchedAt: Date, coverage: Int) {
        self.section = section; self.source = source; self.items = items; self.fetchedAt = fetchedAt; self.coverage = coverage
    }
}

public struct ExploreDAppMetric: Sendable, Equatable {
    public let value: Double
    public let fetchedAt: Date
    init(value: Double, fetchedAt: Date) {
        self.value = value
        // Use the same epoch precision in memory and in SQLite.
        self.fetchedAt = Date(timeIntervalSince1970: fetchedAt.timeIntervalSince1970)
    }
    public func isFresh(at now: Date) -> Bool {
        (-300..<21_600).contains(now.timeIntervalSince(fetchedAt))
    }
}

public enum ExploreRanking {
    public static func ranked(_ tokens: [ExploreToken], section: ExploreSection, networks: Set<String>, now: Date) -> [ExploreToken] {
        var seen = Set<String>()
        var filtered = tokens.compactMap { token -> ExploreToken? in
            guard token.price.isFinite, token.price > 0, seen.insert(token.id).inserted,
                  token.observedAt.map({ now.timeIntervalSince($0) >= -300 && now.timeIntervalSince($0) <= 3600 }) ?? true else { return nil }
            var value = token; value.assets = Array(Set(token.assets.filter { networks.contains($0.network) })).sorted { $0.id < $1.id }
            guard !value.assets.isEmpty else { return nil }
            switch section {
            case .top: guard let cap = value.marketCap, cap.isFinite, cap > 0 else { return nil }
            case .gainers, .losers:
                guard !value.stablecoin, let cap = value.marketCap, cap >= 1_000_000,
                      let volume = value.volume24h, volume >= 100_000,
                      let change = value.change24h, change.isFinite,
                      section == .gainers ? change > 0 : change < 0 else { return nil }
            case .trending: break
            }
            return value
        }
        if section != .trending {
            filtered.sort {
                let a = section == .top ? $0.marketCap! : $0.change24h!
                let b = section == .top ? $1.marketCap! : $1.change24h!
                return a == b ? $0.id < $1.id : section == .losers ? a < b : a > b
            }
        }
        return Array(filtered.prefix(100))
    }
}

public struct DAppDescriptor: Identifiable, Codable, Sendable, Equatable {
    public let id: String, name: String, category: String, domain: String, symbol: String, summary: String
    public let networks: Set<String>
    public var url: URL { URL(string: "https://" + domain)! }
    public static let catalogue: [Self] = [
        .init(id: "uniswap", name: "Uniswap", category: "Swap", domain: "app.uniswap.org", symbol: "arrow.trianglehead.2.clockwise.rotate.90", summary: "Discover and exchange tokens", networks: ["ethereum", "arbitrum", "base", "optimism", "polygon", "bnb", "avalanche", "unichain"]),
        .init(id: "aave", name: "Aave", category: "Lend", domain: "app.aave.com", symbol: "building.columns", summary: "Supply and borrow assets", networks: ["ethereum", "arbitrum", "base", "optimism", "polygon", "avalanche", "gnosis"]),
        .init(id: "lido", name: "Lido", category: "Stake", domain: "stake.lido.fi", symbol: "drop", summary: "Explore liquid staking", networks: ["ethereum"]),
        .init(id: "curve-dex", name: "Curve", category: "Swap", domain: "curve.finance", symbol: "waveform.path", summary: "Trade and explore liquidity", networks: ["ethereum", "arbitrum", "base", "optimism", "polygon", "avalanche", "gnosis"]),
        .init(id: "pancakeswap", name: "PancakeSwap", category: "Swap", domain: "pancakeswap.finance", symbol: "circle.stack", summary: "Exchange tokens across networks", networks: ["bnb", "ethereum", "arbitrum", "base", "linea"]),
        .init(id: "1inch-network", name: "1inch", category: "Swap", domain: "app.1inch.io", symbol: "arrow.up.right", summary: "Compare decentralised swap routes", networks: ["ethereum", "arbitrum", "base", "optimism", "polygon", "bnb", "avalanche", "gnosis"])
    ]
}
