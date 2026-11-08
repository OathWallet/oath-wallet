import Foundation

/// Public provider metadata, bound to a chain and canonical token identity.
/// Never a signing-decimal authority or a guarantee that a token is safe.
public struct LifiTokenMetadata: Codable, Equatable, Sendable {
    public let network: String
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public let priceUSD: String?
    public let verificationStatus: String?
    public var status: LifiVerificationStatus { LifiVerificationStatus(rawValue: verificationStatus ?? "") ?? .unknown }
    public var isVerified: Bool { status == .verified }

    public static let networks: [UInt64: String] = {
        var values = Dictionary(uniqueKeysWithValues: EVMSendNetwork.allCases
            .filter { !$0.isTestnet && $0 != .cronos }.map { ($0.chainID, $0.rawValue) })
        values[1_151_111_081_099_710] = "solana"
        values[9_270_000_000_000_000] = "sui"
        values[728_126_428] = "tron"
        return values
    }()

    public static func url(network: String, reference: String) -> URL? {
        guard reference != "native", let chain = networks.first(where: { $0.value == network })?.key,
              let canonical = try? TokenDiscoveryNetworks.canonical(reference, network: network),
              canonical != "native" else { return nil }
        var url = URLComponents(string: "https://li.quest/v1/token")!
        url.queryItems = [.init(name: "chain", value: String(chain)), .init(name: "token", value: canonical)]
        return url.url
    }

    public static func accepts(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "li.quest", url.path == "/v1/token",
              url.port == nil, url.fragment == nil, url.user == nil, url.password == nil,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 2, Set(query.map(\.name)) == ["chain", "token"],
              let chainValue = query.first(where: { $0.name == "chain" })?.value,
              let chain = UInt64(chainValue), let network = networks[chain],
              let ref = query.first(where: { $0.name == "token" })?.value,
              let canonical = try? TokenDiscoveryNetworks.canonical(ref, network: network),
              canonical != "native" else { return false }
        return true
    }

    struct Response: Decodable {
        let chainId: UInt64
        let address: String
        let name: String
        let symbol: String
        let decimals: Int
        let logoURI: String?
        let priceUSD: String?
        let verificationStatus: String?
    }

    public static func decode(_ data: Data, network: String, reference: String, decimals: Int) throws -> Self {
        guard data.count <= 2_000_000 else { throw TokenDiscoveryError.malformed }
        let row = try JSONDecoder().decode(Response.self, from: data)
        let value = try normalize(row)
        guard value.network == network, value.reference == (try TokenDiscoveryNetworks.canonical(reference, network: network)),
              value.decimals == decimals else { throw TokenDiscoveryError.malformed }
        return value
    }

    static func normalize(_ row: Response) throws -> Self {
        guard let network = networks[row.chainId], (0...255).contains(row.decimals),
              let name = ContractIdentity.clean(row.name), let symbol = ContractIdentity.clean(row.symbol),
              symbol.utf8.count <= 64 else { throw TokenDiscoveryError.malformed }
        let reference = try TokenDiscoveryNetworks.canonical(row.address, network: network)
        let logo = row.logoURI.flatMap { value -> String? in
            guard value.utf8.count <= 2048, let url = URL(string: value), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return value
        }
        let price = row.priceUSD.flatMap { value -> String? in
            guard value.utf8.count <= 256,
                  value.range(of: "^(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
                  let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN, number > 0 else { return nil }
            return NSDecimalNumber(decimal: number).stringValue
        }
        // Unknown/new provider statuses fail closed. Do not infer verification
        // from a logo, price, presence in a directory, or another provider.
        let status = row.verificationStatus.flatMap { ["verified", "unverified", "flagged"].contains($0) ? $0 : nil }
        return .init(network: network, reference: reference, name: name, symbol: symbol.uppercased(),
                     decimals: row.decimals, logo: logo, priceUSD: price, verificationStatus: status)
    }
}

public enum LifiVerificationStatus: String, Codable, Sendable, CaseIterable {
    case verified, unverified, flagged, unknown
}
