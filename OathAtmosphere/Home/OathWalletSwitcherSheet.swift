import OathDiagnostics
import SwiftUI
import UIKit
import OathDatabase

struct OathWalletSwitcherSheet: View {
    let session: OathWalletSession
    let startsAtAddWallet: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(OathAppSettings.self) private var settings
    private enum Route: Hashable { case removalPasscode, importPhrase, privateKeyChains, privateKey(OathPrivateKeyChoice), multisig, restoreList, restorePassword }
    private struct Customization {
        let walletID: String
        let mode: OathWalletCustomizationScreen.Mode
    }
    @State private var customization: Customization?
    @State private var path = NavigationPath()
    @State private var restoresFromICloud = false
    @State private var restore = OathCloudRestoreModel()
    @State private var work: Task<Void, Never>?
    @State private var pendingWalletID: String?
    @State private var createRequestID = UUID()
    @State private var failed = false
    @State private var balances = OathWalletListBalances()

    @State private var editing = false
    @State private var pendingOrder: [String]?
    @State private var removal: OathWalletRemovalModel
    @State private var showsRemovalPasscode = false
    @State private var entryPresentation = OathWalletEntryPresentation()

    init(session: OathWalletSession, startsAtAddWallet: Bool = false) {
        self.session = session
        self.startsAtAddWallet = startsAtAddWallet
        if startsAtAddWallet, let id = session.pendingCustomizationID {
            _customization = State(initialValue: Customization(walletID: id, mode: .setup))
        }
        _removal = State(initialValue: OathWalletRemovalModel(session: session))
    }

    private var actionsEnabled: Bool {
        session.isUnlocked && !session.changingWallet && work == nil && pendingOrder == nil && !removal.busy && !removal.confirming
    }

    private var rootTitle: OathStringKey {
        if customization != nil { return .customizeWallet }
        return startsAtAddWallet ? .addWallet : .wallets
    }

    private var requiresCustomization: Bool {
        guard let customization else { return false }
        return customization.mode != .edit
    }

