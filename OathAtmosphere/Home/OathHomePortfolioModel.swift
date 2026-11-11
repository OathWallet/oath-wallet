import Foundation
import Observation
import OathDatabase
import OathDiagnostics

/// Only visible data invalidates Home's presentation. Provider checkpoints and
/// observation timestamps still reach the session and detail/history screens.
struct OathHomePortfolioInput: Equatable, Sendable {
    let walletID: String?
    let holdings: [Holding]
    let currency: String
    let total: Decimal
    let filter: PortfolioFilter
    let query: String
    let formattingLocale: String
    let sortingLocale: String
    var hiddenAssetIDs: Set<String> = []

    func hasSameScope(as other: Self) -> Bool {
        walletID == other.walletID && currency == other.currency && filter == other.filter &&
        query == other.query && formattingLocale == other.formattingLocale &&
        sortingLocale == other.sortingLocale && hiddenAssetIDs == other.hiddenAssetIDs
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasSameScope(as: rhs) && lhs.total == rhs.total &&
        lhs.holdings.count == rhs.holdings.count &&
        zip(lhs.holdings, rhs.holdings).allSatisfy { $0.hasSameHomeContent(as: $1) }
    }
}

extension Holding {
    fileprivate func hasSameHomeContent(as other: Self) -> Bool {
        accountID == other.accountID && assetID == other.assetID && networkID == other.networkID &&
        address == other.address && reference == other.reference && name == other.name &&
        symbol == other.symbol && decimals == other.decimals && logo == other.logo &&
        amountAtomic == other.amountAtomic && usdPrice == other.usdPrice &&
        exchangeRate == other.exchangeRate && transactionCount == other.transactionCount &&
        pendingTransactionCount == other.pendingTransactionCount && homeVerified == other.homeVerified
    }
}

struct OathHomeAssetPresentation: Equatable, Identifiable, Sendable {
    let holding: Holding
    let nativeSummary: String
    let nativeFull: String
    let fiat: String
    let unitPrice: String?
    var id: String { holding.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.holding.networkID == rhs.holding.networkID &&
        lhs.holding.name == rhs.holding.name && lhs.holding.symbol == rhs.holding.symbol &&
        lhs.holding.logo == rhs.holding.logo && lhs.holding.decimals == rhs.holding.decimals && lhs.holding.reference == rhs.holding.reference &&
        lhs.holding.pendingTransactionCount == rhs.holding.pendingTransactionCount &&
        lhs.nativeSummary == rhs.nativeSummary &&
        lhs.nativeFull == rhs.nativeFull && lhs.fiat == rhs.fiat &&
        lhs.unitPrice == rhs.unitPrice
    }
}

/// Display-only tree, built from already filtered rows. A missing/hidden native
/// asset gets a network heading, never an invented balance or a restored asset.
struct OathHomeAssetTreeEntry: Equatable, Identifiable, Sendable {
    let id: String
    let networkID: String
    let presentation: OathHomeAssetPresentation?
    let isChild: Bool
    let hasChildren: Bool
    let continues: Bool

    static func build(_ rows: [OathHomeAssetPresentation]) -> [Self] {
        struct Group: Hashable { let network: String; let account: String }
        var order: [Group] = []
        var groups: [Group: [OathHomeAssetPresentation]] = [:]
        for row in rows {
            let key = Group(network: row.holding.networkID, account: row.holding.accountID)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        return order.flatMap { key -> [Self] in
            let values = groups[key] ?? []
            let parents = values.filter { $0.holding.reference == "native" }
            let children = values.filter { $0.holding.reference != "native" }
            var result = parents.map {
                Self(id: $0.id, networkID: key.network, presentation: $0,
                     isChild: false, hasChildren: !children.isEmpty, continues: false)
            }
            if parents.isEmpty, !children.isEmpty {
                result.append(Self(id: "chain-header:\(key.network):\(key.account)", networkID: key.network,
                                   presentation: nil, isChild: false, hasChildren: true, continues: false))
            }
            result += children.enumerated().map { index, row in
                Self(id: row.id, networkID: key.network, presentation: row,
                     isChild: true, hasChildren: false, continues: index < children.count - 1)
            }
            return result
        }
    }
}

/// Only structural information is observed by List. Each asset cell observes its own value.
struct OathHomeRowLayout: Equatable, Identifiable, Sendable {
    let id: String
    let chain: OathImportChain
    let heading: Bool
    let isChild: Bool
    let hasChildren: Bool
    let continues: Bool

