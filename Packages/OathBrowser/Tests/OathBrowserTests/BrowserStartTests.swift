import Foundation
import os
import Testing
@testable import OathBrowser

@Test func startMatchesOnlyTheRequestedPageInTheCurrentGroup() {
    let id = UUID()
    let open = URL(string: "https://EXAMPLE.org:443/")!
    let group = [(id: id, url: open)]
    let url = URL(string: "https://example.org")!
    var nav = BrowserNavigation()
    #expect(nav.opening(url, group: group, total: 8) == .resume(id))
    #expect(nav.opening(url, group: [], total: 8) == .limitReached)
    for suffix in ["/other", "/?q=1", "/#section"] {
        #expect(nav.opening(URL(string: "https://example.org" + suffix)!, group: group, total: 1) == .create)
    }
    nav.showStart(newTab: true)
    #expect(nav.path.isEmpty)
    #expect(nav.opening(url, group: group, total: 8) == .limitReached)
    #expect(nav.opening(url, group: group, total: 7) == .create)
    nav.showStart()
    #expect(nav.opening(url, group: group, total: 1) == .resume(id))
}

@Test func pageKeepsItsNavigationParentUntilTheUserEntersStart() {
    var nav = BrowserNavigation()
    nav.showPage()
    #expect(nav.path == [.page])
    nav.setPath([.tabs])
    nav.showPage()
    nav.showPage()
    #expect(nav.path == [.tabs, .page])
    nav.showStart()
    #expect(nav.path.isEmpty)
    nav.setPath([.connections("test-wallet")])
    nav.showStart()
    #expect(nav.path.isEmpty)
}

@Test func addingAFavoriteUpdatesExistingBookmarksAndUsesRestorableURLs() async throws {
    var archive = BrowserArchive()
    let legacy = BrowserPageRecord(url: URL(string: "https://example.org")!, title: "Old title")
    archive.bookmarks = [legacy]
    let added = archive.addBookmark(url: URL(string: "https://example.org/?code=sensitive#fragment")!, title: "  New title  ")
    let page = try #require(added)
    #expect(archive.bookmarks == [page])
    #expect(page.id == legacy.id && page.title == "New title")
    #expect(page.url.absoluteString == "https://example.org/")
    let invalid = archive.addBookmark(url: URL(string: "http://example.org")!, title: "")
    #expect(invalid == nil)
    let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let storage = BrowserStorage(url: folder.appendingPathComponent("browser.json"))
    try await storage.save(archive)
    #expect(await storage.load().bookmarks == [page])
    #expect(await storage.load().tabs.isEmpty)
}

@Test func recentsKeepTheLatestVisitAndRemovalSurvivesLateTitlesAndRelaunch() async throws {
    var archive = BrowserArchive()
    let home = URL(string: "https://example.org")!
    let samePage = URL(string: "https://EXAMPLE.org:443/?code=private#callback")!
    let other = URL(string: "https://example.org/other")!
    archive.recordVisit(to: home, title: "Home")
    let id = try #require(archive.history.first?.id)
    archive.recordVisit(to: other, title: "Other page")
    archive.recordVisit(to: samePage, title: nil)
    #expect(archive.history.map(\.title) == ["Home", "Other page"])
    #expect(archive.history.first?.id == id)
    #expect(archive.history.first?.url.query == nil && archive.history.first?.url.fragment == nil)

    let saved = archive.addBookmark(url: home, title: "")
    let favorite = try #require(saved)
    #expect(favorite.title == "Home" && !favorite.hasCustomTitle)
    let updated = archive.updatePageTitle("Updated title", for: home)
    #expect(updated)
    #expect(archive.bookmarks.first?.displayTitle == "Updated title")
    archive.removeVisit(id)
    let completed = archive.updatePageTitle("Final title", for: home)
    #expect(completed)
    #expect(archive.history.map(\.url) == [other])
    #expect(archive.bookmarks.first?.id == favorite.id)
    #expect(archive.bookmarks.first?.title == "Final title")

    let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let storage = BrowserStorage(url: folder.appendingPathComponent("browser.json"))
    try await storage.save(archive)
    let restored = await storage.load()
    #expect(restored.history.map(\.displayTitle) == ["Other page"])
    #expect(restored.bookmarks.first?.isCustomTitle == false)
}

@Test func clearingHistoryPersistsAllRemovalsAndPreservesOtherBrowserData() async throws {
    let home = URL(string: "https://example.org/")!
    var archive = BrowserArchive()
    for index in 0..<12 {
        archive.recordVisit(to: home.appendingPathComponent(String(index)), title: nil)
    }
    let page = try #require(archive.history.first)
    archive.addBookmark(url: page.url, title: "Saved page")
    archive.tabs = [page]
    archive.session = BrowserSession(selectedTabID: page.id, screen: .page)
    archive.permissions = [BrowserPermission(origin: try BrowserOrigin(home), walletID: "wallet",
                                             accountID: "account", address: "address", chainID: 1)]

    let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let storage = BrowserStorage(url: folder.appendingPathComponent("browser.json"))
    try await storage.save(archive)
    var saved = await storage.load()
    #expect(saved.history.count == 12)
    var expected = saved
    expected.history = []

    saved.clearHistory()
    _ = saved.updatePageTitle("Late page title", for: page.url)
    try await storage.save(saved)
    var restored = await storage.load()
    #expect(restored == expected)
    restored.recordVisit(to: page.url, title: "Visited again")
    #expect(restored.history.map(\.url) == [page.url])
}

