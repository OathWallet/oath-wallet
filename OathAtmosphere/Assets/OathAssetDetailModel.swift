import OathDiagnostics
import Foundation
import Observation
import OathDatabase
import OathMarketData
import OathAnkr

actor OathMarketEnvironment {
    static let shared = OathMarketEnvironment()
    private var setup: Task<MarketDataService, Error>?
    func service() async throws -> MarketDataService {
        if setup == nil {
            setup = Task { MarketDataService(database: try await OathDataEnvironment.shared.database()) }
        }
        do { return try await setup!.value }
        catch { OathDiagnostics.record(error); setup = nil; throw error }
    }
}

@MainActor @Observable final class OathAssetDetailModel {
    var quote: CachedMarketValue<MarketQuote>?
    var information: CachedMarketValue<AssetInformation>?
    var chart: CachedMarketValue<MarketChart>?
    var lifiMetadata: CachedMarketValue<LifiTokenMetadata>?
    var verificationStatus: LifiVerificationStatus {
        guard let lifiMetadata, lifiMetadata.isFresh(lifetime: 86_400) else { return .unknown }
        return lifiMetadata.value.status
    }
    var quoteFailed = false
    var informationFailed = false
    var chartFailed = false
    var loading = true
    var quoteLoading = true
    var history: [ChainHistoryItem] = []
    var historyFailed = false
    var loadingHistory = false
    private(set) var hasMoreHistory = false
    let historyLimit = 5
    private var requestID = UUID()
    private var historyRequestID = UUID()
    private var historyScope: String?

    func open(asset: MarketAsset, walletID: String, accountID: String) async {
        let request = UUID(); requestID = request
        loading = true; quoteLoading = true
        do {
            let service = try await OathMarketEnvironment.shared.service()
            async let savedQuote = service.cachedQuote(for: asset)
            async let savedInfo = service.cachedInformation(for: asset)
            async let savedChart = service.cachedChart(for: asset)
            async let savedLifi = service.cachedLifiToken(for: asset)
            let cached = try await (savedQuote, savedInfo, savedChart, savedLifi)
            guard !Task.isCancelled, requestID == request else { return }
            quote = cached.0; information = cached.1; chart = cached.2; lifiMetadata = cached.3
            await refresh(asset: asset, walletID: walletID, accountID: accountID)
        } catch { OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"]);
            guard !Task.isCancelled, requestID == request else { return }
            quoteFailed = true; informationFailed = true; chartFailed = true
            loading = false; quoteLoading = false
        }
    }

