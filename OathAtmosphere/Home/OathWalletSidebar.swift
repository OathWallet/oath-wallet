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

struct OathWalletSidebarButton: View {
    @Environment(\.oathWalletSidebar) private var sidebar
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathButton(feedback: nil, action: sidebar.open) {
            // A symbol-only Label uses the toolbar's default symbol size.
            Image(systemName: "appclip")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        }
        .disabled(!sidebar.walletAvailable)
        .accessibilityLabel(strings.text(.wallets) + ", " + sidebar.walletName)
        .accessibilityIdentifier("wallet.sidebar.open")
    }
}

struct OathWalletSidebar: View {
    let session: OathWalletSession
    let model: OathWalletSidebarModel
    let balances: OathWalletListBalances
    let onSelect: (String) -> Void
    let onConfirmRemoval: (String) -> Void
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.oathLocalizer) private var strings

    @State private var editMode = EditMode.inactive
    @State private var pendingOrder: [String]?
    @State private var orderFailed = false
    @State private var contactWarning = false
    @State private var walletToDelete: WalletRecord?

    private var canReorder: Bool { session.wallets.count >= 2 }

    var body: some View {
        NavigationStack {
            Group {
                #if compiler(>=6.4.2)
                if #available(iOS 27.2, *) {
                    sidebarContent
                        .toolbarTitleDisplayMode(.inline)
                        .toolbarTitleAlignment(.leading)
                } else {
                    sidebarContent.toolbarTitleDisplayMode(.inlineLarge)
                }
                #else
                sidebarContent.toolbarTitleDisplayMode(.inlineLarge)
                #endif
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
    }

    private var sidebarContent: some View {
        let tree = WalletTree(session.wallets)
        let ordered = pendingOrder.map { tree.reordering($0) } ?? tree
        let standard = WalletTree(ordered.roots.filter { $0.wallet.kind != "privateKey" }.flatMap(\.flattened))
        let keys = WalletTree(ordered.roots.filter { $0.wallet.kind == "privateKey" }.flatMap(\.flattened))
        return VStack(spacing: 0) {
            List {
                walletGroup(standard, other: keys, first: true)
                if !standard.roots.isEmpty && !keys.roots.isEmpty {
                    OathSettingsSectionRule().accessibilityHidden(true)
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                walletGroup(keys, other: standard, first: false)
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

    private func walletGroup(_ group: WalletTree, other: WalletTree, first: Bool) -> some View {
        ForEach(group.rows) { entry in walletRow(entry) }
            .onMove(perform: editMode.isEditing ? { offsets, destination in
                guard pendingOrder == nil, session.isUnlocked, !session.changingWallet else { return }
                let old = group.flattened.map(\.id)
                let new = group.movingRows(offsets, to: destination)
                guard old != new else { return }
                let rest = other.flattened.map(\.id)
                let ids = first ? new + rest : rest + new
                guard Set(ids) == Set(session.wallets.map(\.id)) else { return }
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
    }

    private func walletRow(_ entry: WalletTree.Row) -> some View {
        HStack(spacing: 0) {
            OathButton(feedback: nil) { onSelect(entry.id) } label: {
                OathWalletTreeRow(entry: entry) {
                    OathWalletListRow(wallet: entry.wallet, session: session, balances: balances,
                                      showsDisclosure: false, compact: true)
                }
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .disabled(editMode.isEditing)
            if !editMode.isEditing {
                walletAccessory(entry)
                    .frame(width: 44, height: 44)
                    .padding(.trailing, 8)
            }
        }
        .disabled(!session.isUnlocked || session.changingWallet || model.selectingID != nil)
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
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
