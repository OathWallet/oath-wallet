#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import OathDatabase
import OathDiagnostics

/// Real Home, local SQL observation, deterministic data, no wallet credentials.
struct OathHomeScrollFixture: View {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-oath-home-scroll-fixture")
    @MainActor private(set) static var homeBodyEvaluations = 0
    @MainActor static func recordHomeBody() {
        if enabled { homeBodyEvaluations += 1 }
    }
    private static let testsAccounts = ProcessInfo.processInfo.arguments.contains("-oath-hd-account-fixture")
    static let verifiesRows = ProcessInfo.processInfo.arguments.contains("-oath-scroll-verify")
    private static var testsSidebarWallets: Bool {
        ProcessInfo.processInfo.arguments.contains("-oath-sidebar-wallets") &&
        UserDefaults.standard.string(forKey: "oath.walletTestScope").flatMap(UUID.init(uuidString:)) != nil
    }
    @State private var session: OathWalletSession?
    @State private var settings = OathAppSettings(browserEnabled: ProcessInfo.processInfo.arguments.contains("-oath-test-browser"))
    @State private var failed = false
    @State private var probe = HomeScrollSampler()
    @State private var foregroundDepartures = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                let home = OathHomeScreen(profile: session.displayedProfile, session: session,
                                          settings: settings, lockCoverHidden: true)
                    .overlay(alignment: .bottomTrailing) { HomeRefreshFixtureStatus(probe: probe) }
                    .overlay(alignment: .topLeading) {
                        Text(probe.report).font(.system(size: 1)).foregroundStyle(.clear)
                            .accessibilityLabel("Scroll sample")
                            .accessibilityValue(probe.report)
                            .accessibilityIdentifier("fixture.scroll.sample")
                            .allowsHitTesting(false)
                    }
                    .environment(settings)
                if Self.testsSidebarWallets {
                    OathLocalizedRoot(settings: settings) {
                        home.oathInAppLinks(walletUnlocked: session.isUnlocked)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(verbatim: String(describing: scenePhase))
                            .font(.system(size: 1)).foregroundStyle(.clear)
                            .accessibilityIdentifier("fixture.scenePhase")
                            .accessibilityValue(String(foregroundDepartures))
                            .allowsHitTesting(false)
                    }
                    .onChange(of: scenePhase) { previous, current in
                        if previous == .active && current != .active { foregroundDepartures += 1 }
                    }
                } else {
                    home.oathLanguage(.english)
                }
            } else if failed { Text("Fixture setup failed") }
            else { ProgressView() }
        }
        .onDisappear { probe.stop() }
        .task {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do { try await run() }
                catch is CancellationError { }
                catch {
                    OathDiagnostics.record(error, component: "home", operation: "scroll_fixture")
                    failed = true
                }
            }
        }
    }

    private func run() async throws {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("scroll.sqlite"))
        let tokens = (0..<72).map { index in
            AssetRecord(id: "bench-\(index)", networkID: "ethereum",
                        reference: String(format: "0x%040x", index + 1),
                        name: String(format: "Asset %02d", index), symbol: "T\(index)", decimals: 0)
        }
        try await OathDataEnvironment.seed(db)
        try await db.importWalletIfNeeded(.init(id: id.uuidString, name: "Scroll fixture", kind: Self.testsAccounts ? "hd" : "watchOnly",
            vaultReference: "fixture", createdAt: 1, backedUp: true), accounts: [
                .init(id: "fixture", walletID: id.uuidString, networkID: "ethereum",
                      address: "synthetic-scroll-account", derivationPath: Self.testsAccounts ? "m/44'/60'/0'/0/0" : "")])
        if Self.testsAccounts, let wallet = try await db.wallet(id.uuidString) {
            try await db.importWalletIfNeeded(wallet, accounts: [
                .init(id: "fixture-evm-1", walletID: id.uuidString, networkID: "ethereum",
                    address: "0x0000000000000000000000000000000000000001", derivationPath: "m/44'/60'/0'/0/1", accountIndex: 1),
                .init(id: "fixture-solana-0", walletID: id.uuidString, networkID: "solana",
                    address: "11111111111111111111111111111111", derivationPath: "m/44'/501'/0'/0'", accountIndex: 0)
            ])
        }
        if Self.testsSidebarWallets {
            let preferences = try await OathDataEnvironment.shared.database()
            try await preferences.saveExchangeRates(.init(rates: ["USD": "1", "EUR": "0.9"],
                observedAt: 1, fetchedAt: 1, source: "fixture"))
            let extraKinds = ["hd", "imported", "privateKey", "privateKey"]
            let extraCount = UserDefaults.standard.string(forKey: "oath.sidebarExtraWallets").flatMap(Int.init) ?? extraKinds.count
            for (index, kind) in extraKinds.prefix(max(0, extraCount)).enumerated() {
                let fixtureID = String(format: "00000000-0000-4000-8000-%012d", index + 1)
                try await db.importWalletIfNeeded(.init(id: fixtureID, name: "Fixture wallet \(index + 1)", kind: kind,
                    vaultReference: "fixture-\(index)", createdAt: Double(index + 2), backedUp: true), accounts: [])
            }
            var deleted = WalletRecord(id: UUID().uuidString, name: "Deleted fixture wallet", kind: "watchOnly",
                                       vaultReference: "fixture-trash", createdAt: 1)
            deleted.deletedAt = Date.now.timeIntervalSince1970
            try await db.importWalletIfNeeded(deleted, accounts: [])
        }
        var filter = PortfolioFilter()
        filter.hidesUnverifiedTokens = false
        filter.sort = .nameAscending
        try await db.savePortfolioFilter(filter, walletID: id.uuidString)
        try await db.seed(networks: [], assets: tokens)
        let startsEmpty = ProcessInfo.processInfo.arguments.contains("-oath-empty-home-fixture")
        if !startsEmpty {
            try await commit(tokens, generation: 1, db: db)
        }
        let probe = probe
        session = try await OathWalletSession.scrollFixtureSession(database: db, walletID: id, refresh: {
            probe.refreshState = "running"
            var outcome = "interrupted"
            defer { probe.refreshState = outcome }
            // The empty wallet gets its first holdings in one update. The
            // populated fixture keeps publishing balances during the next swipe.
            let lastGeneration = startsEmpty ? 2 : 121
            for generation in 2...lastGeneration {
                try Task.checkCancellation()
                try await commit(tokens, generation: generation, db: db)
                try await Task.sleep(for: .milliseconds(100))
            }
            outcome = "completed"
        })
        if let session { probe.start(session) }
        guard ProcessInfo.processInfo.arguments.contains("-oath-scroll-updating") else { return }
        let changing = tokens.enumerated().compactMap { $0.offset.isMultiple(of: 4) ? $0.element : nil }
        var generation = 2
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(100))
            try await commit(changing, generation: generation, db: db)
            generation += 1
        }
    }

    private func commit(_ tokens: [AssetRecord], generation: Int, db: OathDatabase) async throws {
        try await db.saveBalances(tokens.map { .init(accountID: "fixture", assetID: $0.id,
            networkID: "ethereum", amountAtomic: String(generation), observedAt: Double(generation), source: "fixture") })
        try await db.savePrices(tokens.map { .init(assetID: $0.id, currency: "USD",
            value: generation.isMultiple(of: 2) ? "2" : "1", observedAt: Double(generation), source: "fixture") })
    }
}
/// A display-link gap measures delayed app callbacks, independently of XCTest's signpost duration.
@MainActor @Observable private final class HomeScrollSampler: NSObject {
    var report = ""
    var refreshState = "idle"
    var homeBodyChanges = ""
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private weak var session: OathWalletSession?
    @ObservationIgnored private weak var scroll: UIScrollView?
    private var previousTarget: Double?
    private var elapsed = 0.0
    private var delayed = 0.0
    private var previousTotal = ""
    static weak var current: HomeScrollSampler?
    private var dragRows = 0
    private var coastRows = 0
    private var dragChanges = 0
    private var coastChanges = 0
    private var initialHomeBodyCount = 0

