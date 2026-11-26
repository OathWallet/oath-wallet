import Foundation
import Testing
@testable import OathBrowser

@Test func secureOriginAndAddressEntry() throws {
    #expect(try BrowserOrigin(URL(string: "https://example.com/path?q=a")!).string == "https://example.com")
    #expect(try BrowserOrigin(URL(string: "https://example.com:443")!) == BrowserOrigin(URL(string: "https://example.com")!))
    for value in ["http://example.com", "https://user:password@example.com", "https://localhost", "https://127.0.0.1", "file:///tmp/a", "javascript:alert(1)"] {
        #expect(throws: (any Error).self) { try BrowserPolicy.destination(value) }
    }
    #expect(try BrowserPolicy.destination("app.aave.com").absoluteString == "https://app.aave.com")
    #expect(try BrowserPolicy.destination("what is ethereum").host == "duckduckgo.com")
    #expect(try BrowserPolicy.resolve("1inch.com") == .website(URL(string: "https://1inch.com")!))
    #expect(try BrowserPolicy.resolve("duckduckgo.com") == .website(URL(string: "https://duckduckgo.com")!))
    let query = try BrowserPolicy.destination("how does a wallet work?")
    #expect(try BrowserPolicy.resolve("how does a wallet work?") == .webSearch(query))
    #expect(URLComponents(url: query, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "q", value: "how does a wallet work?")])
}
@Test func sensitiveCallbackNeverRestores() {
    let result = BrowserPolicy.restorable(URL(string: "https://example.com/login?code=secret&state=abc#token")!)
    #expect(result?.absoluteString == "https://example.com/login")
    #expect(BrowserPolicy.restorable(URL(string: "wc:secret")!) == nil)
}

@Test func selectedSearchEngineResolvesSubmittedQueries() throws {
    let providers: [(BrowserSearchEngine, String, String)] = [
        (.duckDuckGo, "duckduckgo.com", "/"), (.google, "www.google.com", "/search"),
        (.bing, "www.bing.com", "/search"), (.brave, "search.brave.com", "/search")
    ]
    #expect(providers.count == BrowserSearchEngine.allCases.count)
    let term = "C++ & café / 你好"
    for (engine, host, path) in providers {
        #expect(engine.homeURL.absoluteString == "https://" + host + "/")
        let destination = try BrowserPolicy.resolve(term, searchEngine: engine)
        guard case .webSearch(let url) = destination else { Issue.record("Expected a search"); continue }
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == host && parts.path == path)
        #expect(parts.queryItems == [.init(name: "q", value: term)])
        #expect(parts.percentEncodedQuery?.contains("%2B%2B") == true)
        #expect(try BrowserPolicy.resolve("example.org/path?q=1", searchEngine: engine) == .website(URL(string: "https://example.org/path?q=1")!))
    }
}

@Test func browserSessionRestoresSelectedPageAndOverviewFromDisk() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("browser.json")
    let store = BrowserStorage(url: url)
    let first = BrowserPageRecord(url: URL(string: "https://example.com")!)
    let selected = BrowserPageRecord(url: URL(string: "https://example.org")!)
    var archive = BrowserArchive()
    archive.tabs = [first, selected]
    archive.history = [first]
    for screen in [BrowserSession.Screen.page, .tabs] {
        archive.session = .init(selectedTabID: selected.id, screen: screen, showsLibrary: screen == .tabs)
        try await store.save(archive)
        #expect(await BrowserStorage(url: url).load().lastSession == archive.session)
    }
    archive.tabs.removeLast()
    try await store.save(archive)
    #expect(await store.load().lastSession?.selectedTabID == first.id)
    archive.tabs.removeAll()
    try await store.save(archive)
    #expect(await store.load().lastSession == .init(selectedTabID: nil, screen: .tabs, showsLibrary: true))
    archive.session = nil
    try await store.save(archive)
    #expect(await store.load().lastSession == nil)
}

