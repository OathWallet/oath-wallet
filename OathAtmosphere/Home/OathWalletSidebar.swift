import SwiftUI
import OathDatabase
import OathDiagnostics
import OathExchangeRates

struct OathWalletSidebarContext: Sendable {
    var session: OathWalletSession?
    var walletName = ""
    var isVisible = false
    var open: @MainActor @Sendable () -> Void = {}

    @MainActor var walletAvailable: Bool {
        guard let session else { return false }
        return session.isUnlocked && !session.changingWallet && !session.resetting
    }
}

private struct OathWalletSidebarKey: EnvironmentKey {
    static let defaultValue = OathWalletSidebarContext()
}

extension EnvironmentValues {
    var oathWalletSidebar: OathWalletSidebarContext {
        get { self[OathWalletSidebarKey.self] }
        set { self[OathWalletSidebarKey.self] = newValue }
    }
}

struct OathWalletSidebarButton<Detail: View>: View {
    private let detail: Detail
    private let detailAccessibilityValue: String
    @Environment(\.oathWalletSidebar) private var sidebar
    @Environment(\.oathLocalizer) private var strings

    init(accessibilityValue: String = "", @ViewBuilder detail: () -> Detail) {
        self.detail = detail()
        detailAccessibilityValue = accessibilityValue
    }

    init() where Detail == EmptyView {
        self.init { EmptyView() }
    }

    var body: some View {
        OathButton(feedback: nil, action: sidebar.open) {
            HStack(spacing: 10) {
                Image(systemName: "appclip")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                detail
            }
        }
        .disabled(!sidebar.walletAvailable)
        .accessibilityLabel(strings.text(.wallets) + ", " + sidebar.walletName)
        .accessibilityValue(detailAccessibilityValue)
        .accessibilityIdentifier("wallet.sidebar.open")
    }
}

