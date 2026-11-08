import Foundation

/// A browsing filter can narrow a payment request, never expand its networks.
/// Nil means all enabled chains; it is independent of Home's saved asset filters.
struct OathAssetSearchScope: Hashable, Sendable {
    var chain: OathImportChain? = nil
    static let all = Self()

    func includes(networkID: String) -> Bool {
        guard let network = OathImportChain(rawValue: networkID), network.isEnabled else { return false }
        return chain == nil || chain == network
    }

    func networks(permitted: Set<OathImportChain>? = nil) -> Set<OathImportChain> {
        let enabled = Set(OathImportChain.enabledCases)
        let available = permitted.map { enabled.intersection($0) } ?? enabled
        return chain.map { available.intersection([$0]) } ?? available
    }
}
