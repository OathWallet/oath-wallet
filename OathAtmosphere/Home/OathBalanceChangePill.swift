import SwiftUI
import OathDatabase
import OathDiagnostics
import OathBalanceChart

/// Recorded balance changes and their native scrubber share one scoped history.
/// The main balance above keeps its stable numeric-transition identity.
struct OathBalanceChangePill: View {
    let session: OathWalletSession
    let visible: Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.colorScheme) private var colorScheme
    @State private var day = BalanceDaySummary.interval(containing: Date())
    @State private var period: BalanceHistoryPeriod = .today
    @State private var showingPeriods = false
    @State private var selectionRevision = 0
    @State private var history: BalanceChartHistory?
    @State private var loadedScope: PeriodContext?
    @State private var selectedPoint: BalanceChartSelection?
    @State private var liveUpdatedAt = Date()

    private struct Context: Hashable {
        let walletID: String
        let currency: String
        let day: DateInterval
        let accountIDs: Set<String>
        let hiddenAssetIDs: Set<String>
        let exchangeRate: Decimal?
    }
    private struct PeriodContext: Hashable {
        let context: Context
        let period: BalanceHistoryPeriod
        let revision: Int
    }
    private var context: Context? {
        guard let portfolio = session.portfolio else { return nil }
        return Context(walletID: portfolio.wallet.id, currency: portfolio.currency, day: day,
            accountIDs: Set(portfolio.accounts.map(\.id)), hiddenAssetIDs: portfolio.hiddenAssetIDs, exchangeRate: portfolio.displayExchangeRate)
    }
    private var visitContext: Context? { visible ? context : nil }
    private var periodContext: PeriodContext? {
        guard session.isUnlocked, !session.changingWallet, !session.resetting, let context else { return nil }
        return PeriodContext(context: context, period: period, revision: selectionRevision)
    }
    private var matchingHistory: BalanceChartHistory? {
        guard let scope = periodContext, loadedScope == scope, let history,
              history.walletID == scope.context.walletID, history.currency == scope.context.currency,
              history.accountIDs == scope.context.accountIDs,
              history.exchangeRate == scope.context.exchangeRate,
              history.hiddenAssetIDs == scope.context.hiddenAssetIDs else { return nil }
        return history
    }
    private var series: BalanceChartSeries {
        let history = matchingHistory
        let end = max(liveUpdatedAt, history?.interval.end ?? liveUpdatedAt)
        let start = history?.interval.start ?? min(period.interval(containing: day.start).start, end)
        var points = history?.points.map { BalanceChartPoint(date: $0.date, value: $0.total) } ?? []
        // Immediate live endpoint while the coalesced database write catches up.
        // Match Home's displayed valuation once a settled baseline exists, even
        // when an unrelated token has no available price. Initial discovery is excluded.
        if let portfolio = session.portfolio, !points.isEmpty {
            points.append(BalanceChartPoint(date: end, value: portfolio.totalFiat))
        }
        return BalanceChartSeries(points: points, interval: DateInterval(start: start, end: end))
    }
    private var change: BalanceDayChange? {
        guard let opening = series.opening else { return nil }
        let current = selectedPoint == nil ? series.points.last?.value : selectedPoint?.value
        guard let current else { return nil }
        return BalanceDayChange(opening: opening, current: current)
    }
    private var displayCurrency: String {
        context?.currency ?? Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
    }
    private var hasNonzeroChange: Bool {
        (change?.amount ?? .zero) != .zero
    }
    private var color: Color {
        guard !session.balancesHidden, hasNonzeroChange, let change else { return .secondary }
        if change.amount > 0 {
            return colorScheme == .dark ? Color(red: 0.61, green: 0.96, blue: 0.75)
                : Color(red: 0.05, green: 0.52, blue: 0.36)
        }
        return colorScheme == .dark ? Color(red: 1, green: 0.67, blue: 0.69)
            : Color(red: 0.84, green: 0.17, blue: 0.25)
    }
    private var amount: String {
        // Sub-cent changes use the shared nonzero bound; only exact zero is zero.
        // Every wallet starts with a neutral display while its first settled
        // comparison loads. This fallback never creates a zero history baseline.
        let value = change?.amount ?? .zero
        return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: displayCurrency)
            .money(value, signed: true)
    }
    private var percentage: String? {
        // A missing comparison starts at 0%. A real gain from a zero opening
        // still has no defined percentage and must not be presented as 0%.
        guard let value = change == nil ? Decimal.zero : change?.percentage else { return nil }
        return ((hasNonzeroChange ? value : 0) / 100).formatted(.percent.precision(.fractionLength(2)).locale(strings.language.locale))
    }
    private var accessibilityValue: String {
        if session.balancesHidden { return strings.text(.balanceHidden) }
        return [amount, percentage, strings.text(period.titleKey)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 4) {
            OathButton { showingPeriods = true } label: { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(strings.text(.balanceChangePeriodTitle))
                .accessibilityValue(accessibilityValue)
                .accessibilityIdentifier("home.balanceChange")
                .sheet(isPresented: $showingPeriods) {
                    OathBalancePeriodPicker(selected: period) { selected in
                        period = selected
                        selectionRevision += 1
                        showingPeriods = false
                    }
                }
            BalanceChartView(series: series, concealed: session.balancesHidden, interactive: visible,
                accessibilityLabel: strings.text(.balanceChangePeriodTitle),
                accessibilityValue: chartAccessibilityValue,
                hapticsEnabled: { OathHaptics.shared.isEnabled },
                onSelection: { selectedPoint = $0 })
                .id(periodContext)
                .accessibilityIdentifier("home.balanceChart")
            chartCaption
        }
        .onChange(of: visible, initial: true) { _, active in
            if active { updateDay() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in updateDay() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in updateDay() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in updateDay() }
        .task(id: context) {
            guard context != nil else { return }
            await session.refreshBalanceDay()
        }
        .task(id: visitContext) {
            guard visitContext != nil else { return }
            await session.recordBalanceSnapshot(.homeVisit)
            await session.refreshBalanceDay()
        }
        .onChange(of: context) { _, _ in selectedPoint = nil; liveUpdatedAt = Date() }
        .onChange(of: session.portfolio?.totalFiat) { _, _ in liveUpdatedAt = Date() }
        .task(id: visible ? periodContext : nil) {
            guard visible, let scope = periodContext else { return }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let observations = try await session.observeBalanceChart(scope.period, at: scope.context.day.start)
                    for try await value in observations {
                        guard !Task.isCancelled, periodContext == scope else { return }
                        history = value
                        loadedScope = scope
                    }
                } catch is CancellationError { } // Expected selection, lock, wallet change or teardown.
                catch {
                    OathDiagnostics.record(error, component: "balance_history", operation: "observe_chart")
                }
            }
        }
    }

    private var chartAccessibilityValue: String {
        guard !session.balancesHidden else { return strings.text(.balanceHidden) }
        if let selectedPoint {
            return [selectedPoint.value.map(formattedValue) ?? "—", timestamp(selectedPoint.date), accessibilityValue].joined(separator: ", ")
        }
        guard let point = series.points.last else { return accessibilityValue }
        return [formattedValue(point.value), timestamp(point.date), accessibilityValue].joined(separator: ", ")
    }
    private func formattedValue(_ value: Decimal) -> String {
        OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: displayCurrency).money(value)
    }
    private func timestamp(_ date: Date) -> String {
        if period == .today { return date.formatted(.dateTime.hour().minute().locale(strings.language.locale)) }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(strings.language.locale))
    }
    private var chartCaption: some View {
        HStack(spacing: 8) {
            if !session.balancesHidden {
                if let point = selectedPoint {
                    Text(point.value.map(formattedValue) ?? "—").foregroundStyle(.primary)
                    Text(timestamp(point.date))
                } else {
                    Text(matchingHistory.map { timestamp($0.interval.start) } ?? " ")
                    Spacer(minLength: 8)
                    Text(matchingHistory.map { timestamp($0.interval.end) } ?? " ")
                }
            }
        }
        // Time runs left to right, matching physical scrub coordinates in every locale.
        .environment(\.layoutDirection, .leftToRight)
        .oathFont(.caption2, weight: .medium)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        // Keep the chart footprint stable when hiding its dates and times.
        .frame(minHeight: 18)
        .accessibilityHidden(true)
    }

    private var content: some View {
        label.background(Color(uiColor: OathSurfaceColors.field), in: Capsule())
    }
    private var label: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let change, hasNonzeroChange {
                    Image(systemName: change.amount > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.caption2).foregroundStyle(color)
                }
                Text(amount).fontWeight(.medium).foregroundStyle(color)
                if let percentage { Text(verbatim: "(\(percentage))").foregroundStyle(.secondary) }
            }
            Text(strings.text(period.titleKey)).foregroundStyle(.secondary)
        }
        .oathBalanceConcealed(session.balancesHidden, style: .compact)
        .oathFont(.subheadline, weight: .medium)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Capsule())
    }
    private func updateDay() {
        let current = BalanceDaySummary.interval(containing: Date())
        if day != current { day = current }
    }
}

