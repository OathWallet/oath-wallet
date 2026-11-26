import Foundation

/// Contract candidates for mainnets using ordinary ANKR JSON-RPC only.
/// The directory is not a balance index: every balance and decimal precision
/// is read from that chain. Saved/custom tokens are merged by IndexedEVMClient.
enum RPCCatalogTokens {
    private struct Seed: Decodable { let entries: [TokenDiscoveryEntry] }

    /// Canonical Elysium bridge assets, independently documented by Bitquery's
    /// Elysium integration and checked against mainnet contract precision.
    /// Recognition grants no price mapping or assumed dollar peg.
    static func isCoreAsset(_ reference: String, chain: IndexedEVMChain) -> Bool {
        chain == .elysium && [
            "0xb47c4c8f73f009cc0c0d3f92b388d13e293f0b65",
            "0xba876237b0f021a6c6d852d6c26e107997cc5e81"
        ].contains(reference.lowercased())
    }

    static func tokens(chain: IndexedEVMChain) throws -> [IndexedEVMToken] {
        guard chain.usesRPCCatalog,
              let url = Bundle.module.url(forResource: "TokenDiscoverySeed", withExtension: "json") else {
            throw AnkrError.configurationMissing
        }
        var entries = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: url)).entries
            .filter { $0.network == chain.rawValue }
        // These bridge assets have no CoinGecko identity. Keep them outside the
        // CoinGecko-only discovery snapshot so its validation stays strict.
        if chain == .elysium {
            entries += [
                .init(network: chain.rawValue, reference: "0xb47c4c8f73f009cc0c0d3f92b388d13e293f0b65",
                    coinID: nil, name: "Bridged USDC", symbol: "USDC", decimals: 6, logo: nil),
                .init(network: chain.rawValue, reference: "0xba876237b0f021a6c6d852d6c26e107997cc5e81",
                    coinID: nil, name: "Wrapped HYPE", symbol: "WHYPE", decimals: 18, logo: nil)
            ].filter { core in !entries.contains { $0.reference.lowercased() == core.reference } }
        }
        guard !entries.isEmpty, entries.count <= 500 else { throw AnkrError.invalidResponse }
        var seen: Set<String> = []
        return try entries.map { entry in
            guard let decimals = entry.decimals,
                  entry.coinID != nil || isCoreAsset(entry.reference, chain: chain) else { throw AnkrError.invalidResponse }
            let token = try IndexedEVMToken(reference: entry.reference, name: entry.name,
                symbol: entry.symbol, decimals: decimals, logo: entry.logo)
            guard token.reference != "native", seen.insert(token.reference).inserted else { throw AnkrError.invalidResponse }
            return token
        }.sorted { $0.reference < $1.reference }
    }
}
