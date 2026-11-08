import SwiftUI
import WebKit

// Only Oath styling/localization and wallet-link dependencies are substituted.
// The inset, shared UITextField/keyboard accessory, tab coordinator, URL policy and WKWebView
// model are the production files, with a synthetic page and no wallet/relay.
enum OathStringKey {
    case browserAddress, browserTabs, clear, browserInvalidAddress, browserLoadFailed
    case done, showPrivateKey, hidePrivateKey
}
struct FixtureStrings {
    func text(_ key: OathStringKey) -> String {
        switch key {
        case .browserAddress: "Website address"
        case .browserTabs: "Tabs"
        case .clear: "Clear"
        case .browserInvalidAddress: "Invalid address"
        case .browserLoadFailed: "Load failed"
        case .done: "Done"
        case .showPrivateKey: "Show"
        case .hidePrivateKey: "Hide"
        }
    }
    func number(_ count: Int) -> String { String(count) }
}
private struct StringsKey: EnvironmentKey { static let defaultValue = FixtureStrings() }
enum OathLanguage { case english; var isRightToLeft: Bool { false } }
private struct LanguageKey: EnvironmentKey { static let defaultValue = OathLanguage.english }
extension EnvironmentValues {
    var oathLocalizer: FixtureStrings { get { self[StringsKey.self] } set { self[StringsKey.self] = newValue } }
    var oathLanguage: OathLanguage { get { self[LanguageKey.self] } set { self[LanguageKey.self] = newValue } }
}
enum OathInputMetrics { static let minimumContentHeight: CGFloat = 44 }
enum OathHairlineMetrics { static func thickness(displayScale: CGFloat) -> CGFloat { 1 / max(1, displayScale) } }
@MainActor struct OathHaptics {
    enum Event { case selection, dismiss }
    static let shared = OathHaptics()
    func play(_ event: Event) {}
    func perform(_ event: Event, _ action: () -> Void) { action() }
}
extension View {
    func oathFont(_ style: Font.TextStyle) -> some View { font(.system(style)) }
}
struct OathButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    var body: some View { Button(action: action, label: label) }
}
enum OathWalletLink {
    case connection
    var isWalletConnect: Bool { true }
    static func parse(_ url: URL) -> Self? { nil }
}
@main struct AddressBarFixture: App {
    var body: some Scene { WindowGroup { FixtureTabs() } }
}
private struct FixtureTabs: View {
    @State private var tabs = OathBrowserSession(makePage: OathBrowserModel.init)
    @State private var selected = 1
    @State private var pendingFocus = false
    var body: some View {
        TabView(selection: $selected) {
            Tab("Wallet", systemImage: "wallet.bifold", value: 0) { Text("Wallet") }
            Tab("Browser", systemImage: "globe", value: 1) {
                NavigationStack {
                    VStack {
                        if let issue = tabs.current.issue {
                            Text(FixtureStrings().text(issue)).accessibilityIdentifier("fixture.issue")
                        }
                        if let webView = tabs.current.webView {
                            FixtureWebView(view: webView)
                        } else { Spacer() }
                    }
                    .modifier(OathBrowserBottomBarInset(tabs: tabs))
                    .navigationTitle("Browser")
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: 2, role: .search) { Text("Search") }
        }
        .modifier(OathBrowserTabBehavior(visible: selected == 1))
        .sheet(item: $tabs.sheet, onDismiss: {
            tabs.setActive(selected == 1)
            if pendingFocus { pendingFocus = false; tabs.focusAddress() }
        }) { _ in
            NavigationStack {
                List(tabs.items) { tab in
                    Button(tab.page.url?.absoluteString ?? "New Tab") {
                        tabs.select(tab.id); tabs.sheet = nil
                    }.accessibilityIdentifier("fixture.tab")
                }
                .navigationTitle("Tabs")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Tab", systemImage: "plus") {
                            _ = tabs.add(); pendingFocus = true; tabs.sheet = nil
                        }.accessibilityIdentifier("fixture.newTab")
                    }
                }
            }.presentationDetents([.large])
        }
        .onAppear { tabs.setActive(true) }
        .onChange(of: selected) { _, value in tabs.setActive(value == 1) }
        .onChange(of: tabs.sheet) { _, value in tabs.setActive(selected == 1 && value == nil) }
    }
}
private struct FixtureWebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
