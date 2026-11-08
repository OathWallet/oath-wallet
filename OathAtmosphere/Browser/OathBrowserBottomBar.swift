import SwiftUI

typealias OathBrowserSession = OathBrowserTabs<OathBrowserModel>

/// The system tab accessory owns the glass, safe area, and tab-bar positioning.
/// https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(isenabled:content:)
struct OathBrowserTabAccessory: ViewModifier {
    let tabs: OathBrowserSession
    let visible: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabViewBottomAccessory(isEnabled: visible) { OathBrowserBottomBar(tabs: tabs) }
                .tabBarMinimizeBehavior(visible ? .never : .automatic)
        } else { content }
    }
}

struct OathBrowserLegacyBottomBar: ViewModifier {
    let tabs: OathBrowserSession
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) { content }
        else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                OathBrowserBottomBar(tabs: tabs)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
}

struct OathBrowserBottomBar: View {
    let tabs: OathBrowserSession
    @Environment(\.oathLocalizer) private var strings
    private var address: String? { OathBrowserPolicy.connectionAuthority(tabs.current.url) }
    var body: some View {
        HStack(spacing: 0) {
            OathButton { tabs.sheet = .address } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 21))
                    Group {
                        if let address {
                            Text(verbatim: address).environment(\.layoutDirection, .leftToRight)
                        } else { Text(strings.text(.browserAddress)) }
                    }
                    .oathFont(.body, weight: .medium)
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity)
                }
                .padding(.leading, 16).padding(.trailing, 8)
                .frame(minHeight: 48).contentShape(Rectangle())
            }
            .accessibilityLabel(strings.text(.browserAddress))
            .accessibilityValue(address ?? "")
            .accessibilityIdentifier("browser.address")

            OathButton { tabs.sheet = .tabs } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 23)).frame(width: 52, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(strings.text(.browserTabs))
            .accessibilityValue(strings.number(tabs.items.count))
            .accessibilityIdentifier("browser.tabs")
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityIdentifier("browser.bottomBar")
    }
}
