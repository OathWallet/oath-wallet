import Foundation
import OathDiagnostics

/// Receiving rules belong to the network, never to the token whose detail
/// screen opened Receive. The catalog is illustrative, not an allowlist.
struct OathReceiveNetworkGuide: Sendable {
    let chain: OathImportChain
    var robinhoodIndexAvailable = false
    var arcIndexAvailable = false

    var supportsTokens: Bool { chain.supportsTokens }

    var notice: OathStringKey {
        switch chain {
        case .stellar, .xrpl: .receiveTrustlineNotice
        case .near: .receiveRegistrationNotice
        default: supportsTokens ? .receiveTokenNotice : .receiveNativeNotice
        }
    }

    var explanation: OathStringKey {
        switch chain {
        case .bitcoin, .bitcoincash, .dogecoin, .litecoin: .receiveNativeExplanation
        case .solana: .receiveSolanaExplanation
        case .stellar, .xrpl: .receiveTrustlineExplanation
        case .thorchain: .receiveThorchainExplanation
        case .near: .receiveNearExplanation
        case .polkadot: .receivePolkadotExplanation
        case .aptos: .receiveAptosExplanation
        case .sui: .receiveSuiExplanation
        case .ton: .receiveJettonExplanation
        case .tron: .receiveTronExplanation
        case .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .somnia, .story, .plasma, .worldchain, .elysium, .gnosis,
             .linea, .optimism, .polygon, .chiliz, .filecoin, .sei, .zerog, .iotex, .cronos, .celo, .monad, .unichain, .hyperevm, .robinhood, .scroll, .taiko, .telos, .xlayer: .receiveEVMExplanation
        }
    }

    var trackingExplanation: OathStringKey {
        if chain == .cronos { return .receiveManualTracking }
        if chain == .arc && !arcIndexAvailable { return .receiveManualTracking }
        if chain == .robinhood && !robinhoodIndexAvailable { return .receiveManualTracking }
        if chain == .bitcoin { return .bitcoinReceiveTracking }
        if !supportsTokens { return .receiveNativeTracking }
        if chain.isEVM || chain == .solana || chain == .tron || chain == .ton || chain == .aptos || chain == .sui || chain == .thorchain || chain == .near || chain == .xrpl || chain == .stellar || chain == .polkadot { return .receiveIndexedTracking }
        if chain.isEVM { return .receiveManualTracking }
        return .receiveDeferredTracking
    }
}

struct OathReceiveExample: Decodable, Identifiable, Equatable, Sendable {
    /// Includes the network and exact contract/mint/issuer identity. Symbols
    /// alone cannot distinguish bridged tokens or assets with the same name.
    let id: String
    let name: String
    let symbol: String
    let artwork: String
    let usesRedesignedArtwork: Bool?
}

struct OathReceiveExampleCatalog: Decodable, Sendable {
    let networks: [String: [OathReceiveExample]]
    private let redesigned: [String: String]
    private let providerImages: [String: String]

    private enum CodingKeys: String, CodingKey { case networks }

    init(networks: [String: [OathReceiveExample]]) {
        self.networks = networks
        var artwork: [String: String] = [:]
        var originals: [String: String] = [:]
        for (network, examples) in networks {
            guard let chain = OathImportChain(rawValue: network) else { continue }
            for example in examples where example.id.hasPrefix(network + ":") {
                if example.id == network + ":native" {
                    if example.usesRedesignedArtwork == true { artwork[network] = example.artwork }
                } else if example.usesRedesignedArtwork != true {
                    originals[chain.isEVM ? example.id.lowercased() : example.id] = example.artwork
                }
            }
        }
        redesigned = artwork
        providerImages = originals
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(networks: try container.decode([String: [OathReceiveExample]].self, forKey: .networks))
    }

    static let bundled = load(from: Bundle.main.url(forResource: "ReceiveAssets", withExtension: "json"))

    static func load(from url: URL?) -> Self {
        OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                guard let url else { throw DiagnosticFailure("receive_example_catalog_missing") }
                return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            } catch {
                OathDiagnostics.record(error, component: "receive", operation: "example_catalog_load")
                // The address and QR remain usable even if bundled artwork cannot load.
                return Self(networks: [:])
            }
        }
    }

    func examples(for chain: OathImportChain) -> [OathReceiveExample] {
        guard OathReceiveNetworkGuide(chain: chain).supportsTokens else { return [] }
        return Array((networks[chain.id] ?? []).prefix(10))
    }

    /// Only native coins retain custom chain artwork. Tokens always use their
    /// provider logos, even if an older catalog still carries a redesign flag.
    func redesignedArtwork(networkID: String, reference: String) -> String? {
        guard reference == "native", OathImportChain(rawValue: networkID) != nil else { return nil }
        return redesigned[networkID]
    }

    /// The installed provider original can fill the row while remote artwork is
    /// unavailable. Only case-insensitive EVM contracts fold case.
    func providerArtwork(networkID: String, reference: String) -> String? {
        guard let chain = OathImportChain(rawValue: networkID) else { return nil }
        return providerImages[networkID + ":" + (chain.isEVM ? reference.lowercased() : reference)]
    }
}