    func refresh(asset: MarketAsset, walletID: String, accountID: String, force: Bool = false) async {
        loading = true
        await OathDiagnostics.$chain.withValue(asset.networkID) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                async let quoteWork: () = updateQuote(asset, force: force)
                async let infoWork: () = updateInformation(asset, force: force)
                async let verificationWork: () = updateVerification(asset, force: force)
                async let chartWork: () = updateChart(asset, force: force)
                async let rates = await OathExchangeRateEnvironment.shared.refresh()
                _ = await (quoteWork, infoWork, chartWork, rates, verificationWork)
            }
        }
        if !Task.isCancelled { loading = false }
    }
    private func updateVerification(_ asset: MarketAsset, force: Bool) async {
        guard !asset.isNative else { return }
        do {
            let service = try await OathMarketEnvironment.shared.service()
            let value = try await service.lifiToken(for: asset, force: force)
            guard !Task.isCancelled else { return }
            lifiMetadata = value
        } catch {
            // diagnostics: lifi-provider-recovery
            // The market service records failures; missing provider coverage and
            // cancellation are expected. Keep the original cached status/date.
        }
    }

    func updateQuote(_ asset: MarketAsset, force: Bool = false) async {
        quoteLoading = true
        defer { quoteLoading = false }
        do {
            let service = try await OathMarketEnvironment.shared.service()
            let result = try await service.quote(for: asset, force: force)
            guard !Task.isCancelled else { return }
            quote = result; quoteFailed = false
        } catch {
            // A provider may have no listing for an otherwise valid token. Keep
            // the existing unavailable/saved-data presentation without logging
            // expected coverage gaps. Invalid data and outages remain failures.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"])
            }
            if !Task.isCancelled { quoteFailed = true } }
    }
    private func updateInformation(_ asset: MarketAsset, force: Bool) async {
        do {
            let service = try await OathMarketEnvironment.shared.service()
            // Information includes market cap and supply; refresh those with
            // the user's pull while retaining shared coalescing and backoff.
            let result = try await service.information(for: asset, force: force)
            guard !Task.isCancelled else { return }
            information = result; informationFailed = false
            if !asset.isNative {
                do {
                    if let enriched = try await service.enrichTokenInformation(for: asset, force: force), !Task.isCancelled {
                        information = enriched
                    }
                } catch {
                    // diagnostics: lifi-provider-recovery
                    // Optional enrichment already reports failures at its provider
                    // boundary. LI.FI metadata stays visible throughout the request.
                }
            }
        } catch {
            // A provider may have no listing for an otherwise valid token. Keep
            // the existing unavailable/saved-data presentation without logging
            // expected coverage gaps. Invalid data and outages remain failures.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"])
            }
            if !Task.isCancelled { informationFailed = true } }
    }
    private func updateChart(_ asset: MarketAsset, force: Bool) async {
        do {
            let service = try await OathMarketEnvironment.shared.service()
            let result = try await service.chartForPresentation(for: asset, force: force)
            guard !Task.isCancelled else { return }
            chart = result; chartFailed = false
        } catch {
            // A provider may have no listing for an otherwise valid token. Keep
            // the existing unavailable/saved-data presentation without logging
            // expected coverage gaps. Invalid data and outages remain failures.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"])
            }
            if !Task.isCancelled { chartFailed = true } }
    }
    func observeHistory(walletID: String, accountID: String, assetID: String, currency: String) async {
        let request = UUID()
        historyRequestID = request
        let scope = "\(walletID):\(accountID):\(assetID)"
        if historyScope != scope {
            history = []; hasMoreHistory = false; historyFailed = false; historyScope = scope
        }
        loadingHistory = true
        defer { if historyRequestID == request { loadingHistory = false } }
        do {
            let db = try await OathDataEnvironment.shared.database()
            async let _: Void = OathSwapHistoryEnrichment.shared.observe(walletID: walletID)
            let limit = historyLimit
            // One lookahead row determines whether this asset needs View All.
            for try await page in db.observeChainHistory(walletID: walletID, accountID: accountID, assetID: assetID, currency: currency, limit: limit + 1) {
                guard !Task.isCancelled, historyRequestID == request else { return }
                history = Array(page.prefix(limit))
                hasMoreHistory = page.count > limit
                historyFailed = false; loadingHistory = false
            }
        } catch { OathDiagnostics.record(error); if !Task.isCancelled, historyRequestID == request { historyFailed = true } }
    }
}

struct OathAssetRoute: Hashable {
    let walletID: String
    let holding: Holding
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.walletID == rhs.walletID && lhs.holding.id == rhs.holding.id }
    func hash(into hasher: inout Hasher) { hasher.combine(walletID); hasher.combine(holding.id) }
}

@MainActor @Observable final class OathChainActivityModel {
    private(set) var items: [ChainHistoryItem] = []
    private(set) var displayCurrency = "USD"
    private(set) var loading = true
    private(set) var hasCurrentPage = false
    private(set) var failed = false
    private(set) var hasMore = false
    private(set) var limit = OathHomeHistorySnapshot.pageSize
    private(set) var attempt = 0
    private let firstPageTimeout: Duration
    private var requestID = UUID()
    private var scope: String?
    private var contentScope: String?
    private var filterScope: HistoryFilter?

