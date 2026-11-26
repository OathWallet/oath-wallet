import SwiftUI
import WebKit
import Combine
import OathBrowser
import OathDiagnostics
import OathAnkr
import OathDatabase

private final class OathBrowserPageWebView: WKWebView {
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        if #available(iOS 26, *) {
            // Let the page scroll behind the bars, with its first line and fixed
            // website controls inside the visible viewport.
            var insets = obscuredContentInsets
            insets.top = safeAreaInsets.top
            insets.bottom = safeAreaInsets.bottom
            if obscuredContentInsets != insets { obscuredContentInsets = insets }
            if scrollView.contentInset.top != insets.top {
                let wasAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top
                scrollView.contentInset.top = insets.top
                if wasAtTop { scrollView.contentOffset.y = -scrollView.adjustedContentInset.top }
            }
        }
    }
}

@MainActor @Observable final class OathBrowserTab: Identifiable {
    let id: UUID
    let isPrivate: Bool
    var url: URL {
        didSet {
            guard oldValue != url else { return }
            preview = nil
            storedPreview = nil
            title = ""
        }
    }
    // WebKit can display a redirect or a warning before it commits a new document.
    var webViewURL: URL?
    var displayedURL: URL { webViewURL ?? url }
    var canBookmark: Bool { !isPrivate && ready && displayedURL == url }
    var title = ""
    var preview: UIImage?
    @ObservationIgnored weak var previewView: UIImageView?
    @ObservationIgnored var storedPreview: BrowserTabPreview?
    @ObservationIgnored var previewRequest: UUID?
    var chainID: UInt64 = 1
    var documentID = UUID()
    var ready = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var failure: String?
    var lastUsed = Date()
    @ObservationIgnored var webView: WKWebView?
    @ObservationIgnored var observations: [NSKeyValueObservation] = []
    init(id: UUID = UUID(), url: URL, isPrivate: Bool) { self.id = id; self.url = url; self.isPrivate = isPrivate }
}

@MainActor @Observable final class OathBrowserController: NSObject {
    var tabs: [OathBrowserTab] = []
    var selectedID: UUID?
    private(set) var privateMode = false
    var searchEngine: BrowserSearchEngine = .duckDuckGo
    private(set) var showsLibrary = false
    private(set) var navigation = BrowserNavigation()
    private(set) var openedFromPreview = false
    var isViewingPage: Bool { navigation.path.last == .page }
    var showsTabOverview: Bool { navigation.path.last == .tabs }
    var isReady: Bool { loaded && !clearingData }
    private var canInteractWithPage: Bool { isViewingPage && isForeground && !showsLibrary && session?.isUnlocked == true }
    var archive = BrowserArchive()
    var notice: OathStringKey?
    var privateWalletConnectURL: URL?
    var popupURL: URL?
    private var loaded = false
    private var clearingData = false
    var isForeground = true
    var review: OathBrowserReview?
    var preparing = false
    var signing = false
    var approvalCancelled = false
    @ObservationIgnored weak var session: OathWalletSession?
    @ObservationIgnored private var privateStore: WKWebsiteDataStore?
    @ObservationIgnored private var privatePermissions: [BrowserPermission] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var readTimes: [ContinuousClock.Instant] = []
    @ObservationIgnored private var bridgeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingReply: (([String: Any]) -> Void)?
    // SwiftUI's sheet binding observes this identity. Excluding it from
    // observation leaves the dApp waiting behind an invisible approval.
    var approvalID: UUID? {
        didSet { teardownApprovalID = approvalID }
    }
    // Deinitialization can run outside the main actor. Keep only the Sendable
    // gate token here so cleanup never invokes an observed property's getter.
    @ObservationIgnored private var teardownApprovalID: UUID?
    @ObservationIgnored var approvalOrigin: DAppRequestOrigin?
    @ObservationIgnored var approvalWalletID: String?
    @ObservationIgnored var approvalScope: HomeAccountSelection?
    @ObservationIgnored var preparationTask: Task<Void, Never>?
    private let storage: BrowserStorage
    private let iconCache: BrowserFavoriteIcons
    private(set) var favoriteImages: [BrowserOrigin: UIImage] = [:]
    @ObservationIgnored private var favoriteRequests: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingFavorites: [UUID] = []
    @ObservationIgnored private var iconPruneTask: Task<Void, Never>?
    var selected: OathBrowserTab? { tabs.first { $0.id == selectedID } }
    var groupTabs: [OathBrowserTab] { tabs.filter { $0.isPrivate == privateMode } }