@Test func legacyBrowserArchiveUsesMostRecentVisitedOpenSite() throws {
    let first = BrowserPageRecord(url: URL(string: "https://example.com")!)
    let recent = BrowserPageRecord(url: URL(string: "https://example.org")!)
    let old = ["tabs": [first, recent], "bookmarks": [], "history": [recent, first], "permissions": []]
    let archive = try JSONDecoder().decode(BrowserArchive.self, from: JSONEncoder().encode(old))
    #expect(archive.session == nil)
    #expect(archive.lastSession == .init(selectedTabID: recent.id, screen: .page))
    #expect(BrowserArchive().lastSession == nil)
}
@Test func browserReadRPCIsBounded() {
    #expect(!BrowserPolicy.validatesRead(method: "eth_sendRawTransaction", params: Data(#"["0xdead"]"#.utf8)))
    #expect(!BrowserPolicy.validatesRead(method: "eth_feeHistory", params: Data(#"["0x10000","latest",[]]"#.utf8)))
    #expect(BrowserPolicy.validatesRead(method: "eth_feeHistory", params: Data(#"["0x10","latest",[25,75]]"#.utf8)))
    #expect(!BrowserPolicy.validatesRead(method: "eth_call", params: Data(#"[{"to":"0x1","stateOverride":{}},"latest"]"#.utf8)))
    #expect(!BrowserPolicy.validatesRead(method: "eth_getBlockByNumber", params: Data(#"["latest",true]"#.utf8)))
    #expect(BrowserPolicy.validatesRead(method: "eth_getBlockByNumber", params: Data(#"["latest",false]"#.utf8)))
}
@Test func archiveIsBoundedAndExpiresHistory() throws {
    var archive = BrowserArchive()
    let time = Date(timeIntervalSince1970: 2_000_000_000)
    archive.tabs = (0..<20).map { BrowserPageRecord(url: URL(string: "https://example.com/\($0)")!) }
    archive.history = [BrowserPageRecord(url: URL(string: "https://example.com")!, visitedAt: time.addingTimeInterval(-31 * 86400))]
    archive.normalize(now: time)
    #expect(archive.tabs.count == 8)
    #expect(archive.history.isEmpty)
}
@Test func storageRoundTripAndClear() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let storage = BrowserStorage(url: folder.appendingPathComponent("browser.json"))
    var archive = BrowserArchive()
    archive.bookmarks = [.init(url: URL(string: "https://example.com")!, title: "Example")]
    try await storage.save(archive)
    #expect(await storage.load().bookmarks.count == 1)
    try await storage.save(.init())
    #expect(await storage.load().bookmarks.isEmpty)
}

@Test func tabPreviewsRestoreOnlyForTheSameRegularTabAndPage() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("browser.json")
    let storage = BrowserStorage(url: file)
    let first = URL(string: "https://example.com/first")!
    let second = URL(string: "https://example.com/second")!
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let tab = BrowserPageRecord(url: first)
    let image = try #require(BrowserTabPreview(url: first, jpeg: jpeg))
    #expect(BrowserTabPreview(url: URL(string: "https://example.com/?token=secret")!, jpeg: jpeg) == nil)
    #expect(BrowserTabPreview(url: first, jpeg: Data(count: BrowserTabPreview.maximumBytes + 1)) == nil)
    var archive = BrowserArchive()
    archive.tabs = [tab]
    // The private tab's ID is absent from the regular restoration archive.
    try await storage.save(archive, tabPreviews: [tab.id: image, UUID(): image])
    let freshStore = BrowserStorage(url: file)
    let restored = await freshStore.restoreTabs()
    #expect(restored.previews == [tab.id: image])
    archive.tabs[0].url = second
    try await freshStore.save(archive)
    #expect(await BrowserStorage(url: file).restoreTabs().previews.isEmpty)
    archive.tabs = [tab]
    try await freshStore.save(archive, tabPreviews: [tab.id: image])
    try await freshStore.save(.init())
    #expect(await BrowserStorage(url: file).restoreTabs().previews.isEmpty)
}
