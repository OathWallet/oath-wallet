import Foundation
import Observation
import OathDatabase
import OathDiagnostics

/// Live filters have one writer and at most one newer pending selection. The
/// session retains this model, so closing/reopening the sheet cannot lose or
/// reorder a save. Invalid range text is local editing state, never stored.
@MainActor @Observable
final class OathAssetFilterModel {
    private(set) var selection: PortfolioFilter
    private(set) var minimum: String
    private(set) var maximum: String
    private(set) var currency: String
    private(set) var isSaving = false
    private(set) var saveFailed = false
    @ObservationIgnored private var committed: PortfolioFilter
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let save: @MainActor (PortfolioFilter) async throws -> Void
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var invalidated = false

    init(selection: PortfolioFilter, currency: String, locale: Locale = .autoupdatingCurrent,
         save: @escaping @MainActor (PortfolioFilter) async throws -> Void) {
        let current = selection.adjusted(for: currency)
        self.selection = current; committed = current
        self.currency = currency; self.locale = locale; self.save = save
        minimum = Self.input(current.minimumValue, locale: locale)
        maximum = Self.input(current.maximumValue, locale: locale)
    }

    var hasInvalidRange: Bool { rangeSelection == nil }
    var canReset: Bool {
        selection != PortfolioFilter() || !minimum.isEmpty || !maximum.isEmpty || saveFailed
    }

    func set<Value>(_ keyPath: WritableKeyPath<PortfolioFilter, Value>, to value: Value) {
        guard !invalidated else { return }
        selection[keyPath: keyPath] = value
        persist()
    }

    func setMinimum(_ value: String) { minimum = value; applyRange() }
    func setMaximum(_ value: String) { maximum = value; applyRange() }

    func reset() {
        guard !invalidated else { return }
        minimum = ""; maximum = ""; selection = .init()
        persist()
    }

    func retry() { persist() }

    func waitForPendingSave() async { await work?.value }

    func updateCurrency(_ value: String) {
        guard currency != value, !invalidated else { return }
        currency = value
        selection = selection.adjusted(for: value)
        minimum = Self.input(selection.minimumValue, locale: locale)
        maximum = Self.input(selection.maximumValue, locale: locale)
        persist()
    }

    /// Accept resets made outside the sheet. Ordinary snapshot/price updates
    /// must not clear incomplete text or supersede a pending user edit.
    func acceptCommitted(_ value: PortfolioFilter) {
        guard !invalidated, !isSaving, !saveFailed, value != committed else { return }
        committed = value
        selection = value.adjusted(for: currency)
        minimum = Self.input(selection.minimumValue, locale: locale)
        maximum = Self.input(selection.maximumValue, locale: locale)
    }

    func cancel() {
        invalidated = true
        work?.cancel(); work = nil
        isSaving = false
    }

    private static func input(_ value: Decimal?, locale: Locale) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue
            .replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".") } ?? ""
    }

    private var rangeSelection: PortfolioFilter? {
        var result = selection
        let low = minimum.trimmingCharacters(in: .whitespacesAndNewlines)
        let high = maximum.trimmingCharacters(in: .whitespacesAndNewlines)
        result.minimumValue = low.isEmpty ? nil : PortfolioFilter.value(low, locale: locale)
        result.maximumValue = high.isEmpty ? nil : PortfolioFilter.value(high, locale: locale)
        result.rangeCurrency = low.isEmpty && high.isEmpty ? nil : currency
        guard low.isEmpty || result.minimumValue != nil,
              high.isEmpty || result.maximumValue != nil, result.isValid else { return nil }
        return result
    }

    private func applyRange() {
        guard !invalidated, let valid = rangeSelection else { return }
        selection = valid
        persist()
    }

    private func persist() {
        guard !invalidated, work == nil, selection != committed || saveFailed else { return }
        isSaving = true
        work = Task {
            await OathDiagnostics.$operationID.withValue(UUID()) { await drain() }
        }
    }

    private func drain() async {
        defer { work = nil; isSaving = false }
        while !invalidated, !Task.isCancelled {
            let next = selection
            saveFailed = false
            do {
                try await save(next)
                try Task.checkCancellation()
                guard !invalidated else { return }
                committed = next
            } catch is CancellationError {
                // Session teardown is expected; it must not retry into a new wallet.
                return
            } catch {
                OathDiagnostics.record(error, component: "asset_filters", operation: "save")
                guard !invalidated else { return }
                if selection == next { saveFailed = true; return }
                // A newer user selection gets one attempt, not an automatic
                // retry loop for the failed value.
                continue
            }
            if selection == committed { return }
        }
    }
}