    func start(_ session: OathWalletSession) {
        Self.current = self
        self.session = session
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ link: CADisplayLink) {
        if scroll == nil {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            for window in windows {
                if let found = homeScroll(in: window) { scroll = found; break }
            }
        }
        guard let scroll else { return }
        let total = session?.homePortfolio.total ?? ""
        defer { previousTotal = total }
        if scroll.isDragging || scroll.isDecelerating {
            if previousTarget == nil { initialHomeBodyCount = OathHomeScrollFixture.homeBodyEvaluations }
            if let previousTarget {
                let interval = link.targetTimestamp - link.timestamp
                elapsed += link.targetTimestamp - previousTarget
                let gap = link.timestamp - previousTarget
                if gap > interval * 0.5 { delayed += gap }
                if total != previousTotal {
                    if scroll.isDecelerating { coastChanges += 1 } else { dragChanges += 1 }
                }
            }
            previousTarget = link.targetTimestamp
        } else if previousTarget != nil {
            homeBodyChanges = String(OathHomeScrollFixture.homeBodyEvaluations - initialHomeBodyCount)
            report = String(format: "%.3f %.3f %d %d", elapsed, elapsed > 0 ? 1000 * delayed / elapsed : 0,
                            dragChanges, coastChanges)
            if OathHomeScrollFixture.verifiesRows { report += " \(dragRows) \(coastRows)" }
            dragRows = 0; coastRows = 0
            previousTarget = nil
            elapsed = 0; delayed = 0; dragChanges = 0; coastChanges = 0
        }
    }

    func rowChanged(in frame: CGRect) {
        guard let scroll, scroll.convert(scroll.bounds, to: scroll.window).intersects(frame) else { return }
        if scroll.isDecelerating { coastRows += 1 }
        else if scroll.isDragging { dragRows += 1 }
    }

    private func homeScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.accessibilityIdentifier == "home.scroll" { return scroll }
        // Lazy compactMap + Collection.first evaluates matching transforms
        // again while resolving indices. Recursive use multiplies traversal
        // work with hierarchy depth and contaminates the performance fixture.
        for child in view.subviews {
            if let found = homeScroll(in: child) { return found }
        }
        return nil
    }
}

/// Observe the witness separately so it cannot invalidate the measured Home.
private struct HomeRefreshFixtureStatus: View {
    let probe: HomeScrollSampler
    var body: some View {
        VStack {
            Text(probe.refreshState).accessibilityIdentifier("fixture.refresh.state")
            Text(probe.homeBodyChanges).accessibilityIdentifier("fixture.home.bodyChanges")
        }
        .font(.system(size: 1)).foregroundStyle(.clear).allowsHitTesting(false)
    }
}
/// Only the correctness run probes rendered rows. Initial realization is excluded.
struct OathScrollRowWitness: View {
    let display: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.onChange(of: display) {
                HomeScrollSampler.current?.rowChanged(in: geometry.frame(in: .global))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