    override init() {
        var folder = URL.applicationSupportDirectory.appendingPathComponent("OathBrowser", isDirectory: true)
        var icons = URL.cachesDirectory.appendingPathComponent("OathBrowserFavorites", isDirectory: true)
        #if DEBUG && targetEnvironment(simulator)
        if let scope = UserDefaults.standard.string(forKey: "oath.walletTestScope").flatMap(UUID.init(uuidString:)) {
            folder.appendPathComponent(scope.uuidString, isDirectory: true)
            icons.appendPathComponent(scope.uuidString, isDirectory: true)
        }
        #endif
        storage = BrowserStorage(url: folder.appendingPathComponent("browser-v1.json"))
        iconCache = BrowserFavoriteIcons(directory: icons)
        super.init()
    }
    deinit {
        preparationTask?.cancel()
        iconPruneTask?.cancel()
        for task in favoriteRequests.values { task.cancel() }
        // The last metadata write owns its snapshot and can finish after this controller.
        // A removed wallet/Home hierarchy must not leave the global approval gate owned.
        if let id = teardownApprovalID { Task { @MainActor in OathDAppApprovalGate.shared.release(id) } }
    }
    func load(session: OathWalletSession) async {
        self.session = session
        guard !loaded else { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { await restore(session: session) }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func restore(session: OathWalletSession) async {
        let (saved, previews) = await storage.restoreTabs()
        archive = saved; archive.permissions = []
        pruneFavoriteIcons()
        tabs = saved.tabs.map { record in
            let tab = OathBrowserTab(id: record.id, url: record.url, isPrivate: false)
            tab.title = record.title
            tab.lastUsed = record.visitedAt
            if let preview = previews[record.id] {
                if let image = UIImage(data: preview.jpeg) {
                    tab.storedPreview = preview
                    tab.preview = image
                } else {
                    OathDiagnostics.record(DiagnosticFailure("Unreadable tab preview"), component: "browser", operation: "decode_tab_preview")
                }
            }
            return tab
        }
        selectedID = saved.lastSession?.selectedTabID
        do {
            if !saved.permissions.isEmpty, let walletID = session.displayedProfile?.id.uuidString {
                let database = try await session.vault.database()
                let accounts = try await database.walletConnectAccounts(walletID: walletID, scope: .connection)
                if session.displayedProfile?.id.uuidString == walletID {
                    archive.permissions = saved.permissions.filter { permission in
                        permission.walletID == walletID && accounts.contains { account in
                            account.id == permission.accountID && account.address.lowercased() == permission.address.lowercased() &&
                            account.supportsActiveUse && EVMSendNetwork(rawValue: account.networkID)?.chainID == permission.chainID
                        }
                    }
                }
            }
        } catch { OathDiagnostics.record(error, component: "browser", operation: "restore_permissions") }
        loaded = true
    }

    func showStart(newTab: Bool = false) {
        if isViewingPage { capturePreview(selected) }
        cancelApproval()
        popupURL = nil
        privateWalletConnectURL = nil
        showsLibrary = false
        notice = nil
        openedFromPreview = false
        navigation.showStart(newTab: newTab)
    }

    func leaveBrowser() {
        showStart()
        suspend()
    }

    func setPath(_ path: [BrowserNavigation.Route]) {
        guard path != navigation.path, isForeground, session?.isUnlocked == true else { return }
        if path.isEmpty { showStart(); return }
        if path.last == .tabs { showTabOverview(); return }
        navigation.setPath(path)
    }

    func goBack() {
        setPath(Array(navigation.path.dropLast()))
    }

    func presentLibrary(_ presented: Bool) {
        guard showsLibrary != presented else { return }
        if presented { cancelApproval() }
        showsLibrary = presented
        save(immediately: true)
    }
    func open(_ url: URL, newTab: Bool = false, network: String? = nil) {
        guard isReady, session?.isUnlocked == true else { return }
        guard let origin = try? BrowserOrigin(url) else { notice = .browserInvalidAddress; return }
        if !isViewingPage && !newTab {
            let group = groupTabs.sorted { $0.lastUsed > $1.lastUsed }.map { (id: $0.id, url: $0.url) }
            switch navigation.opening(url, group: group, total: tabs.count) {
            case .resume(let id):
                if let tab = tabs.first(where: { $0.id == id }) { select(tab) }
                return
            case .limitReached: notice = .browserTabLimit; return
            case .create: break
            }
        }
        if isViewingPage, !newTab, let tab = selected, tab.isPrivate == privateMode {
            cancelApproval(tabID: tab.id)
            if origin != (try? BrowserOrigin(tab.url)) { tab.ready = false }
            tab.lastUsed = .now
            if let network, let value = EVMSendNetwork(rawValue: network), !value.isTestnet { tab.chainID = value.chainID }
            if let web = tab.webView { web.load(URLRequest(url: url)) }
            else { tab.url = url }
        } else {
            guard tabs.count < BrowserPolicy.maximumTabs else { notice = .browserTabLimit; return }
            if isViewingPage { capturePreview(selected) }
            let tab = OathBrowserTab(url: url, isPrivate: privateMode)
            if let network, let value = EVMSendNetwork(rawValue: network), !value.isTestnet { tab.chainID = value.chainID }
            tabs.append(tab); selectedID = tab.id
        }
        if !isViewingPage || newTab { openedFromPreview = false }
        navigation.showPage()
        save(immediately: true)
    }
    private func resolveAddress(_ text: String) -> BrowserPolicy.Destination? {
        do { return try BrowserPolicy.resolve(text, searchEngine: searchEngine) }
        catch {
            // diagnostics: browser-address-validation
            notice = .browserInvalidAddress
            return nil
        } // Expected address-field validation; never report input.
    }
    func navigate(_ text: String) {
        if let destination = resolveAddress(text) { open(destination.url) }
    }
    func select(_ tab: OathBrowserTab, fromPreview: Bool = false) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if selectedID != tab.id {
            if isViewingPage { capturePreview(selected) }
            cancelApproval()
        }
        openedFromPreview = fromPreview
        selectedID = tab.id; privateMode = tab.isPrivate; tab.lastUsed = .now
        navigation.showPage()
        if !tab.isPrivate, tab.ready { archive.recordVisit(to: tab.url, title: tab.title) }
        save(immediately: true)
    }
    func close(_ tab: OathBrowserTab) {
        cancelApproval(tabID: tab.id); destroy(tab)
        tabs.removeAll { $0.id == tab.id }
        let closedSelection = selectedID == tab.id
        if closedSelection { selectedID = groupTabs.last?.id }
        if !tabs.contains(where: \.isPrivate) { privateStore = nil; privatePermissions = [] }
        // Closing an inactive tab must not navigate or change the library's mode.
        if closedSelection && isViewingPage {
            if let selected { select(selected) }
            else { showTabOverview() }
        }
        save(immediately: true)
    }
    func walletChanged() {
        cancelApproval()
        if case .connections = navigation.path.last { showStart() }
        archive.permissions = []; privatePermissions = []; save()
        for tab in tabs { publishState(tab) }
    }
    func locked() {
        suspend()
        bridgeTasks.values.forEach { $0.cancel() }; bridgeTasks.removeAll()
        for tab in tabs {
            tab.previewRequest = nil
            if tab.isPrivate { tab.preview = nil }
            tab.webView?.stopLoading()
            publishState(tab)
        }
    }
    func suspend() {
        guard isForeground else { return }
        isForeground = false
        cancelApproval()
        popupURL = nil
        privateWalletConnectURL = nil
        save(immediately: true)
    }
    func bookmark(_ tab: OathBrowserTab) {
        guard tab.canBookmark else { return }
        addFavorite(url: tab.url, name: tab.title, customTitle: false)
    }

    func addFavorite(url: URL, name: String, customTitle: Bool = true) {
        guard isReady, !privateMode, let saved = archive.addBookmark(url: url, title: name, customTitle: customTitle) else { return }
        save(immediately: true)
        pruneFavoriteIcons()
        enqueueFavoriteMetadata(saved.id)
    }

    func removeBookmark(_ id: UUID) {
        archive.bookmarks.removeAll { $0.id == id }
        save(immediately: true)
        pruneFavoriteIcons()
    }

    func removeVisit(_ id: UUID) {
        archive.removeVisit(id)
        save(immediately: true)
    }

    func clearHistory() {
        guard isReady, !privateMode else { return }
        archive.clearHistory()
        save(immediately: true)
    }

    private func pruneFavoriteIcons() {
        let origins = Set(archive.bookmarks.compactMap { try? BrowserOrigin($0.url) })
        favoriteImages = favoriteImages.filter { origins.contains($0.key) }
        let ids = Set(archive.bookmarks.map(\.id))
        pendingFavorites.removeAll { !ids.contains($0) }
        for id in favoriteRequests.keys.filter({ !ids.contains($0) }) {
            favoriteRequests[id]?.cancel()
        }
        iconPruneTask?.cancel()
        iconPruneTask = Task { [iconCache] in await iconCache.keepOnly(origins) }
    }

    func loadFavorite(_ page: BrowserPageRecord) async {
        guard !privateMode, session?.isUnlocked == true, let origin = try? BrowserOrigin(page.url) else { return }
        if favoriteImages[origin] == nil, let data = await iconCache.cached(for: origin),
           !Task.isCancelled, !privateMode, archive.bookmarks.contains(where: { $0.id == page.id }) {
            favoriteImages[origin] = UIImage(data: data)
        }
        guard !Task.isCancelled, !privateMode, let saved = archive.bookmarks.first(where: { $0.id == page.id }),
              favoriteImages[origin] == nil || (!saved.hasCustomTitle && BrowserPageRecord.pageTitle(saved.title, for: saved.url) == nil),
              saved.metadataAttemptedAt.map({ Date.now.timeIntervalSince($0) >= 86_400 }) ?? true else { return }
        enqueueFavoriteMetadata(saved.id)
    }

    private func enqueueFavoriteMetadata(_ id: UUID) {
        guard favoriteRequests[id] == nil, !pendingFavorites.contains(id) else { return }
        pendingFavorites.append(id)
        fetchPendingFavorites()
    }

    private func fetchPendingFavorites() {
        while favoriteRequests.count < 3, !pendingFavorites.isEmpty {
            let id = pendingFavorites.removeFirst()
            guard let page = archive.bookmarks.first(where: { $0.id == id }), let origin = try? BrowserOrigin(page.url) else { continue }
            let needsTitle = !page.hasCustomTitle && BrowserPageRecord.pageTitle(page.title, for: page.url) == nil
            favoriteRequests[id] = Task { [weak self, iconCache] in
                let metadata = await OathDiagnostics.$operationID.withValue(UUID()) {
                    await iconCache.metadata(for: page.url, needsTitle: needsTitle)
                }
                guard let self else { return }
                defer { favoriteRequests[id] = nil; fetchPendingFavorites() }
                guard !Task.isCancelled, let i = archive.bookmarks.firstIndex(where: { $0.id == id }) else { return }
                if let icon = metadata.icon { favoriteImages[origin] = UIImage(data: icon) }
                if let title = metadata.title, !archive.bookmarks[i].hasCustomTitle,
                   BrowserPageRecord.pageTitle(archive.bookmarks[i].title, for: page.url) == nil {
                    archive.bookmarks[i].isCustomTitle = false
                    archive.bookmarks[i].title = title
                }
                archive.bookmarks[i].metadataAttemptedAt = .now
                save(immediately: true)
            }
        }
    }
    func clearBrowsingData() async {
        guard !clearingData else { return }
        clearingData = true
        cancelApproval()
        for tab in tabs { destroy(tab) }
        tabs = []
        selectedID = nil
        navigation.showStart()
        showsLibrary = false
        privateMode = false
        archive.session = nil
        privateStore = nil; privatePermissions = []; archive.tabs = []; archive.permissions = []
        archive.clearHistory()
        save(immediately: true)
        await saveTask?.value
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        clearingData = false
    }
    func permission(_ tab: OathBrowserTab) -> BrowserPermission? {
        guard let session, session.isUnlocked, !session.changingWallet, !session.resetting,
              let origin = try? BrowserOrigin(tab.url), let walletID = session.displayedProfile?.id.uuidString else { return nil }
        return (tab.isPrivate ? privatePermissions : archive.permissions).first {
            $0.origin == origin && $0.walletID == walletID && $0.chainID == tab.chainID
        }
    }
    func grant(_ permission: BrowserPermission, tab: OathBrowserTab) {
        if tab.isPrivate {
            privatePermissions.removeAll { $0.origin == permission.origin && $0.walletID == permission.walletID }
            privatePermissions.insert(permission, at: 0)
            privatePermissions = Array(privatePermissions.prefix(200))
        } else {
            archive.permissions.removeAll { $0.origin == permission.origin && $0.walletID == permission.walletID }
            archive.permissions.insert(permission, at: 0); save()
        }
        tab.chainID = permission.chainID; publishState(tab)
    }
    func disconnect(_ tab: OathBrowserTab) {
        guard let origin = try? BrowserOrigin(tab.url) else { return }
        cancelApproval(tabID: tab.id)
        if tab.isPrivate { privatePermissions.removeAll { $0.origin == origin } }
        else { archive.permissions.removeAll { $0.origin == origin }; save() }
        for peer in tabs where peer.isPrivate == tab.isPrivate && (try? BrowserOrigin(peer.url)) == origin { publishState(peer) }
    }
    func confirmPrivateWalletConnect() {
        guard let url = privateWalletConnectURL else { return }
        privateWalletConnectURL = nil; OathWalletLinkInbox.shared.receive(url, browserHost: OathBrowserPolicy.connectionAuthority(selected?.url))
    }
    func save(immediately: Bool = false) {
        guard loaded else { return }
        let normalTabs = tabs.filter { !$0.isPrivate }
        archive.tabs = normalTabs.compactMap { tab in
            BrowserPolicy.restorable(tab.url).map { .init(id: tab.id, url: $0, title: tab.title, visitedAt: tab.lastUsed) }
        }
        if !privateMode, isViewingPage || showsTabOverview {
            let normalID = selected?.isPrivate == false ? selectedID : archive.session?.selectedTabID
            archive.session = BrowserSession(selectedTabID: normalID, screen: isViewingPage ? .page : .tabs)
        }
        let previews = Dictionary(uniqueKeysWithValues: normalTabs.compactMap { tab in tab.storedPreview.map { (tab.id, $0) } })
        archive.normalize()
        saveTask?.cancel()
        let value = archive, store = storage
        saveTask = Task {
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
                try await store.save(value, tabPreviews: previews)
            }
            catch is CancellationError { }
            catch {
                // diagnostics: browser-storage-propagation
                // BrowserStorage records a privacy-safe error at the file boundary.
            }
        }
    }
    func showTabOverview() {
        guard session?.isUnlocked == true else { return }
        if isViewingPage { capturePreview(selected) }
        cancelApproval()
        popupURL = nil
        privateWalletConnectURL = nil
        navigation.setPath([.tabs])
        save(immediately: true)
    }

