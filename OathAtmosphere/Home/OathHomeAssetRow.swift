import OathDatabase
import SwiftUI

struct OathHomeAssetRow: View, Equatable {
    let chain: OathImportChain
    let presentation: OathHomeAssetPresentation
    let balancesHidden: Bool
    var showsSeparator = false
    var isSearchResult = false
    private var pendingCountText: String {
        presentation.holding.pendingTransactionCount.formatted(
            .number.grouping(.never).locale(strings.language.locale))
    }
    @ScaledMetric(relativeTo: .caption2) private var badgeSize = 18.0
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.layoutDirection) private var layoutDirection

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chain == rhs.chain && lhs.presentation == rhs.presentation &&
        lhs.balancesHidden == rhs.balancesHidden && lhs.showsSeparator == rhs.showsSeparator &&
        lhs.isSearchResult == rhs.isSearchResult
    }

    var body: some View {
        OathRefinedListRow(
            title: strings.invariant(isSearchResult ? presentation.holding.symbol : presentation.holding.name),
            subtitle: isSearchResult ? strings.invariant(presentation.holding.name) : priceDescription,
            value: presentation.fiat,
            primaryFontWeight: .medium,
            detail: strings.invariant(presentation.nativeSummary),
            showsSeparator: showsSeparator,
            concealsAmounts: balancesHidden,
            titleBadgeAsset: isSearchResult || presentation.holding.reference != "native" ? chain.logoAsset : nil,
            assetNetworkName: isSearchResult ? strings.invariant(chain.name) : nil,
            showsAssetNetworkBadge: presentation.holding.reference != "native",
            customSubtitle: isSearchResult ? nil : AnyView(OathAssetUnitPrice(
                price: presentation.unitPrice))
        ) { size in
            OathSendLogo(holding: presentation.holding, size: size, showsChainBadge: false)
                .overlay(alignment: .topTrailing) {
                    if presentation.holding.pendingTransactionCount > 0 {
                        Text(pendingCountText)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: badgeSize, minHeight: badgeSize)
                            .background(.red, in: Capsule())
                            .offset(x: layoutDirection == .rightToLeft ? -5 : 5, y: -5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var priceDescription: String {
        presentation.unitPrice ?? strings.text(.assetPriceUnavailable)
    }

    private var accessibilityText: String {
        let pending = presentation.holding.pendingTransactionCount
        let pendingDescription = pending > 0 ? ", \(strings.text(.assetPending)): \(pendingCountText)" : ""
        let symbol = isSearchResult ? "\(presentation.holding.symbol), " : ""
        let price = isSearchResult ? "" : ", \(strings.text(.assetPriceLabel)): \(priceDescription)"
        let identity = "\(symbol)\(presentation.holding.name), \(chain.name)\(pendingDescription)\(price)"
        if balancesHidden { return "\(identity), \(strings.text(.balanceHidden))" }
        return "\(identity), \(presentation.fiat), \(presentation.nativeFull)"
    }
}

/// Public unit prices stay visible when wallet balances are concealed.
/// Missing market coverage is an expected display state, not a new app error.
struct OathAssetUnitPrice: View {
    let price: String?
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        if let price {
            // Inherit the row subtitle's secondary style, shared with native units.
            Text(verbatim: price)
                .accessibilityIdentifier("home.asset.unitPrice")
        } else {
            Label(strings.text(.assetPriceUnavailable), systemImage: "exclamationmark.circle")
                .labelStyle(OathPriceUntrackedLabelStyle())
                .anchorPreference(key: OathUntrackedPriceBounds.self, value: .bounds) { $0 }
                .accessibilityHidden(true)
        }
    }
}

/// Keep this inline warning out of context-dependent label icon columns.
/// Omitting a spacing value lets SwiftUI choose the native distance between
/// the symbol and title, while retaining both under an icon-only parent style.
struct OathPriceUntrackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.icon
            configuration.title
        }
    }
}

private struct OathUntrackedPriceBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    @ViewBuilder func homeCopyAddressAction(enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        if enabled {
            highPriorityGesture(LongPressGesture().onEnded { _ in action() })
                .accessibilityAction(named: Text(verbatim: label), action)
        } else { self }
    }

    /// A sibling hit target over the label avoids nesting a button inside the
    /// asset navigation button. Remaining row taps still open asset details.
    @ViewBuilder func oathUntrackedPriceAction(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        if enabled { modifier(OathUntrackedPriceAction(action: action)) }
        else { self }
    }
}

struct OathHomeCopiedAsset: Identifiable {
    let id = UUID()
    let holding: Holding
    let networkName: String
    let networkLogo: String
}

struct OathHomeAddressCopyBanner: View {
    @Binding var asset: OathHomeCopiedAsset?
    @State private var isPresented = false
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var logoSize = 20.0

