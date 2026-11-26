import SwiftUI

/// Shared visual contract for Home and asset details. Screens supply data and
/// actions, with optional insets for the compact, title-free Home header.
enum OathWalletSummaryStyle {
    static let horizontalInset: CGFloat = 24
    static let maximumWidth: CGFloat = 700
    static let detailHeight: CGFloat = 44
    static let balanceSize: CGFloat = 58
}

struct OathWalletSummary<Balance: View, Detail: View, Send: View, Receive: View, Scan: View>: View {
    let topInset: CGFloat
    let bottomInset: CGFloat
    @ViewBuilder let balance: () -> Balance
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let send: () -> Send
    @ViewBuilder let receive: () -> Receive
    @ViewBuilder let scan: () -> Scan
    @ScaledMetric(relativeTo: .subheadline) private var detailHeight = OathWalletSummaryStyle.detailHeight

    init(topInset: CGFloat = 36, bottomInset: CGFloat = 40,
         @ViewBuilder balance: @escaping () -> Balance, @ViewBuilder detail: @escaping () -> Detail,
         @ViewBuilder send: @escaping () -> Send, @ViewBuilder receive: @escaping () -> Receive,
         @ViewBuilder scan: @escaping () -> Scan) {
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.balance = balance; self.detail = detail
        self.send = send; self.receive = receive; self.scan = scan
    }

    // Asset details keep their existing two-action composition.
    init(topInset: CGFloat = 36, bottomInset: CGFloat = 40,
         @ViewBuilder balance: @escaping () -> Balance, @ViewBuilder detail: @escaping () -> Detail,
         @ViewBuilder send: @escaping () -> Send, @ViewBuilder receive: @escaping () -> Receive) where Scan == EmptyView {
        self.init(topInset: topInset, bottomInset: bottomInset, balance: balance, detail: detail,
                  send: send, receive: receive, scan: { EmptyView() })
    }

    var body: some View {
        OathWalletSummaryLayout(topInset: topInset, bottomInset: bottomInset) {
            VStack(spacing: 12) {
                balance()
                // Keep the shared height below the detail, not between balances.
                detail().frame(minHeight: detailHeight, alignment: .top)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: OathActionMetrics.spacing) { send(); receive(); scan() }
                VStack(spacing: OathActionMetrics.spacing) { send(); receive(); scan() }
            }
            .oathActionArea(existingInset: OathWalletSummaryStyle.horizontalInset)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, OathWalletSummaryStyle.horizontalInset)
        .frame(maxWidth: OathWalletSummaryStyle.maximumWidth)
        .frame(maxWidth: .infinity)
    }
}

struct OathBalanceText: View {
    let value: String
    let font: Font

    var body: some View {
        Text(verbatim: value)
            .font(font.monospacedDigit())
            .contentTransition(.identity)
            .lineLimit(1, reservesSpace: true)
            .minimumScaleFactor(0.5)
    }
}

struct OathWalletBalance: View {
    let value: String
    let concealed: Bool
    var valueIdentifier = "home.balanceValue"
    var title: String? = nil
    var fontWeight: Font.Weight = .semibold

    var body: some View {
        VStack(spacing: 4) {
            if let title {
                Text(verbatim: title)
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(valueIdentifier).title")
            }
            OathBalanceText(value: value, font: .system(size: OathWalletSummaryStyle.balanceSize, weight: fontWeight))
                .oathBalanceConcealed(concealed, style: .hero)
                .frame(height: OathBalanceMaskStyle.hero.lineHeight)
                .accessibilityIdentifier(valueIdentifier)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
    }
}
