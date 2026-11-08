import SwiftUI

typealias OathBrowserSession = OathBrowserTabs<OathBrowserModel>

struct OathBrowserTabBehavior: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabBarMinimizeBehavior(visible ? .never : .automatic)
        } else { content }
    }
}

/// A single field stays mounted while the native keyboard safe area changes.
/// TabView's bottom accessory stays behind the keyboard on iOS 27; a content
/// inset follows it without moving/recreating the first responder.
/// https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)-4s51l
struct OathBrowserBottomBarInset: ViewModifier {
    let tabs: OathBrowserSession
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            OathBrowserBottomBar(tabs: tabs)
                .modifier(BrowserBarMaterial())
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

private struct BrowserBarMaterial: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}

struct OathBrowserBottomBar: View {
    let tabs: OathBrowserSession
    @Environment(\.oathLocalizer) private var strings
    @State private var draft = OathBrowserAddressDraft()
    @State private var addressFocused = false
    var body: some View {
        HStack(spacing: 0) {
            OathButton { addressFocused = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 21))
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .accessibilityLabel(strings.text(.browserAddress))

            OathTextInput(text: $draft.text, focused: $addressFocused,
                title: strings.text(.browserAddress), identifier: "browser.address",
                address: true, keyboardType: .URL, dismissesOnSubmit: false,
                returnKeyType: .go, onSubmit: submit)
                .frame(maxWidth: .infinity, minHeight: 48)

            if addressFocused && !draft.text.isEmpty {
                OathButton { draft.text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .accessibilityLabel(strings.text(.clear))
                .accessibilityIdentifier("browser.address.clear")
            }

            OathButton { addressFocused = false; tabs.sheet = .tabs } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 23)).frame(width: 52, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(strings.text(.browserTabs))
            .accessibilityValue(strings.number(tabs.items.count))
            .accessibilityIdentifier("browser.tabs")
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .onAppear { draft.reset(url: tabs.current.url) }
        .onChange(of: tabs.current.webView != nil) { _, loaded in
            // Opening a start-page bookmark also ends address editing.
            if loaded { addressFocused = false }
        }
        .onChange(of: tabs.current.url) { _, url in draft.synchronize(url: url) }
        .onChange(of: addressFocused) { _, value in draft.setEditing(value, url: tabs.current.url) }
        .onChange(of: tabs.selectedID) { _, _ in
            addressFocused = false; draft.reset(url: tabs.current.url)
        }
        .onChange(of: tabs.addressFocusRequest) { _, _ in
            guard tabs.active, tabs.sheet == nil else { return }
            draft.reset(url: tabs.current.url); addressFocused = true
        }
        .onChange(of: tabs.active) { _, active in if !active { addressFocused = false } }
        .onChange(of: tabs.sheet) { _, sheet in if sheet != nil { addressFocused = false } }
        .onDisappear { addressFocused = false; draft.reset(url: nil) }
    }

    private func submit() {
        guard tabs.active, tabs.sheet == nil else { return }
        guard let target = draft.target else {
            // Invalid address input is expected form validation, not diagnostics.
            tabs.current.issue = .browserInvalidAddress
            return
        }
        tabs.current.open(target.absoluteString)
        addressFocused = false
    }
}