    var body: some View {
        OathWalletSettingsScreen(session: session, switcherPath: $path,
            dismissDisabled: requiresCustomization || work != nil || pendingOrder != nil || removal.busy || removal.confirming || restore.phase == .saving) { onWalletSettings, onRecentlyDeleted in
            AnyView(switcherNavigationRoot(onWalletSettings: onWalletSettings, onRecentlyDeleted: onRecentlyDeleted))
        }
        .environment(\.oathWalletEntryPresentation, startsAtAddWallet ? entryPresentation : nil)
        .environment(\.oathAutofocusPresentation, startsAtAddWallet ? entryPresentation.autofocus : nil)
        .presentationDragIndicator(.visible)
        .oathNativeLocalization()
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.walletChangeFailed), isPresented: $failed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            Text(strings.text(.walletChangeFailedDetail))
        }
        .alert(strings.text(removalTitle), isPresented: Binding(
            get: { (removal.phase == .confirmation || removal.phase == .recentlyDeletedConfirmation) && !removal.confirming },
            set: { _ in }
        )) {
            OathButton(strings.text(removalButton), role: .destructive) {
                if removal.phase == .recentlyDeletedConfirmation { removal.confirmRecentlyDeleted() }
                else { removal.confirm() }
            }
            OathButton(strings.text(.cancel), role: .cancel) { removal.cancel() }
        } message: { Text(removalDetail) }
        .alert(strings.text(.removeWallets), isPresented: Binding(
            get: { removal.notice != nil && !showsRemovalPasscode },
            set: { if !$0 { removal.notice = nil } }
        )) {
            OathDoneButton { removal.notice = nil }
        } message: { if let notice = removal.notice { Text(strings.text(notice)) } }
        .onDisappear { work?.cancel(); work = nil; restore.stop(); removal.cancel() }
        .onChange(of: removal.phase) { _, phase in
            if phase == .passcode, !showsRemovalPasscode {
                showsRemovalPasscode = true
                path.append(Route.removalPasscode)
            } else if phase == .idle, showsRemovalPasscode {
                showsRemovalPasscode = false
                if !path.isEmpty { path.removeLast() }
            }
        }
        .task(id: restoresFromICloud ? [] : balances.scope(session: session)) {
            if !restoresFromICloud { await balances.observe(session: session) }
        }
        .onChange(of: path.count) { previous, count in
            if count == 0 {
                restoresFromICloud = false; restore.stop()
                if showsRemovalPasscode { showsRemovalPasscode = false; removal.cancel(preserveNotice: true) }
            }
            else if previous > count, count == 1, restoresFromICloud { restore.backToList() }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { stopRestore(); removal.cancel(); editing = false }
            else if let id = session.pendingCustomizationID { showCreatedWallet(id) }
            else if restoresFromICloud { restore.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopRestore(); removal.cancel() }
            else if phase == .active, restoresFromICloud, session.isUnlocked { restore.start() }
        }
    }

    private func switcherNavigationRoot(onWalletSettings: @escaping (String) -> Void,
                                        onRecentlyDeleted: @escaping () -> Void) -> some View {
        Group {
            if let customization {
                OathWalletCustomizationScreen(session: session, walletID: customization.walletID,
                    mode: customization.mode, autofocusName: !startsAtAddWallet) { dismiss() }
                    .id(customization.walletID)
            } else if startsAtAddWallet {
                ScrollView {
                    addWalletActions.oathWalletEntryContent()
                }
                    .scrollBounceBehavior(.basedOnSize)
                    .disabled(!actionsEnabled)
            } else {
                walletList(onWalletSettings: onWalletSettings, onRecentlyDeleted: onRecentlyDeleted)
            }
        }
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .navigationTitle(strings.text(rootTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !requiresCustomization {
                    ToolbarItem(placement: .topBarLeading) {
                        OathCloseButton { dismiss() }
                            .disabled(!actionsEnabled)
                            .accessibilityIdentifier("wallets.close")
                    }
                }
                if !startsAtAddWallet && customization == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        if editing {
                            OathDoneButton { withAnimation { editing = false } }
                        } else {
                            OathButton(strings.text(.editWallets)) { withAnimation { editing = true } }
                                .oathNeutralControl()
                        }
                    }
                    .disabled(!actionsEnabled)
                    .accessibilityIdentifier("wallets.edit")
                }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .removalPasscode:
                    OathSecretPasscodePage(session: session, busy: removal.busy || removal.confirming,
                        notice: Binding(get: { removal.notice }, set: { removal.notice = $0 }),
                        title: .removeWallets, identifier: "wallets.remove.passcode", onSubmit: removal.submit)
                        .navigationBarBackButtonHidden(removal.confirming)
                case .importPhrase:
                    OathAdditionalWalletImportPage(session: session, onImported: showCreatedWallet)
                        .navigationBarTitleDisplayMode(.inline)
                case .privateKeyChains:
                    OathChooseChainScreen { path.append(Route.privateKey($0)) }
                        .oathWalletEntryContent(.large)
                case .privateKey(let choice):
                    OathPrivateKeyImportScreen(choice: choice, isAllowed: session.isUnlocked) { key, requestID in
                        let id = try await session.addWallet(requestID: requestID, privateKey: key)
                        try Task.checkCancellation()
                        if session.isUnlocked { showCreatedWallet(id) }
                    }
                case .multisig:
                    OathAdditionalMultisigPages(session: session, path: $path, onCreated: showCreatedWallet)
                case .restoreList:
                    ScrollView {
                        OathCloudRestoreList(model: restore) { entry in
                            restore.choose(entry)
                            if restore.selected != nil { path.append(Route.restorePassword) }
                        }
                        .oathWalletEntryContent()
                    }
                    .navigationTitle(strings.text(.restoreICloud))
                    .navigationBarTitleDisplayMode(.inline)
                case .restorePassword:
                    ScrollView {
                        OathCloudRestorePasswordPage(model: restore) { restored in
                            try await session.restoreWallet(restored)
                            try Task.checkCancellation()
                            if let id = session.pendingCustomizationID { showCreatedWallet(id) }
                            else { dismiss() }
                        }
                        .oathWalletEntryContent()
                    }
                    .navigationTitle(strings.text(.restoreICloud))
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(restore.phase == .saving)
                }
            }
    }

    private var removalTitle: OathStringKey {
        if removal.phase == .recentlyDeletedConfirmation { return .recentlyDeleted }
        return removal.action?.resetsApp == true ? .resetWarningTitle : .walletRemovalTitle
    }

    private var removalButton: OathStringKey {
        if removal.phase == .recentlyDeletedConfirmation { return .deleteWalletsPermanently }
        return removal.action?.resetsApp == true ? .resetConfirm : .moveToRecentlyDeleted
    }

    private var removalDetail: String {
        if removal.phase == .recentlyDeletedConfirmation { return strings.text(.walletPermanentRemovalDetail) }
        if removal.action?.resetsApp == true {
            return strings.text(.resetWalletsDetail) + "\n\n" + strings.text(.resetDataDetail)
                + "\n\n" + strings.text(.resetCloudDetail)
        }
        return strings.text(.walletRemovalDetail)
    }

    private func walletList(onWalletSettings: @escaping (String) -> Void,
                            onRecentlyDeleted: @escaping () -> Void) -> some View {
        let rows = OathWalletManagementSnapshot(session: session, pendingOrder: pendingOrder)
        return OathWalletFamilyList(tree: rows.tree, editing: editing, enabled: actionsEnabled,
            allowsSelectionWhileEditing: true, reorderingRequiresEditing: true, deleteTitle: strings.text(.delete), onMove: move,
            onDelete: { id in
                guard actionsEnabled, scenePhase != .background else { return }
                removal.begin(.init(ids: [id], permanently: false), reason: strings.text(.walletRemovalAuthentication))
            }, onSelect: { id in
                guard actionsEnabled, scenePhase != .background else { return }
                if editing { openWallet(id, using: onWalletSettings) }
                else if let uuid = UUID(uuidString: id) {
                    pendingWalletID = id
                    run { try await session.selectWallet(uuid) }
                }
            }, contextMenu: { id in
                UIMenu(children: [
                    UIAction(title: strings.text(.customizeWallet), image: UIImage(systemName: "paintpalette")) { _ in
                        openWallet(id) { customization = Customization(walletID: $0, mode: .edit) }
                    },
                    UIAction(title: strings.text(.walletDetails), image: UIImage(systemName: "slider.horizontal.3")) { _ in
                        openWallet(id, using: onWalletSettings)
                    }
                ])
            }) { entry in
                OathWalletTreeRow(entry: entry) {
                    OathWalletListRow(wallet: entry.wallet, session: session, balances: balances,
                        showsDisclosure: editing, isWorking: work != nil && pendingWalletID == entry.id)
                }
                .oathLanguage(strings.language)
            } footer: {
                VStack(spacing: 0) {
                    if rows.deletedCount > 0 && !settings.hideRecentlyDeletedInSwitcher {
                        OathSettingsListSectionRule()
                        OathRecentlyDeletedWalletsRow(count: rows.deletedCount) {
                            guard actionsEnabled, scenePhase != .background else { return }
                            editing = false
                            onRecentlyDeleted()
                        }
                    }
                    OathSettingsSectionRule()
                    addWalletActions
                }
                .oathLanguage(strings.language)
            }
        .accessibilityIdentifier("wallets.list")
    }

    private var addWalletActions: some View {
        OathWalletActions(identifier: "wallets",
                        onCreate: {
                            if actionsEnabled, customization == nil {
                                customization = Customization(walletID: createRequestID.uuidString, mode: .create(createRequestID))
                            }
                        },
                        onCreateMultisig: { path.append(Route.multisig) },
                        onImport: { path.append(Route.importPhrase) },
                        onImportPrivateKey: { path.append(Route.privateKeyChains) },
                        onRestore: {
                            restoresFromICloud = true
                            restore.start()
                            path.append(Route.restoreList)
                        })
    }

    private func showCreatedWallet(_ id: String) {
        guard session.isUnlocked, customization?.walletID != id else { return }
        // The wallet is committed. Drop its input pages and finish setup in this sheet.
        customization = Customization(walletID: id, mode: .setup)
        path = NavigationPath()
    }

    private func move(_ proposed: [String]) {
        guard editing, actionsEnabled, scenePhase != .background else { return }
        let tree = WalletTree(session.wallets)
        let ids = tree.reordering(proposed).flattened.map(\.id)
        guard ids != tree.flattened.map(\.id) else { return }
        pendingOrder = ids
        Task {
            defer { pendingOrder = nil }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do { try await session.reorderWallets(ids) }
                catch is CancellationError { /* Lock or session transition cancels the local reorder. */ }
                catch {
                    OathDiagnostics.record(error, component: "wallet_list", operation: "reorder_family")
                    failed = true
                }
            }
        }
    }

    private func stopRestore() {
        restore.stop()
        // A cleared password page cannot resume a restore. Keep the same sheet
        // and return to discovery after backgrounding or locking.
        if restoresFromICloud, path.count > 1 { path = NavigationPath([Route.restoreList]) }
    }

    private func openWallet(_ id: String, using action: (String) -> Void) {
        guard actionsEnabled,
              session.wallets.contains(where: { $0.id == id }) else { return }
        // Return from wallet navigation to the normal switcher, not its editor.
        editing = false
        action(id)
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        work = Task {
            defer { work = nil }
            do {
                try await action()
                guard !Task.isCancelled, session.isUnlocked else { return }
                dismiss()
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled, session.isUnlocked { failed = true } }
        }
    }
}