    init?(id: String, network: String, entry: OathHomeAssetTreeEntry? = nil) {
        guard let chain = OathImportChain(rawValue: network) else { return nil }
        self.id = id; self.chain = chain
        heading = entry.map { $0.presentation == nil } ?? false
        isChild = entry?.isChild ?? false
        hasChildren = entry?.hasChildren ?? false
        continues = entry?.continues ?? false
    }
}

@MainActor @Observable final class OathHomeHoldingRow {
    fileprivate(set) var value: OathHomeAssetPresentation
    init(_ value: OathHomeAssetPresentation) { self.value = value }
}

/// This actor performs filtering, Decimal conversion and Foundation formatting
/// away from MainActor. Cache only the current portfolio; never accumulate history.
actor OathHomePortfolioBuilder {
    struct Result: Sendable {
        let rows: [OathHomeAssetPresentation]
        let treeRows: [OathHomeAssetTreeEntry]
        let searchRows: [OathHomeAssetPresentation]
        let total: String
        let formattedRowCount: Int
    }
    private var cache: [String: OathHomeAssetPresentation] = [:]
    private var walletID: String?
    private var currency: String?
    private var locale: String?

    func build(_ input: OathHomePortfolioInput) throws -> Result {
        try Task.checkCancellation()
        let reusable = walletID == input.walletID && currency == input.currency && locale == input.formattingLocale
        let format = OathAssetAmountFormat(locale: Locale(identifier: input.formattingLocale), selectedCurrencyCode: input.currency)
        var next: [String: OathHomeAssetPresentation] = [:]
        next.reserveCapacity(input.holdings.count)
        var formatted = 0
        for holding in input.holdings {
            try Task.checkCancellation()
            if reusable, let previous = cache[holding.id], previous.holding.hasSameHomeContent(as: holding) {
                next[holding.id] = previous
            } else {
                let price = holding.price.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
                    .flatMap { !$0.isNaN && $0 > 0 ? $0 : nil }
                let amounts = OathAssetAmounts(native: holding.nativeDisplayValue, fiat: holding.fiatDisplayValue,
                                               currencyCode: input.currency)
                next[holding.id] = OathHomeAssetPresentation(holding: holding,
                    nativeSummary: format.nativeSummary(amounts.native, ticker: holding.symbol),
                    nativeFull: format.native(amounts.native, ticker: holding.symbol),
                    fiat: String(format.fiat(amounts).characters),
                    unitPrice: price.map { format.money($0) })
                formatted += 1
            }
        }
        let visibleHoldings = input.holdings.filter { !input.hiddenAssetIDs.contains($0.assetID) && (!input.filter.hidesUnverifiedTokens || $0.isVerifiedForHome) }
        let rows = input.filter.applying(to: visibleHoldings, currency: input.currency,
            locale: Locale(identifier: input.sortingLocale), preservingRecommendedOrder: true)
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerQuery = query.lowercased()
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let search = query.isEmpty ? input.holdings : input.holdings.filter {
            let text = $0.name + " " + $0.symbol + " " + $0.networkID
            return words.allSatisfy { text.localizedStandardContains($0) } ||
            ($0.networkID == "arc" && $0.reference == "native" && lowerQuery == "0x3600000000000000000000000000000000000000") ||
            ($0.reference != "native" && ($0.reference == query ||
                (OathImportChain(rawValue: $0.networkID)?.isEVM == true && $0.reference.lowercased() == lowerQuery)))
        }
        try Task.checkCancellation()
        cache = next; walletID = input.walletID; currency = input.currency; locale = input.formattingLocale
        let presented = rows.compactMap { next[$0.id] }
        return Result(rows: presented,
            treeRows: input.filter.groupsTokensByChain ? OathHomeAssetTreeEntry.build(presented) : [],
            searchRows: search.compactMap { next[$0.id] },
            total: String(format.fiat(.init(native: nil, fiat: input.total, currencyCode: input.currency)).characters),
            formattedRowCount: formatted)
    }

    /// Diff against the last *accepted* snapshot. A superseded build may have warmed
    /// the formatting cache, but can never become the baseline for publication.
    struct Snapshot: Sendable {
        let input: OathHomePortfolioInput
        let values: [String: OathHomeAssetPresentation]
        let latest: [String: Holding]
        let layout: [OathHomeRowLayout]
        let search: [OathHomeRowLayout]
        let total: String
    }

    struct Changes: Sendable {
        let snapshot: Snapshot
        let updated: [OathHomeAssetPresentation]
        let removed: [String]
        let layoutChanged: Bool
        let searchChanged: Bool
    }

    func changes(_ input: OathHomePortfolioInput, since accepted: Snapshot?) throws -> Changes {
        try Task.checkCancellation()
        let previous = accepted?.input.walletID == input.walletID ? accepted : nil
        let latest = Dictionary(uniqueKeysWithValues: input.holdings.map { ($0.id, $0) })
        if let previous, input == previous.input {
            let snapshot = Snapshot(input: input, values: previous.values, latest: latest,
                                    layout: previous.layout, search: previous.search, total: previous.total)
            return Changes(snapshot: snapshot, updated: [], removed: [], layoutChanged: false, searchChanged: false)
        }
        let built = try build(input)
        let layout = input.filter.groupsTokensByChain
            ? built.treeRows.compactMap { OathHomeRowLayout(id: $0.id, network: $0.networkID, entry: $0) }
            : built.rows.compactMap { OathHomeRowLayout(id: $0.id, network: $0.holding.networkID) }
        let search = built.searchRows.compactMap { OathHomeRowLayout(id: $0.id, network: $0.holding.networkID) }
        let snapshot = Snapshot(input: input, values: cache, latest: latest,
                                layout: layout, search: search, total: built.total)
        let updated = cache.values.filter { previous?.values[$0.id] != $0 }
        let removed = previous?.values.keys.filter { cache[$0] == nil } ?? []
        try Task.checkCancellation()
        return Changes(snapshot: snapshot, updated: updated, removed: removed,
                       layoutChanged: previous?.layout != layout, searchChanged: previous?.search != search)
    }

}

/// A bounded first page from the native SQL index, ready before Home is revealed.
/// It contains display metadata only, never credentials or signing material.
struct OathHomeHistorySnapshot: Equatable {
    static let pageSize = 50
    static let readTimeout: Duration = .seconds(5)
    let walletID: String
    let currency: String
    let localeIdentifier: String
    let items: [ChainHistoryItem]

