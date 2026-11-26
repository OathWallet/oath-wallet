import Foundation

public struct BrowserOrigin: Hashable, Codable, Sendable {
    public let host: String
    public let port: Int
    public var string: String { "https://" + host + (port == 443 ? "" : ":\(port)") }
    public init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty, host.count <= 253,
              !host.contains(":"), host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              host.contains("."), host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil,
              (1...65535).contains(url.port ?? 443) else { throw BrowserRPCError.invalidOrigin }
        self.host = host; port = url.port ?? 443
    }
}

public struct BrowserRPCError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    public init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    public static let invalidOrigin = Self(4100, "This page cannot connect to Oath.")
    public static let unauthorized = Self(4100, "Connect this account first.")
    public static let disconnected = Self(4900, "The page is no longer connected.")
    public static let rejected = Self(4001, "Request cancelled.")
    public static let unsupported = Self(4200, "This method is not supported by Oath.")
    public static let invalid = Self(-32602, "Invalid request parameters.")
    public static let busy = Self(-32002, "Another request is awaiting approval.")
}

public enum BrowserSearchEngine: String, CaseIterable, Sendable {
    case duckDuckGo, google, bing, brave

    public var name: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .brave: "Brave Search"
        }
    }

    public var homeURL: URL {
        switch self {
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .google: URL(string: "https://www.google.com/")!
        case .bing: URL(string: "https://www.bing.com/")!
        case .brave: URL(string: "https://search.brave.com/")!
        }
    }

    fileprivate func searchURL(for term: String) -> URL {
        var components = URLComponents(url: homeURL, resolvingAgainstBaseURL: false)!
        if self != .duckDuckGo { components.path = "/search" }
        components.queryItems = [URLQueryItem(name: "q", value: term)]
        // Search providers decode '+' as a space when reading form-style queries.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

public enum BrowserPolicy {
    public static let maximumTabs = 8
    public static let maximumLiveTabs = 3
    public static let maximumMessageBytes = 131_072
    public static let readMethods: Set<String> = ["net_version", "eth_blockNumber", "eth_getBalance", "eth_getCode",
        "eth_call", "eth_estimateGas", "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory",
        "eth_getTransactionCount", "eth_getTransactionReceipt", "eth_getTransactionByHash", "eth_getBlockByNumber", "eth_getBlockByHash"]
    public static let approvalMethods: Set<String> = ["eth_requestAccounts", "personal_sign", "eth_signTypedData_v4", "eth_sendTransaction", "wallet_switchEthereumChain", "wallet_requestPermissions"]
    public enum Destination: Equatable, Sendable {
        case website(URL)
        case webSearch(URL)

        public var url: URL {
            switch self {
            case .website(let url), .webSearch(let url): url
            }
        }
    }

    public static func destination(_ input: String) throws -> URL { try resolve(input).url }

    public static func resolve(_ input: String, searchEngine: BrowserSearchEngine = .duckDuckGo) throws -> Destination {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.properties.isBidiControl || $0.value < 32 }) else { throw BrowserRPCError.invalid }
        let looksLikeDomain = !text.contains(where: \.isWhitespace) && text.split(separator: "/").first?.contains(".") == true
        if text.contains("://") || looksLikeDomain {
            guard let url = URL(string: text.contains("://") ? text : "https://" + text) else { throw BrowserRPCError.invalid }
            _ = try BrowserOrigin(url); return .website(url)
        }
        if let scheme = URL(string: text)?.scheme, scheme != "https" { throw BrowserRPCError.invalid }
        return .webSearch(searchEngine.searchURL(for: text))
    }
    /// Never put WalletConnect secrets, auth callback parameters or fragments in restoration/history.
    public static func restorable(_ url: URL) -> URL? {
        guard url.absoluteString.utf8.count <= 4096, (try? BrowserOrigin(url)) != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let sensitive = ["uri", "token", "code", "state", "signature", "sig", "session", "key", "mnemonic", "password"]
        if parts.queryItems?.contains(where: { item in sensitive.contains { item.name.lowercased().contains($0) } || (item.value ?? "").lowercased().contains("wc:") }) == true { parts.query = nil }
        parts.fragment = nil
        return parts.url
    }
    public static func validatesRead(method: String, params: Data) -> Bool {
        guard readMethods.contains(method), params.count <= 65_536,
              let values = try? JSONSerialization.jsonObject(with: params) as? [Any], values.count <= 3 else { return false }
        switch method {
        case "net_version", "eth_blockNumber", "eth_gasPrice", "eth_maxPriorityFeePerGas": return values.isEmpty
        case "eth_getBlockByNumber", "eth_getBlockByHash":
            return values.count == 2 && values[0] is String && (values[1] as? NSNumber) == false
        case "eth_feeHistory":
            guard values.count >= 2, let count = values[0] as? String, count.hasPrefix("0x"),
                  let blocks = UInt64(count.dropFirst(2), radix: 16), blocks > 0, blocks <= 128 else { return false }
            if values.count == 3 {
                guard let rewards = values[2] as? [Double], rewards.count <= 10, rewards.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { return false }
            }
            return values[1] is String
        case "eth_call", "eth_estimateGas":
            guard !values.isEmpty, values.count <= 2, let tx = values[0] as? [String: Any], tx.count <= 8,
                  Set(tx.keys).isSubset(of: ["from", "to", "data", "input", "value", "gas", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas"]),
                  tx.values.allSatisfy({ $0 is String }) else { return false }
            return values.count == 1 || values[1] is String
        default: return !values.isEmpty && values.allSatisfy { $0 is String }
        }
    }
}

public struct BrowserPermission: Codable, Equatable, Sendable {
    public let origin: BrowserOrigin
    public let walletID: String
    public let accountID: String
    public let address: String
    public let chainID: UInt64
    public init(origin: BrowserOrigin, walletID: String, accountID: String, address: String, chainID: UInt64) {
        self.origin = origin; self.walletID = walletID; self.accountID = accountID; self.address = address; self.chainID = chainID
    }
}
public struct DAppRequestOrigin: Hashable, Sendable {
    public let tabID: UUID, documentID: UUID
    public let origin: BrowserOrigin
    public init(tabID: UUID, documentID: UUID, origin: BrowserOrigin) { self.tabID = tabID; self.documentID = documentID; self.origin = origin }
}
