import Foundation

/// The welcome capsule completes its local Receive showcase before advancing
/// through the remaining features. No catalog download is needed on first open.
struct OathFeatureRotation: Equatable, Sendable {
    enum Feature: Int, CaseIterable, Sendable {
        case receive, send, pay, request, multichain

        var title: OathStringKey {
            switch self {
            case .receive: .receive
            case .send: .send
            case .pay: .pay
            case .request: .requestCrypto
            case .multichain: .selfCustody
            }
        }

        var symbol: String? {
            switch self {
            case .receive, .multichain: nil
            case .send: "arrow.up.forward"
            case .pay: "qrcode.viewfinder"
            case .request: "arrow.down.message"
            }
        }

        var dwell: Duration {
            switch self {
            case .receive, .send, .pay: .seconds(2.4)
            case .request: .seconds(2.8)
            case .multichain: .seconds(3.2)
            }
        }
    }

    // Product showcase order: keep Bitcoin, Ethereum and Solana first. Reuse
    // the app's bundled chain identities and artwork, not provider rankings.
    static let receiveChains: [OathImportChain] = [
        .bitcoin, .ethereum, .solana, .bnb, .tron, .ton,
        .xrpl, .dogecoin, .litecoin, .sui, .avalanche, .polkadot
    ].filter(\.isEnabled)

    private(set) var feature: Feature = .receive
    private var chainIndex = 0

    var chain: OathImportChain? {
        feature == .receive ? Self.receiveChains[chainIndex] : nil
    }

    mutating func advance() {
        if feature == .receive, chainIndex + 1 < Self.receiveChains.count {
            chainIndex += 1
        } else {
            feature = Feature.allCases[(feature.rawValue + 1) % Feature.allCases.count]
            chainIndex = 0
        }
    }
}
