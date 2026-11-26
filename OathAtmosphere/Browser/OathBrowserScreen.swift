import SwiftUI
import WebKit
import OathBrowser

struct OathBrowserScreen: View {
    let controller: OathBrowserController
    let session: OathWalletSession
    let namespace: Namespace.ID
    let onExit: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.oathLocalizer) private var strings
    @State private var editingAddress = false
    private struct ApprovalPresentation: Identifiable { let id: UUID }
    private var reviewPresentation: Binding<ApprovalPresentation?> {
        let requestID = controller.approvalCancelled ? nil : controller.approvalID
        return .init(get: { requestID.map(ApprovalPresentation.init) }, set: { value in
            if value == nil, controller.approvalID == requestID { controller.cancelApproval() }
        })
    }
    @ViewBuilder var body: some View {
        let previewID = controller.openedFromPreview && !reduceMotion ? controller.selectedID : nil
        if #available(iOS 27, *) {
            let transition = previewID.map { AnyNavigationTransition(.zoom(sourceID: $0, in: namespace)) }
            page.navigationTransition(transition ?? AnyNavigationTransition(.automatic))
        } else if #available(iOS 18, *), let tabID = previewID {
            page.navigationTransition(.zoom(sourceID: tabID, in: namespace))
        } else {
            page
        }
    }
    private var page: some View {
        browserPage
            .modifier(OathBrowserAddressToolbar(tab: controller.selected, origin: displayedOrigin, editingAddress: $editingAddress,
                submit: controller.navigate, showTabs: {
                    prepareReturn(to: controller.selected)
                    controller.showTabOverview()
                }))
            .navigationBarBackButtonHidden(true)
            .toolbar(.visible, for: .bottomBar)
            .toolbarBackground(.hidden, for: .bottomBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(strings.text(.back), systemImage: "chevron.backward") {
                        prepareReturn(to: controller.navigation.path.dropLast().last == .tabs ? controller.selected : nil)
                        onExit()
                    }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("BackButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(strings.text(.browserLibrary), systemImage: "book") { controller.presentLibrary(true) }
                            .accessibilityIdentifier("browser.library")
                        if let tab = controller.selected {
                            if !tab.isPrivate {
                                Button(strings.text(.browserAddBookmark), systemImage: "bookmark") { controller.bookmark(tab) }
                                    .disabled(!tab.canBookmark)
                            }
                            if controller.permission(tab) != nil { Button(strings.text(.scannerWCDisconnect), systemImage: "link.badge.plus", role: .destructive) { controller.disconnect(tab) } }
                            Button(strings.text(.browserConnections), systemImage: "link") { OathWalletLinkInbox.shared.receive(URL(string: "oathwallet://wc")!) }
                            ShareLink(item: tab.displayedURL) { Label(strings.text(.browserShare), systemImage: "square.and.arrow.up") }
                            Button(strings.text(.browserReload), systemImage: "arrow.clockwise") { tab.failure = nil; tab.webView?.reload() }
                        }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel(strings.text(.browserMenu))
                        .accessibilityIdentifier("browser.menu")
                }
            }
            .oathNativeAppBar(title: displayedOrigin.isEmpty ? strings.text(.browserTitle) : displayedOrigin,
                              subtitle: controller.selected?.isPrivate == true ? strings.text(.browserPrivate) : nil)
            .onChange(of: controller.selectedID) { editingAddress = false }
            .onChange(of: controller.showsTabOverview) { if controller.showsTabOverview { editingAddress = false } }
            .sheet(item: reviewPresentation) { presentation in
                OathBrowserApprovalSheet(controller: controller, session: session, requestID: presentation.id)
                    .onDisappear { if controller.approvalID == presentation.id { controller.cancelApproval() } }
            }
            .alert(strings.text(.browserPrivateConnection), isPresented: Binding(get: { controller.privateWalletConnectURL != nil }, set: { if !$0 { controller.privateWalletConnectURL = nil } })) {
                Button(strings.text(.cancel), role: .cancel) { controller.privateWalletConnectURL = nil }
                Button(strings.text(.browserContinue)) { controller.confirmPrivateWalletConnect() }
            } message: { Text(strings.text(.browserPrivateConnectionDetail)) }
            .confirmationDialog(strings.text(.browserOpenTab), isPresented: Binding(get: { controller.popupURL != nil }, set: { if !$0 { controller.popupURL = nil } }), titleVisibility: .visible) {
                if let url = controller.popupURL {
                    Button(url.host ?? strings.text(.browserOpenTab)) { controller.popupURL = nil; controller.open(url, newTab: true) }
                }
                Button(strings.text(.cancel), role: .cancel) { controller.popupURL = nil }
            }
    }

    @ViewBuilder private var browserPage: some View {
        if let tab = controller.selected {
            ZStack {
                OathBrowserWebView(controller: controller, tab: tab)
                    .id(tab.id)
                    .ignoresSafeArea(.container, edges: .vertical)
                if let failure = tab.failure {
                    ContentUnavailableView {
                        Label(strings.text(.browserPageUnavailable), systemImage: "globe")
                    } description: { Text(failure) } actions: {
                        Button(strings.text(.tryAgain)) { tab.failure = nil; tab.webView?.reload() }
                    }.background(Color(uiColor: OathSurfaceColors.groupedCanvas))
                }
            }.overlay(alignment: .top) {
                if tab.progress > 0 && tab.progress < 1 { ProgressView(value: tab.progress).tint(.blue).accessibilityLabel(strings.text(.exploreLoading)) }
            }
        } else { Color(uiColor: OathSurfaceColors.groupedCanvas) }
    }

    private var displayedOrigin: String {
        guard let url = controller.selected?.displayedURL, let host = url.host else { return "" }
        if let port = url.port, port != 443 { return "\(host):\(port)" }
        return host
    }

    private func prepareReturn(to previewTab: OathBrowserTab?) {
        guard #available(iOS 18, *), let webView = controller.selected?.webView else { return }
        var responder: UIResponder? = webView
        while let current = responder {
            if let owner = current as? UIViewController,
               let page = owner.navigationController?.topViewController,
               webView.isDescendant(of: page.view) {
                if let previewTab, !reduceMotion {
                    page.preferredTransition = .zoom { [weak previewTab] context in
                        guard let source = context.sourceViewController.viewIfLoaded else { return nil }
                        source.layoutIfNeeded()
                        guard let preview = previewTab?.previewView, preview.isDescendant(of: source) else { return nil }
                        return preview
                    }
                } else {
                    page.preferredTransition = nil
                }
                return
            }
            responder = current.next
        }
    }
}

