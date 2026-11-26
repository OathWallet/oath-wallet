import Foundation
import OathAnkr
import OathDatabase
import OathDiagnostics

/// A display-only service. No balance/price-table writes, credentials or wallet addresses.
public actor ExploreDataService {
    private let database: OathDatabase
    private let transport: any MarketTransport
    private let personalDataAllowed: Bool
    private let now: @Sendable () -> Date
    private var identities: [String: [ExploreAsset]]
    private var entries: [String: TokenDiscoveryEntry]
    private var snapshots: [String: ExploreSectionSnapshot] = [:]
    private var flights: [String: (id: UUID, task: Task<ExploreSectionSnapshot?, Never>)] = [:]
    private var metrics: [String: ExploreDAppMetric] = [:]
    private var metricFlights: [String: (id: UUID, task: Task<ExploreDAppMetric?, Never>)] = [:]
    private var retryAfter: [String: Date] = [:]
    private var metadata: [String: ExploreIdentityMetadata] = [:]
    private var metadataLoaded = false
    private var metadataBusy = false

    public init(database: OathDatabase, entries: [TokenDiscoveryEntry], personalDataAllowed: Bool,
                transport: any MarketTransport = URLSessionMarketTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.database = database; self.transport = transport; self.personalDataAllowed = personalDataAllowed; self.now = now
        identities = ExploreDecoding.seed(entries: entries)
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// Identity enrichment is installed after the UI has hydrated from SQLite.
    public func updateEntries(_ entries: [TokenDiscoveryEntry]) {
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        identities = ExploreDecoding.seed(entries: entries)
        for (id, row) in metadata { identities[id] = Array(Set((identities[id] ?? []) + row.assets)) }
    }

    /// Indexed SQLite reads only. No network or catalogue initialization is
    /// allowed on this path, including when the observation is several days old.
    public func cached(_ section: ExploreSection, networks: Set<String>) async -> ExploreSectionSnapshot? {
        let key = "explore.v1." + section.rawValue + "." + networks.sorted().joined(separator: ",")
        let time = now()
        if snapshots[key] == nil {
            do {
                if let row = try await database.marketCache(key: key),
                   personalDataAllowed || ![ExploreSource.coinPaprika.rawValue, ExploreSource.coinLore.rawValue].contains(row.source) {
                    do { remember(try decodeSnapshot(row, section: section, networks: networks), key: key) }
                    catch {
                        OathDiagnostics.record(error, component: "explore", operation: "decode_snapshot")
                        try await database.discardMarketCache(matching: row)
                    }
                }
            } catch { OathDiagnostics.record(error, component: "explore", operation: "read_snapshot") }
        }
        return usable(key, at: time)
    }

    public func load(_ section: ExploreSection, networks: Set<String>) async -> ExploreSectionSnapshot? {
        let key = "explore.v1." + section.rawValue + "." + networks.sorted().joined(separator: ",")
        if let flight = flights[key], !flight.task.isCancelled { return await flight.task.value }
        let id = UUID()
        let flight = Task {
            await OathDiagnostics.$chain.withValue(networks.count == 1 ? networks.first : nil) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    await refresh(section, networks: networks, key: key)
                }
            }
        }
        flights[key] = (id, flight)
        let result = await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
        if flights[key]?.id == id { flights[key] = nil }
        return result
    }

    private func refresh(_ section: ExploreSection, networks: Set<String>, key: String) async -> ExploreSectionSnapshot? {
        _ = await cached(section, networks: networks)
        let time = now()
        if let cached = snapshots[key], cached.isFresh(at: time) { return cached }
        if retryAfter[key].map({ $0 > time }) == true { return usable(key, at: time) }
        if section != .trending && !personalDataAllowed { return nil }
        let sources: [ExploreSource] = section == .trending ? [.geckoTerminal, .dexPaprika] : [.coinPaprika, .coinLore]
        for source in sources {
            // Preserve the meaning of a recent trending ranking before changing to activity.
            if source == .dexPaprika, let cached = usable(key, at: time), cached.source == .geckoTerminal,
               time.timeIntervalSince(cached.fetchedAt) < 900 { retryAfter[key] = time.addingTimeInterval(60); return cached }
            do {
                try Task.checkCancellation()
                let tokens = try await fetch(source, section: section, networks: networks)
                let ranked = ExploreRanking.ranked(tokens, section: section, networks: networks, now: time)
                // An empty qualified list is normal, not a provider failure; try the next source.
                guard !ranked.isEmpty else { continue }
                let snapshot = ExploreSectionSnapshot(section: section, source: source, items: ranked, fetchedAt: time, coverage: tokens.count)
                try Task.checkCancellation()
                remember(snapshot, key: key); retryAfter[key] = nil
                do {
                    // Store the normalized display model for every provider.
                    // This is an explicit offline database, not URLCache.
                    let data = try JSONEncoder().encode(snapshot)
                    let winner = try await database.saveMarketCache(.init(key: key, source: source.rawValue, payload: data, fetchedAt: time.timeIntervalSince1970))
                    remember(try decodeSnapshot(winner, section: section, networks: networks), key: key)
                } catch { OathDiagnostics.record(error, component: "explore", operation: "save_snapshot") }
                return usable(key, at: now())
            } catch is CancellationError { return usable(key, at: time) }
            catch { OathDiagnostics.record(error, component: "explore", operation: "load_section", context: ["provider": source.rawValue]) }
        }
        retryAfter[key] = time.addingTimeInterval(60)
        return usable(key, at: time)
    }
    private func usable(_ key: String, at time: Date) -> ExploreSectionSnapshot? {
        snapshots[key].flatMap { $0.isUsable(at: time) ? $0 : nil }
    }
    private func remember(_ snapshot: ExploreSectionSnapshot, key: String) {
        guard snapshots[key].map({ $0.fetchedAt > snapshot.fetchedAt }) != true else { return }
        snapshots[key] = snapshot
    }
    private func decodeSnapshot(_ row: MarketCacheEntry, section: ExploreSection, networks: Set<String>) throws -> ExploreSectionSnapshot {
        let value = try JSONDecoder().decode(ExploreSectionSnapshot.self, from: row.payload)
        let sources: Set<ExploreSource> = section == .trending ? [.geckoTerminal, .dexPaprika] : [.coinPaprika, .coinLore]
        guard value.section == section, sources.contains(value.source), value.source.rawValue == row.source,
              abs(value.fetchedAt.timeIntervalSince1970 - row.fetchedAt) < 0.001, value.isUsable(at: now()),
              (1...100).contains(value.items.count), value.coverage >= value.items.count,
              Set(value.items.map(\.id)).count == value.items.count else { throw MarketDataError.invalidResponse }
        for token in value.items {
            guard token.price.isFinite, token.price > 0, !token.assets.isEmpty else { throw MarketDataError.invalidResponse }
            for asset in token.assets {
                guard networks.contains(asset.network),
                      try ExploreAsset(network: asset.network, reference: asset.reference, decimals: asset.decimals) == asset else {
                    throw MarketDataError.invalidResponse
                }
            }
        }
        return value
    }
    private func fetch(_ source: ExploreSource, section: ExploreSection, networks: Set<String>) async throws -> [ExploreToken] {
        switch source {
        case .coinPaprika:
            let data = try await transport.data(from: URL(string: "https://api.coinpaprika.com/v1/tickers?quotes=USD")!)
            await enrichIdentities(data)
            let stable = ExploreDecoding.stablecoins.union(metadata.filter { $0.value.stablecoin }.keys)
            return try ExploreDecoding.paprika(data, identities: identities, now: now(), stablecoinIDs: stable)
        case .coinLore:
            let path = section == .top ? "tickers/?start=0&limit=100" : "movers/?sort=24h"
            let items = try ExploreDecoding.lore(await transport.data(from: URL(string: "https://api.coinlore.net/api/" + path)!), identities: identities)
            if section != .top, ExploreRanking.ranked(items, section: section, networks: networks, now: now()).isEmpty {
                // Global movers may all be outside the wallet catalogue. Fall back to
                // ranking the explicitly mapped top-100 cohort from the same provider.
                return try ExploreDecoding.lore(await transport.data(from: URL(string: "https://api.coinlore.net/api/tickers/?start=0&limit=100")!), identities: identities)
            }
            return items
        case .geckoTerminal:
            let path: String
            if networks.count == 1, let network = networks.first {
                guard let mapped = ContractPriceRequest.terminalNetworks[network] else { throw MarketDataError.notListed }
                path = "networks/\(mapped)/trending_pools"
            } else { path = "networks/trending_pools" }
            let url = URL(string: "https://api.geckoterminal.com/api/v2/\(path)?include=base_token,quote_token,network&page=1")!
            return try ExploreDecoding.terminal(await transport.data(from: url), now: now())
        case .dexPaprika:
            try await reserveDexPaprikaCredit()
            var parts = URLComponents(string: "https://api.dexpaprika.com/tokens/search")!
            parts.queryItems = [.init(name: "limit", value: "100"), .init(name: "order_by", value: "volume_usd_24h"), .init(name: "sort", value: "desc")]
            if networks.count == 1, let network = networks.first {
                parts.queryItems?.append(.init(name: "chains", value: network == "bnb" ? "bsc" : network))
            }
            return try ExploreDecoding.dexPaprika(await transport.data(from: parts.url!), entries: entries, now: now())
        }
    }
    /// Gradual, bounded enrichment uses exact platform+contract matches only.
    /// Two metadata calls per refresh, fifty per UTC day; no symbol joins.
    private func enrichIdentities(_ tickers: Data) async {
        guard !metadataBusy else { return }; metadataBusy = true
        defer { metadataBusy = false }
        let time = now(); let key = "explore.v1.paprika.identities"
        do {
            if !metadataLoaded {
                metadataLoaded = true
                if let cached = try await database.marketCache(key: key) {
                    metadata = try JSONDecoder().decode([String: ExploreIdentityMetadata].self, from: cached.payload)
                        .filter { time.timeIntervalSince($0.value.fetchedAt) < 7 * 86400 }
                    for (id, row) in metadata { identities[id] = Array(Set((identities[id] ?? []) + row.assets)) }
                }
            }
            let rows = try ExploreDecoding.rows(tickers)
            let candidates = rows.filter { row in
                guard let id = row["id"] as? String, id.range(of: "^[a-z0-9-]{1,100}$", options: .regularExpression) != nil else { return false }
                return identities[id] == nil && metadata[id] == nil
            }.sorted { (ExploreDecoding.number($0["rank"]) ?? .infinity) < (ExploreDecoding.number($1["rank"]) ?? .infinity) }
            let budgetKey = "explore.v1.paprika.metadata_budget", day = Int(time.timeIntervalSince1970 / 86400)
            let previous = try await database.marketCache(key: budgetKey)
            let saved = try previous.map { try JSONDecoder().decode([Int].self, from: $0.payload) } ?? [day, 0]
            var count = saved.count == 2 && saved[0] == day ? saved[1] : 0
            for row in candidates.prefix(2) where count < 50 {
                try Task.checkCancellation()
                guard let id = row["id"] as? String else { continue }
                count += 1
                try await database.saveMarketCache(.init(key: budgetKey, source: "explore", payload: JSONEncoder().encode([day, count]), fetchedAt: time.timeIntervalSince1970))
                let data = try await transport.data(from: URL(string: "https://api.coinpaprika.com/v1/coins/" + id)!)
                let value = try ExploreIdentityMetadata.decode(data, id: id, entries: entries, now: time)
                metadata[id] = value
                if !value.assets.isEmpty { identities[id] = value.assets }
                // Commit each successful response even if the next provider
                // request fails or the user leaves the screen.
                try await database.saveMarketCache(.init(key: key, source: "coinPaprika", payload: JSONEncoder().encode(metadata), fetchedAt: time.timeIntervalSince1970))
            }
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error, component: "explore", operation: "identity_metadata") }
    }
    private func reserveDexPaprikaCredit() async throws {
        let date = now(); let day = Int(date.timeIntervalSince1970 / 86400)
        let key = "explore.v1.dexpaprika.budget"
        let old = try await database.marketCache(key: key)
        let budget = try old.map { try JSONDecoder().decode([Int].self, from: $0.payload) } ?? [day, 0]
        let count = budget.count == 2 && budget[0] == day ? budget[1] : 0
        guard count < 200 else { throw DiagnosticDeferral.publicMarketCooldown }
        try await database.saveMarketCache(.init(key: key, source: "explore", payload: JSONEncoder().encode([day, count + 1]), fetchedAt: date.timeIntervalSince1970))
    }
    public func cachedTVL(_ app: DAppDescriptor) async -> ExploreDAppMetric? {
        guard DAppDescriptor.catalogue.contains(app) else { return nil }
        if let metric = metrics[app.id] { return metric }
        do {
            if let row = try await database.marketCache(key: "explore.v1.tvl." + app.id) {
                do { remember(try decodeMetric(row), appID: app.id) }
                catch {
                    OathDiagnostics.record(error, component: "explore", operation: "decode_dapp_metric")
                    try await database.discardMarketCache(matching: row)
                }
            }
        } catch { OathDiagnostics.record(error, component: "explore", operation: "read_dapp_metric") }
        return metrics[app.id]
    }
    public func loadTVL(_ app: DAppDescriptor) async -> ExploreDAppMetric? {
        guard DAppDescriptor.catalogue.contains(app) else { return nil }
        if let flight = metricFlights[app.id], !flight.task.isCancelled { return await flight.task.value }
        let id = UUID()
        let flight = Task {
            await OathDiagnostics.$operationID.withValue(UUID()) { await refreshTVL(app) }
        }
        metricFlights[app.id] = (id, flight)
        let result = await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
        if metricFlights[app.id]?.id == id { metricFlights[app.id] = nil }
        return result
    }
    private func refreshTVL(_ app: DAppDescriptor) async -> ExploreDAppMetric? {
        let cached = await cachedTVL(app), time = now()
        if let cached, cached.isFresh(at: time) { return cached }
        let key = "explore.v1.tvl." + app.id
        if retryAfter[key].map({ $0 > time }) == true { return cached }
        do {
            try Task.checkCancellation()
            let data = try await transport.data(from: URL(string: "https://api.llama.fi/tvl/" + app.id)!)
            let value = try JSONDecoder().decode(Double.self, from: data)
            guard value.isFinite, value >= 0 else { throw MarketDataError.invalidResponse }
            try Task.checkCancellation()
            remember(.init(value: value, fetchedAt: time), appID: app.id)
            retryAfter[key] = nil
            do {
                let winner = try await database.saveMarketCache(.init(key: key, source: "defillama", payload: JSONEncoder().encode(value), fetchedAt: time.timeIntervalSince1970))
                remember(try decodeMetric(winner), appID: app.id)
            } catch { OathDiagnostics.record(error, component: "explore", operation: "save_dapp_metric") }
        } catch is CancellationError { /* Cancellation preserves the saved observation. */ }
        catch {
            OathDiagnostics.record(error, component: "explore", operation: "dapp_metric")
            retryAfter[key] = time.addingTimeInterval(120)
        }
        return metrics[app.id]
    }
    private func remember(_ metric: ExploreDAppMetric, appID: String) {
        guard metrics[appID].map({ $0.fetchedAt > metric.fetchedAt }) != true else { return }
        metrics[appID] = metric
    }
    private func decodeMetric(_ row: MarketCacheEntry) throws -> ExploreDAppMetric {
        let value = try JSONDecoder().decode(Double.self, from: row.payload)
        guard row.source == "defillama", value.isFinite, value >= 0,
              row.fetchedAt.isFinite, row.fetchedAt > 0, row.fetchedAt <= now().timeIntervalSince1970 + 300 else {
            throw MarketDataError.invalidResponse
        }
        return .init(value: value, fetchedAt: Date(timeIntervalSince1970: row.fetchedAt))
    }
}