/// Additional wallets inherit the existing app lock. Reuse the full validated
/// phrase editor and scanner without asking the user to set another passcode.
struct OathAdditionalWalletImportPage: View {
    let session: OathWalletSession
    var scannedPhrase: OathValidatedMnemonic? = nil
    @State private var didSeedScan = false
    let onImported: (String) -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var draft = OathRecoveryPhraseDraft()
    @State private var work: Task<Void, Never>?
    @State private var failed = false

    var body: some View {
        OathRecoveryPhraseScreen(draft: draft, isImporting: work != nil, onImport: importPhrase)
        .onAppear { if !didSeedScan { didSeedScan = true; if let scannedPhrase { draft.replace(with: scannedPhrase.phrase) } } }
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.walletChangeFailed), isPresented: $failed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            Text(strings.text(.walletChangeFailedDetail))
        }
        // The editor owns import progress in its native toolbar action.
        .navigationBarBackButtonHidden(work != nil)
        .oathNativeLocalization()
        .interactiveDismissDisabled(work != nil)
        .onDisappear { work?.cancel(); work = nil }
        // A scanner temporarily covers this view. Keep its draft intact while
        // scanning; clear on explicit close/success, or release with the cover.
    }

    private func importPhrase(_ phrase: OathValidatedMnemonic) {
        guard work == nil else { return }
        let requestID = draft.importRequestID
        work = Task {
            defer { work = nil }
            do {
                let id = try await session.addWallet(requestID: requestID, importing: phrase)
                guard !Task.isCancelled, session.isUnlocked else { return }
                draft.clear()
                onImported(id)
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled, session.isUnlocked { failed = true } }
        }
    }
}

