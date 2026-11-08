import Foundation
import Observation

@MainActor protocol OathBrowserPage: AnyObject {
    var active: Bool { get set }
    func clear()
}

enum OathBrowserSheet: String, Identifiable {
    case bookmark, bookmarks, pair, tabs
    var id: String { rawValue }
}

/// Keeps redirects/progress updates from replacing an address being typed.
/// Drafts are view-local and reset when the selected page or wallet changes.
struct OathBrowserAddressDraft {
    var text = ""
    private(set) var isEditing = false

    var target: URL? {
        guard let url = OathBrowserPolicy.website(text, allowsBareHost: true),
              case .website = OathBrowserPolicy.destination(url) else { return nil }
        return url
    }

    mutating func synchronize(url: URL?) {
        guard !isEditing else { return }
        text = url?.absoluteString ?? ""
    }

    mutating func setEditing(_ value: Bool, url: URL?) {
        isEditing = value
        if !value { synchronize(url: url) }
    }

    mutating func reset(url: URL?) {
        isEditing = false
        synchronize(url: url)
    }
}

/// Owns live pages, not just URL strings: switching tabs preserves each page's
/// navigation history and form state. No browsing history is written to disk.
@MainActor @Observable final class OathBrowserTabs<Page: OathBrowserPage> {
    struct Tab: Identifiable {
        let id: UUID
        let page: Page
    }
    static var maximumCount: Int { 12 }
    private(set) var items: [Tab]
    private(set) var selectedID: UUID
    private(set) var active = false
    var sheet: OathBrowserSheet?
    private(set) var addressFocusRequest = UUID()
    @ObservationIgnored private let makePage: @MainActor () -> Page

    init(makePage: @escaping @MainActor () -> Page) {
        self.makePage = makePage
        let first = Tab(id: UUID(), page: makePage())
        items = [first]; selectedID = first.id
    }

    var current: Page { items.first { $0.id == selectedID }!.page }
    var canAdd: Bool { items.count < Self.maximumCount }

    func focusAddress() { addressFocusRequest = UUID() }

    func setActive(_ value: Bool) {
        active = value
        for tab in items { tab.page.active = value && tab.id == selectedID }
    }

    @discardableResult func add() -> Page? {
        guard canAdd else { return nil } // Bounded WebKit processes; expected UI limit.
        current.active = false
        let tab = Tab(id: UUID(), page: makePage())
        items.append(tab); selectedID = tab.id
        tab.page.active = active
        return tab.page
    }

    func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        current.active = false
        selectedID = id
        current.active = active
    }

    func close(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let page = items[index].page
        page.active = false; page.clear()
        items.remove(at: index)
        if items.isEmpty {
            let blank = Tab(id: UUID(), page: makePage())
            items = [blank]; selectedID = blank.id
        } else if selectedID == id {
            selectedID = items[min(index, items.count - 1)].id
        }
        setActive(active)
    }

    func reset() {
        for tab in items { tab.page.active = false; tab.page.clear() }
        let blank = Tab(id: UUID(), page: makePage())
        items = [blank]; selectedID = blank.id; sheet = nil
        setActive(active)
    }
}