struct OathBrowserAddressToolbar: ViewModifier {
    let tab: OathBrowserTab?
    let origin: String
    @Binding var editingAddress: Bool
    let submit: (String) -> Void
    let showTabs: () -> Void
    @Environment(\.oathLocalizer) private var strings

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .modifier(OathBrowserAddressSearch(url: tab?.displayedURL, origin: origin,
                    placeholder: strings.text(.browserSearchOrAddress), presented: $editingAddress, submit: submit))
                .toolbar {
                    if tab != nil && !editingAddress {
                        historyButtons
                        ToolbarSpacer(.fixed, placement: .bottomBar)
                    }
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    if !editingAddress {
                        ToolbarSpacer(.fixed, placement: .bottomBar)
                        tabsButton
                    }
                }
        } else {
            GeometryReader { viewport in
                content.toolbar {
                    if tab != nil && !editingAddress { historyButtons }
                    ToolbarItem(placement: .bottomBar) {
                        OathBrowserAddressField(url: tab?.displayedURL, origin: origin,
                            placeholder: strings.text(.browserSearchOrAddress), editing: $editingAddress, submit: submit)
                            .frame(width: max(70, viewport.size.width - (editingAddress || tab == nil ? 96 : 190)), height: 40)
                    }
                    if editingAddress {
                        ToolbarItem(placement: .bottomBar) {
                            Button(strings.text(.close), systemImage: "xmark") { editingAddress = false }
                        }
                    } else { tabsButton }
                }
            }
        }
    }

    private var historyButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button(strings.text(.browserBack), systemImage: "chevron.backward") { tab?.webView?.goBack() }
                .disabled(tab?.canGoBack != true)
                .accessibilityIdentifier("browser.back")
            Button(strings.text(.browserForward), systemImage: "chevron.forward") { tab?.webView?.goForward() }
                .disabled(tab?.canGoForward != true)
                .accessibilityIdentifier("browser.forward")
        }
    }

    private var tabsButton: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button(strings.text(.browserTabs), systemImage: "square.on.square", action: showTabs)
                .accessibilityIdentifier("browser.tabs")
        }
    }

}

@available(iOS 26, *)
private struct OathBrowserAddressSearch: ViewModifier {
    let url: URL?
    let origin: String
    let placeholder: String
    @Binding var presented: Bool
    let submit: (String) -> Void
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    private var prompt: String {
        presented || origin.isEmpty ? placeholder : origin
    }

    func body(content: Content) -> some View {
        content
            .searchable(text: $draft, isPresented: $presented, prompt: prompt)
            .searchFocused($focused)
            .searchSelection($selection)
            .keyboardType(.webSearch)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(of: .search) {
                let address = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                presented = false
                if !address.isEmpty { submit(address) }
            }
            .onChange(of: focused) {
                guard focused else { return }
                draft = url?.absoluteString ?? ""
                selection = TextSelection(range: draft.startIndex..<draft.endIndex)
            }
            .onChange(of: presented) {
                if !presented { draft = ""; selection = nil }
            }
    }
}