    func selectTabGroup(isPrivate: Bool) {
        privateMode = isPrivate
        save(immediately: true)
    }

    private func capturePreview(_ tab: OathBrowserTab?) {
        guard let tab, let web = tab.webView, web.window != nil, !web.bounds.isEmpty,
              tab.ready, tab.failure == nil, let url = web.url, url == tab.url,
              isForeground, session?.isUnlocked == true, tab.previewRequest == nil else { return }
        // Snapshot the visible website, excluding the space occupied by either toolbar.
        var viewport = web.safeAreaLayoutGuide.layoutFrame.intersection(web.bounds)
        guard !viewport.isEmpty else { return }
        viewport.size.height = min(viewport.height, viewport.width * 1.4)
        let document = tab.documentID
        let request = UUID()
        tab.previewRequest = request
        let configuration = WKSnapshotConfiguration()
        configuration.rect = viewport
        configuration.snapshotWidth = NSNumber(value: Double(min(viewport.width, 448 / max(1, web.traitCollection.displayScale))))
        configuration.afterScreenUpdates = false
        web.takeSnapshot(with: configuration) { [weak self, weak web, weak tab] image, error in
            guard let self, let tab, tab.previewRequest == request else { return }
            tab.previewRequest = nil
            guard let web, tab.webView === web, tab.documentID == document, tab.url == url,
                  tab.ready, isForeground, session?.isUnlocked == true else { return }
            if let error {
                OathDiagnostics.record(DiagnosticFailure("WebKit tab snapshot failed"), component: "browser",
                                       operation: "capture_tab_preview", context: ["code": String((error as NSError).code)])
                return
            }
            guard let image else { return }
            tab.preview = image
            if !tab.isPrivate, BrowserPolicy.restorable(url) == url,
               let data = image.jpegData(compressionQuality: 0.7), let preview = BrowserTabPreview(url: url, jpeg: data),
               preview != tab.storedPreview {
                tab.storedPreview = preview
                save()
            }
        }
    }
    func ensureWebView(_ tab: OathBrowserTab) -> WKWebView {
        if let existing = tab.webView { return existing }
        let config = WKWebViewConfiguration()
        if tab.isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            config.websiteDataStore = privateStore!
        } else { config.websiteDataStore = .default() }
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addScriptMessageHandler(OathBrowserMessageRelay(self), contentWorld: .page, name: "oathWallet")
        config.userContentController.addUserScript(WKUserScript(source: BrowserProviderScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web: WKWebView = OathBrowserPageWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false; web.backgroundColor = OathSurfaceColors.groupedCanvas
        if #available(iOS 26, *) {
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.scrollView.topEdgeEffect.style = .soft
            web.scrollView.bottomEdgeEffect.isHidden = true
        }
        tab.webView = web
        tab.observations = [web.observe(\.estimatedProgress, options: [.new]) { [weak tab, weak web] _, _ in
            Task { @MainActor in
                guard let tab, let web, tab.webView === web else { return }
                tab.progress = web.estimatedProgress
            }
        }]
        for key in [\WKWebView.canGoBack, \.canGoForward] {
            tab.observations.append(web.observe(key, options: [.initial, .new]) { [weak tab, weak web] _, _ in
                Task { @MainActor in
                    guard let tab, let web, tab.webView === web else { return }
                    tab.canGoBack = web.canGoBack
                    tab.canGoForward = web.canGoForward
                }
            })
        }
        tab.observations.append(web.observe(\.url, options: [.initial, .new]) { [weak self, weak tab, weak web] _, _ in
            Task { @MainActor in
                guard let self, let web, let tab, tab.webView === web else { return }
                tab.webViewURL = web.url
                // Only adopt same-document history after WebKit has made it current.
                guard tab.ready, !web.isLoading, let url = web.url, tab.url != url,
                      web.backForwardList.currentItem?.url == url,
                      let origin = try? BrowserOrigin(url), origin == (try? BrowserOrigin(tab.url)) else { return }
                tab.url = url
                tab.title = BrowserPageRecord.pageTitle(web.title, for: url) ?? ""
                if !tab.isPrivate {
                    self.archive.recordVisit(to: url, title: tab.title)
                    self.archive.updatePageTitle(tab.title, for: url)
                    self.save()
                }
            }
        })
        tab.observations.append(web.observe(\.title, options: [.new]) { [weak self, weak tab, weak web] _, _ in
            Task { @MainActor in
                guard let web, let tab, tab.webView === web else { return }
                self?.updateDocumentTitle(tab, from: web)
            }
        })
        // Start the first navigation when the native destination mounts. Selecting
        // a live tab reuses its document, scroll position and back/forward list.
        web.load(URLRequest(url: tab.url))
        trimWebViews()
        return web
    }
    private func updateDocumentTitle(_ tab: OathBrowserTab, from web: WKWebView) {
        guard tab.ready, web.url == tab.url, let title = BrowserPageRecord.pageTitle(web.title, for: tab.url) else { return }
        let tabChanged = tab.title != title
        tab.title = title
        if !tab.isPrivate {
            let archiveChanged = archive.updatePageTitle(title, for: tab.url)
            if tabChanged || archiveChanged { save() }
        }
    }
    private func trimWebViews() {
        let inactive = tabs.filter { $0.id != selectedID && $0.id != approvalOrigin?.tabID && $0.webView != nil }.sorted { $0.lastUsed < $1.lastUsed }
        var count = tabs.filter { $0.webView != nil }.count
        for tab in inactive where count > BrowserPolicy.maximumLiveTabs { destroy(tab); count -= 1 }
    }
    private func destroy(_ tab: OathBrowserTab) {
        tab.previewRequest = nil
        tab.observations = []; tab.webView?.stopLoading()
        tab.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "oathWallet", contentWorld: .page)
        tab.webView?.navigationDelegate = nil; tab.webView?.uiDelegate = nil; tab.webView = nil; tab.ready = false; tab.documentID = UUID()
        tab.webViewURL = nil
    }
    func publishState(_ tab: OathBrowserTab) {
        guard tab.ready, let web = tab.webView else { return }
        let grant = permission(tab)
        let state: [String: Any] = ["accounts": grant.map { [$0.address] } ?? [], "chainId": "0x" + String(tab.chainID, radix: 16), "connected": grant != nil]
        guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.dispatchEvent(new CustomEvent('oath:state',{detail:" + json + "}));") { _, error in
            // Navigation/lock may remove the document during delivery; no page content is logged.
            if let error, (error as NSError).code != WKError.webViewInvalidated.rawValue {
                OathDiagnostics.record(DiagnosticFailure("Browser event delivery failed"), component: "browser", operation: "provider_event")
            }
        }
    }
    private func tab(for web: WKWebView) -> OathBrowserTab? { tabs.first { $0.webView === web } }
}