struct OathWalletSidebar: View {
    let session: OathWalletSession
    let model: OathWalletSidebarModel
    let balances: OathWalletListBalances
    let onSelect: (String) -> Void
    let onSelectAccount: (String, HomeAccountSelection?) -> Void
    let onConfirmRemoval: (String) -> Void
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.oathLocalizer) private var strings

    @State private var accountGroups: [HDAccountFamily: [String: [EVMAccountGroup]]] = [:]
    @State private var editMode = EditMode.inactive
    @State private var pendingOrder: [String]?
    @State private var orderFailed = false
    @State private var contactWarning = false
    @State private var walletToDelete: WalletRecord?
    @State private var accountDetails: OathHDAccountDestination?

    private var canReorder: Bool { WalletTree(session.wallets).sections.contains { $0.wallets.count > 1 } }

    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 27.2, *) {
                    sidebarContent
                        .toolbarTitleDisplayMode(.inline)
                        .toolbarTitleAlignment(.leading)
                } else {
                    sidebarContent.toolbarTitleDisplayMode(.inlineLarge)
                }
            }
            .navigationTitle(strings.text(.wallets))
            .toolbar {
                if editMode.isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(strings.text(.done)) { editMode = .inactive }
                            .accessibilityIdentifier("sidebar.sort.done")
                    }
                }
            }
            .oathNativeLocalization()
        }
        .accessibilityIdentifier("wallet.sidebar")
        .sheet(item: $accountDetails) { destination in
            OathHDAccountDetails(session: session, destination: destination)
        }
        .task(id: session.isUnlocked) {
            guard session.isUnlocked else { return }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let db = try await session.vault.database()
                    for try await values in db.observeAccountGroups() {
                        guard !Task.isCancelled else { return }
                        if accountGroups != values { accountGroups = values }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    OathDiagnostics.record(error, component: "wallet_list", operation: "observe_accounts")
                }
            }
        }
    }

    private var sidebarContent: some View {
        let tree = WalletTree(session.wallets)
        let ordered = pendingOrder.map { tree.reordering($0) } ?? tree
        let sections = ordered.sections
        return VStack(spacing: 0) {
            List {
                ForEach(sections) { section in
                    OathWalletSectionHeader(category: section.category, title: strings.text(section.category.titleKey),
                                            showsDivider: section.id != sections.first?.id)
                    walletGroup(section.tree, category: section.category, sections: sections)
                }
                if !session.recentlyDeletedWallets.isEmpty && (!settings.hideRecentlyDeletedInSwitcher || session.wallets.isEmpty) {
                    OathRecentlyDeletedWalletsRow(count: session.recentlyDeletedWallets.count) {
                        model.navigate(.recentlyDeleted)
                    }
                    .disabled(editMode.isEditing)
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                if let failedID = model.failedID, session.wallets.contains(where: { $0.id == failedID }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(strings.text(.walletChangeFailedDetail)).oathFont(.subheadline).foregroundStyle(.secondary)
                        OathButton(strings.text(.tryAgain), feedback: nil) { onSelect(failedID) }
                    }
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }
            // Recreate the native list when its direction flips. Reused cells
            // can otherwise retain their previous horizontal mirroring.
            .id(strings.language.isRightToLeft)
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
            .environment(\.defaultMinListRowHeight, 0)
            .accessibilityIdentifier("wallet.sidebar.list")

            OathSettingsSectionRule().accessibilityHidden(true)
            VStack(spacing: 0) {
                action(.addWallet, title: .addWallet, icon: "plus.circle")
                action(.settings, title: .walletSettings, icon: "gearshape")
                    .modifier(OathSidebarPreferences(model: model))
                action(.support, title: .helpCenter, icon: "questionmark.circle")
                    .contextMenu {
                        Button { model.navigate(.support) } label: {
                            Label(strings.text(.helpCenter), systemImage: "questionmark.circle")
                        }
                        Button { contactWarning = true } label: {
                            Label(strings.text(.sendContactSupport), systemImage: "envelope")
                        }
                    }
            }
            .disabled(editMode.isEditing || session.changingWallet || model.selectingID != nil)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .onChange(of: canReorder) { _, available in
            if !available { editMode = .inactive }
        }
        .onChange(of: model.isVisible) { _, visible in
            if !visible {
                editMode = .inactive
                contactWarning = false
                walletToDelete = nil
                accountDetails = nil
            }
        }
        .alert(strings.text(.walletRemovalTitle), isPresented: Binding(
            get: { walletToDelete != nil }, set: { if !$0 { walletToDelete = nil } }
        ), presenting: walletToDelete) { wallet in
            Button(strings.text(.moveToRecentlyDeleted), role: .destructive) {
                onConfirmRemoval(wallet.id)
            }
            Button(strings.text(.cancel), role: .cancel) {}
        } message: { wallet in
            Text(session.walletName(wallet, strings: strings) + "\n\n" + strings.text(.walletRemovalDetail))
        }
        .alert(strings.text(.sendContactSupport), isPresented: $contactWarning) {
            Button(strings.text(.cancel), role: .cancel) {}
            Button(strings.text(.sidebarSupportAccept)) { model.navigate(.contactSupport) }
        } message: { Text(strings.text(.sidebarSupportWarning)) }
        .alert(strings.text(.walletChangeFailed), isPresented: $orderFailed) {} message: {
            Text(strings.text(.walletChangeFailedDetail))
        }
    }

    @ViewBuilder private func walletGroup(_ group: WalletTree, category: WalletListCategory, sections: [WalletListSection]) -> some View {
        if editMode.isEditing {
            ForEach(group.rows) { entry in
                walletRow(entry, hasChildren: false).moveDisabled(group.roots.count < 2)
            }
                .onMove(perform: editMode.isEditing ? { offsets, destination in
                    guard pendingOrder == nil, session.isUnlocked, !session.changingWallet else { return }
                    let old = group.flattened.map(\.id)
                    let new = group.movingRows(offsets, to: destination)
                    guard old != new else { return }
                    let ids = sections.flatMap { $0.category == category ? new : $0.wallets.map(\.id) }
                    guard ids.count == session.wallets.count, Set(ids) == Set(session.wallets.map(\.id)) else { return }
                    pendingOrder = ids
                    Task {
                        defer { pendingOrder = nil }
                        await OathDiagnostics.$operationID.withValue(UUID()) {
                            do { try await session.reorderWallets(ids) }
                            catch is CancellationError { /* Drawer or session closed. */ }
                            catch {
                                OathDiagnostics.record(error, component: "wallet_list", operation: "reorder_sidebar")
                                orderFailed = true
                            }
                        }
                    }
                } : nil)
        } else {
            // One lazy List row per wallet/account; a family VStack eagerly
            // constructs every child, even when only its parent is on screen.
            ForEach(listRows(group)) { row in
                Group {
                    if let child = row.child {
                        accountRow(child, parent: row.parent, hasFollowingSibling: row.hasFollowingSibling)
                    } else {
                        walletRow(row.parent, hasChildren: row.hasChildren)
                    }
                }
                .disabled(!session.isUnlocked || session.changingWallet || model.selectingID != nil)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
    }

    private struct ListRow: Identifiable {
        let parent: WalletTree.Row
        var child: AccountChild?
        var hasChildren = false
        var hasFollowingSibling = false
        var id: String { parent.id + ":" + (child?.id.identity ?? "root") }
    }

    private func listRows(_ group: WalletTree) -> [ListRow] {
        group.rows.flatMap { entry in
            let children = accountChildren(entry)
            return [ListRow(parent: entry, hasChildren: !children.isEmpty)] + children.map { child in
                ListRow(parent: entry, child: child, hasFollowingSibling: child.id != children.last?.id)
            }
        }
    }

    private struct AccountChild: Identifiable {
        let family: HDAccountFamily
        let account: EVMAccountGroup
        var id: HomeAccountSelection { .init(family: family, path: account.path) }
    }

    private func accountChildren(_ entry: WalletTree.Row) -> [AccountChild] {
        guard !editMode.isEditing, ["hd", "imported", "passphrase"].contains(entry.wallet.kind) else { return [] }
        return HDAccountFamily.allCases.flatMap { family -> [AccountChild] in
            let accounts = accountGroups[family]?[entry.id] ?? []
            // Each type owns its tree visibility. Adding a Solana account must
            // not expose a lone EVM account (and vice versa).
            guard accounts.count >= 2 else { return [] }
            return accounts.map { AccountChild(family: family, account: $0) }
        }
    }

    private func walletRow(_ entry: WalletTree.Row, hasChildren: Bool) -> some View {
        HStack(spacing: 0) {
            if editMode.isEditing {
                // Reordering is not a disabled wallet. Keep the regular content
                // without a selection button; native List owns the move handle.
                walletRowContent(entry, hasChildren: hasChildren)
            } else {
                OathButton(feedback: nil) { onSelect(entry.id) } label: {
                    walletRowContent(entry, hasChildren: hasChildren)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                walletAccessory(entry)
                    .frame(width: 44, height: 44)
                    .padding(.trailing, 8)
            }
        }
        .disabled(!session.isUnlocked || session.changingWallet || model.selectingID != nil)
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }

    private func walletRowContent(_ entry: WalletTree.Row, hasChildren: Bool) -> some View {
        OathWalletTreeRow(entry: entry, hasChildren: hasChildren) {
            OathWalletListRow(wallet: entry.wallet, session: session, balances: balances,
                              showsDisclosure: false, compact: true,
                              representsSelectedAccount: representsSelectedSingleAccount(entry))
        }
    }

    private func representsSelectedSingleAccount(_ entry: WalletTree.Row) -> Bool {
        guard let selected = session.selectedHomeAccount,
              let accounts = accountGroups[selected.family]?[entry.id], accounts.count == 1 else { return false }
        // A formerly visible account can become the only remaining account of
        // its type. Keep the selection checkmark on its wallet when hiding it.
        return accounts[0].path == selected.path
    }

    private func accountRow(_ child: AccountChild, parent: WalletTree.Row, hasFollowingSibling: Bool) -> some View {
        let selected = session.displayedProfile?.id.uuidString == parent.id && session.selectedHomeAccount == child.id
        return OathButton(feedback: nil) {
            guard accountDetails == nil else { return }
            onSelectAccount(parent.id, child.id)
        } label: {
            OathWalletTreeRow(childOf: parent, hasFollowingSibling: hasFollowingSibling) {
                OathHDAccountSummary(wallet: parent.wallet, account: child.account, family: child.family,
                    session: session, balances: balances, selected: selected, showsAddress: false)
            }
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .highPriorityGesture(LongPressGesture().onEnded { _ in
            guard session.isUnlocked, !session.changingWallet, !editMode.isEditing else { return }
            OathHaptics.shared.play(.selection)
            accountDetails = .init(wallet: parent.wallet, selection: child.id)
        })
        .accessibilityIdentifier("sidebar.account.\(child.family.rawValue).\(child.account.index)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: strings.text(.hdAccountDetails)) {
            accountDetails = .init(wallet: parent.wallet, selection: child.id)
        }
    }

    @ViewBuilder private func walletAccessory(_ entry: WalletTree.Row) -> some View {
        if model.selectingID == entry.id {
            ProgressView()
                .accessibilityLabel(session.walletName(entry.wallet, strings: strings))
        } else {
            Menu {
                walletAction(.customize, id: entry.id, title: .customizeWallet, icon: "pencil")
                if entry.wallet.kind == "privateKey" {
                    walletAction(.revealPrivateKey, id: entry.id, title: .sidebarRevealKey, icon: "key")
                } else if entry.wallet.kind != "watchOnly" {
                    walletAction(.revealRecoveryPhrase, id: entry.id,
                                 title: entry.wallet.kind.hasSuffix("Multisig") ? .multisigRecovery : .sidebarRevealPhrase,
                                 icon: "key")
                }
                walletAction(.settings, id: entry.id, title: .walletDetails, icon: "gearshape")
                if canReorder {
                    Divider()
                    Button {
                        if canReorder { editMode = .active }
                    } label: {
                        Label(strings.text(.sidebarResort), systemImage: "arrow.up.arrow.down")
                    }
                }
                Divider()
                Button(role: .destructive) { walletToDelete = entry.wallet } label: {
                    Label {
                        Text(strings.text(.deleteWallet))
                    } icon: {
                        if let icon = Self.deleteIcon { Image(uiImage: icon).renderingMode(.original) }
                        else { Image(systemName: "trash") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
            }
            .menuOrder(.fixed)
            .buttonStyle(.borderless)
            .accessibilityLabel(strings.text(.moreOptions) + ", " + session.walletName(entry.wallet, strings: strings))
            .accessibilityIdentifier("sidebar.walletMenu." + entry.id)
        }
    }

    // The native menu colors a destructive title but can leave a template symbol neutral.
    private static let deleteIcon = UIImage(systemName: "trash")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)

    private func walletAction(_ action: OathWalletSidebarModel.WalletAction, id: String,
                              title: OathStringKey, icon: String) -> some View {
        Button { model.navigate(.wallet(action, id)) } label: {
            Label(strings.text(title), systemImage: icon)
        }
    }

    private func action(_ action: OathWalletSidebarModel.Action, title: OathStringKey, icon: String) -> some View {
        OathButton(feedback: nil) { model.navigate(action) } label: {
            OathSettingsRow(title: strings.text(title), icon: icon)
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityIdentifier("wallet.sidebar." + String(describing: action))
    }
}

/// Home presents authentication above the drawer so its wallet list stays in place.
struct OathSidebarRemovalPresentation: ViewModifier {
    let session: OathWalletSession
    let removal: OathWalletRemovalModel
    @Environment(\.oathLocalizer) private var strings
    @State private var passcodeVisible = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { removal.phase == .passcode },
                set: { if !$0 && removal.phase == .passcode { removal.cancel() } }
            ), onDismiss: { passcodeVisible = false }) {
                NavigationStack {
                    OathSecretPasscodePage(session: session, busy: removal.busy, notice: Binding(
                        get: { removal.phase == .passcode ? removal.notice : nil }, set: { removal.notice = $0 }
                    ), title: .removeWallets, identifier: "wallets.remove.passcode", onSubmit: removal.submit)
                    .navigationTitle(strings.text(.removeWallets))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { OathCloseButton { removal.cancel() } }
                    }
                }
                .oathLanguage(strings.language)
                .presentationDetents([.large])
                .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
                .presentationCompactAdaptation(.sheet)
                .onAppear { passcodeVisible = true }
            }
            .alert(strings.text(.removeWallets), isPresented: Binding(
                get: { !passcodeVisible && removal.phase == .idle && removal.notice != nil },
                set: { if !$0 { removal.notice = nil } }
            )) {} message: {
                if let notice = removal.notice { Text(strings.text(notice)) }
            }
            .oathErrorFeedback(removal.notice)
    }
}

/// Both shortcuts write through the same settings store as the full preference pages.
private struct OathSidebarPreferences: ViewModifier {
    let model: OathWalletSidebarModel
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.oathLocalizer) private var strings
    @State private var rates = OathCurrencyModel()
    @State private var saving = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Menu {
                let codes = CurrencyCatalog.sections(availableCodes: rates.snapshot?.rates.keys.map { $0 } ?? [],
                    selectedCode: settings.currency, query: "", displayLocale: strings.language.locale)
                Picker(strings.text(.currency), selection: Binding(get: { settings.currency }, set: { code in
                    guard !saving, settings.currency != code, code == "USD" || rates.snapshot?.rates[code] != nil else { return }
                    model.changePreference { selectCurrency(code) }
                })) {
                    ForEach(codes.mostUsed + codes.others, id: \.self) { code in
                        Text(CurrencyCatalog.name(code, locale: strings.language.locale) + " (" + strings.invariant(code) + ")")
                            .tag(code)
                            .disabled(code != "USD" && rates.snapshot?.rates[code] == nil)
                    }
                }
                .pickerStyle(.inline)
            } label: { Label(strings.text(.currency), systemImage: "banknote") }
            Menu {
                Picker(strings.text(.language), selection: Binding(get: { settings.preference }, set: { preference in
                    guard preference != settings.preference else { return }
                    model.changePreference { [settings] in settings.select(preference) }
                })) {
                    Text(strings.text(.systemLanguage)).tag(OathLanguagePreference.system)
                    ForEach(OathLanguage.matching("", strings: strings), id: \.self) { language in
                        Text(language.nativeName).tag(OathLanguagePreference.language(language))
                    }
                }
                .pickerStyle(.inline)
            } label: { Label(strings.text(.language), systemImage: "globe") }
            Button { model.navigate(.security) } label: { Label(strings.text(.sidebarSecurity), systemImage: "lock.shield") }
        }
        .task(id: model.isVisible) { if model.isVisible { await rates.observe() } }
    }

    private func selectCurrency(_ code: String) {
        saving = true
        Task {
            defer { saving = false }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do { try await settings.selectCurrency(code) }
                catch is CancellationError { /* Closing the scene cancelled the write. */ }
                catch {
                    OathDiagnostics.record(error, component: "preferences", operation: "select_sidebar_currency")
                    settings.showsError = true
                }
            }
        }
    }
}
