import SwiftUI
import WebKit
import OathDiagnostics

struct OathBrowserScreen: View {
    let session: OathWalletSession
    @Bindable var tabs: OathBrowserSession
    let selected: Bool
    private var model: OathBrowserModel { tabs.current }
    @State private var bookmarks = OathBrowserBookmarks()
    @State private var pendingNewTabAddress = false
    @State private var connections = false
    @State private var clearWebsiteData = false
    @State private var pendingPair: URL?
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private var usable: Bool { selected && scenePhase == .active && session.isUnlocked && !session.changingWallet && !session.resetting }
    private var browsing: Bool {
        usable && tabs.sheet == nil && !connections && !clearWebsiteData && model.externalURL == nil &&
        !OathWalletConnectService.shared.presentationOpen
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.loading { ProgressView(value: model.progress).tint(OathOnboardingColors.blue).accessibilityLabel(strings.text(.browserTitle)) }
                if let issue = model.issue {
                    HStack {
                        Text(strings.text(issue)).oathFont(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        OathButton(strings.text(.tryAgain)) { model.reload() }.disabled(model.url == nil)
                    }.padding().accessibilityIdentifier("browser.error")
                }
                if let view = model.webView {
                    // A new website store must mount its new WKWebView even if
                    // clear/reopen are coalesced into one SwiftUI update.
                    BrowserWebView(view: view).id(ObjectIdentifier(view)).accessibilityIdentifier("browser.web")
                }
                else { startPage }
            }
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .modifier(OathBrowserBottomBarInset(tabs: tabs))
            .navigationTitle(strings.text(.browserTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    OathButton { model.back() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!model.canGoBack).accessibilityLabel(strings.text(.back)).accessibilityIdentifier("browser.back")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        OathButton { model.forward() } label: { Label(strings.text(.browserForward), systemImage: "chevron.forward") }.disabled(!model.canGoForward)
                        OathButton { model.reload() } label: { Label(strings.text(.browserReload), systemImage: "arrow.clockwise") }.disabled(model.webView == nil)
                        OathButton { tabs.sheet = .bookmark } label: { Label(strings.text(.browserAddBookmark), systemImage: "bookmark") }.disabled(model.url == nil || !bookmarks.loaded)
                        OathButton { tabs.sheet = .bookmarks } label: { Label(strings.text(.browserBookmarks), systemImage: "book") }
                        if let url = model.url { ShareLink(item: url) { Label(strings.text(.receiveShare), systemImage: "square.and.arrow.up") } }
                        OathButton { connections = true } label: { Label(strings.text(.walletConnect), systemImage: "link") }
                        OathButton { tabs.sheet = .pair } label: { Label(strings.text(.wcAddConnection), systemImage: "plus") }
                        OathButton { clearWebsiteData = true } label: { Label(strings.text(.browserClearData), systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(strings.text(.browserTitle)).accessibilityIdentifier("browser.menu")
                }
            }
            .sheet(item: $tabs.sheet, onDismiss: finishSheet) { selection in
                if selection == .tabs {
                    OathBrowserTabsSheet(tabs: tabs) {
                        guard tabs.add() != nil else { return }
                        pendingNewTabAddress = true
                        tabs.sheet = nil
                    }
                } else if selection == .bookmarks {
                    NavigationStack {
                        ScrollView { bookmarkList.padding(.vertical, 12) }
                            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
                            .navigationTitle(strings.text(.browserBookmarks)).navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .topBarLeading) { OathCloseButton { tabs.sheet = nil } } }
                    }.presentationDetents([.large]).presentationDragIndicator(.visible).oathLanguage(strings.language)
                } else if selection == .pair {
                    OathBrowserPairSheet { url in pendingPair = url; tabs.sheet = nil }
                } else {
                    OathBrowserBookmarkEditor(bookmarks: bookmarks, url: model.url, title: model.title)
                }
            }
            .sheet(isPresented: $connections) {
                NavigationStack {
                    OathWalletConnectPage(session: session)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { OathCloseButton { connections = false } } }
                }.presentationDetents([.large]).presentationDragIndicator(.visible).oathLanguage(strings.language)
            }
            .confirmationDialog(strings.text(.browserClearData), isPresented: $clearWebsiteData, titleVisibility: .visible) {
                OathButton(strings.text(.clear), role: .destructive) { tabs.reset() }
            } message: { Text(strings.text(.browserClearDataDetail)) }
            .confirmationDialog(strings.text(.wcOpenWebsite), isPresented: Binding(get: { model.externalURL != nil }, set: { if !$0 { model.externalURL = nil } }), titleVisibility: .visible) {
                if let url = model.externalURL {
                    OathButton(strings.text(.wcOpenWebsite)) { model.externalURL = nil; openURL(url) }
                }
            } message: {
                Text(String((model.externalURL?.absoluteString ?? "").prefix(2_048)))
                    .environment(\.layoutDirection, .leftToRight)
            }
            .alert(model.dialog?.host ?? "", isPresented: Binding(get: { model.dialog != nil }, set: { if !$0 { model.resolveDialog(accept: false) } })) {
                if model.dialog?.kind == .prompt {
                    TextField("", text: Binding(get: { model.dialogText }, set: { model.dialogText = $0 }))
                }
                if model.dialog?.kind != .alert { OathButton(strings.text(.cancel), role: .cancel) { model.resolveDialog(accept: false) } }
                OathButton(strings.text(.done)) { model.resolveDialog(accept: true) }
            } message: { Text(model.dialog?.message ?? "") }
            .onAppear { bookmarks.load(); tabs.setActive(browsing); configurePage() }
            .onChange(of: browsing, initial: true) { _, value in
                tabs.setActive(value); configurePage()
            }
            .onChange(of: tabs.selectedID) { _, _ in configurePage(); tabs.setActive(browsing) }
            .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { suspend() } }
            .onChange(of: session.changingWallet) { _, changing in if changing { suspend() } }
            .onChange(of: session.displayedProfile?.id) { _, _ in
                // Also cover a fast switch whose intermediate changing flag is
                // coalesced into one SwiftUI update.
                suspend(); tabs.setActive(browsing); configurePage()
            }
            .onChange(of: session.resetting) { _, resetting in if resetting { suspend() } }
            .onDisappear { tabs.setActive(false) }
            .oathNativeLocalization()
        }
    }

    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OathSettingsFooter { Text(strings.text(.browserPrivateDetail)) }
                OathSettingsSectionRule()
                OathSettingsFooter { Text(strings.text(.browserBookmarks)).oathFont(.headline) }
                bookmarkList
            }.padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
    }
    private var bookmarkList: some View {
        VStack(spacing: 0) {
                if bookmarks.failed {
                    OathSettingsFooter { Text(strings.text(.preferencesSaveFailed)) }
                    OathButton(strings.text(.tryAgain)) { bookmarks.load() }.padding()
                } else if bookmarks.items.isEmpty {
                    OathSettingsFooter { Text(strings.text(.browserNoBookmarks)) }
                }
                ForEach(bookmarks.items) { bookmark in
                    OathButton { tabs.sheet = nil; tabs.setActive(usable); model.open(bookmark.url.absoluteString) } label: {
                        OathSettingsRow(title: bookmark.title, icon: "bookmark", value: bookmark.url.host)
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .contextMenu {
                        OathButton(strings.text(.delete), role: .destructive) {
                            do { try bookmarks.remove(bookmark.id) }
                            catch {
                                if !(error is OathBrowserBookmarks.Failure) {
                                    OathDiagnostics.record(error, component: "browser", operation: "remove_bookmark")
                                }
                                model.issue = .preferencesSaveFailed
                            }
                        }
                    }
                    .accessibilityIdentifier("browser.bookmark")
                }
        }.frame(maxWidth: 700).frame(maxWidth: .infinity)
    }
    private func configurePage() {
        let browser = model, wallet = session
        model.walletLink = { [weak browser, weak wallet] url, host in
            guard browser?.active == true, wallet?.isUnlocked == true,
                  wallet?.changingWallet == false, wallet?.resetting == false,
                  !OathWalletConnectService.shared.presentationOpen else { return }
            OathWalletLinkInbox.shared.receive(url, browserHost: host)
        }
    }
    private func suspend() {
        tabs.setActive(false); tabs.reset()
        connections = false; pendingPair = nil; pendingNewTabAddress = false
    }
    private func finishSheet() {
        if pendingNewTabAddress {
            pendingNewTabAddress = false
            if usable { tabs.setActive(browsing); tabs.focusAddress() }
        } else { deliverPendingPair() }
    }
    private func deliverPendingPair() {
        guard let url = pendingPair else { return }
        pendingPair = nil
        guard usable, !OathWalletConnectService.shared.presentationOpen else { return }
        OathWalletLinkInbox.shared.receive(url, browserHost: OathBrowserPolicy.connectionAuthority(model.url))
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

private struct OathBrowserBookmarkEditor: View {
    let bookmarks: OathBrowserBookmarks
    @State private var address: String
    @State private var title: String
    @State private var focused = false
    @State private var titleFocused = false
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    init(bookmarks: OathBrowserBookmarks, url: URL?, title: String) {
        self.bookmarks = bookmarks
        _address = State(initialValue: url?.absoluteString ?? ""); _title = State(initialValue: title)
    }
    private var target: URL? {
        guard let url = OathBrowserPolicy.website(address, allowsBareHost: true), case .website = OathBrowserPolicy.destination(url) else { return nil }
        return url
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    OathTextInput(text: $title, focused: $titleFocused, title: strings.text(.contactName),
                        identifier: "browser.bookmark.title").oathInputRow()
                    OathTextInput(text: $address, focused: $focused, title: strings.text(.browserAddress),
                        identifier: "browser.url.input", address: true, onSubmit: submit).oathInputRow()
                    if failed { Text(strings.text(.preferencesSaveFailed)).foregroundStyle(.red) }
                    Text(strings.text(.browserPrivateDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .navigationTitle(strings.text(.browserAddBookmark)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { OathCloseButton { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { OathDoneButton { submit() }.disabled(target == nil).accessibilityIdentifier("browser.url.confirm") }
            }
            .onAppear { focused = true }
            .oathNativeLocalization()
        }.presentationDetents([.large]).presentationDragIndicator(.visible).oathLanguage(strings.language)
    }
    private func submit() {
        guard let target else { return }
        do { try bookmarks.save(title: title, url: target); dismiss() }
        catch {
            // Invalid input/full bookmark storage are expected form states.
            if !(error is OathBrowserBookmarks.Failure) {
                OathDiagnostics.record(error, component: "browser", operation: "save_bookmark")
            }
            failed = true
        }
    }
}

private struct OathBrowserPairSheet: View {
    let connect: (URL) -> Void
    @State private var text = ""
    @State private var focused = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    private var target: URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let route = OathWalletLink.parse(url), route.isWalletConnect else { return nil }
        return url
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                OathTextInput(text: $text, focused: $focused, title: strings.text(.browserPairingLink), identifier: "browser.pair.input", address: true)
                    .oathInputRow()
                Text(strings.text(.scannerWCAccountsPermission)).oathFont(.footnote).foregroundStyle(.secondary)
                Spacer()
            }.padding(20)
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .navigationTitle(strings.text(.walletConnect)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { OathCloseButton { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    OathDoneButton { if let target { connect(target) } }.disabled(target == nil)
                }
            }.onAppear { focused = true }.oathNativeLocalization()
        }.presentationDetents([.large]).presentationDragIndicator(.visible).oathLanguage(strings.language)
    }
}