extension OathBrowserController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let tab = tab(for: webView), let url = action.request.url else { decisionHandler(.cancel); return }
        if let route = OathWalletLink.parse(url), route.isWalletConnect {
            guard action.sourceFrame.isMainFrame, tab.id == selectedID, canInteractWithPage, approvalID == nil else { decisionHandler(.cancel); return }
            if tab.isPrivate { privateWalletConnectURL = url } else { OathWalletLinkInbox.shared.receive(url, browserHost: OathBrowserPolicy.connectionAuthority(tab.url)) }
            decisionHandler(.cancel); return
        }
        guard url.scheme == "https", url.user == nil, url.password == nil else {
            if canInteractWithPage, tab.id == selectedID, action.navigationType == .linkActivated,
               ["mailto", "tel"].contains(url.scheme) { UIApplication.shared.open(url) }
            decisionHandler(.cancel); return
        }
        if action.targetFrame?.isMainFrame != false, (try? BrowserOrigin(url)) == nil { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        cancelApproval(tabID: tab.id); tab.ready = false; tab.documentID = UUID(); tab.failure = nil
        tab.previewRequest = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView), let url = webView.url else { return }
        tab.url = url; tab.ready = (try? BrowserOrigin(url)) != nil
        tab.title = ""
        if tab.ready, !tab.isPrivate {
            archive.recordVisit(to: url, title: nil)
            save()
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView), tab.ready, let url = webView.backForwardList.currentItem?.url,
              url == webView.url else { return }
        if tab.url != url, !tab.isPrivate { archive.recordVisit(to: url, title: webView.title) }
        tab.url = url; tab.progress = 1
        tab.canGoBack = webView.canGoBack; tab.canGoForward = webView.canGoForward; tab.lastUsed = .now
        updateDocumentTitle(tab, from: webView)
        if !tab.isPrivate { save() }
        publishState(tab)
        capturePreview(tab)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    private func failed(_ web: WKWebView, error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled, let tab = tab(for: web) else { return } // Expected replacement/stop.
        tab.failure = "This page couldn’t load. Check your connection and try again."; tab.progress = 1
        // NSError userInfo and website URLs are deliberately excluded.
        OathDiagnostics.record(DiagnosticFailure("Browser navigation failed"), component: "browser", operation: "navigation", context: ["code": String((error as NSError).code)])
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        cancelApproval(tabID: tab.id); tab.ready = false; tab.documentID = UUID(); tab.failure = "This tab was interrupted. Reload to continue."
        OathDiagnostics.record(DiagnosticFailure("Web content process terminated"), component: "browser", operation: "web_process")
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        close(tab)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url, (try? BrowserOrigin(url)) != nil, action.sourceFrame.isMainFrame, canInteractWithPage, tab(for: webView)?.id == selectedID else { return nil }
        popupURL = url // Explicit user choice; no background popup creation or opener authority.
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard frame.isMainFrame else { completionHandler(); return }
        javascriptDialog(webView, message: message, confirmation: false) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard frame.isMainFrame else { completionHandler(false); return }
        javascriptDialog(webView, message: message, confirmation: true, completion: completionHandler)
    }
    private func javascriptDialog(_ web: WKWebView, message: String, confirmation: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard canInteractWithPage, tab(for: web)?.id == selectedID, approvalID == nil, var top = web.window?.rootViewController else { completion(false); return }
        while let next = top.presentedViewController { top = next }
        guard !(top is UIAlertController) else { completion(false); return }
        let alert = UIAlertController(title: web.url?.host, message: String(message.prefix(1000)), preferredStyle: .alert)
        let strings = OathLocalizer.current
        if confirmation { alert.addAction(UIAlertAction(title: strings.text(.cancel), style: .cancel) { _ in completion(false) }) }
        alert.addAction(UIAlertAction(title: strings.text(.ok), style: .default) { _ in completion(true) })
        top.present(alert, animated: true)
    }
}

