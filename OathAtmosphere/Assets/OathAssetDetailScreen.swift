import OathAnkr
import OathDiagnostics
import SwiftUI
import Charts
import OathDatabase
import OathMarketData

struct OathAssetDetailScreen: View {
    let route: OathAssetRoute
    let session: OathWalletSession
    @Environment(\.oathWalletSidebar) private var sidebar
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = OathAssetDetailModel()
    @State private var sheet: Sheet?
    @State private var showsScanner = false
    @State private var scannedRecipient: OathScannedRecipient?
    @State private var scanUsesCurrentAsset = true
    @State private var selectedTransaction: HistoryEntry?
    @State private var showsAllActivity = false
    private enum Sheet: Identifiable {
        case receive, send, information, verification, priceChart
        var id: String {
            switch self {
            case .receive: "receive"
            case .send: "send"
            case .information: "information"
            case .verification: "verification"
            case .priceChart: "priceChart"
            }
        }
    }
    private var holding: Holding {
        if let current = session.portfolio?.holdings.first(where: { $0.id == route.holding.id }) { return current }
        if route.holding.networkID == "solana",
           let activeAddress = session.portfolio?.holdings.first(where: {
               $0.accountID == route.holding.accountID && $0.reference == "native"
           })?.address, activeAddress != route.holding.address {
            return route.holding.withoutBalance(address: activeAddress)
        }
        return route.holding
    }
    private var asset: MarketAsset {
        MarketAsset(id: holding.assetID, networkID: holding.networkID, reference: holding.reference, decimals: holding.decimals)
    }
    private var currency: String { session.portfolio?.currency ?? "USD" }
    private var active: Bool { scenePhase == .active && session.isUnlocked && session.portfolio?.wallet.id == route.walletID }
    private var metadataReady: Bool { active && !holding.isCatalogPreview && !session.usesSyntheticPortfolio }
    private var network: NetworkRecord? { session.portfolio?.networks.first { $0.id == route.holding.networkID } }
    private var networkName: String { network?.name ?? OathImportChain(rawValue: holding.networkID)?.name ?? holding.networkID }
    private var receiveAddress: OathWalletAddress? {
        guard let chain = OathImportChain(rawValue: holding.networkID) else { return nil }
        let path = session.portfolio?.accounts.first { $0.id == holding.accountID }?.derivationPath ?? ""
        return OathWalletAddress(chain: chain, address: holding.address, path: path,
            accountID: holding.accountID, assetID: holding.assetID,
            storedNetworkName: networkName, storedTicker: chain.ticker, storedLogo: chain.logoAsset)
    }

    private func refresh() async throws {
        guard !holding.isCatalogPreview else { return }
        guard !session.usesSyntheticPortfolio else { return }
        // Quote/info/chart requests can run alongside the ledger update. The
        // common refresh owner bounds presentation independently of this work
        // and still handles cancellation when its screen/wallet is invalidated.
        async let market: Void = model.refresh(asset: asset, walletID: route.walletID,
                                               accountID: holding.accountID, force: true)
        do {
            if holding.usesUTXOLedger { try await session.refreshBitcoin() }
            else if holding.networkID == "tron" { try await session.refreshTron() }
            else if holding.networkID == "ton" { try await session.refreshTon() }
            else if holding.networkID == "aptos" { try await session.refreshAptos() }
            else if holding.networkID == "sui" { try await session.refreshSui() }
            else if holding.networkID == "thorchain" { try await session.refreshThorchain() }
            else if holding.networkID == "near" { try await session.refreshNear() }
            else if holding.networkID == "xrpl" { try await session.refreshXrpl() }
            else if holding.networkID == "polkadot" { try await session.refreshPolkadot() }
            else if holding.networkID == "stellar" { try await session.refreshStellar() }
            else if holding.networkID == "solana" { try await session.refreshSolana() }
            else if holding.networkID == "cronos" { try await session.refreshCronos() }
            else if holding.networkID == "arc" { try await session.refreshArc() }
            else if let chain = IndexedEVMChain(rawValue: holding.networkID) { try await session.refreshIndexedEVM(chain) }
            else if holding.networkID == "hyperevm" { try await session.refreshHyperEVM() }
            else if holding.networkID == "robinhood" { try await session.refreshRobinhood() }
            else if AnkrSynchronizer.supports(networkID: holding.networkID) { try await session.refreshAnkr() }
            await market
            try Task.checkCancellation()
        } catch { OathDiagnostics.record(error);
            await market
            throw error
        }
    }

