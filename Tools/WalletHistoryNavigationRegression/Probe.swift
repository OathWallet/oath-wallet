import SwiftUI

private enum OathHomeTab: Hashable { case wallet, history }
private struct Profile { let id: UUID; var revision = 0 }
private struct OathWalletSession { let balancesHidden = false }
private struct OathHistoryFilterSelection {}
private struct Entry { let networkID = "ethereum"; let wallet: String }
private struct Holding {}
private struct Item: Identifiable { let id = "shared-transaction"; let entry: Entry; let holding = Holding() }
private struct Model { let items: [Item]; let displayCurrency = "USD" }
private enum OathImportChain: String { case ethereum; var name: String { "Ethereum" } }
private enum Wallets {
    static let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static func name(_ id: String) -> String { id == first.uuidString ? "Wallet 1" : "Wallet 2" }
}

private struct OathTransactionDetailScreen: View {
    let entry: Entry
    let holding: Holding
    let networkName: String
    let currency: String
    let balancesHidden: Bool
    var body: some View {
        Text(entry.wallet + " receipt").accessibilityIdentifier("receipt")
            .navigationTitle("Transaction details")
    }
}

private struct OathChainActivityScreen: View {
    let walletID: String
    let session: OathWalletSession
    let query: String
    let isVisible: Bool
    let filterSelection: Binding<OathHistoryFilterSelection>
    @State private var selected: Item?
    private var model: Model { .init(items: [.init(entry: .init(wallet: Wallets.name(walletID)))]) }

    var body: some View {
        List {
            Text(Wallets.name(walletID) + " history").accessibilityIdentifier("history.wallet")
            Button("Received USDC") { selected = model.items[0] }
                .accessibilityIdentifier("transaction.row")
        }
        .navigationTitle("History")
        // PRODUCTION_DESTINATION
    }
}

// PRODUCTION_HISTORY_CONTENT

private struct Strings {
    enum Key { case searchTransactions }
    func text(_ key: Key) -> String { "Search transactions" }
}

private struct Probe: View {
    @State private var profile: Profile? = .init(id: Wallets.first)
    @State private var selectedTab = OathHomeTab.wallet
    @State private var historyQuery = ""
    @State private var historyFilters = OathHistoryFilterSelection()
    private let session = OathWalletSession()
    private let strings = Strings()
    private var historyVisible: Bool { selectedTab == .history }
    private var accountScopeIdentity: String { profile?.id.uuidString ?? "" }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Wallet", systemImage: "wallet.bifold", value: OathHomeTab.wallet) {
                NavigationStack {
                    Text(Wallets.name(profile!.id.uuidString)).accessibilityIdentifier("active.wallet")
                        .navigationTitle("Wallet")
                }
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: OathHomeTab.history) { historyNavigation }
        }
        // Fixture-only controls exercise account changes while a receipt is open.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Switch wallet") {
                    profile = .init(id: profile?.id == Wallets.first ? Wallets.second : Wallets.first)
                }.accessibilityIdentifier("switch.wallet")
                Button("Refresh same wallet") { profile?.revision += 1 }
                    .accessibilityIdentifier("refresh.wallet")
            }
        }
        .onChange(of: profile?.id) { _, _ in
            historyQuery = ""
            historyFilters = .init()
        }
    }

    // PRODUCTION_NAVIGATION
}

@main struct WalletHistoryNavigationProbe: App {
    var body: some Scene { WindowGroup { Probe() } }
}
