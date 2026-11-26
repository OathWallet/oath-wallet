import SwiftUI
import OathDiagnostics
import OathMarketData

struct OathExploreAssetSelection: Hashable {
    let token: ExploreToken
    var source: ExploreSource?
    var fetchedAt: Date?
    var catalogueCoinID: String?

    var marketAsset: MarketAsset? {
        guard let asset = token.detailAsset else { return nil }
        let decimals = asset.reference == "native" ? OathImportChain(rawValue: asset.network)?.nativeDecimals : asset.decimals
        guard let decimals else { return nil }
        return .init(id: asset.id, networkID: asset.network, reference: asset.reference, decimals: decimals)
    }
}

struct OathExploreAssetDetail: View {
    let selection: OathExploreAssetSelection
    let session: OathWalletSession
    let openHolding: (OathAssetRoute) -> Void
    @State private var range = MarketHistoryRange.day
    @State private var histories: [MarketHistoryRange: CachedMarketValue<ExplorePriceHistory>] = [:]
    @State private var chartUnavailable = Set<MarketHistoryRange>()
    @State private var retry = 0
    @State private var selectedDate: Date?
    @State private var quote: CachedMarketValue<MarketQuote>?
    @State private var information: CachedMarketValue<AssetInformation>?
    @State private var loadingInfo = true
    @State private var showsNetworks = false
    @State private var pendingHolding: OathAssetRoute?
    @Environment(\.oathLocalizer) private var strings

    private var token: ExploreToken { selection.token }
    private var marketRequest: ExploreHistoryRequest? {
        ExploreHistoryRequest(token: token, source: selection.source, catalogueCoinID: selection.catalogueCoinID)
    }
    private var history: CachedMarketValue<ExplorePriceHistory>? { histories[range] }
    private var selectedPoint: MarketCandle? { history?.value.chart.point(nearest: selectedDate) }
    private var displayedPrice: (value: Double, date: Date?)? {
        if let point = selectedPoint { return (point.close, Date(timeIntervalSince1970: point.time)) }
        let observedAt = token.observedAt ?? selection.fetchedAt
        if let quote, let decimal = quote.value.decimal, token.price <= 0 || quote.fetchedAt >= (observedAt ?? .distantPast) {
            return (NSDecimalNumber(decimal: decimal).doubleValue, quote.fetchedAt)
        }
        if token.price > 0 { return (token.price, observedAt) }
        guard let point = history?.value.chart.points.last else { return nil }
        return (point.close, Date(timeIntervalSince1970: point.time))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pricePanel
                statistics
                if let info = information?.value {
                    if !info.description.isEmpty || info.website.flatMap(MarketDecoding.safeURL) != nil {
                        about(info)
                    }
                } else if loadingInfo {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(strings.text(.assetAbout)).oathFont(.headline)
                        Text(strings.text(.assetMarketLoading)).oathFont(.subheadline)
                    }.modifier(OathExploreShimmer())
                }
                if !token.assets.isEmpty {
                    OathButton { showsNetworks = true } label: {
                        OathSettingsRow(title: strings.text(.historyNetworks), value: strings.number(Set(token.assets.map(\.network)).count))
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .padding(.horizontal, -20)
                    .accessibilityIdentifier("explore.asset.networks")
                }
                Text(strings.text(.exploreTokenDisclaimer))
                    .oathFont(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .background { Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea() }
        .oathNativeAppBar(title: token.symbol)
        .task { await loadOverview() }
        .task(id: HistoryLoad(range: range, retry: retry)) { await loadHistory(range) }
        .sheet(isPresented: $showsNetworks, onDismiss: {
            if let pendingHolding, session.displayedProfile?.id.uuidString == pendingHolding.walletID {
                openHolding(pendingHolding)
            }
            pendingHolding = nil
        }) {
            OathExploreNetworksSheet(token: token, session: session) { route in
                pendingHolding = route
                showsNetworks = false
            }
        }
    }

    private var pricePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                OathExploreTokenArtwork(token: token, size: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: token.name).oathFont(.title3, weight: .semibold)
                    Text(verbatim: token.symbol).oathFont(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let rank = token.rank {
                    Text(verbatim: "#" + strings.number(rank)).oathFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: displayedPrice.map { ExploreFormat.price($0.value) } ?? "—")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let change = history?.value.chart.changePercent {
                    HStack(spacing: 6) {
                        ExploreChange(value: change)
                        Text(verbatim: range.label).foregroundStyle(.secondary)
                    }.oathFont(.subheadline, weight: .semibold)
                } else if range == .day, let change = token.change24h {
                    HStack(spacing: 6) {
                        ExploreChange(value: change)
                        Text(verbatim: ExploreFormat.dayLength(locale: strings.language.locale)).foregroundStyle(.secondary)
                    }.oathFont(.subheadline, weight: .medium)
                }
                if let date = displayedPrice?.date {
                    Text(verbatim: timestamp(date)).oathFont(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 4)
            if let history {
                OathMarketPriceChart(chart: history.value.chart, fetchedAt: history.fetchedAt, range: range,
                                     conversionRate: 1, priceText: { ExploreFormat.price(NSDecimalNumber(decimal: $0).doubleValue) },
                                     chartSelectedDate: $selectedDate)
            } else if chartUnavailable.contains(range) {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(strings.text(.exploreUnavailable)).oathFont(.subheadline).foregroundStyle(.secondary)
                    Button(strings.text(.tryAgain)) { retry &+= 1 }.oathFont(.subheadline, weight: .semibold)
                }.frame(maxWidth: .infinity, minHeight: 180)
            } else {
                RoundedRectangle(cornerRadius: 14).fill(.secondary.opacity(0.12))
                    .frame(height: 180).modifier(OathExploreShimmer())
                    .accessibilityHidden(false).accessibilityLabel(strings.text(.assetMarketLoading))
            }
            ViewThatFits(in: .horizontal) {
                rangeButtons
                ScrollView(.horizontal) { rangeButtons }.scrollIndicators(.hidden)
            }
        }
        .padding(18).background(Color(uiColor: OathSurfaceColors.exploreCard), in: .rect(cornerRadius: 24))
    }

