import Foundation
import Observation
import OathDatabase
import OathAnkr
import OathDiagnostics
import OathTokenImages

struct OathManagedTokenRow: Identifiable, Sendable {
    let id: String
    let networkID: String
    let reference: String
    let name: String
    let symbol: String
    let logo: String?
    let decimals: Int?
    let entry: TokenDiscoveryEntry?
    var resolvedToken: OathTokenDefinition? = nil
    // Rendering needs only the canonical public identity, not a full token
    // definition (including EVM checksum and fallback URL construction).
    var artworkIdentity: TokenArtworkIdentity? {
        .init(networkID: networkID, reference: reference, decimals: decimals)
    }
    var token: OathTokenDefinition? { resolvedToken ?? entry.flatMap(OathTokenDefinition.discovery) }
}

/// Uses the complete catalog rather than the search picker's 200-result cap.
/// Rows carry public metadata only; switch state always comes from the database.
actor OathManagedTokenBuilder {
    /// Small wallet-only projection can publish before the catalog actor loads
    /// its disk cache. Freeze ranks for this visit so switches never jump rows.
    static func walletRows(snapshot: ManagedAssetsSnapshot, query: String,
                           networks: Set<String>, originalOrder: [String: Int]) -> [OathManagedTokenRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096, !Task.isCancelled else { return [] }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result: [OathManagedTokenRow] = []
        var seen = Set<String>()
        for asset in snapshot.assets where networks.contains(asset.networkID) {
            guard !Task.isCancelled else { return [] }
            let identity = asset.networkID + ":" + asset.reference
            let matches = text.isEmpty || words.allSatisfy { (asset.name + " " + asset.symbol + " " + asset.networkID).localizedStandardContains($0) }
                || (try? TokenDiscoveryNetworks.canonical(text, network: asset.networkID)) == asset.reference
            guard matches, seen.insert(identity).inserted else { continue }
            result.append(.init(id: identity, networkID: asset.networkID, reference: asset.reference,
                name: asset.name, symbol: asset.symbol, logo: asset.logo, decimals: asset.decimals, entry: nil))
        }
        return result.sorted {
            let a = originalOrder[$0.id] ?? Int.max, b = originalOrder[$1.id] ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }

    func rows(snapshot: ManagedAssetsSnapshot, catalog: [TokenDiscoveryEntry], query: String,
              networks: Set<String>, originalOrder: [String: Int]) -> [OathManagedTokenRow] {
        guard !Task.isCancelled else { return [] }
        let saved = Self.walletRows(snapshot: snapshot, query: query, networks: networks, originalOrder: originalOrder)
        var remaining = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var catalogRows: [OathManagedTokenRow] = [], original: [String: OathManagedTokenRow] = [:]
        var seen = Set<String>()
        for entry in catalog {
            guard !Task.isCancelled else { return [] }
            guard networks.contains(entry.network), seen.insert(entry.id).inserted else { continue }
            let existing = remaining.removeValue(forKey: entry.id)
            let isOriginal = originalOrder[entry.id] != nil
            let row = OathManagedTokenRow(id: entry.id, networkID: entry.network, reference: entry.reference,
                name: isOriginal ? existing?.name ?? entry.name : entry.name,
                symbol: isOriginal ? existing?.symbol ?? entry.symbol : entry.symbol,
                logo: existing?.logo ?? entry.logo, decimals: existing?.decimals ?? entry.decimals, entry: entry)
            if isOriginal { original[row.id] = row } else { catalogRows.append(row) }
        }
        // Provider order is already prepared by the catalog. Only the small
        // wallet subset needs ordering; never re-sort thousands of catalog rows.
        for row in saved where originalOrder[row.id] != nil { original[row.id] = original[row.id] ?? row }
        var result = original.values.sorted { originalOrder[$0.id]! < originalOrder[$1.id]! }
        result += saved.filter { originalOrder[$0.id] == nil && remaining[$0.id] != nil }
        result += catalogRows
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return result }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let canonical = Dictionary(uniqueKeysWithValues: networks.map { ($0, try? TokenDiscoveryNetworks.canonical(text, network: $0)) })
        var buckets = Array(repeating: [OathManagedTokenRow](), count: 5)
        for row in result {
            guard !Task.isCancelled else { return [] }
            let rank: Int
            if (canonical[row.networkID] ?? nil) == row.reference { rank = 0 }
            else if row.symbol.localizedCaseInsensitiveCompare(text) == .orderedSame { rank = 1 }
            else if row.name.localizedCaseInsensitiveCompare(text) == .orderedSame { rank = 2 }
            else { rank = row.symbol.lowercased().hasPrefix(folded) ? 3 : 4 }
            buckets[rank].append(row)
        }
        return buckets.flatMap { $0 }
    }
}

/// Session-owned work survives navigation, but not a wallet/session change.
/// Each identity has at most one writer. Failure leaves committed state intact.
@Observable @MainActor final class OathManagedTokenOperations {
    private(set) var pending: Set<String> = []
    private(set) var failed: Set<String> = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var queued: [String: @MainActor () async -> Void] = [:]

