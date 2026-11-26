import Foundation

/// Presentation belongs to the current visit to Browser. Saved tab metadata is
/// restored independently, so entering Start never mounts a website.
public struct BrowserNavigation: Equatable, Sendable {
    public enum Route: Hashable, Sendable {
        case tabs, page, connections(String)
    }
    public enum Opening: Equatable, Sendable {
        case resume(UUID), create, limitReached
    }

    public private(set) var path: [Route] = []
    private var requestsNewTab = false
    public init() {}

    public mutating func showStart(newTab: Bool = false) {
        path = []
        requestsNewTab = newTab
    }

    public mutating func setPath(_ path: [Route]) {
        self.path = path
        requestsNewTab = false
    }

    public mutating func showPage() {
        guard path.last != .page else { return }
        setPath(path.last == .tabs ? [.tabs, .page] : [.page])
    }

    public func opening(_ url: URL, group: [(id: UUID, url: URL)], total: Int) -> Opening {
        if !requestsNewTab, let tab = group.first(where: { BrowserPolicy.samePage($0.url, url) }) {
            return .resume(tab.id)
        }
        return total < BrowserPolicy.maximumTabs ? .create : .limitReached
    }
}

extension BrowserPolicy {
    static func samePage(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        // WebKit adds a slash to bare origins. Paths, queries and fragments still
        // identify individual pages and must match exactly.
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? 443) == (b.port ?? 443)
            && (a.percentEncodedPath.isEmpty ? "/" : a.percentEncodedPath) == (b.percentEncodedPath.isEmpty ? "/" : b.percentEncodedPath)
            && a.percentEncodedQuery == b.percentEncodedQuery && a.percentEncodedFragment == b.percentEncodedFragment
    }
}