    private var rangeButtons: some View {
        HStack(spacing: 0) {
            ForEach(MarketHistoryRange.allCases, id: \.self) { period in
                Button {
                    selectedDate = nil
                    range = period
                } label: {
                    Text(verbatim: period.label).oathFont(.subheadline, weight: .semibold)
                        .fixedSize().padding(.horizontal, 5).frame(minWidth: 44, minHeight: 44)
                        .background { if range == period { Capsule().fill(Color(uiColor: OathSurfaceColors.card)) } }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(period.spokenLabel(locale: strings.language.locale))
                .accessibilityAddTraits(range == period ? .isSelected : [])
                .accessibilityIdentifier("explore.range." + period.label)
            }
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var statistics: some View {
        let info = information?.value
        let cap = info?.marketCaps?["usd"].map { NSDecimalNumber(decimal: $0).doubleValue } ?? token.marketCap
        let circulating = info?.circulatingSupply.map { NSDecimalNumber(decimal: $0).doubleValue } ?? token.circulatingSupply
        let total = info?.totalSupply.map { NSDecimalNumber(decimal: $0).doubleValue } ?? token.totalSupply
        if cap != nil || token.volume24h != nil || token.liquidity != nil || circulating != nil || total != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.text(.assetInformation)).oathFont(.headline).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    statistic(.exploreMarketCap, value: cap)
                    statistic(.exploreVolume, value: token.volume24h)
                    statistic(.exploreLiquidity, value: token.liquidity)
                    statistic(.assetCirculatingSupply, value: circulating, supply: true)
                    statistic(.assetTotalSupply, value: total, supply: true)
                }.padding(16).background(Color(uiColor: OathSurfaceColors.exploreCard), in: .rect(cornerRadius: 18))
            }
        }
    }

    @ViewBuilder private func statistic(_ key: OathStringKey, value: Double?, supply: Bool = false) -> some View {
        if let value, value.isFinite, value >= 0 {
            LabeledContent(strings.text(key)) {
                Text(verbatim: supply ? value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) + " " + token.symbol : ExploreFormat.compact(value))
                    .foregroundStyle(.primary).monospacedDigit()
            }.oathFont(.subheadline)
        }
    }

    private func about(_ info: AssetInformation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.text(.assetAbout)).oathFont(.headline).accessibilityAddTraits(.isHeader)
            if !info.description.isEmpty {
                Text(verbatim: info.description).oathFont(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let website = info.website.flatMap(MarketDecoding.safeURL) {
                Link(destination: website) { Label(strings.text(.assetWebsite), systemImage: "arrow.up.right.square") }
                    .oathFont(.subheadline, weight: .medium)
            }
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(strings.language.locale))
    }

    private struct HistoryLoad: Hashable { let range: MarketHistoryRange; let retry: Int }

    private func loadHistory(_ period: MarketHistoryRange) async {
        guard let request = marketRequest else {
            chartUnavailable.insert(period)
            return
        }
        chartUnavailable.remove(period)
        do {
            let service = try await OathMarketEnvironment.shared.service()
            if histories[period] == nil, let saved = try await service.cachedHistory(request, range: period) {
                try Task.checkCancellation()
                histories[period] = saved
            }
            let updated = try await service.history(request, range: period)
            try Task.checkCancellation()
            histories[period] = updated
        } catch {
            guard !Task.isCancelled else { return }
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "explore", operation: "asset_history",
                                       context: ["chain": token.detailAsset?.network ?? "unknown"])
            }
            chartUnavailable.insert(period)
        }
    }

    private func loadOverview() async {
        defer { if !Task.isCancelled { loadingInfo = false } }
        guard let network = token.detailAsset?.network else { return }
        do {
            let service = try await OathMarketEnvironment.shared.service()
            try await OathDiagnostics.withChain(network) {
                if let asset = selection.marketAsset {
                    async let quoteWork: Void = loadQuote(asset, service: service)
                    async let infoWork: Void = loadInformation(asset, service: service)
                    _ = await (quoteWork, infoWork)
                } else if let request = marketRequest {
                    if let saved = try await service.cachedDiscoveryInformation(request) {
                        try Task.checkCancellation()
                        information = saved
                    }
                    let updated = try await service.discoveryInformation(request)
                    try Task.checkCancellation()
                    information = updated
                }
            }
        } catch {
            if !Task.isCancelled, error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "explore", operation: "asset_overview", context: ["chain": network])
            }
        }
    }

    private func loadInformation(_ asset: MarketAsset, service: MarketDataService) async {
        defer { if !Task.isCancelled { loadingInfo = false } }
        do {
            if let saved = try await service.cachedInformation(for: asset) {
                try Task.checkCancellation()
                information = saved
            }
            let updated = try await service.information(for: asset)
            try Task.checkCancellation()
            information = updated
            if let enriched = try await service.enrichTokenInformation(for: asset) {
                try Task.checkCancellation()
                information = enriched
            }
        } catch {
            if !Task.isCancelled, error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "explore", operation: "asset_information", context: ["chain": asset.networkID])
            }
        }
    }

    private func loadQuote(_ asset: MarketAsset, service: MarketDataService) async {
        do {
            if let saved = try await service.cachedExploreQuote(for: asset) {
                try Task.checkCancellation()
                quote = saved
            }
            let updated = try await service.exploreQuote(for: asset)
            try Task.checkCancellation()
            quote = updated
        } catch {
            if !Task.isCancelled, error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "explore", operation: "asset_quote", context: ["chain": asset.networkID])
            }
        }
    }
}