    func set(_ enabled: Bool, row: OathManagedTokenRow, walletID: String,
             save: @escaping @MainActor (Bool, OathManagedTokenRow, String) async throws -> Void) {
        let key = walletID + ":" + row.id
        guard !pending.contains(key) else { return }
        guard pending.count < 200 else {
            OathDiagnostics.record(DiagnosticFailure("managed_token_write_capacity"), component: "manage_tokens", operation: "save_visibility")
            failed.insert(key)
            return
        }
        let ticket = generation
        pending.insert(key); failed.remove(key)
        queued[key] = { [self] in
            do {
                try Task.checkCancellation()
                try await OathDiagnostics.$chain.withValue(row.networkID) {
                    try await OathDiagnostics.$operationID.withValue(UUID()) { try await save(enabled, row, walletID) }
                }
            } catch is CancellationError { }
            catch {
                if ticket == generation {
                    OathDiagnostics.record(error, component: "manage_tokens", operation: "save_visibility", context: ["chain": row.networkID])
                    failed.insert(key)
                }
            }
            guard ticket == generation else { return }
            pending.remove(key); tasks[key] = nil
            drain()
        }
        drain()
    }

    private func drain() {
        while tasks.count < 4, let key = queued.keys.sorted().first, let work = queued.removeValue(forKey: key) {
            tasks[key] = Task { await work() }
        }
    }

    func cancel() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); queued.removeAll(); pending.removeAll(); failed.removeAll()
    }
}

/// Coalesces additions while a network/account refresh is active. One follow-up
/// observes any tokens committed after that refresh captured its inventory.
@MainActor final class OathManagedTokenRefreshQueue {
    private var generation = UUID()
    private var queued: [String: @MainActor () async -> Void] = [:]
    private var active: [String: Task<Void, Never>] = [:]
    func enqueue(_ key: String, operation: @escaping @MainActor () async -> Void) {
        guard queued[key] != nil || active[key] != nil || queued.count < 200 else {
            OathDiagnostics.record(DiagnosticFailure("managed_token_refresh_capacity"), component: "manage_tokens", operation: "queue_refresh")
            return
        }
        queued[key] = operation
        drain()
    }
    private func drain() {
        while active.count < 4, let key = queued.keys.sorted().first(where: { active[$0] == nil }),
              let operation = queued.removeValue(forKey: key) {
            let ticket = generation
            active[key] = Task {
                await operation()
                guard ticket == generation else { return }
                active[key] = nil
                drain()
            }
        }
    }
    func cancel() {
        generation = UUID(); queued.removeAll()
        for task in active.values { task.cancel() }
        active.removeAll()
    }
}

protocol OathManagedTokenCatalog: Sendable {
    func managementEntries(query: String, networks: Set<String>) async -> [TokenDiscoveryEntry]
    func refreshIfNeeded() async -> Bool
    func hasManagementEntries(networks: Set<String>) async -> Bool
}
extension OathManagedTokenCatalog {
    func hasManagementEntries(networks: Set<String>) async -> Bool {
        !(await managementEntries(query: "", networks: networks)).isEmpty
    }
}
extension TokenDiscoveryCatalog: OathManagedTokenCatalog {}

/// Shared by the real management page and host regression tests. Catalog work
/// can finish after navigation; only the current request may publish rows.
@Observable @MainActor final class OathManageTokensModel {
    @ObservationIgnored private(set) var snapshot: ManagedAssetsSnapshot?
    private(set) var rows: [OathManagedTokenRow] = []
    private(set) var revision = 0
    private(set) var limit = 200
    private(set) var loading = true
    private(set) var catalogUnavailable = false
    private(set) var observationFailed = false
    private(set) var lookupFailed = false
    @ObservationIgnored private var originalOrder: [String: Int]?
    private var enabledIdentities: Set<String> = []
    @ObservationIgnored private var cachedCatalog: (query: String, networks: Set<String>, entries: [TokenDiscoveryEntry])?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let builder = OathManagedTokenBuilder()
    @ObservationIgnored private let catalog: any OathManagedTokenCatalog
    @ObservationIgnored private let lookup: OathTokenSearchModel
    @ObservationIgnored private var lastQuery = ""
    @ObservationIgnored private var lastScope = OathAssetSearchScope.all

    init(catalog: any OathManagedTokenCatalog = TokenDiscoveryCatalog.shared,
         lookup: OathTokenSearchModel = OathTokenSearchModel()) {
        self.catalog = catalog; self.lookup = lookup
    }