extension OathBrowserController: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let web = message.webView, let tab = tab(for: web), tab.id == selectedID, tab.ready,
              message.frameInfo.isMainFrame, canInteractWithPage,
              let origin = try? BrowserOrigin(tab.url),
              message.frameInfo.securityOrigin.protocol == "https", message.frameInfo.securityOrigin.host.lowercased() == origin.host,
              (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port) == origin.port,
              let body = message.body as? [String: Any], let method = body["method"] as? String, method.utf8.count <= 80 else {
            replyHandler(Self.error(BrowserRPCError.invalidOrigin), nil); return
        }
        if method == "oath_document" { replyHandler(["result": tab.documentID.uuidString], nil); return }
        guard body["document"] as? String == tab.documentID.uuidString, let params = body["params"],
              params is [Any], JSONSerialization.isValidJSONObject(params), let data = try? JSONSerialization.data(withJSONObject: params),
              data.count <= BrowserPolicy.maximumMessageBytes else { replyHandler(Self.error(.invalid), nil); return }
        let context = DAppRequestOrigin(tabID: tab.id, documentID: tab.documentID, origin: origin)
        if BrowserPolicy.approvalMethods.contains(method) {
            beginApproval(method: method, data: data, context: context) { replyHandler($0, nil) }; return
        }
        readTimes.removeAll { $0.duration(to: .now) > .seconds(60) }
        guard readTimes.count < 120 else { replyHandler(Self.error(.busy), nil); return }
        readTimes.append(.now)
        guard bridgeTasks.count < 2 else { replyHandler(Self.error(.busy), nil); return }
        let id = UUID()
        bridgeTasks[id] = Task { [weak self] in
            guard let self else { replyHandler(Self.error(.disconnected), nil); return }
            defer { bridgeTasks[id] = nil }
            do {
                let value = try await read(method: method, data: data, context: context)
                try validate(context)
                replyHandler(["result": value], nil)
            } catch let error as BrowserRPCError {
                // diagnostics: browser-peer-validation
                replyHandler(Self.error(error), nil)
            }
            catch is CancellationError { replyHandler(Self.error(.disconnected), nil) }
            catch {
                OathDiagnostics.record(error, component: "browser", operation: "provider_read")
                replyHandler(Self.error(.init(-32000, "The network request could not complete.")), nil)
            }
        }
    }
    static func error(_ error: BrowserRPCError) -> [String: Any] { ["error": ["code": error.code, "message": error.message]] }
    func validate(_ context: DAppRequestOrigin) throws {
        guard canInteractWithPage, session?.changingWallet == false, session?.resetting == false,
              let tab = selected, tab.id == context.tabID, tab.documentID == context.documentID, tab.ready,
              (try? BrowserOrigin(tab.url)) == context.origin else { throw BrowserRPCError.disconnected }
    }
    private func read(method: String, data: Data, context: DAppRequestOrigin) async throws -> Any {
        try validate(context); guard let tab = selected else { throw BrowserRPCError.disconnected }
        let permission = permission(tab)
        switch method {
        case "eth_accounts": return permission.map { [$0.address] } ?? []
        case "eth_chainId": return "0x" + String(tab.chainID, radix: 16)
        case "wallet_getPermissions": return permission == nil ? [] : [["parentCapability": "eth_accounts"]]
        case "wallet_revokePermissions": disconnect(tab); return NSNull()
        default:
            guard BrowserPolicy.readMethods.contains(method) else { throw BrowserRPCError.unsupported }
            guard BrowserPolicy.validatesRead(method: method, params: data) else { throw BrowserRPCError.invalid }
            guard permission != nil, let network = EVMSendNetwork.allCases.first(where: { $0.chainID == tab.chainID && !$0.isTestnet }),
                  OathImportChain(rawValue: network.rawValue)?.isEnabled == true else { throw BrowserRPCError.unauthorized }
            let client = try await OathEVMSendService.shared.connection(network)
            let value = try await client.browserRead(method: method, parameters: data)
            return try JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)
        }
    }
}

/// WebKit retains handlers. Keep the controller weak so closing the wallet
/// releases its browser and private in-memory data store.
@MainActor private final class OathBrowserMessageRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: OathBrowserController?
    init(_ owner: OathBrowserController) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let owner else { replyHandler(OathBrowserController.error(.disconnected), nil); return }
        owner.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
}