private struct OathExploreNetworksSheet: View {
    let token: ExploreToken
    let session: OathWalletSession
    let openHolding: (OathAssetRoute) -> Void
    private struct TokenSelection: Identifiable {
        let token: OathTokenDefinition
        let walletID: String
        var id: String { token.id }
    }
    @State private var selectedToken: TokenSelection?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        NavigationStack {
            List(token.assets) { asset in
                networkRow(asset)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .navigationTitle(strings.text(.historyNetworks))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    OathCloseButton { dismiss() }.accessibilityIdentifier("explore.networks.close")
                }
            }
            .oathNativeLocalization()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedToken) { selection in
            OathTokenDetailsSheet(token: selection.token, session: session, walletID: selection.walletID)
        }
    }

    @ViewBuilder private func networkRow(_ asset: ExploreAsset) -> some View {
        if let snapshot = session.portfolio, snapshot.wallet.id == session.displayedProfile?.id.uuidString,
           let holding = snapshot.holdings.first(where: {
               $0.networkID == asset.network && $0.reference == asset.reference &&
                   (asset.reference == "native" || $0.isHomeListCandidate(hidingUnverified: snapshot.assetFilter.hidesUnverifiedTokens,
                                                                          hiddenAssetIDs: snapshot.hiddenAssetIDs))
           }) {
            OathButton { openHolding(.init(walletID: snapshot.wallet.id, holding: holding)) } label: {
                rowLabel(asset, actionable: true)
            }.buttonStyle(OathSettingsRowButtonStyle())
        } else if asset.reference != "native", let walletID = session.displayedProfile?.id.uuidString,
                  let value = OathTokenDefinition.discovery(networkID: asset.network, reference: asset.reference,
                    name: token.name, symbol: token.symbol, decimals: asset.decimals, logo: token.image) {
            OathButton { selectedToken = TokenSelection(token: value, walletID: walletID) } label: {
                rowLabel(asset, actionable: true)
            }.buttonStyle(OathSettingsRowButtonStyle())
        } else {
            rowLabel(asset, actionable: false)
        }
    }

    private func rowLabel(_ asset: ExploreAsset, actionable: Bool) -> some View {
        let chain = OathImportChain(rawValue: asset.network)
        let name = strings.invariant(chain?.name ?? asset.network)
        let address = asset.reference
        let abbreviated = address.count > 13 ? String(address.prefix(6)) + "…" + String(address.suffix(4)) : address
        let native = address == "native"
        return OathSettingsRow(title: name, value: native ? strings.text(.assetNativeCoin) : strings.invariant(abbreviated),
                               keepsValueInline: true, accessory: actionable ? .disclosure : .none,
                               networkLogo: chain?.logoAsset ?? "network-" + asset.network)
            .accessibilityLabel(name)
            .accessibilityValue(native ? strings.text(.assetNativeCoin) : strings.invariant(address))
    }
}

private extension MarketHistoryRange {
    func spokenLabel(locale: Locale) -> String {
        let component: DateComponents
        switch self {
        case .day: component = DateComponents(day: 1)
        case .week: component = DateComponents(weekOfMonth: 1)
        case .month: component = DateComponents(month: 1)
        case .quarter: component = DateComponents(month: 3)
        case .halfYear: component = DateComponents(month: 6)
        case .year: component = DateComponents(year: 1)
        }
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        return formatter.string(from: component) ?? label
    }
}