    static func preload(database: OathDatabase, walletID: String, currency: String, localeIdentifier: String,
                        timeout: Duration = readTimeout) async throws -> [ChainHistoryItem] {
        // Home can finish opening even if SQLite cannot grant a History reader.
        // Canceling iteration releases the stream without waiting for the underlying SQL.
        try await withThrowingTaskGroup(of: [ChainHistoryItem].self) { group in
            group.addTask {
                let pages = database.observeChainHistory(walletID: walletID, currency: currency,
                                                         limit: pageSize + 1, localeIdentifier: localeIdentifier)
                for try await page in pages { return page }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DiagnosticFailure("history_first_page_timeout")
            }
            defer { group.cancelAll() }
            guard let page = try await group.next() else { throw CancellationError() }
            return page
        }
    }
}

@MainActor @Observable
final class OathHomePortfolioModel {
    struct Prepared: Sendable {
        fileprivate let epoch: UUID
        fileprivate let input: OathHomePortfolioInput
        fileprivate let changes: OathHomePortfolioBuilder.Changes
    }
    private(set) var walletID: String?
    @ObservationIgnored private var storedLayout: [OathHomeRowLayout] = []
    @ObservationIgnored private var storedSearchLayout: [OathHomeRowLayout] = []
    private(set) var layout: [OathHomeRowLayout] {
        get { access(keyPath: \.layout); return storedLayout }
        set { withMutation(keyPath: \.layout) { storedLayout = newValue } }
    }
    private(set) var searchLayout: [OathHomeRowLayout] {
        get { access(keyPath: \.searchLayout); return storedSearchLayout }
        set { withMutation(keyPath: \.searchLayout) { storedSearchLayout = newValue } }
    }
    @ObservationIgnored private var cells: [String: OathHomeHoldingRow] = [:]
    @ObservationIgnored private var accepted: OathHomePortfolioBuilder.Snapshot?

    // Full-value projections for snapshot consumers and host verification. The
    // scrolling List subscribes to layout and individual cells instead.
    var rows: [OathHomeAssetPresentation] { layout.compactMap { cells[$0.id]?.value } }
    var searchRows: [OathHomeAssetPresentation] { searchLayout.compactMap { cells[$0.id]?.value } }

    func cell(_ id: String) -> OathHomeHoldingRow? { cells[id] }
    func latestHolding(_ id: String) -> Holding? { accepted?.latest[id] }

