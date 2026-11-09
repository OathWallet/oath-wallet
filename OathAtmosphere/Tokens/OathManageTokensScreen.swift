import SwiftUI
import OathDatabase
import OathDiagnostics

struct OathManageTokensScreen: View {
    let session: OathWalletSession
    let walletID: String
    let currency: String
    @State private var model = OathManageTokensModel()
    @State private var query = ""
    @State private var scope = OathAssetSearchScope.all
    @State private var retry = 0
    @Environment(\.oathLocalizer) private var strings

    private struct Request: Hashable {
        let query: String
        let scope: OathAssetSearchScope
        let revision: Int
        let retry: Int
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                OathSettingsFooter { Text(strings.text(.manageTokensFilterDetail)) }
                if model.observationFailed || model.catalogUnavailable || model.lookupFailed {
                    VStack(spacing: 8) {
                        Text(strings.text(.tokenSearchIncomplete)).foregroundStyle(.secondary)
                        Button(strings.text(.tryAgain)) { retry += 1 }
                    }.padding()
                }
                if model.loading { ProgressView().padding() }
                else if model.rows.isEmpty {
                    Text(strings.text(.tokenNotFound)).foregroundStyle(.secondary).padding()
                }
                ForEach(model.visibleRows) { item in
                    row(item).onAppear { model.revealMore(after: item) }
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(strings.text(.manageTokens))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(OathAssetSearchFilter(query: $query, scope: $scope, permittedNetworks: model.permittedNetworks))
        .task(id: retry) {
            do {
                let db = try await session.vault.database()
                await model.observe(database: db, walletID: walletID, currency: currency)
            } catch {
                OathDiagnostics.record(error, component: "manage_tokens", operation: "open")
                model.failedToOpen(error)
            }
        }
        .task(id: retry) { await model.refreshCatalog() }
        .task(id: Request(query: query, scope: scope, revision: model.revision, retry: retry)) {
            await model.load(query: query, scope: scope)
        }
        .onDisappear { model.stop() }
        .oathNativeLocalization()
    }

    private func row(_ item: OathManagedTokenRow) -> some View {
        let key = walletID + ":" + item.id
        let pending = session.managedTokenOperations.pending.contains(key)
        let failed = session.managedTokenOperations.failed.contains(key)
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                OathBadgedAssetLogo(networkID: item.networkID, isNative: item.reference == "native",
                    source: item.logo, symbol: item.symbol, identity: item.artworkIdentity,
                    size: 40)
                Toggle(isOn: Binding(get: { model.enabled(item) }, set: { save($0, item: item) })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.name).oathFont(.body, weight: .medium)
                        Text(verbatim: item.symbol + " · " + (OathImportChain(rawValue: item.networkID)?.name ?? item.networkID))
                            .oathFont(.subheadline, weight: .regular).foregroundStyle(.secondary)
                    }
                }
                .oathSwitchStyle()
                .disabled(pending || !session.isUnlocked || session.displayedProfile?.id.uuidString != walletID)
                .accessibilityIdentifier("manageTokens.switch." + item.id)
                if pending { ProgressView().accessibilityLabel(strings.text(.manageTokens)) }
            }
            if failed {
                HStack {
                    Text(strings.text(.preferencesSaveFailed)).foregroundStyle(.red)
                    Spacer()
                    Button(strings.text(.tryAgain)) { save(!model.enabled(item), item: item) }
                }.oathFont(.footnote)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
    }

    private func save(_ enabled: Bool, item: OathManagedTokenRow) {
        session.managedTokenOperations.set(enabled, row: item, walletID: walletID) { enabled, row, wallet in
            try await session.setManagedTokenEnabled(enabled, row: row, walletID: wallet)
        }
    }
}
