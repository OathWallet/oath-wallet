import Foundation

/// Untrusted page URLs never become scripts, local files, or wallet authority.
/// Public HTTPS navigation and explicitly requested app links are separate paths.
enum OathBrowserPolicy {
    enum Destination: Equatable { case website(URL), wallet(URL), external(URL), blocked }
    static let maximumURLBytes = 8_192

    static func website(_ raw: String, allowsBareHost: Bool = false) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maximumURLBytes,
              !text.unicodeScalars.contains(where: { $0.properties.isBidiControl || CharacterSet.controlCharacters.contains($0) }),
              !text.contains("\\") else { return nil }
        let input = allowsBareHost && !text.contains("://") && !text.contains(":") ? "https://" + text : text
        guard var parts = URLComponents(string: input), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, let host = parts.url?.host?.lowercased(),
              host.count <= 253, host.contains("."), !host.hasSuffix("."),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }),
              !host.contains(where: { $0.isWhitespace }), parts.port == nil || (1...65535).contains(parts.port!),
              !isLocal(host) else { return nil }
        parts.scheme = "https"
        // URL.host uses ASCII/Punycode, avoiding a misleading Unicode host in chrome.
        parts.host = host
        return parts.url
    }

    static func destination(_ url: URL) -> Destination {
        guard url.absoluteString.utf8.count <= maximumURLBytes else { return .blocked }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "wc" || scheme == "oathwallet" ||
            (scheme == "https" && url.host?.lowercased() == "oathwallet.org" && ["/wc", "/wc/"].contains(url.path)) {
            return .wallet(url) // The existing wallet-link parser validates protocol/expiry next.
        }
        if let site = website(url.absoluteString) { return .website(site) }
        if ["mailto", "tel", "sms", "facetime", "facetime-audio", "itms-apps"].contains(scheme),
           !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .external(url)
        }
        return .blocked
    }

    static func origin(_ url: URL?) -> String? {
        guard let url, let site = website(url.absoluteString), let host = site.host else { return nil }
        return "https://" + host.lowercased() + ((site.port == nil || site.port == 443) ? "" : ":\(site.port!)")
    }

    static func canRequestWallet(sourceIsMainFrame: Bool, sourceOrigin: String?, currentURL: URL?, active: Bool) -> Bool {
        active && sourceIsMainFrame && sourceOrigin != nil && sourceOrigin == origin(currentURL)
    }

    static func matchesPeer(browserHost: String?, peerHost: String?) -> Bool {
        guard let browserHost else { return true } // Existing scanner/external-link flow.
        return !browserHost.isEmpty && browserHost == peerHost
    }

    /// WalletConnect metadata permits the default HTTPS port. Retaining an
    /// alternate port makes a different web origin fail that same peer check.
    static func connectionAuthority(_ url: URL?) -> String? {
        origin(url).map { String($0.dropFirst("https://".count)) }
    }

    static func displayTitle(_ value: String, fallback: String) -> String {
        let safe = value.unicodeScalars.filter { !$0.properties.isBidiControl && !CharacterSet.controlCharacters.contains($0) }
        let title = String(String.UnicodeScalarView(safe)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? fallback : String(title.prefix(120))
    }

    private static func isLocal(_ host: String) -> Bool {
        if ["localhost", "local", "internal", "home", "lan"].contains(host.split(separator: ".").last.map(String.init) ?? "") { return true }
        // Browsing public sites does not grant navigation to IP literals, loopback,
        // LAN addresses, file URLs or custom scheme handlers inside the wallet.
        if host.contains(":") || host.first == "[" { return true }
        // Numeric/hex terminal labels are not public DNS suffixes. Reject odd
        // IPv4 representations too (127.1, 0x7f.1, octal and integer forms).
        guard let last = host.split(separator: ".").last else { return true }
        return last.allSatisfy(\.isNumber) || last.hasPrefix("0x")
    }
}