private struct OathBalancePeriodPicker: View {
    let selected: BalanceHistoryPeriod
    let onChoose: (BalanceHistoryPeriod) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathContentSizedSheet(contentID: "balance.periods", navigation: .init(
            strings: strings, title: .balanceChangePeriodTitle, backIdentifier: "balance.periods.back",
            onBack: nil, onClose: { dismiss() }, preservesNativeButtonBackground: true
        ), opaqueBackground: true) {
            VStack(spacing: 0) {
                ForEach(BalanceHistoryPeriod.allCases, id: \.self) { period in
                    OathButton(feedback: .selection) { onChoose(period) } label: {
                        OathSettingsRow(title: strings.text(period.titleKey), accessory: .selection(period == selected))
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityAddTraits(period == selected ? .isSelected : [])
                    .accessibilityIdentifier("balance.period.\(period.rawValue)")
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
        }
        .presentationDragIndicator(.visible)
    }
}

private extension BalanceHistoryPeriod {
    var titleKey: OathStringKey {
        switch self {
        case .today: .historyToday
        case .week: .balanceChangeWeek
        case .month: .balanceChangeMonth
        case .sixMonths: .balanceChangeSixMonths
        case .year: .balanceChangeYear
        case .all: .balanceChangeAll
        }
    }
}