    var body: some View {
        ZStack {
            if let asset {
                capsule(for: asset)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(announcement(for: asset))
                    .accessibilityIdentifier("home.asset.addressCopied")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .blur(radius: isPresented || reduceMotion ? 0 : 5)
        .offset(y: isPresented || reduceMotion ? 0 : -46)
        .opacity(isPresented ? 1 : 0)
        .accessibilityHidden(!isPresented)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .task(id: asset?.id) {
            guard let current = asset else {
                isPresented = false
                return
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.50, dampingFraction: 0.67)) {
                isPresented = true
            }
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: announcement(for: current))
            }
            // The reference starts moving up 1.12 s after the entrance begins.
            do { try await Task.sleep(for: .milliseconds(1_120)) }
            catch { return } // A newer confirmation or leaving Home cancels the timer.
            guard asset?.id == current.id else { return }
            let dismissal = reduceMotion ? Animation.easeOut(duration: 0.15) : .timingCurve(0.2, 0.7, 0.3, 1, duration: 0.30)
            withAnimation(dismissal, completionCriteria: .removed) {
                isPresented = false
            } completion: {
                if asset?.id == current.id, !isPresented { asset = nil }
            }
        }
    }

    private func capsule(for asset: OathHomeCopiedAsset) -> some View {
        let copied = Text(strings.text(.homeAddressCopied))
        return ViewThatFits(in: .horizontal) {
            glassCapsule {
                HStack(spacing: 6) {
                    assetAndNetwork(asset)
                    copied
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            glassCapsule {
                VStack(spacing: 3) {
                    assetAndNetwork(asset)
                    copied
                }
            }
        }
    }

    @ViewBuilder private func glassCapsule<Content: View>(@ViewBuilder label: () -> Content) -> some View {
        let content = label()
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .frame(minHeight: 50)
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }

    private func announcement(for asset: OathHomeCopiedAsset) -> String {
        strings.format(.sendAssetOnNetwork, asset.holding.symbol, asset.networkName) + ". " + strings.text(.homeAddressCopied)
    }

    private func assetAndNetwork(_ asset: OathHomeCopiedAsset) -> some View {
        // Preserve each language's argument order while pairing each label with its artwork.
        let marker = "\u{FFFC}"
        let parts = strings.format(.sendAssetOnNetwork, marker + "asset" + marker, marker + "network" + marker)
            .components(separatedBy: marker)
        return HStack(spacing: 0) {
            ForEach(parts.indices, id: \.self) { index in
                switch parts[index] {
                case "asset":
                    HStack(spacing: 4) {
                        OathSendLogo(holding: asset.holding, size: logoSize, showsChainBadge: false)
                        Text(verbatim: strings.invariant(asset.holding.symbol))
                    }
                case "network":
                    HStack(spacing: 4) {
                        OathNetworkLogo(asset: asset.networkLogo, size: logoSize)
                        Text(verbatim: strings.invariant(asset.networkName))
                    }
                case "": EmptyView()
                default: Text(verbatim: parts[index])
                }
            }
        }
    }
}

private struct OathUntrackedPriceAction: ViewModifier {
    let action: () -> Void
    @Environment(\.oathLocalizer) private var strings
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(OathUntrackedPriceBounds.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    let bounds = geometry[anchor]
                    OathButton(action: action) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: bounds.width, height: max(44, bounds.height))
                    .position(x: bounds.midX, y: bounds.midY)
                    .accessibilityLabel(strings.text(.assetPriceUnavailable))
                    .accessibilityIdentifier("home.asset.priceUntracked")
                }
            }
        }
    }
}

/// Match wallet/input trees: semantic leading indentation, rounded hairlines,
/// and decorative branches that never intercept the asset's tap target.
struct OathAssetTreeHeading: View {
    let chain: OathImportChain
    @ScaledMetric(relativeTo: .body) private var iconSize = 40.0
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = 52.0
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        HStack(spacing: 12) {
            OathNetworkLogo(asset: chain.logoAsset, size: iconSize).frame(width: iconColumnWidth)
                .accessibilityHidden(true)
            Text(strings.invariant(chain.name)).oathFont(.callout, weight: .medium)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 13).frame(minHeight: 78)
        .accessibilityAddTraits(.isHeader)
    }
}

struct OathAssetTreeRow<Content: View>: View {
    let entry: OathHomeRowLayout?
    @ViewBuilder let content: () -> Content
    @ScaledMetric(relativeTo: .body) private var indentation = 28.0
    @ScaledMetric(relativeTo: .body) private var iconSize = 40.0
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = 52.0

    var body: some View {
        content()
            .padding(.leading, entry?.isChild == true ? indentation : 0)
            .overlay {
                if let entry, entry.isChild || entry.hasChildren {
                    OathAssetTreeBranch(isChild: entry.isChild, hasChildren: entry.hasChildren,
                        continues: entry.continues, indentation: indentation,
                        iconSize: iconSize, iconColumnWidth: iconColumnWidth)
                        .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

private struct OathAssetTreeBranch: Shape {
    let isChild: Bool
    let hasChildren: Bool
    let continues: Bool
    let indentation: CGFloat
    let iconSize: CGFloat
    let iconColumnWidth: CGFloat
    var layoutDirectionBehavior: LayoutDirectionBehavior { .mirrors }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + 20 + iconColumnWidth / 2
        if isChild {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: continues ? rect.maxY : rect.midY))
            path.move(to: CGPoint(x: x, y: rect.midY))
            path.addLine(to: CGPoint(x: x + indentation - iconSize / 2 - 4, y: rect.midY))
        }
        if hasChildren {
            path.move(to: CGPoint(x: x, y: rect.midY + iconSize / 2 + 4))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}