/// Entry points for onboarding and scanned additional wallets.
enum OathAdditionalWalletDestination: Identifiable {
    case createMultisig, importPhrase, importPrivateKey, customize(String)
    var id: String {
        switch self {
        case .createMultisig: "create-multisig"
        case .importPhrase: "import"
        case .importPrivateKey: "import-private-key"
        case .customize(let id): "customize-" + id
        }
    }
}

struct OathAdditionalWalletFlow: View {
    let session: OathWalletSession
    let start: OathAdditionalWalletDestination
    var scannedPhrase: OathValidatedMnemonic? = nil
    var scannedPrivateKey: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    private enum Route: Hashable { case privateKey(OathPrivateKeyChoice), customize(String) }
    @State private var path: [Route] = []

    var body: some View {
        if case .createMultisig = start {
            OathAdditionalMultisigFlow(session: session)
        } else {
            importFlow
        }
    }

    private var importFlow: some View {
        NavigationStack(path: $path) {
            Group {
                switch start {
                case .createMultisig: EmptyView()
                case .importPhrase:
                    OathAdditionalWalletImportPage(session: session, scannedPhrase: scannedPhrase) { id in path.append(.customize(id)) }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                OathCloseButton { dismiss() }
                                    .disabled(session.changingWallet)
                                    .accessibilityIdentifier("options.close")
                            }
                        }
                case .importPrivateKey:
                    OathChooseChainScreen { path.append(.privateKey($0)) }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                OathCloseButton { dismiss() }
                                    .accessibilityIdentifier("options.close")
                            }
                        }
                case .customize(let id): customize(id)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .customize(let id): customize(id)
                case .privateKey(let choice):
                    OathPrivateKeyImportScreen(choice: choice, isAllowed: session.isUnlocked, scannedKey: scannedPrivateKey) { key, requestID in
                        let id = try await session.addWallet(requestID: requestID, privateKey: key)
                        try Task.checkCancellation()
                        if session.isUnlocked { path.append(.customize(id)) }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: session.isUnlocked) { _, unlocked in
            // A vault commit can precede a background lock. Resume its existing
            // wallet after authentication instead of repeating the import.
            guard unlocked, let id = session.pendingCustomizationID, !path.contains(.customize(id)) else { return }
            switch start {
            case .importPhrase, .importPrivateKey: path.append(.customize(id))
            case .createMultisig, .customize: break
            }
        }
    }

    private func customize(_ id: String) -> some View {
        OathWalletCustomizationScreen(session: session, walletID: id, mode: .setup) { dismiss() }
            .oathWalletCustomizationNavigation()
            .navigationBarBackButtonHidden()
    }
}
