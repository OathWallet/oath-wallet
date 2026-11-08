import Foundation
import Observation
import OathDiagnostics

struct OathBrowserBookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var url: URL
}

/// Explicitly saved URLs only; no browsing history or wallet-link bookmarks. UserDefaults
/// is scoped to this app and erased by the existing full-reset preferences step.
@MainActor @Observable final class OathBrowserBookmarks {
    static let storageKey = "browser.bookmarks.v1"
    static let maximumCount = 200
    private(set) var items: [OathBrowserBookmark] = []
    private(set) var loaded = false
    private(set) var failed = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    enum Failure: Error { case invalidData, invalidBookmark, limit }

    init(defaults: UserDefaults = .standard, key: String = storageKey) {
        self.defaults = defaults; self.key = key
    }

    func load() {
        do {
            guard let data = defaults.data(forKey: key) else { items = []; loaded = true; failed = false; return }
            guard data.count <= 2_000_000 else { throw Failure.invalidData }
            let decoded = try JSONDecoder().decode([OathBrowserBookmark].self, from: data)
            guard decoded.count <= Self.maximumCount, Set(decoded.map(\.id)).count == decoded.count,
                  decoded.allSatisfy({ item in
                      guard case .website = OathBrowserPolicy.destination(item.url) else { return false }
                      return item.title == OathBrowserPolicy.displayTitle(item.title, fallback: item.url.host ?? "")
                  }) else { throw Failure.invalidData }
            items = decoded; loaded = true; failed = false
        } catch {
            // Do not overwrite a damaged store with an empty collection.
            failed = true; loaded = false
            OathDiagnostics.record(error, component: "browser", operation: "load_bookmarks")
        }
    }

    func save(id: UUID? = nil, title: String, url: URL) throws {
        guard loaded, let canonical = OathBrowserPolicy.website(url.absoluteString),
              case .website = OathBrowserPolicy.destination(canonical) else { throw Failure.invalidBookmark }
        var next = items
        let existing = id.flatMap { id in next.firstIndex { $0.id == id } } ?? next.firstIndex { $0.url == canonical }
        let item = OathBrowserBookmark(id: existing.map { next[$0].id } ?? UUID(),
            title: OathBrowserPolicy.displayTitle(title, fallback: canonical.host ?? ""), url: canonical)
        if let existing { next[existing] = item }
        else {
            guard next.count < Self.maximumCount else { throw Failure.limit }
            next.append(item)
        }
        try commit(next)
    }

    func remove(_ id: UUID) throws { try commit(items.filter { $0.id != id }) }

    private func commit(_ next: [OathBrowserBookmark]) throws {
        guard loaded else { throw Failure.invalidData }
        // The UI records a propagated encoding failure exactly once.
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: key)
        items = next; failed = false
    }
}