    var body: some View {
        GeometryReader { geometry in
            OathWalletRefreshScroll(identifier: "asset.scroll",
                colorHex: session.wallets.first { $0.id == route.walletID }?.colorHex,
                timing: .fixed(.milliseconds(1_500)),
                isEnabled: active && !session.changingWallet,
                refreshIdentity: "\(route.walletID):\(holding.id):\(holding.address)",
                action: refresh) {
                OathHeaderScrollContent(viewportHeight: geometry.size.height, fillsViewport: model.history.isEmpty) {
                    summary()
                } content: {
                    OathEmptyStateLayout(centersContent: model.history.isEmpty) {
                        Text(strings.text(.assetActivity)).oathFont(.title3, weight: .bold)
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 28)
                        activity.padding(.bottom, 28)
                        VStack(alignment: .leading, spacing: 0) {
                            OathHairline()
                                .padding(.horizontal, -20)
                                .padding(.bottom, 12)
                            if holding.reference != "native" { verificationRow }
                            priceRow
                            OathButton { sheet = .information } label: {
                                OathSettingsRow(title: strings.text(.assetInformation), icon: "info.circle",
                                    subtitle: strings.text(.assetInformationDetail))
                            }
                            .buttonStyle(OathSettingsRowButtonStyle())
                            .padding(.horizontal, -20)
                            .accessibilityIdentifier("asset.informationRow")
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 40)
                    .frame(maxWidth: 700).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
        .toolbar { assetToolbar }
        .toolbar(.hidden, for: .bottomBar, .tabBar)
        .navigationDestination(isPresented: Binding(get: { selectedTransaction != nil }, set: { if !$0 { selectedTransaction = nil } })) {
            if let selectedTransaction {
                OathTransactionDetailScreen(entry: model.history.first { $0.id == selectedTransaction.id }?.entry ?? selectedTransaction,
                    holding: holding, networkName: networkName, currency: currency, balancesHidden: session.balancesHidden)
            }
        }
        .navigationDestination(isPresented: $showsAllActivity) {
            OathChainActivityScreen(walletID: route.walletID, networkID: holding.networkID,
                networkName: networkName, accountID: holding.accountID, assetID: holding.assetID, session: session)
                .toolbar(.hidden, for: .tabBar)
        }
        .oathNativeAppBar(title: strings.invariant(holding.name))
        .oathScannerCover(isPresented: $showsScanner, onDismiss: {
            guard scannedRecipient != nil, canScan else { scannedRecipient = nil; return }
            sheet = .send
        }) {
            if let chain = OathImportChain(rawValue: holding.networkID) {
                OathScanner(strings: strings, onPayload: { _ in showsScanner = false },
                    onFailure: { _ in showsScanner = false }, onClose: { showsScanner = false },
                    title: .scan, identifier: "asset.scanner.camera",
                    context: .asset(chain, reference: holding.reference, symbol: holding.symbol),
                    onRecipient: { result, _ in finishScan(result, usesCurrentAsset: true) },
                    onSelectAsset: { result in finishScan(result, usesCurrentAsset: false) })
                    .environment(\.oathScanSession, session)
            }
        }
        .sheet(item: $sheet, onDismiss: { scannedRecipient = nil; scanUsesCurrentAsset = true }) { selection in
            Group {
                switch selection {
                case .receive:
                    if let receiveAddress { OathReceiveSheet(address: receiveAddress, session: session, holding: holding) }
                case .send:
                    OathSendFlow(session: session, walletID: route.walletID,
                        holdingID: scanUsesCurrentAsset ? holding.id : nil, scannedRecipient: scannedRecipient,
                        initialHolding: scanUsesCurrentAsset ? holding : nil,
                        startsScannedAmount: scanUsesCurrentAsset && scannedRecipient != nil)
                case .information:
                    OathAssetInformationSheet(holding: holding, networkName: networkName, currency: currency, model: model)
                case .verification:
                    verificationSheet
                case .priceChart:
                    OathAssetPriceSheet(symbol: holding.symbol, quote: displayQuote, chart: model.chart,
                        chartLoading: metadataReady && model.loading && model.chart == nil && !model.chartFailed,
                        chartFailed: model.chartFailed,
                        conversionRate: conversionRate, quoteCurrency: quoteCurrency, priceText: priceText)
                }
            }
            .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
            .oathLanguage(strings.language)
        }
        // Keep Receive/Info mounted beneath the lock. Dismissing this sheet
        // on lock also dismisses UIKit's passcode presentation above it.
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { cancelScan() }
        }
        .onChange(of: session.changingWallet) { _, changing in
            if changing { cancelScan() }
        }
        .onChange(of: session.resetting) { _, resetting in
            if resetting { cancelScan() }
        }
        .onChange(of: session.portfolio?.wallet.id) { _, walletID in
            if walletID != route.walletID { cancelScan() }
        }
        .task(id: metadataReady) {
            guard metadataReady else { return }
            await model.observeHistory(walletID: route.walletID, accountID: holding.accountID, assetID: holding.assetID, currency: currency)
        }
        .task(id: metadataReady) {
            guard metadataReady else { return }
            await model.open(asset: asset, walletID: route.walletID, accountID: holding.accountID)
            // Only the visible asset refreshes, at a bounded frequency. No
            // account/balance RPCs are part of this screen's market-data service.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await model.updateQuote(asset)
            }
        }
        .accessibilityIdentifier("asset.detail")
    }

    private var verificationRow: some View {
        OathButton(feedback: .navigate) { sheet = .verification } label: {
            OathListRow {
                OathSettingsIcon(symbol: "checkmark.shield")
            } content: {
                Text(strings.text(.assetVerificationStatus))
                    .oathFont(.body).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 12)
            } accessory: {
                Label(strings.text(verificationTitle), systemImage: verificationIcon)
                    .labelStyle(.titleAndIcon)
                    .oathFont(.body).foregroundStyle(verificationColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .padding(.horizontal, -20)
        .accessibilityIdentifier("asset.verification.status")
    }

    private var verificationSheet: some View {
        OathWalletSheet(title: .assetVerificationStatus) {
            VStack(alignment: .leading, spacing: 20) {
                Label(strings.text(verificationTitle), systemImage: verificationIcon)
                    .oathFont(.headline).foregroundStyle(verificationColor)
                Text(strings.text(verificationExplanation))
                    .oathFont(.body).fixedSize(horizontal: false, vertical: true)
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("asset.verification.sheet")
    }

    private var verificationTitle: OathStringKey {
        switch model.verificationStatus {
        case .verified: .assetVerificationVerified
        case .unverified: .assetVerificationUnverified
        case .flagged: .assetVerificationFlagged
        case .unknown: .assetVerificationUnknown
        }
    }
    private var verificationExplanation: OathStringKey {
        switch model.verificationStatus {
        case .verified: .assetVerificationVerifiedDetail
        case .unverified: .assetVerificationUnverifiedDetail
        case .flagged: .assetVerificationFlaggedDetail
        case .unknown: .assetVerificationUnknownDetail
        }
    }
    private var verificationIcon: String {
        switch model.verificationStatus {
        case .verified: "checkmark.seal.fill"
        case .unverified, .flagged: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
    private var verificationColor: Color {
        switch model.verificationStatus {
        case .verified: .green
        case .unverified: .orange
        case .flagged: .red
        case .unknown: .secondary
        }
    }

    private func summary() -> some View {
        let format = OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: currency)
        return OathWalletSummary {
            OathWalletBalance(value: String(format.fiat(.init(native: holding.nativeDisplayValue ?? .zero,
                fiat: holding.fiatDisplayValue ?? .zero, currencyCode: currency)).characters),
                concealed: session.balancesHidden, valueIdentifier: "asset.fiatBalance", title: strings.text(.totalBalance))
        } detail: {
            OathBalanceText(value: strings.invariant(format.native(holding.nativeDisplayValue, ticker: holding.symbol)), font: .title3)
                .foregroundStyle(.secondary)
                .oathBalanceConcealed(session.balancesHidden, style: .detail)
                .accessibilityIdentifier("asset.balance")
        } send: {
            send
        } receive: {
            receive
        }
    }
    private var send: some View {
        OathActionButton(title: strings.text(.send), icon: "paperplane", appearance: .wallet) {
            scannedRecipient = nil; scanUsesCurrentAsset = true
            sheet = .send
        }.accessibilityIdentifier("asset.send")
    }
    private var receive: some View {
        OathActionButton(title: strings.text(.receive), icon: "qrcode", appearance: .wallet) {
            sheet = .receive
        }.disabled(receiveAddress == nil).accessibilityIdentifier("asset.receive")
    }

    private var canScan: Bool {
        active && !session.changingWallet && !session.resetting && sheet == nil
            && OathImportChain(rawValue: holding.networkID) != nil
    }

    private func finishScan(_ result: OathScannedRecipient, usesCurrentAsset: Bool) {
        guard canScan else { cancelScan(); return }
        scannedRecipient = result
        scanUsesCurrentAsset = usesCurrentAsset
        showsScanner = false
    }

    private func cancelScan() {
        scannedRecipient = nil
        showsScanner = false
    }

    @ViewBuilder private var priceRow: some View {
        let title = strings.format(.assetPrice, strings.invariant(holding.symbol))
        if let quote = displayQuote {
            OathButton(feedback: .navigate) {
                guard displayQuote != nil else { return }
                sheet = .priceChart
            } label: {
                OathSettingsRow(title: title, icon: "chart.xyaxis.line", subtitle: priceText(quote.value))
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .padding(.horizontal, -20)
            .accessibilityIdentifier("asset.priceRow")
        } else {
            let loading = model.quoteLoading && !holding.isCatalogPreview && !session.usesSyntheticPortfolio
            OathSettingsRow(title: title, icon: "chart.xyaxis.line", accessory: .none,
                subtitle: strings.text(loading ? .assetMarketLoading : .assetPriceUnavailable), isWorking: loading)
                .padding(.horizontal, -20)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("asset.priceUntracked")
        }
    }

    private var displayQuote: (value: Decimal, date: Date?)? {
        if let quote = model.quote, let value = quote.value.decimal, value > 0, quote.isFresh(lifetime: 120), !model.quoteFailed {
            return (value, quote.fetchedAt)
        }
        if let text = holding.usdPrice, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
           value > 0 {
            return (value, holding.priceObservedAt.map(Date.init(timeIntervalSince1970:)))
        }
        if let quote = model.quote, let value = quote.value.decimal, value > 0 { return (value, quote.fetchedAt) }
        return nil
    }

    private var conversionRate: Double {
        guard currency != "USD", let rate = holding.exchangeRate.flatMap(Double.init), rate.isFinite, rate > 0 else { return 1 }
        return rate
    }
    private var quoteCurrency: String { currency == "USD" || holding.exchangeRate != nil ? currency : "USD" }
    private func priceText(_ usd: Decimal) -> String {
        let rate = holding.exchangeRate.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } ?? 1
        let converted = FiatConversion.multiply(usd, currency == "USD" ? 1 : rate) ?? usd
        return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: quoteCurrency).money(converted)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.history.isEmpty {
                if model.loadingHistory && !route.holding.isCatalogPreview {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else {
                    let incomplete = model.historyFailed || session.portfolio?.accountSync.contains(where: {
                        $0.accountID == holding.accountID && $0.stream != "balances" && !$0.complete
                    }) == true
                    OathEmptyState(strings.text(incomplete ? .assetActivity : .assetActivityEmpty),
                        systemImage: "arrow.left.arrow.right", description: strings.text(IndexedEVMChain(rawValue: holding.networkID)?.usesRPCCatalog == true ? .assetActivityLocalOnly : .assetActivityEmptyDetail))
                        .accessibilityIdentifier("asset.activityEmpty")
                }
            } else {
                VStack(spacing: 0) {
                    OathActivityRows(items: Array(model.history.prefix(5)),
                        currency: currency, balancesHidden: session.balancesHidden) { selectedTransaction = $0.entry }
                }.padding(.horizontal, -20)
            }
            if model.hasMoreHistory {
                OathButton { showsAllActivity = true } label: {
                    Text(strings.text(.assetViewAllActivity))
                        .oathFont(.body, weight: .medium)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.gray).foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("asset.activity.viewAll")
            }
        }
    }

    @ToolbarContentBuilder private var assetToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            OathButton(strings.text(.assetInformation), systemImage: "info.circle") { sheet = .information }
                .accessibilityIdentifier("asset.information")
        }
        ToolbarItem(placement: .topBarTrailing) {
            OathButton(strings.text(.scan), systemImage: "viewfinder", feedback: .scan) {
                guard canScan else { return }
                scannedRecipient = nil
                scanUsesCurrentAsset = true
                showsScanner = true
            }
            .disabled(!canScan)
            .accessibilityIdentifier("asset.scanner")
        }
    }
}

private struct OathAssetPriceSheet: View {
    let symbol: String
    let quote: (value: Decimal, date: Date?)?
    let chart: CachedMarketValue<MarketChart>?
    let chartLoading: Bool
    let chartFailed: Bool
    let conversionRate: Double
    let quoteCurrency: String
    let priceText: (Decimal) -> String
    @State private var chartSelectedDate: Date?
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OathWalletSheet(title: .assetChart24h) {
            VStack(alignment: .leading, spacing: 10) {
                Text(strings.format(.assetPrice, strings.invariant(symbol)))
                    .oathFont(.subheadline).foregroundStyle(.secondary)
                HStack {
                    if let price = selectedChartPoint.map({ Decimal($0.close) }) ?? quote?.value {
                        Text(priceText(price)).oathFont(.title2, weight: .medium).monospacedDigit()
                            .accessibilityIdentifier("asset.price")
                    }
                    Spacer(minLength: 8)
                    if let chart, chart.isFresh(lifetime: 600), !chartFailed, let change = chart.value.changePercent {
                        Text(change.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2))
                            .locale(strings.language.locale)) + "%")
                            .oathFont(.subheadline).foregroundStyle(OathAssetChartPalette.color(for: change)).monospacedDigit()
                    }
                }
                if let date = selectedChartPoint.map({ Date(timeIntervalSince1970: $0.time) }) ?? quote?.date {
                    Text(date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(strings.language.locale)))
                        .oathFont(.caption2).foregroundStyle(.secondary)
                }
                if let chart, chart.value.points.count >= 2 {
                    chartContent(chart)
                } else if chartLoading {
                    ProgressView(strings.text(.assetMarketLoading)).frame(maxWidth: .infinity)
                } else {
                    Text(strings.text(.assetChartUnavailable)).oathFont(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { chartSelectedDate = nil } }
    }

    private var selectedChartPoint: MarketCandle? {
        chart?.value.point(nearest: chartSelectedDate)
    }

    @ViewBuilder private func chartContent(_ saved: CachedMarketValue<MarketChart>) -> some View {
        OathMarketPriceChart(chart: saved.value, fetchedAt: saved.fetchedAt, range: .day, conversionRate: conversionRate,
                             priceText: priceText, chartSelectedDate: $chartSelectedDate)
        Text(strings.format(.assetChartCurrency, quoteCurrency)).oathFont(.caption2).foregroundStyle(.secondary)
    }
}

extension MarketChart {
    func point(nearest date: Date?) -> MarketCandle? {
        guard let date, let index = nearestPointIndex(to: date.timeIntervalSince1970) else { return nil }
        return points[index]
    }
}

struct OathMarketPriceChart: View {
    let chart: MarketChart
    let fetchedAt: Date
    let range: MarketHistoryRange
    let conversionRate: Double
    let priceText: (Decimal) -> String
    @Binding var chartSelectedDate: Date?
    @Environment(\.oathLocalizer) private var strings