@Test func olderBookmarksPickUpPageTitlesAndKeepUserNames() throws {
    let url = URL(string: "https://www.example.org")!
    let old = BrowserPageRecord(url: url, title: "www.example.org")
    let decoded = try JSONDecoder().decode(BrowserPageRecord.self, from: JSONEncoder().encode(old))
    #expect(!decoded.hasCustomTitle && decoded.displayTitle == "Example")
    var archive = BrowserArchive()
    archive.bookmarks = [decoded]
    let repaired = archive.updatePageTitle("Example & Company", for: url)
    #expect(repaired)
    #expect(archive.bookmarks.first?.displayTitle == "Example & Company")
    _ = archive.addBookmark(url: url, title: "My shortcut")
    _ = archive.addBookmark(url: url, title: "WebKit title", customTitle: false)
    let overwritten = archive.updatePageTitle("Another title", for: url)
    #expect(!overwritten)
    #expect(archive.bookmarks.first?.displayTitle == "My shortcut")
}

@Test func favoriteMarkupResolvesTitlesEntitiesBasePathsAndDeclaredIcons() {
    let html = """
    <html><head><base href="/assets/"><meta content="Social fallback" property="og:title">
    <title>Swaps &amp; Pools</title><link href="favicon.ico" rel="shortcut icon">
    <link rel="apple-touch-icon" href="https://cdn.example.org/app.png">
    <link rel="icon" href="https://localhost/private"><link rel="ICON" href="favicon.ico"></head></html>
    """
    let page = URL(string: "https://app.example.org/markets/")!
    let metadata = BrowserPageMetadata(html: Data(html.utf8), url: page, encoding: "UTF-8")
    #expect(metadata.title == "Swaps & Pools")
    #expect(metadata.icons.map(\.absoluteString) == ["https://cdn.example.org/app.png", "https://app.example.org/assets/favicon.ico"])
    let social = BrowserPageMetadata(html: Data("<meta property='og:title' content='Crème &amp; Co'>".utf8), url: page, encoding: "UTF-8")
    #expect(social.title == "Crème & Co")
}

private final class FavoriteIconProtocol: URLProtocol, @unchecked Sendable {
    static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let isPage = request.url?.path == "/article"
        let html = Data("<head><title>Publisher</title><link rel='icon' href='https://cdn.example.org/design/site.png'></head>".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": isPage ? "text/html" : "image/png"])!
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isPage ? html : png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func favoritesCacheConventionalAndPageDeclaredIcons() async throws {
    FavoriteIconProtocol.requests.withLock { $0.removeAll() }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FavoriteIconProtocol.self]
    let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let icons = BrowserFavoriteIcons(directory: folder, configuration: config)
    let origin = try BrowserOrigin(URL(string: "https://favorite.example/private-path?value=1")!)
    #expect(await icons.cached(for: origin) == nil)
    #expect(FavoriteIconProtocol.requests.withLock { $0.isEmpty })
    let image = try #require(await icons.iconForVisit(to: origin))
    #expect(await icons.cached(for: origin) == image)
    #expect(await BrowserFavoriteIcons(directory: folder).cached(for: origin) == image)
    #expect(await icons.iconForVisit(to: origin) == image)
    let requests = FavoriteIconProtocol.requests.withLock { $0 }
    #expect(requests.map { $0.url?.absoluteString } == ["https://favorite.example/favicon.ico"])
    #expect(requests[0].value(forHTTPHeaderField: "Cookie") == nil)
    await icons.keepOnly([origin])
    #expect(await icons.cached(for: origin) == image)
    await icons.keepOnly([])
    #expect(await icons.cached(for: origin) == nil)

    let page = URL(string: "https://publisher.example/article?code=private#fragment")!
    let metadata = await icons.metadata(for: page, needsTitle: true)
    #expect(metadata.title == "Publisher")
    let declaredIcon = try #require(metadata.icon)
    let publisher = try BrowserOrigin(page)
    #expect(await BrowserFavoriteIcons(directory: folder).cached(for: publisher) == declaredIcon)
    _ = await icons.metadata(for: page, needsTitle: false)
    let fetched = FavoriteIconProtocol.requests.withLock { Array($0.dropFirst()) }
    #expect(fetched.compactMap { $0.url?.absoluteString } == ["https://publisher.example/article", "https://cdn.example.org/design/site.png"])
    #expect(fetched.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Referer") == nil })
}
