import Foundation

/// Search directory with cached public prices and provider verification.
/// Provider precision never replaces chain-validated signing metadata. Contract identity is always scoped to the documented chain ID.
/// https://docs.li.fi/api-reference/fetch-all-known-tokens
enum LifiTokenDiscovery {
    // Explicit zero removes the default minimum-price filter so low-priced
    // tokens remain discoverable.
    static let endpoint = "https://li.quest/v1/tokens?chainTypes=EVM,SVM,MVM,TVM&minPriceUSD=0"
    private static let networks = LifiTokenMetadata.networks
    private struct Envelope: Decodable { let tokens: [String: [LifiTokenMetadata.Response]] }

    static func decode(_ data: Data, observedAt: Date = Date()) throws -> [TokenDiscoveryEntry] {
        guard data.count <= 32_000_000 else { throw TokenDiscoveryError.malformed }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.tokens.count <= 256,
              envelope.tokens.values.reduce(0, { $0 + $1.count }) <= 100_000 else { throw TokenDiscoveryError.malformed }
        var entries: [String: TokenDiscoveryEntry] = [:]
        var precisions: [String: Int] = [:]
        var ambiguous: Set<String> = []
        for (key, tokens) in envelope.tokens {
            guard let chainID = UInt64(key), let network = networks[chainID] else { continue }
            for token in tokens {
                guard token.chainId == chainID, (0...255).contains(token.decimals) else { throw TokenDiscoveryError.malformed }
                // diagnostics: discovery-optional-listing. A public directory can
                // include native placeholders and unsupported/non-token identities.
                // These never become searchable contracts, just as in the primary.
                guard !isNativePlaceholder(token.address, network: network),
                      let name = ContractIdentity.clean(token.name),
                      let symbol = ContractIdentity.clean(token.symbol), symbol.utf8.count <= 64,
                      let reference = try? TokenDiscoveryNetworks.canonical(token.address, network: network),
                      reference != "native" else { continue }
                let metadata = try LifiTokenMetadata.normalize(token)
                // Keep provider precision separate from chain-validated precision.
                let entry = TokenDiscoveryEntry(network: network, reference: reference, coinID: nil,
                    name: name, symbol: symbol.uppercased(), decimals: nil, logo: metadata.logo, source: .lifi,
                    lifiPriceUSD: metadata.priceUSD, lifiVerificationStatus: metadata.verificationStatus,
                    lifiDecimals: token.decimals, lifiFetchedAt: observedAt)
                if let previous = entries[entry.id] {
                    if previous.name != entry.name || previous.symbol != entry.symbol || precisions[entry.id] != token.decimals {
                        ambiguous.insert(entry.id)
                    }
                } else {
                    entries[entry.id] = entry
                    precisions[entry.id] = token.decimals
                }
            }
        }
        for id in ambiguous { entries.removeValue(forKey: id) }
        guard !entries.isEmpty else { throw TokenDiscoveryError.malformed }
        return entries.values.sorted { $0.id < $1.id }
    }

    private static func isNativePlaceholder(_ address: String, network: String) -> Bool {
        if network == "solana" { return address == "11111111111111111111111111111111" }
        if network == "tron" { return address == "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb" }
        let lower = address.lowercased()
        return lower == "native" || lower == "0x" + String(repeating: "0", count: 40)
            || lower == "0x" + String(repeating: "e", count: 40)
    }
}