    private var selectedChartPoint: MarketCandle? { chart.point(nearest: chartSelectedDate) }
    private var axisDateFormat: Date.FormatStyle {
        let span = (chart.points.last?.time ?? 0) - (chart.points.first?.time ?? 0)
        if range == .day || span <= 86_400 { return .dateTime.hour(.defaultDigits(amPM: .abbreviated)) }
        if span <= 90 * 86_400 { return .dateTime.month(.abbreviated).day() }
        return .dateTime.month(.abbreviated).year(.twoDigits)
    }

    var body: some View {
        let points = chart.points
        let rate = conversionRate
        let minimum = (points.map(\.close).min() ?? 0) * rate
        let maximum = (points.map(\.close).max() ?? 1) * rate
        let inset = max((maximum - minimum) * 0.12, maximum * 0.001)
        let lowerBound = max(0, minimum - inset)
        let change = chart.changePercent ?? ((points.last?.close ?? 0) - (points.first?.close ?? 0))
        let color = OathAssetChartPalette.color(for: change)
        Chart {
            ForEach(chart.plotPoints(limit: 240)) { point in
                AreaMark(x: .value(strings.text(.assetTime), Date(timeIntervalSince1970: point.time)),
                         yStart: .value(strings.text(.assetPriceLabel), lowerBound),
                         yEnd: .value(strings.text(.assetPriceLabel), point.close * rate))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
                LineMark(x: .value(strings.text(.assetTime), Date(timeIntervalSince1970: point.time)),
                         y: .value(strings.text(.assetPriceLabel), point.close * rate))
                    // Monotone curves soften corners without inventing
                    // peaks or troughs between the actual closing prices.
                    .interpolationMethod(.monotone)
                    .lineStyle(.init(lineWidth: 2.75, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(color)
            }
            if let selected = selectedChartPoint {
                RuleMark(x: .value(strings.text(.assetTime), Date(timeIntervalSince1970: selected.time)))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                    .accessibilityHidden(true)
                PointMark(x: .value(strings.text(.assetTime), Date(timeIntervalSince1970: selected.time)),
                          y: .value(strings.text(.assetPriceLabel), selected.close * rate))
                    .symbolSize(65)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            } else if let last = points.last {
                PointMark(x: .value(strings.text(.assetTime), Date(timeIntervalSince1970: last.time)),
                          y: .value(strings.text(.assetPriceLabel), last.close * rate))
                    .symbolSize(30)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
        }
        .chartXSelection(value: $chartSelectedDate)
        .onChange(of: chartSelectedDate) { oldDate, newDate in
            guard let newDate,
                  let index = chart.nearestPointIndex(to: newDate.timeIntervalSince1970) else { return }
            let oldIndex = oldDate.flatMap { chart.nearestPointIndex(to: $0.timeIntervalSince1970) }
            guard index != oldIndex else { return }
            let spread = maximum - minimum
            let height = spread > 0 ? (points[index].close * rate - minimum) / spread : 0.5
            let movement = oldIndex.map { spread > 0 ? abs(points[index].close - points[$0].close) * rate / spread : 0 } ?? 0
            OathHaptics.shared.playChartSample(height: height, movement: movement)
        }
        .onChange(of: fetchedAt) { _, _ in chartSelectedDate = nil }
        .chartYScale(domain: lowerBound...(maximum + inset))
        .chartXScale(range: .plotDimension(padding: 5))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine(stroke: .init(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.16))
                AxisValueLabel(format: maximum < 1
                    ? FloatingPointFormatStyle<Double>(locale: strings.language.locale).precision(.significantDigits(1...4))
                    : FloatingPointFormatStyle<Double>(locale: strings.language.locale).notation(.compactName).precision(.fractionLength(0...2)))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisValueLabel(format: axisDateFormat.locale(strings.language.locale))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(height: 180).padding(.top, 16)
        // Time increases left to right in all languages; surrounding UI is RTL-aware.
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.locale, strings.language.locale)
        .accessibilityIdentifier("asset.chart")
        .accessibilityValue(selectedChartPoint.map {
            priceText(Decimal($0.close)) + ", " + Date(timeIntervalSince1970: $0.time)
                .formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(strings.language.locale))
        } ?? "")
        .accessibilityAdjustableAction { direction in
            let index = chartSelectedDate.flatMap {
                chart.nearestPointIndex(to: $0.timeIntervalSince1970)
            } ?? (points.count - 1)
            switch direction {
            case .increment: chartSelectedDate = Date(timeIntervalSince1970: points[min(points.count - 1, index + 1)].time)
            case .decrement: chartSelectedDate = Date(timeIntervalSince1970: points[max(0, index - 1)].time)
            @unknown default: break
            }
        }
    }
}

/// Explicit adaptive chart colors never inherit the artwork's white tint.
enum OathAssetChartPalette {
    static func color(for change: Double) -> Color {
        guard change.isFinite, change != 0 else { return Color(uiColor: .secondaryLabel) }
        return Color(uiColor: UIColor { traits in
            if change > 0 {
                return traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.22, green: 0.83, blue: 0.62, alpha: 1)
                    : UIColor(red: 0.05, green: 0.52, blue: 0.36, alpha: 1)
            }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0.40, blue: 0.45, alpha: 1)
                : UIColor(red: 0.84, green: 0.17, blue: 0.25, alpha: 1)
        })
    }
}

struct OathAssetLogo: View {
    let holding: Holding
    let information: AssetInformation?
    var size: CGFloat = 56
    var body: some View {
        if holding.reference == "native" {
            OathNetworkLogo(asset: OathImportChain(rawValue: holding.networkID)?.logoAsset ?? holding.logo ?? "network-" + holding.networkID, size: size)
        } else {
            OathTokenLogo(source: information?.imageURL ?? holding.logo, symbol: holding.symbol, size: size, fallbackSource: holding.logo, identity: holding.artworkIdentity)
        }
    }



}
