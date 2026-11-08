import Foundation
import Testing
@testable import BrowserCore

struct BrowserPolicyTests {
    @Test func addressesAreCanonicalPublicHTTPS() {
        #expect(OathBrowserPolicy.website("  app.example.com/swap  ", allowsBareHost: true)?.absoluteString == "https://app.example.com/swap")
        #expect(OathBrowserPolicy.origin(URL(string: "https://EXAMPLE.com:443/path?q=a")) == "https://example.com")
        #expect(OathBrowserPolicy.origin(URL(string: "https://example.com:8443")) == "https://example.com:8443")
        #expect(OathBrowserPolicy.website("https://bücher.de")?.host == "xn--bcher-kva.de")
    }
    @Test(arguments: ["", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,a", "http://example.com", "https://user:pass@example.com", "https://example.com\\@evil.com", "https://127.0.0.1", "https://127.1", "https://0x7f.1", "https://[::1]", "https://app.local", "https://app.lan", "https://app.home", "https://app.internal", "https://localhost", "https://a..com", "https://-a.com", "https://a-.com", "https://example.com.", "https://examp\u{202E}le.com", "https://exam\nple.com", "https://example.com:0"])
    func invalidAddressesDoNotLoad(input: String) {
        #expect(OathBrowserPolicy.website(input, allowsBareHost: true) == nil)
    }
    @Test func URLAndTitleLimits() {
        #expect(OathBrowserPolicy.website("https://example.com/" + String(repeating: "a", count: 8192)) == nil)
        #expect(OathBrowserPolicy.displayTitle("\u{202E}\nWallet", fallback: "example.com") == "Wallet")
        #expect(OathBrowserPolicy.displayTitle(String(repeating: "x", count: 1000), fallback: "") == String(repeating: "x", count: 120))
        #expect(OathBrowserPolicy.displayTitle("  ", fallback: "example.com") == "example.com")
    }
    @Test func walletLinksCannotBecomeBookmarksOrWebLoads() {
        for raw in ["wc:topic@2?relay-protocol=irn&symKey=synthetic", "oathwallet://wc", "https://oathwallet.org/wc?uri=test"] {
            let url = URL(string: raw)!
            #expect(OathBrowserPolicy.destination(url) == .wallet(url))
        }
        #expect(OathBrowserPolicy.destination(URL(string: "https://oathwallet.org.evil.com/wc")!) == .website(URL(string: "https://oathwallet.org.evil.com/wc")!))
        #expect(OathBrowserPolicy.destination(URL(string: "evilapp://sign")!) == .blocked)
        #expect(OathBrowserPolicy.destination(URL(string: "tel:123")!) == .external(URL(string: "tel:123")!))
    }
    @Test func onlyActiveSameOriginMainFrameCanRequestWallet() {
        let url = URL(string: "https://app.example.com/swap")!
        #expect(OathBrowserPolicy.canRequestWallet(sourceIsMainFrame: true, sourceOrigin: "https://app.example.com", currentURL: url, active: true))
        for source in [nil, "http://app.example.com", "https://evil.com", "https://app.example.com:8443"] {
            #expect(!OathBrowserPolicy.canRequestWallet(sourceIsMainFrame: true, sourceOrigin: source, currentURL: url, active: true))
        }
        #expect(!OathBrowserPolicy.canRequestWallet(sourceIsMainFrame: false, sourceOrigin: "https://app.example.com", currentURL: url, active: true))
        #expect(!OathBrowserPolicy.canRequestWallet(sourceIsMainFrame: true, sourceOrigin: "https://app.example.com", currentURL: url, active: false))
        #expect(!OathBrowserPolicy.canRequestWallet(sourceIsMainFrame: true, sourceOrigin: "about:blank", currentURL: URL(string: "about:blank"), active: true))
    }
    @Test func browserPairingMustMatchPeer() {
        #expect(OathBrowserPolicy.matchesPeer(browserHost: "app.example.com", peerHost: "app.example.com"))
        #expect(!OathBrowserPolicy.matchesPeer(browserHost: "evil.com", peerHost: "app.example.com"))
        #expect(!OathBrowserPolicy.matchesPeer(browserHost: "", peerHost: ""))
        #expect(!OathBrowserPolicy.matchesPeer(browserHost: "app.example.com", peerHost: nil))
        #expect(OathBrowserPolicy.matchesPeer(browserHost: nil, peerHost: "app.example.com"))
        let alternatePort = OathBrowserPolicy.connectionAuthority(URL(string: "https://app.example.com:8443"))
        #expect(alternatePort == "app.example.com:8443")
        #expect(!OathBrowserPolicy.matchesPeer(browserHost: alternatePort, peerHost: "app.example.com"))
        #expect(OathBrowserPolicy.connectionAuthority(URL(string: "https://app.example.com:443/path")) == "app.example.com")
    }
}

@MainActor struct BrowserBookmarkTests {
    private func withStore(_ body: (UserDefaults, OathBrowserBookmarks) throws -> Void) rethrows {
        let name = "org.oathwallet.browser.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OathBrowserBookmarks(defaults: defaults)
        store.load()
        try body(defaults, store)
    }
    @Test func savesAndRestoresEditsAndDeletes() throws {
        try withStore { defaults, store in
            let url = URL(string: "https://example.com/swap")!
            try store.save(title: "Example", url: url)
            let id = store.items[0].id
            let reopened = OathBrowserBookmarks(defaults: defaults); reopened.load()
            #expect(reopened.items == store.items)
            try reopened.save(title: "Renamed", url: url)
            #expect(reopened.items.count == 1 && reopened.items[0].id == id)
            #expect(reopened.items[0].title == "Renamed")
            try reopened.remove(id)
            store.load(); #expect(store.items.isEmpty)
        }
    }
    @Test func corruptStoreCannotBeOverwrittenAndCanRecover() throws {
        try withStore { defaults, store in
            let damaged = Data("not json".utf8)
            defaults.set(damaged, forKey: OathBrowserBookmarks.storageKey)
            store.load(); #expect(store.failed && !store.loaded)
            #expect(throws: OathBrowserBookmarks.Failure.self) { try store.save(title: "X", url: URL(string: "https://example.com")!) }
            #expect(throws: OathBrowserBookmarks.Failure.self) { try store.remove(UUID()) }
            #expect(defaults.data(forKey: OathBrowserBookmarks.storageKey) == damaged)
            defaults.removeObject(forKey: OathBrowserBookmarks.storageKey)
            store.load(); #expect(store.loaded && !store.failed)
            try store.save(title: "X", url: URL(string: "https://example.com")!)
        }
    }
    @Test func invalidEntriesAreRejectedOnReadAndWrite() throws {
        try withStore { defaults, store in
            for raw in ["wc:topic@2", "https://oathwallet.org/wc?uri=test", "file:///etc/passwd", "http://example.com"] {
                #expect(throws: OathBrowserBookmarks.Failure.self) { try store.save(title: "X", url: URL(string: raw)!) }
                let record = OathBrowserBookmark(id: UUID(), title: "X", url: URL(string: raw)!)
                defaults.set(try JSONEncoder().encode([record]), forKey: OathBrowserBookmarks.storageKey)
                let reopened = OathBrowserBookmarks(defaults: defaults); reopened.load()
                #expect(reopened.failed && !reopened.loaded)
            }
        }
    }
    @Test func boundedCollectionAndSanitizedTitle() throws {
        try withStore { _, store in
            for i in 0..<OathBrowserBookmarks.maximumCount { try store.save(title: "\u{202E}Site", url: URL(string: "https://example.com/\(i)")!) }
            #expect(store.items.allSatisfy { $0.title == "Site" })
            #expect(throws: OathBrowserBookmarks.Failure.self) { try store.save(title: "Overflow", url: URL(string: "https://example.com/extra")!) }
            try store.save(title: "Edited", url: URL(string: "https://example.com/0")!)
            #expect(store.items.count == 200 && store.items[0].title == "Edited")
        }
    }
}

@MainActor private final class TestBrowserPage: OathBrowserPage {
    var active = false
    var clears = 0
    var history: [String] = []
    var form = ""
    func clear() { clears += 1; history = []; form = "" }
}

@MainActor struct BrowserTabTests {
    @Test func switchingPreservesPagesAndOnlySelectedPageIsActive() {
        let tabs = OathBrowserTabs(makePage: TestBrowserPage.init)
        tabs.setActive(true)
        let firstID = tabs.selectedID, first = tabs.current
        first.history = ["first", "second"]; first.form = "draft"
        let second = tabs.add()!
        #expect(!first.active && second.active)
        second.history = ["another"]
        tabs.select(firstID)
        #expect(tabs.current === first)
        #expect(first.active && !second.active)
        #expect(first.history == ["first", "second"] && first.form == "draft")
        #expect(second.history == ["another"])
        tabs.setActive(false)
        #expect(tabs.items.allSatisfy { !$0.page.active })
        tabs.select(tabs.items[1].id)
        #expect(tabs.items.allSatisfy { !$0.page.active })
    }

    @Test func closingSelectedBackgroundAndFinalTabsCleansUpExactlyOnce() {
        let tabs = OathBrowserTabs(makePage: TestBrowserPage.init)
        tabs.setActive(true)
        let firstID = tabs.selectedID, first = tabs.current
        let second = tabs.add()!, secondID = tabs.selectedID
        let third = tabs.add()!, thirdID = tabs.selectedID
        tabs.close(secondID)
        #expect(second.clears == 1 && !second.active)
        #expect(tabs.selectedID == thirdID && third.active)
        tabs.close(thirdID)
        #expect(third.clears == 1 && tabs.selectedID == firstID && first.active)
        tabs.close(firstID)
        #expect(first.clears == 1 && !first.active)
        #expect(tabs.items.count == 1 && tabs.current !== first && tabs.current.active)
        let blankID = tabs.selectedID
        tabs.close(firstID); tabs.select(thirdID)
        #expect(tabs.selectedID == blankID)
    }

    @Test func lockResetReleasesEveryOldPageAndRestoresOneBlankTab() {
        let tabs = OathBrowserTabs(makePage: TestBrowserPage.init)
        tabs.setActive(true)
        _ = tabs.add(); _ = tabs.add()
        let old = tabs.items.map(\.page)
        tabs.sheet = .tabs
        tabs.setActive(false); tabs.reset()
        #expect(old.allSatisfy { !$0.active && $0.clears == 1 })
        #expect(tabs.items.count == 1 && tabs.sheet == nil && !tabs.current.active)
        tabs.setActive(true)
        #expect(tabs.current.active && old.allSatisfy { !$0.active })
    }

    @Test func capacityCannotReplaceOrDiscardAnExistingPage() {
        let tabs = OathBrowserTabs(makePage: TestBrowserPage.init)
        for _ in 1..<OathBrowserTabs<TestBrowserPage>.maximumCount { #expect(tabs.add() != nil) }
        let selected = tabs.selectedID
        #expect(!tabs.canAdd && tabs.add() == nil)
        #expect(tabs.selectedID == selected && tabs.items.allSatisfy { $0.page.clears == 0 })
        tabs.close(tabs.items[0].id)
        #expect(tabs.canAdd && tabs.add() != nil)
    }
}
