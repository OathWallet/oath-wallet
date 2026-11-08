import SwiftUI

/// Shared visual contract for Home and asset details. Screens supply data and
/// actions, never their own balance typography, slot sizing or header insets.
enum OathWalletSummaryStyle {
    static let horizontalInset: CGFloat = 24
    static let maximumWidth: CGFloat = 700
    static let identityHeight: CGFloat = 56
    static let detailHeight: CGFloat = 44
    static let balanceFont = Font.system(size: 58, weight: .semibold, design: .default)
}

struct OathWalletSummary<Balance: View, Detail: View, Send: View, Receive: View>: View {
    let viewportHeight: CGFloat
    let bottomSafeAreaInset: CGFloat
    @ViewBuilder let balance: () -> Balance
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let send: () -> Send
    @ViewBuilder let receive: () -> Receive
    @ScaledMetric(relativeTo: .subheadline) private var detailHeight = OathWalletSummaryStyle.detailHeight

    var body: some View {
        OathWalletSummaryLayout(viewportHeight: viewportHeight, bottomSafeAreaInset: bottomSafeAreaInset) {
            VStack(spacing: 12) {
                balance()
                // Keep the shared height below the detail, not between balances.
                detail().frame(minHeight: detailHeight, alignment: .top)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: OathActionMetrics.spacing) { send(); receive() }
                VStack(spacing: OathActionMetrics.spacing) { send(); receive() }
            }
            .oathActionArea(existingInset: OathWalletSummaryStyle.horizontalInset)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, OathWalletSummaryStyle.horizontalInset)
        .frame(maxWidth: OathWalletSummaryStyle.maximumWidth)
        .frame(maxWidth: .infinity)
    }
}

struct OathWalletBalance<Identity: View>: View {
    let value: String
    let concealed: Bool
    var valueIdentifier = "home.balanceValue"
    @ViewBuilder let identity: () -> Identity
    @ScaledMetric(relativeTo: .subheadline) private var identityHeight = OathWalletSummaryStyle.identityHeight

    var body: some View {
        VStack(spacing: 8) {
            identity()
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: identityHeight)
            Text(verbatim: value)
                .font(OathWalletSummaryStyle.balanceFont)
                .lineLimit(1).minimumScaleFactor(0.5).monospacedDigit()
                .contentTransition(.opacity)
                .oathBalanceConcealed(concealed, radius: 22)
                .accessibilityIdentifier(valueIdentifier)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
    }
}