    private(set) var permittedNetworks: Set<OathImportChain> = []
    var visibleRows: ArraySlice<OathManagedTokenRow> { rows.prefix(limit) }
    func revealMore(after row: OathManagedTokenRow) {
        if visibleRows.last?.id == row.id { limit = min(rows.count, limit + 200) }
    }
    func enabled(_ row: OathManagedTokenRow) -> Bool {
        enabledIdentities.contains(row.id)
    }
    func accept(_ value: ManagedAssetsSnapshot) {
        if let snapshot, snapshot.walletID != value.walletID { return }
        // Amounts, prices, history and visibility change switch state/counts,
        // not the catalog membership. They must not cancel SwiftUI's load task.
        let needsRows = snapshot?.assets != value.assets || snapshot?.networks != value.networks
        snapshot = value
        let enabled = Set(value.assets.filter { !value.hiddenAssetIDs.contains($0.id) }.map { $0.networkID + ":" + $0.reference })
        if enabled != enabledIdentities { enabledIdentities = enabled }
        let networks = Set(value.networks.compactMap { OathImportChain(rawValue: $0.id) }).filter(\.isEnabled)
        if networks != permittedNetworks { permittedNetworks = networks }
        if originalOrder == nil {
            let order = PortfolioAssetOrder(value.holdings)
            let sorted = AssetOrdering.sorted(value.assets) { order.key(networkID: $0.networkID, reference: $0.reference, name: $0.name) }
            originalOrder = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.networkID + ":" + $0.element.reference, $0.offset) })
        }
        if observationFailed { observationFailed = false }
        if needsRows { generation = UUID(); revision += 1 }
    }
    func observe(database: OathDatabase, walletID: String, currency: String) async {
        do {
            for try await value in database.observeManagedAssets(walletID: walletID, currency: currency) {
                try Task.checkCancellation()
                accept(value)
            }
            // A stream is expected to live as long as this page.
            if !Task.isCancelled { throw StoreError.missingRecord }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            OathDiagnostics.record(error, component: "manage_tokens", operation: "observe")
            observationFailed = true; loading = false
        }
    }
    func failedToOpen(_ error: Error) {
        guard !OathDiagnostics.isExpectedCancellation(error) else { return }
        // The screen records the original vault-open failure at its boundary.
        observationFailed = true; loading = false
    }
    func refreshCatalog() async {
        let updated = await catalog.refreshIfNeeded()
        guard !Task.isCancelled else { return }
        // Refresh errors are recorded at the catalog's provider boundary.
        // A missing cache is not an error and never clears wallet rows.
        let hasEntries = await catalog.hasManagementEntries(networks: Set(OathImportChain.enabledCases.map(\.id)))
        guard !Task.isCancelled else { return }
        catalogUnavailable = !hasEntries && !updated
        if updated {
            generation = UUID()
            cachedCatalog = nil
            revision += 1
        }
    }
    func load(query: String, scope: OathAssetSearchScope) async {
        guard !Task.isCancelled, let snapshot else { return }
        generation = UUID()
        let ticket = generation
        lookupFailed = false
        let typing = lastQuery != query && !query.isEmpty
        let changedQuery = lastQuery != query || lastScope != scope
        if changedQuery { limit = 200 }
        let networks = scope.networks(permitted: permittedNetworks)
        let networkIDs = Set(networks.map(\.id))
        if loading || changedQuery {
            rows = OathManagedTokenBuilder.walletRows(snapshot: snapshot, query: query,
                networks: networkIDs, originalOrder: originalOrder ?? [:])
            loading = rows.isEmpty
        }
        lastQuery = query; lastScope = scope
        if typing {
            // Search debounce is expected cancellation, not a provider failure.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        guard !Task.isCancelled, ticket == generation else { return }
        let catalogRows: [TokenDiscoveryEntry]
        if let cachedCatalog, cachedCatalog.query == query, cachedCatalog.networks == networkIDs {
            catalogRows = cachedCatalog.entries
        } else {
            catalogRows = await catalog.managementEntries(query: query, networks: networkIDs)
            guard !Task.isCancelled, ticket == generation else { return }
            cachedCatalog = (query, networkIDs, catalogRows)
        }
        guard !Task.isCancelled, ticket == generation else { return }
        let result = await builder.rows(snapshot: snapshot, catalog: catalogRows, query: query,
            networks: networkIDs, originalOrder: originalOrder ?? [:])
        guard !Task.isCancelled, ticket == generation else { return }
        rows = result; loading = false
        // Reuse the existing bounded, chain-aware contract resolution when a
        // valid address isn't present in either stored inventory or the catalog.
        if result.isEmpty, !OathTokenAddress.networks(for: query).isEmpty {
            await lookup.search(query, available: networks)
            guard !Task.isCancelled, ticket == generation else { return }
            lookupFailed = !lookup.failedNetworks.isEmpty
            rows = lookup.results.map { token in
                .init(id: token.id, networkID: token.network.id, reference: token.reference,
                    name: token.name, symbol: token.symbol, logo: token.logoURL?.absoluteString,
                    decimals: token.decimals, entry: nil, resolvedToken: token)
            }
        }
    }
    func stop() { generation = UUID(); lookup.reset() }
}
