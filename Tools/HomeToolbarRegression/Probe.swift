import SwiftUI
import UIKit
import Observation
import OathNativeRefresh

// Synthetic data and localization only. The toolbar, sidebar button, balance,
// geometry model, and native refresh/list implementation are production code.
enum ProbeKey { case wallets, historyTab, scan, balanceHidden, sendBalanceUnknown }
struct ProbeStrings {
    func text(_ key: ProbeKey) -> String {
        switch key { case .wallets: "Wallets"; case .historyTab: "History"; case .scan: "Scan"; case .balanceHidden: "Balance hidden"; case .sendBalanceUnknown: "Balance unavailable" }
    }
}
private struct StringsKey: EnvironmentKey { static let defaultValue = ProbeStrings() }
struct ProbeSidebar {
    var walletName = "Daily Wallet"
    var walletAvailable = true
    var open: () -> Void = {}
}
private struct SidebarKey: EnvironmentKey { static let defaultValue = ProbeSidebar() }
extension EnvironmentValues {
    var oathLocalizer: ProbeStrings { self[StringsKey.self] }
    var oathWalletSidebar: ProbeSidebar {
        get { self[SidebarKey.self] }
        set { self[SidebarKey.self] = newValue }
    }
}
enum ProbeFeedback { case tap, navigate, scan }
@MainActor func OathButton<L: View>(feedback: ProbeFeedback? = .tap, action: @escaping () -> Void,
                                  @ViewBuilder label: () -> L) -> some View {
    Button(action: action, label: label)
}
@MainActor func OathButton(_ title: String, systemImage: String, feedback: ProbeFeedback?,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) { Label(title, systemImage: systemImage) }
}
extension View {
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        font(.system(style, weight: weight))
    }
}
enum OathHairlineMetrics { static func thickness(displayScale: CGFloat) -> CGFloat { 2 / max(1, displayScale) } }

// PRODUCTION_DECLARATIONS

@main struct HomeToolbarProbe: App {
    var body: some Scene { WindowGroup { ProbeHome() } }
}

struct ProbeHome: View {
    @State private var toolbarBalance = OathHomeToolbarBalanceState()
    @State private var walletName = "Daily Wallet"
    @State private var concealed = false
    @State private var measuredBottom: CGFloat = 70
    @State private var opens = 0
    @State private var dark = false

    var body: some View {
        NavigationStack {
            NativeRefreshScroll(identifier: "home.scroll", tint: .label, action: {},
                onFailure: {}, onScroll: { toolbarBalance.scroll(to: $0) }) {
                VStack(spacing: 12) {
                    OathButton(action: { concealed.toggle() }) {
                        OathWalletBalance(value: "$1,234.56", concealed: concealed, fontWeight: .bold)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.balance")
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named("home.summary.content")).maxY
                    } action: {
                        measuredBottom = $0
                        toolbarBalance.measureBalanceBottom($0)
                    }
                    Color.clear.frame(height: 240)
                }
                .coordinateSpace(name: "home.summary.content")
                ForEach(0..<30) { index in Text("Synthetic asset \(index)").frame(height: 64) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("")
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbar {
                OathHomeToolbar(walletName: walletName, balance: { "$1,234.56" }, balanceAvailable: true,
                    concealed: concealed, scrollState: toolbarBalance, actionsEnabled: true, onHistory: {}, onScan: {})
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    HStack {
                        Button("Partial") { scroll(to: -(measuredBottom - 10)) }
                        Button("Hidden") { scroll(to: -(measuredBottom + 1)) }
                        Button("Deep") { scroll(to: -1500) }
                        Button("Top") { scroll(to: 0) }
                    }
                    HStack {
                        Button("Privacy") { concealed.toggle() }
                        Button("Rename") { walletName = "A very long wallet name that must fit" }
                        Button("Theme") { dark.toggle() }
                        Text("Opened \(opens)").accessibilityIdentifier("probe.opens")
                    }
                }.font(.caption).padding(8).background(.background)
            }
        }
        .tint(nil)
        .environment(\.oathWalletSidebar, ProbeSidebar(walletName: walletName, open: { opens += 1 }))
        .preferredColorScheme(dark ? .dark : .light)
    }

    private func scroll(to origin: CGFloat) {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.accessibilityIdentifier == "home.scroll" { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if let scroll = scene.windows.lazy.compactMap(find).first {
                scroll.setContentOffset(CGPoint(x: 0, y: -origin - scroll.adjustedContentInset.top), animated: false)
                return
            }
        }
    }
}
