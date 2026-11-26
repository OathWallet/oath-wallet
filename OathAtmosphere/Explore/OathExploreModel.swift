import Foundation
import Observation
import OathAnkr
import OathMarketData
import OathDiagnostics

@MainActor @Observable final class OathExploreModel {
    var snapshots: [ExploreSection: ExploreSectionSnapshot] = [:]
    var loading = Set(ExploreSection.allCases)
    var metrics: [String: ExploreDAppMetric] = [:]
    var loadingMetrics = Set(DAppDescriptor.catalogue.map(\.id))
    private(set) var reloadRevision = 0
    var network: String? {
        didSet {
            guard network != oldValue else { return }
            generation = UUID()
            searchGeneration = UUID(); searching = false
            snapshots = [:]; loading = Set(ExploreSection.allCases)
            searchResults = []
        }
    }
    var searchResults: [TokenDiscoveryEntry] = []
    var searching = false
    @ObservationIgnored private var service: ExploreDataService?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var entriesReady = false
    @ObservationIgnored private var refreshing: UUID?
    @ObservationIgnored private var searchGeneration = UUID()
    var networks: Set<String> { network.map { [$0] } ?? Set(OathImportChain.allCases.filter(\.isEnabled).map(\.id)) }
    func watch(session: OathWalletSession) async {
        let id = UUID(); generation = id
        let networks = networks
        let apps = DAppDescriptor.catalogue.filter { !networks.isDisjoint(with: $0.networks) }
        loading = Set(ExploreSection.allCases)
        loadingMetrics.formUnion(apps.map(\.id))
        do {
            if service == nil {
                let database = try await session.vault.database()
                try Task.checkCancellation()
                service = ExploreDataService(database: database, entries: [],
                    personalDataAllowed: Bundle.main.object(forInfoDictionaryKey: "OathExplorePersonalDataAllowed") as? Bool == true)
            }
            guard let service else { return }
            // Publish SQLite data before catalogue decoding or any API request.
            for section in ExploreSection.allCases {
                let saved = await service.cached(section, networks: networks)
                guard id == generation, !Task.isCancelled else { return }
                if let saved { snapshots[section] = saved }
            }
            for app in apps {
                let saved = await service.cachedTVL(app)
                guard id == generation, !Task.isCancelled else { return }
                if let saved { metrics[app.id] = saved }
            }
            if !entriesReady {
                let entries = await TokenDiscoveryCatalog.shared.managementEntries(query: "", networks: Set(OathImportChain.allCases.filter(\.isEnabled).map(\.id)))
                try Task.checkCancellation()
                await service.updateEntries(entries)
                entriesReady = true
            }
            repeat {
                try Task.checkCancellation(); await refresh(id: id)
                try await Task.sleep(for: .seconds(120))
            } while !Task.isCancelled && generation == id
        } catch is CancellationError { }
        catch {
            guard id == generation else { return }
            loading = []; loadingMetrics = []
            OathDiagnostics.record(error, component: "explore", operation: "initialize")
        }
    }
    func refresh() async {
        // Retry must also recover a failed database/service initialization.
        guard service != nil else { reloadRevision &+= 1; return }
        await refresh(id: generation)
    }
    private func refresh(id: UUID) async {
        guard let service, id == generation, refreshing != id else { return }
        refreshing = id
        defer { if refreshing == id { refreshing = nil } }
        let networks = networks; loading = Set(ExploreSection.allCases)
        let apps = DAppDescriptor.catalogue.filter { !networks.isDisjoint(with: $0.networks) }
        loadingMetrics.formUnion(apps.map(\.id))
        await withTaskGroup(of: RefreshResult.self) { group in
            for section in ExploreSection.allCases {
                group.addTask { .section(section, await service.load(section, networks: networks)) }
            }
            for app in apps { group.addTask { .metric(app.id, await service.loadTVL(app)) } }
            for await result in group {
                guard id == generation, !Task.isCancelled else { group.cancelAll(); return }
                switch result {
                case .section(let section, let snapshot):
                    if let snapshot { snapshots[section] = snapshot }
                    loading.remove(section)
                case .metric(let appID, let value):
                    if let value { metrics[appID] = value }
                    loadingMetrics.remove(appID)
                }
            }
        }
    }
    private enum RefreshResult: Sendable {
        case section(ExploreSection, ExploreSectionSnapshot?)
        case metric(String, ExploreDAppMetric?)
    }
    func search(_ query: String) async {
        let id = UUID(); searchGeneration = id
        searchResults = []
        searching = query.count >= 2
        defer { if searchGeneration == id { searching = false } }
        guard searching else { return }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return } // Expected typing cancellation.
        let found = await TokenDiscoveryCatalog.shared.search(query, networks: networks, limit: 20)
        guard id == searchGeneration, !Task.isCancelled else { return }; searchResults = found
    }
}
