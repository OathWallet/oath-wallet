import SwiftUI
import OathMarketData
import OathAnkr

private struct ExploreAnimationActiveKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var exploreAnimationActive: Bool {
        get { self[ExploreAnimationActiveKey.self] }
        set { self[ExploreAnimationActiveKey.self] = newValue }
    }
}

/// Redact the real row, then move a soft opacity highlight through its shapes.
/// No duplicate layout, white overlay, interaction or placeholder announcements.
struct OathExploreShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var direction
    @Environment(\.exploreAnimationActive) private var active

    func body(content: Content) -> some View {
        content.redacted(reason: .placeholder)
            .mask {
                if reduceMotion || !active || scenePhase != .active {
                    Rectangle()
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        let x = phase * 2.4 - 0.7
                        let center = direction == .rightToLeft ? 1 - x : x
                        LinearGradient(colors: [.black.opacity(0.45), .black, .black.opacity(0.45)],
                                       startPoint: .init(x: center - 0.35, y: 0),
                                       endPoint: .init(x: center + 0.35, y: 0.25))
                    }
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

enum ExploreFormat {
    static let quoteCurrency = "USD"

    static func dayLength(locale: Locale) -> String {
        Duration.seconds(24 * 60 * 60).formatted(.units(allowed: [.hours], width: .narrow).locale(locale))
    }

    static func price(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        if value < 0.00000001 { return "$" + value.formatted(.number.notation(.scientific).precision(.significantDigits(3))) }
        return value.formatted(.currency(code: quoteCurrency).precision(.fractionLength(value < 1 ? 2...8 : 2...2)))
    }
    static func compact(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }
}

struct OathExploreTokenArtwork: View {
    let token: ExploreToken
    var size: CGFloat = 42
    var placeholder = false

    private var logoNetwork: String? {
        guard let asset = token.detailAsset, asset.reference == "native" else { return nil }
        switch MarketIdentity.native[asset.network]?.gecko {
        case "ethereum": return "ethereum"
        case "hyperliquid": return "hyperevm"
        case "usd-coin": return nil
        default: return asset.network
        }
    }

    var body: some View {
        if placeholder {
            RoundedRectangle(cornerRadius: size * 0.25).fill(.primary.opacity(0.12))
                .frame(width: size, height: size)
        } else if let logoNetwork {
            OathNetworkLogo(asset: "network-" + logoNetwork, size: size)
        } else { OathTokenLogo(source: token.image, symbol: token.symbol, size: size) }
    }
}
struct ExploreChange: View {
    let value: Double?
    var body: some View {
        if let value, value.isFinite {
            Text((value > 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(2))) + "%")
                .foregroundStyle(OathAssetChartPalette.color(for: value)).monospacedDigit()
        } else { Text(verbatim: "—").foregroundStyle(.secondary) }
    }
}
struct OathExploreRail<Content: View>: View {
    var lazy = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            if lazy {
                LazyHStack(alignment: .top, spacing: 12) { content() }.scrollTargetLayout()
            } else {
                HStack(alignment: .top, spacing: 12) { content() }.scrollTargetLayout()
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

struct OathExploreCard<Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 182
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(width: min(width, 292), alignment: .leading)
            .foregroundStyle(.primary)
            .background(Color(uiColor: OathSurfaceColors.exploreCard), in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
    }
}

struct OathExploreTokenCard: View {
    let token: ExploreToken
    var placeholder = false
    @Environment(\.oathLocalizer) private var strings
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36

    var body: some View {
        OathExploreCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    OathExploreTokenArtwork(token: token, size: iconSize, placeholder: placeholder)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: token.symbol).oathFont(.body, weight: .semibold)
                        Text(verbatim: token.name).oathFont(.caption).foregroundStyle(.secondary)
                    }.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: ExploreFormat.price(token.price)).oathFont(.title3, weight: .semibold)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    HStack(spacing: 5) {
                        ExploreChange(value: token.change24h)
                        Text(verbatim: ExploreFormat.dayLength(locale: strings.language.locale)).foregroundStyle(.secondary)
                    }.oathFont(.caption, weight: .medium)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ExploreCardLoading(loading: placeholder))
        }
    }
}

private struct ExploreCardLoading: ViewModifier {
    let loading: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if loading { content.modifier(OathExploreShimmer()) } else { content }
    }
}

struct OathExploreTokenRow: View {
    let token: ExploreToken
    var placeholder = false
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 38
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 14) {
            OathExploreTokenArtwork(token: token, size: iconSize, placeholder: placeholder)
                .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    amounts(alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                identity.frame(maxWidth: .infinity, alignment: .leading)
                amounts(alignment: .trailing).layoutPriority(1)
            }
        }
        .frame(minHeight: 56)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: token.symbol).oathFont(.body, weight: .semibold)
            Text(verbatim: token.name).oathFont(.subheadline).foregroundStyle(.secondary)
        }.lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }

    private func amounts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(verbatim: ExploreFormat.price(token.price)).oathFont(.body).monospacedDigit()
            ExploreChange(value: token.change24h).oathFont(.subheadline)
        }.lineLimit(1).minimumScaleFactor(0.8)
    }
}

struct OathExploreSearchCard: View {
    var entry: TokenDiscoveryEntry?
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathExploreCard {
            VStack(alignment: .leading, spacing: 10) {
                if let entry {
                    OathTokenLogo(source: entry.logo, symbol: entry.symbol, size: 36).accessibilityHidden(true)
                } else {
                    RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.12)).frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry?.name ?? strings.text(.tokenDetails)).oathFont(.body, weight: .semibold).lineLimit(2)
                    Text(verbatim: entry.map { $0.symbol + " · " + (OathImportChain(rawValue: $0.network)?.name ?? $0.network) }
                        ?? (strings.text(.assetSymbol) + " · " + strings.text(.tokenNetwork)))
                        .oathFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ExploreCardLoading(loading: entry == nil))
        }
    }
}

struct OathExploreDAppCard: View {
    let app: DAppDescriptor
    let model: OathExploreModel
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathExploreCard {
            VStack(alignment: .leading, spacing: 10) {
                Image("dapp-" + app.id).resizable().scaledToFit().frame(width: 36, height: 36)
                    .clipShape(.rect(cornerRadius: 9)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: app.name).oathFont(.body, weight: .semibold)
                    Text(verbatim: app.domain).oathFont(.caption).foregroundStyle(.secondary)
                    Text(verbatim: app.summary).oathFont(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                if let metric = model.metrics[app.id] {
                    Text(verbatim: valueLocked(metric.value))
                        .oathFont(.caption).foregroundStyle(.secondary)
                } else if model.loadingMetrics.contains(app.id) {
                    Text(verbatim: valueLocked(123_400_000)).oathFont(.caption).modifier(OathExploreShimmer())
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func valueLocked(_ amount: Double) -> String {
        strings.format(.exploreValueLocked, ExploreFormat.compact(amount))
    }
}