struct OathBrowserAddressField: UIViewRepresentable {
    let url: URL?
    let origin: String
    let placeholder: String
    @Binding var editing: Bool
    let submit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .subheadline)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = origin.isEmpty ? .natural : .center
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.clearButtonMode = .whileEditing
        field.accessibilityIdentifier = "browser.address"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholder != placeholder {
            field.placeholder = placeholder
            field.accessibilityLabel = placeholder
        }
        if !editing && field.isFirstResponder { field.resignFirstResponder() }
        if !field.isFirstResponder && field.text != origin { field.text = origin }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: OathBrowserAddressField
        init(_ parent: OathBrowserAddressField) { self.parent = parent }

        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.editing = true
            let address = parent.url?.absoluteString ?? ""
            field.textAlignment = .natural
            field.text = address
            // Apply the selection after UIKit places the caret for the activating tap.
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isFirstResponder, field.text == address else { return }
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            parent.editing = false
            field.textAlignment = parent.origin.isEmpty ? .natural : .center
            field.text = parent.origin
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            let address = field.text ?? ""
            field.resignFirstResponder()
            if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parent.submit(address) }
            return false
        }
    }
}

private struct OathBrowserWebView: UIViewRepresentable {
    let controller: OathBrowserController
    let tab: OathBrowserTab
    func makeUIView(context: Context) -> WKWebView { controller.ensureWebView(tab) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

extension View {
    func oathBrowserLibrary(isPresented: Binding<Bool>, controller: OathBrowserController) -> some View {
        modifier(OathBrowserLibraryPresentation(isPresented: isPresented, controller: controller))
    }
}

private struct OathBrowserLibraryPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let controller: OathBrowserController
    @State private var afterDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            let action = afterDismiss
            afterDismiss = nil
            if controller.isForeground, controller.session?.isUnlocked == true { action?() }
        }) {
            OathBrowserLibrary(controller: controller) { action in
                // Let the sheet finish its native dismissal before any push or pop.
                afterDismiss = action
                isPresented = false
            }
        }
    }
}

private struct OathBrowserLibrary: View {
    let controller: OathBrowserController
    let dismissThen: (@escaping () -> Void) -> Void
    @State private var clearing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(strings.text(.browserTabs), systemImage: "square.on.square") {
                        dismissThen { controller.showTabOverview() }
                    }.accessibilityIdentifier("browser.library.tabs")
                } footer: {
                    if controller.privateMode { Text(strings.text(.browserPrivateDetail)) }
                }
                if !controller.privateMode {
                    Section(strings.text(.browserBookmarks)) {
                        if controller.archive.bookmarks.isEmpty { Text(strings.text(.browserNoBookmarks)).foregroundStyle(.secondary) }
                        ForEach(controller.archive.bookmarks) { page in
                            Button { dismissThen { controller.open(page.url) } } label: { pageLabel(page) }
                                .accessibilityIdentifier("browser.library.bookmark")
                                .swipeActions { Button(strings.text(.delete), role: .destructive) { controller.removeBookmark(page.id) } }
                        }
                    }
                    Section(strings.text(.browserHistory)) {
                        ForEach(controller.archive.history.prefix(100)) { page in
                            Button { dismissThen { controller.open(page.url) } } label: { pageLabel(page) }
                                .contextMenu {
                                    Button(strings.text(.browserRemoveFromRecents), systemImage: "trash", role: .destructive) {
                                        controller.removeVisit(page.id)
                                    }
                                }
                        }
                    }
                }
                Section {
                    Button(strings.text(.browserConnections), systemImage: "link") { dismissThen { OathWalletLinkInbox.shared.receive(URL(string: "oathwallet://wc")!) } }
                    Button(strings.text(.browserClear), role: .destructive) { clearing = true }
                } footer: { Text(strings.text(.browserClearDetail)) }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                OathCloseButton { dismiss() }.accessibilityIdentifier("browser.library.close")
            } }
            .oathNativeAppBar(title: strings.text(.browserLibrary))
            .confirmationDialog(strings.text(.browserClear), isPresented: $clearing, titleVisibility: .visible) {
                Button(strings.text(.browserClear), role: .destructive) { dismissThen { Task { await controller.clearBrowsingData() } } }
            } message: { Text(strings.text(.browserClearDetail)) }
        }
    }
    private func pageLabel(_ page: BrowserPageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: page.displayTitle).oathFont(.body).foregroundStyle(.primary).lineLimit(1)
            Text(page.url.host ?? "").oathFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
