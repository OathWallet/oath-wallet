import SwiftUI
import Observation

extension View {
    @ViewBuilder func oathNativeAppBar(title: String = "", subtitle: String? = nil,
                                       file: StaticString = #fileID, line: UInt = #line) -> some View {
        let screen = navigationBarTitleDisplayMode(.inline)
            .oathNativeLocalization(navigationMaterial: nil,
                                    systemNavigationAppearance: true, systemBackButton: true,
                                    file: file, line: line)
            .modifier(OathNativeAppBarEdge())
        if let subtitle {
            if #available(iOS 26, *) {
                screen.navigationTitle(title).navigationSubtitle(Text(verbatim: subtitle))
            } else {
                screen.navigationTitle(title + " · " + subtitle)
            }
        } else {
            screen.navigationTitle(title)
        }
    }
}

/// Use the system's fading edge under the native bar. On iOS 27 automatic
/// has a different appearance; select soft explicitly for the shadow-like fade.
/// The system owns rendering and accessibility contrast, with no custom overlay.
private struct OathNativeAppBarEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

struct OathHomeToolbar: ToolbarContent {
    let walletName: String
    let balance: () -> String
    let balanceAvailable: Bool
    let concealed: Bool
    let scrollState: OathHomeToolbarBalanceState
    let actionsEnabled: Bool
    let onScan: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            OathHomeToolbarWalletButton(walletName: walletName, balance: balance, balanceAvailable: balanceAvailable,
                                       concealed: concealed, scrollState: scrollState)
        }
        ToolbarItem(placement: .topBarTrailing) {
            OathButton(strings.text(.scan), systemImage: "viewfinder", feedback: .scan, action: onScan)
                .disabled(!actionsEnabled)
                .accessibilityIdentifier("home.scanner")
        }
    }
}

private struct OathHomeToolbarWalletButton: View {
    let walletName: String
    let balance: () -> String
    let balanceAvailable: Bool
    let concealed: Bool
    let scrollState: OathHomeToolbarBalanceState
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        // Only this button observes live totals, and only while it displays one.
        let showsBalance = scrollState.showsBalance
        let value = showsBalance && !concealed ? balance() : ""
        let spokenValue: String = if !showsBalance { "" }
            else if concealed { strings.text(.balanceHidden) }
            else { balanceAvailable ? value : strings.text(.sendBalanceUnknown) }
        OathWalletSidebarButton(accessibilityValue: spokenValue) {
            OathHomeToolbarLabel(walletName: walletName, balance: value, concealed: concealed, showsBalance: showsBalance)
        }
    }
}

private struct OathHomeToolbarLabel: View {
    let walletName: String
    let balance: String
    let concealed: Bool
    let showsBalance: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color(uiColor: .separator))
                .frame(width: OathHairlineMetrics.thickness(displayScale: displayScale), height: 20)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if showsBalance {
                    Group {
                        if concealed {
                            OathBalanceMask(style: .amount)
                        } else {
                            OathBalanceText(value: balance, font: .system(.body, weight: .bold))
                        }
                    }
                    .transition(.opacity)
                    .accessibilityIdentifier("home.toolbar.balance")
                } else {
                    Text(verbatim: walletName)
                        .oathFont(.body, weight: .semibold)
                        .transition(.opacity)
                        .accessibilityIdentifier("home.toolbar.walletName")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .truncationMode(.tail)
            .frame(maxWidth: 160, alignment: .leading)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3), value: showsBalance)
        }
        .accessibilityHidden(true) // The enclosing sidebar button supplies one private, localized label/value.
    }
}

/// The refresh scroll already reports its inset-adjusted origin. Only the
/// crossing of the measured balance edge is observable, never every scroll tick.
/// Geometry, refresh movement and absent measurements are not diagnostic errors.
@MainActor @Observable final class OathHomeToolbarBalanceState {
    private(set) var showsBalance = false
    @ObservationIgnored private var balanceBottom: CGFloat?
    @ObservationIgnored private var scrollOrigin: CGFloat = 0

    func measureBalanceBottom(_ value: CGFloat) {
        guard value.isFinite, value > 0 else { return }
        balanceBottom = value
        update()
    }

    func scroll(to origin: CGFloat) {
        guard origin.isFinite else { return }
        scrollOrigin = origin
        update()
    }

    func reset() {
        scrollOrigin = 0
        if showsBalance { showsBalance = false }
    }

    private func update() {
        let hidden = balanceBottom.map { scrollOrigin + $0 <= 0 } ?? false
        if showsBalance != hidden { showsBalance = hidden }
    }
}