    init(seed: OathHomeHistorySnapshot? = nil, firstPageTimeout: Duration = OathHomeHistorySnapshot.readTimeout) {
        self.firstPageTimeout = firstPageTimeout
        guard let seed else { return }
        accept(seed.items, currency: seed.currency, limit: limit)
        contentScope = "\(seed.walletID):all:all:all"
        scope = "\(seed.walletID):all:all:all:\(seed.currency)::\(seed.localeIdentifier)"
        filterScope = .init()
    }

    private func accept(_ page: [ChainHistoryItem], currency: String, limit: Int) {
        items = Array(page.prefix(limit))
        displayCurrency = currency
        hasMore = page.count > limit
        hasCurrentPage = true
        failed = false
        loading = false
    }

    func loadMoreOrRetry() {
        guard !loading, failed || hasMore else { return }
        requestID = UUID()
        loading = true
        if failed {
            failed = false
            attempt += 1
        } else {
            limit += OathHomeHistorySnapshot.pageSize
        }
    }

    func observe(walletID: String, networkID: String?, accountID: String?, assetID: String?,
                 currency: String, query: String, filter: HistoryFilter, localeIdentifier: String,
                 seed: OathHomeHistorySnapshot? = nil,
                 database: () async throws -> OathDatabase,
                 remember: (OathHomeHistorySnapshot) -> Void = { _ in }) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        let nextContentScope = "\(walletID):\(networkID ?? "all"):\(accountID ?? "all"):\(assetID ?? "all")"
        let nextScope = "\(nextContentScope):\(currency):\(query):\(localeIdentifier)"
        // Retain rows during filter and paging requests within one wallet and asset scope.
        if contentScope != nextContentScope {
            items = []
            contentScope = nextContentScope
        }
        if scope != nextScope || filterScope != filter {
            hasMore = false
            hasCurrentPage = false
            limit = OathHomeHistorySnapshot.pageSize
            scope = nextScope
            filterScope = filter
        }
        let visibleLimit = limit
        let wholeWallet = networkID == nil && accountID == nil && assetID == nil && query.isEmpty && filter == .init()
        if wholeWallet, let seed, seed.walletID == walletID, seed.currency == currency {
            let firstPage = seed.items.prefix(OathHomeHistorySnapshot.pageSize)
            // Keep a paged list in place on re-entry. If the front of the list
            // changed off-tab, use the saved first page until SQL replaces the full window.
            if visibleLimit == OathHomeHistorySnapshot.pageSize || !items.starts(with: firstPage)
                || (seed.items.count <= OathHomeHistorySnapshot.pageSize && items.count != seed.items.count) {
                accept(seed.items, currency: currency, limit: OathHomeHistorySnapshot.pageSize)
            }
        }
        failed = false
        loading = true
        let deadline = Task {
            try await Task.sleep(for: firstPageTimeout)
            guard !Task.isCancelled, requestID == request else { return }
            OathDiagnostics.record(DiagnosticFailure("history_first_page_timeout"), component: "history", operation: "observe")
            failed = true
            loading = false
        }
        // Leaving the tab disarms the deadline even if database acquisition is still suspended.
        defer {
            deadline.cancel()
            if requestID == request { loading = false }
        }
        await withTaskCancellationHandler {
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
                let db = try await database()
                guard !Task.isCancelled, requestID == request else { return }
                for try await page in db.observeChainHistory(walletID: walletID, networkID: networkID,
                    accountID: accountID, assetID: assetID, currency: currency, limit: visibleLimit + 1,
                    search: query, filter: filter, localeIdentifier: localeIdentifier) {
                    guard !Task.isCancelled, requestID == request else { return }
                    deadline.cancel()
                    accept(page, currency: currency, limit: visibleLimit)
                    if wholeWallet {
                        remember(.init(walletID: walletID, currency: currency, localeIdentifier: localeIdentifier,
                                       items: Array(page.prefix(OathHomeHistorySnapshot.pageSize + 1))))
                    }
                }
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                OathDiagnostics.record(error, component: "history", operation: "observe")
                failed = true
            }
        } onCancel: {
            deadline.cancel()
        }
    }
}