    private(set) var total = ""
    private(set) var currency = "USD"
    private(set) var filter = PortfolioFilter()
    private(set) var holdingCount = 0
    private(set) var hasPrepared = false
    @ObservationIgnored private let builder = OathHomePortfolioBuilder()
    @ObservationIgnored private var pending: OathHomePortfolioInput?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var walletGeneration = UUID()

    func update(_ input: OathHomePortfolioInput) {
        if work == nil { epoch = UUID() }
        pending = input
        if walletID != input.walletID {
            clearRows()
            walletID = input.walletID
        }
        guard work == nil else { return }
        let epoch = epoch, builder = builder
        // One worker and one latest pending value. Bursts cannot create an
        // unbounded task queue or publish an older wallet/currency/filter result.
        work = Task(priority: .utility) { [weak self] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                while let input = self?.pending, !Task.isCancelled {
                    self?.pending = nil
                    do {
                        let generation = self?.walletGeneration
                        let changes = try await builder.changes(input, since: self?.accepted)
                        guard let self, self.epoch == epoch, !Task.isCancelled else { return }
                        guard generation == self.walletGeneration else { continue }
                        if let pending = self.pending, !input.hasSameScope(as: pending) { continue }
                        // In the same scope, apply in order even under sustained writes.
                        // The next build will diff its latest input against this publication.
                        self.accept(changes, input: input)
                    } catch is CancellationError { return } // Expected view/session teardown.
                    catch {
                        OathDiagnostics.record(error, component: "home", operation: "prepare_portfolio")
                    }
                }
            }
            if self?.epoch == epoch { self?.work = nil }
        }
    }

    /// Startup/unlock waits for local presentation, not a network refresh.
    /// The session owns this model so view/lock recreation cannot empty it.
    func prepare(_ input: OathHomePortfolioInput) async throws -> Prepared {
        cancel()
        let epoch = epoch
        let changes = try await builder.changes(input, since: accepted)
        guard self.epoch == epoch, !Task.isCancelled else { throw CancellationError() }
        return Prepared(epoch: epoch, input: input, changes: changes)
    }

    /// Commit alongside the session's wallet/history snapshot, after all local
    /// reads finish. A cancelled or superseded preparation cannot publish.
    func publish(_ prepared: Prepared) throws {
        guard epoch == prepared.epoch,
              pending == nil, work == nil, !Task.isCancelled else { throw CancellationError() }
        if walletID != prepared.input.walletID { clearRows() }
        accept(prepared.changes, input: prepared.input)
    }

    private func accept(_ changes: OathHomePortfolioBuilder.Changes, input: OathHomePortfolioInput) {
        for id in changes.removed { cells.removeValue(forKey: id) }
        for value in changes.updated {
            if let cell = cells[value.id] { cell.value = value }
            else { cells[value.id] = OathHomeHoldingRow(value) }
        }
        accepted = changes.snapshot
        if changes.layoutChanged { layout = changes.snapshot.layout }
        if changes.searchChanged { searchLayout = changes.snapshot.search }
        if total != changes.snapshot.total { total = changes.snapshot.total }
        if walletID != input.walletID { walletID = input.walletID }
        updateContext(input)
        if !hasPrepared { hasPrepared = true }
    }

    private func clearRows() {
        walletGeneration = UUID()
        cells.removeAll(); accepted = nil
        layout = []; searchLayout = []; total = ""; hasPrepared = false
    }

    func reset() {
        cancel()
        clearRows()
        walletID = nil
        currency = "USD"; filter = .init(); holdingCount = 0
    }

    private func updateContext(_ input: OathHomePortfolioInput) {
        if currency != input.currency { currency = input.currency }
        if filter != input.filter { filter = input.filter }
        if holdingCount != input.holdings.count { holdingCount = input.holdings.count }
    }

    func cancel() {
        epoch = UUID(); work?.cancel(); work = nil; pending = nil
    }
}

// Display equality is deliberately independent of balance timestamps, provider
// source, history and signing state. The parent retains the latest Holding for
// selection/authorization; only the expensive row subtree skips redundant work.
extension Holding {
    func hasSameAssetSelectionContent(as other: Self) -> Bool {
        id == other.id && networkID == other.networkID && reference == other.reference &&
        name == other.name && symbol == other.symbol && decimals == other.decimals && logo == other.logo &&
        amountAtomic == other.amountAtomic && usdPrice == other.usdPrice && exchangeRate == other.exchangeRate &&
        isCatalogPreview == other.isCatalogPreview
    }
}
