import OathDiagnostics
import SwiftUI
import OathNativeRefresh
import OathDatabase
import OathAnkr
import OathBrowser

struct OathStablecoinRestrictionNotice: View {
    let tokens: [StablecoinRestrictionToken]
    let onAcknowledge: () async throws -> Void
    @State private var acknowledging = false
    @State private var acknowledgementFailed = false
    @Environment(\.oathLocalizer) private var strings
    private var networks: [String] { Array(Set(tokens.map(\.network))).sorted() }
    var body: some View {
        OathContentSizedSheet(contentID: "stablecoin-restriction-notice") {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(OathOnboardingColors.blue)
                    .accessibilityHidden(true)
                Text(strings.text(.stablecoinRestrictionTitle)).oathFont(.title2, weight: .semibold)
                    .multilineTextAlignment(.center)
                Text(strings.text(.stablecoinRestrictionDetail)).oathFont(.body)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(networks, id: \.self) { network in
                            if let chain = OathImportChain(rawValue: network) {
                                HStack(spacing: 10) {
                                    OathNetworkLogo(asset: chain.logoAsset, size: 24)
                                    Text(strings.invariant(chain.name)).oathFont(.headline, weight: .medium)
                                    Spacer(minLength: 8)
                                    Text(strings.invariant(tokens.filter { $0.network == network }.map(\.symbol).sorted().joined(separator: ", ")))
                                        .oathFont(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(networks.count) * 36, 216))
                VStack(spacing: 12) {
                    Text(strings.text(.stablecoinRestrictionWarning)).oathFont(.footnote)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if acknowledgementFailed {
                        Text(strings.text(.preferencesSaveFailed)).oathFont(.footnote)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    OathActionButton(title: strings.text(.multisigGotIt), isWorking: acknowledging) {
                        guard !acknowledging else { return }
                        acknowledging = true; acknowledgementFailed = false
                        Task {
                            await OathDiagnostics.$operationID.withValue(UUID()) {
                                defer { acknowledging = false }
                                do { try await onAcknowledge() }
                                catch is CancellationError { /* Wallet change/lock is normal teardown. */ }
                                catch {
                                    OathDiagnostics.record(error, component: "stablecoin_security", operation: "acknowledge_notice")
                                    acknowledgementFailed = true
                                }
                            }
                        }
                    }.disabled(acknowledging)
                    .accessibilityIdentifier("stablecoinSecurity.gotIt")
                }
            }.padding(24).padding(.top, 16).fixedSize(horizontal: false, vertical: true)
        }
        .presentationBackground(Color(uiColor: OathSurfaceColors.groupedCanvas))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}

/// Public on-chain evidence only. This notice never requests or reads a key.
struct OathMultisigNotice: View {
    let evidence: [PublicMultisigEvidence]
    let onAcknowledge: () async throws -> Void
    @State private var acknowledging = false
    @State private var acknowledgementFailed = false
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathContentSizedSheet(contentID: "multisig-notice") {
            VStack(spacing: 24) {
                Image(systemName: "person.2.badge.key.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(OathOnboardingColors.blue)
                    .accessibilityHidden(true)
                Text(strings.text(.multisigNoticeTitle)).oathFont(.title2, weight: .semibold)
                    .multilineTextAlignment(.center)
                Text(strings.text(.multisigNoticeDetail)).oathFont(.body)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                ForEach(evidence.indices, id: \.self) { index in
                    let account = evidence[index].account
                    VStack(spacing: 8) {
                        if let chain = OathImportChain(rawValue: account.chain.rawValue) {
                            HStack(spacing: 8) {
                                OathNetworkLogo(asset: chain.logoAsset, size: 24)
                                Text(strings.invariant(chain.name)).oathFont(.headline, weight: .medium)
                            }
                        }
                        Text(account.address).oathFont(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                    }.frame(maxWidth: .infinity)
                }
                VStack(spacing: 12) {
                    Text(strings.text(.multisigFundingWarning)).oathFont(.footnote)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("multisig.fundingWarning")
                    if acknowledgementFailed {
                        Text(strings.text(.preferencesSaveFailed)).oathFont(.footnote)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    OathActionButton(title: strings.text(.multisigGotIt), isWorking: acknowledging) {
                        guard !acknowledging else { return }
                        acknowledging = true
                        acknowledgementFailed = false
                        Task {
                            await OathDiagnostics.$operationID.withValue(UUID()) {
                                defer { acknowledging = false }
                                do { try await onAcknowledge() }
                                catch is CancellationError { /* Lock/wallet changes dismiss without acknowledging. */ }
                                catch {
                                    OathDiagnostics.record(error, component: "multisig_notice", operation: "acknowledge")
                                    acknowledgementFailed = true
                                }
                            }
                        }
                    }
                    .disabled(acknowledging)
                    .accessibilityIdentifier("multisig.gotIt")
                }
            }.padding(24).padding(.top, 16).fixedSize(horizontal: false, vertical: true)
        }
        .presentationBackground(Color(uiColor: OathSurfaceColors.groupedCanvas))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}

struct OathWalletSheet<Content: View>: View {
    let title: OathStringKey
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathContentSizedSheet(contentID: title, navigation: .init(
            strings: strings, title: title, backIdentifier: "wallet.sheet.back",
            onBack: nil, onClose: { dismiss() }
        )) {
            content().oathFont(.body).padding(20).fixedSize(horizontal: false, vertical: true)
        }
        .presentationBackground(Color(uiColor: OathSurfaceColors.groupedCanvas))
    }
}

/// SwiftUI Text may hyphenate long addresses. Character wrapping must never
/// insert a visible character that is not actually part of the public address.
struct OathAddressText: UIViewRepresentable {
    let address: String
    var identifier = "receive.address"
    var centered = true
    var emphasizesEnds = false
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = centered ? .center : .left
        label.lineBreakMode = .byCharWrapping
        label.lineBreakStrategy = []
        label.adjustsFontForContentSizeCategory = true
        label.semanticContentAttribute = .forceLeftToRight
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.accessibilityIdentifier = identifier
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        let font = emphasizesEnds
            ? UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium),
                                                         compatibleWith: label.traitCollection)
            : UIFont.preferredFont(forTextStyle: .body, compatibleWith: label.traitCollection)
        label.font = font
        label.textColor = .label
        if emphasizesEnds {
            let text = NSMutableAttributedString(string: address, attributes: [
                .font: font, .foregroundColor: UIColor.label
            ])
            if address.count > 16 {
                let middle = address.index(address.startIndex, offsetBy: 8)..<address.index(address.endIndex, offsetBy: -8)
                text.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(middle, in: address))
            }
            label.attributedText = text
        } else {
            label.attributedText = nil
            label.text = address
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

struct OathWalletInfoSheet: View {
    let title: OathStringKey
    let icon: String
    let detail: OathStringKey
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWalletSheet(title: title) {
            VStack(spacing: 20) {
                Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
                Text(strings.text(detail)).oathFont(.body).multilineTextAlignment(.center)
            }.padding(.vertical)
        }
    }
}

struct OathWalletSettingsScreen: View {
    enum Destination: Identifiable {
        case app, security, sidebarSecurity, helpCenter, recentlyDeleted, wallet(String), customize(String), sidebar(OathWalletSidebarModel.WalletAction, String)

        var walletID: String? {
            switch self {
            case .app, .security, .sidebarSecurity, .helpCenter, .recentlyDeleted: nil
            case .wallet(let id), .customize(let id), .sidebar(_, let id): id
            }
        }

        var id: String {
            switch self {
            case .sidebarSecurity: "sidebarSecurity"
            case .recentlyDeleted: "recentlyDeleted"
            case .sidebar(let action, let id): "sidebar-\(action.rawValue)-\(id)"
            case .app: "app"
            case .security: "security"
            case .helpCenter: "helpCenter"
            case .wallet(let id): "wallet:\(id)"
            case .customize(let id): "customize:\(id)"
            }
        }
    }

    let session: OathWalletSession
    private let initialDestination: Destination
    @State private var didStartDestination = false
    private let rootRoute: Route
    private let dismissDisabled: Bool
    private let switcherPath: Binding<NavigationPath>?
    private let switcherRoot: ((@escaping (String) -> Void, @escaping () -> Void) -> AnyView)?
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var localPath: [Route] = []
    private var path: [Route] {
        get { localPath }
        nonmutating set {
            localPath = newValue
            // Settings always starts at the switcher root. Updating both paths
            // synchronously also handles authentication-driven pops/replacements.
            if let switcherPath { switcherPath.wrappedValue = NavigationPath(newValue) }
        }
    }
    @State private var cloudBackup = OathCloudBackupModel()
    @State private var allBackup = OathAllWalletBackupModel()
    @State private var cloudRestore = OathCloudRestoreModel()
    @State private var recovery: OathRecoveryPhraseModel?
    @State private var privateKeys: OathPrivateKeyModel?
    @State private var contactEditor: OathContactEditorModel?
    @State private var showsMultisigCreation = false
    @State private var newWalletRequest: UUID?
    @State private var creation: Task<Void, Never>?
    @State private var addingWalletID: String?
    @State private var creationFailed = false
    @State private var security: OathSecurityModel
    @State private var securityAccess: OathSecurityAccessModel
    @State private var reset: OathResetModel
    @State private var walletRemoval: OathWalletRemovalModel
    @State private var walletEditMode: EditMode = .inactive

    init(session: OathWalletSession, destination: Destination = .app,
         switcherPath: Binding<NavigationPath>? = nil, dismissDisabled: Bool = false,
         switcherRoot: ((@escaping (String) -> Void, @escaping () -> Void) -> AnyView)? = nil) {
        self.session = session
        self.dismissDisabled = dismissDisabled
        self.switcherPath = switcherPath
        self.switcherRoot = switcherRoot
        initialDestination = destination
        switch destination {
        case .app, .security: rootRoute = .settings
        case .sidebarSecurity: rootRoute = .security
        case .recentlyDeleted: rootRoute = .recentlyDeleted
        case .sidebar(.customize, let id): rootRoute = .customize(id)
        case .sidebar(.revealRecoveryPhrase, let id): rootRoute = .recoveryWarning(id)
        case .sidebar(.revealPrivateKey, let id): rootRoute = .importedPrivateKey(id)
        case .sidebar(_, let id): rootRoute = .wallet(id)
        case .helpCenter: rootRoute = .helpCenter
        case .wallet(let id): rootRoute = .wallet(id)
        case .customize(let id): rootRoute = .customize(id)
        }
        _security = State(initialValue: OathSecurityModel(session: session))
        if case .sidebarSecurity = destination {
            _securityAccess = State(initialValue: OathSecurityAccessModel(session: session,
                whenPasscodeDisabled: OathSecurityAccessModel.authenticateDeviceOwner))
        } else {
            _securityAccess = State(initialValue: OathSecurityAccessModel(session: session))
        }
        _reset = State(initialValue: OathResetModel(session: session))
        _walletRemoval = State(initialValue: OathWalletRemovalModel(session: session))
    }

    private var route: Route { path.last ?? rootRoute }
    private var requestsSecurityPIN: Bool {
        route == .securityAccess || (rootRoute == .security && route == .security && securityAccess.phase == .passcode)
    }

    private enum Route: Hashable {
        case settings, wallets, languages, preferences, wallet(String), customize(String), backupPassword(String), hiddenAssets(String), manageTokens(String)
        case importWallet, restoreWallet, restorePassword, chooseImportChain, importPrivateKey(OathPrivateKeyChoice)
        case recoveryWarning(String), recoveryPasscode(String), recoveryWords(String)
        case privateKeyTypes(String), privateKeyAddresses(String)
        case importedPrivateKey(String)
        case privateKeys(String), privateKeyPasscode(String), privateKeyWarning(String), privateKeyValue(String)
        case contacts, contact(String), contactEditor(String)
        case security, securityAccess, securityVerify, securityNewPasscode, securityDelay
        case currency, browser, searchEngine, appIcon, helpCenter
        case allBackup, allBackupPassword, about, permissions, walletConnect
        case resetPasscode, resetWarning, recentlyDeleted, walletRemovalPasscode
        case accountChains(String), accounts(String, HDAccountFamily)
        case passphraseIntroduction(String), passphraseEntry(String), seedPasswordEntry(String)

        var title: OathStringKey {
            switch self {
            case .settings: .walletSettings
            case .wallets: .wallets
            case .recentlyDeleted: .recentlyDeleted
            case .walletRemovalPasscode: .removeWallets
            case .importWallet: .importWallet
            case .chooseImportChain: .chooseChain
            case .importPrivateKey: .importPrivateKey
            case .restoreWallet, .restorePassword: .restoreICloud
            case .languages: .language
            case .preferences: .preferences
            case .accountChains: .chooseChain
            case .accounts(_, let family): family.accountsTitleKey
            case .wallet: .walletDetails
            case .hiddenAssets: .hiddenAssets
            case .manageTokens: .manageTokens
            case .customize: .customizeWallet
            case .backupPassword: .cloudBackupPasswordTitle
            case .recoveryWarning, .recoveryPasscode, .recoveryWords: .viewRecoveryPhrase
            case .privateKeys: .viewPrivateKeys
            case .privateKeyTypes: .bitcoinAddressType
            case .privateKeyAddresses: .privateKeyAddressesTitle
            case .importedPrivateKey, .privateKeyPasscode, .privateKeyWarning, .privateKeyValue: .viewPrivateKey
            case .contacts: .contacts
            case .contact: .contactDetails
            case .contactEditor: .editContact
            case .security, .securityAccess: .security
            case .securityVerify: .verifyCurrentPasscode
            case .securityNewPasscode: .changePasscode
            case .securityDelay: .requirePasscode
            case .currency: .currency
            case .browser: .browserTitle
            case .searchEngine: .browserSearchEngine
            case .appIcon: .appIcon
            case .helpCenter: .helpCenter
            case .allBackup: .backup
            case .allBackupPassword: .cloudBackupPasswordTitle
            case .about: .aboutOath
            case .permissions: .permissions
            case .walletConnect: .walletConnect
            case .resetPasscode, .resetWarning: .resetApp
            case .passphraseIntroduction, .passphraseEntry: .addPassphrase
            case .seedPasswordEntry: .addSeedPassword
            }
        }

        var walletID: String? {
            switch self {
            case .accountChains(let id), .accounts(let id, _), .wallet(let id), .customize(let id), .backupPassword(let id), .hiddenAssets(let id), .manageTokens(let id),
                 .passphraseIntroduction(let id), .passphraseEntry(let id), .seedPasswordEntry(let id),
                 .recoveryWarning(let id), .recoveryPasscode(let id), .recoveryWords(let id),
                 .importedPrivateKey(let id), .privateKeys(let id), .privateKeyTypes(let id), .privateKeyAddresses(let id),
                 .privateKeyPasscode(let id), .privateKeyWarning(let id), .privateKeyValue(let id): id
            default: nil
            }
        }

        var isCustomization: Bool {
            if case .customize = self { return true }
            return false
        }

        var isWalletSettings: Bool {
            if case .wallet = self { return true }
            return false
        }

        var canStartWalletRemoval: Bool {
            self == .wallets || self == .recentlyDeleted || isWalletSettings
        }

        var isSecurity: Bool {
            switch self {
            case .security, .securityAccess, .securityVerify, .securityNewPasscode, .securityDelay: true
            default: false
            }
        }

        var editsText: Bool {
            switch self {
            case .backupPassword, .allBackupPassword, .restorePassword, .customize, .passphraseEntry, .seedPasswordEntry: true
            default: false
            }
        }
    }

    @ViewBuilder private var navigationStack: some View {
        if let switcherPath, let switcherRoot {
            // One native stack owns both the switcher and every settings page.
            // Keep the typed settings suffix in sync with native Back/swipe pops;
            // the switcher's import and restore routes remain in this same path.
            NavigationStack(path: Binding(
                get: { switcherPath.wrappedValue },
                set: { updated in
                    switcherPath.wrappedValue = updated
                    if updated.count < path.count {
                        localPath.removeLast(localPath.count - updated.count)
                    }
                }
            )) {
                switcherRoot({ path.append(.wallet($0)) }, { path.append(.recentlyDeleted) })
                    .navigationDestination(for: Route.self) { page($0) }
            }
        } else {
            NavigationStack(path: Binding(get: { path }, set: { path = $0 })) {
                page(rootRoute)
                    .navigationDestination(for: Route.self) { page($0) }
            }
        }
    }

    private var navigationContent: some View {
        // Each destination has its own retained screen. The system owns push,
        // pop, interactive back, keyboard avoidance and Reduce Motion behavior.
        navigationStack
        .walletRefreshNavigation()
        .task {
            guard !didStartDestination, session.isUnlocked else { return }
            didStartDestination = true
            switch initialDestination {
            case .security, .sidebarSecurity:
                securityAccess.begin(reason: strings.text(.securityAuthenticationReason))
            case .sidebar(let action, let id):
                guard let wallet = session.wallets.first(where: { $0.id == id }) else { dismiss(); return }
                switch action {
                case .revealRecoveryPhrase:
                    guard !session.changingWallet, wallet.kind != "privateKey", wallet.kind != "watchOnly" else {
                        dismiss()
                        return
                    }
                    recovery = OathRecoveryPhraseModel(walletID: id, reader: session.vault)
                case .revealPrivateKey:
                    guard wallet.kind == "privateKey" else { dismiss(); return }
                    startPrivateKeys(walletID: id)
                case .customize, .settings: break
                }
            default: break
            }
        }
        .fullScreenCover(isPresented: $showsMultisigCreation) {
            OathAdditionalMultisigFlow(session: session).oathLanguage(strings.language)
        }
        .oathLanguage(strings.language)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .task(id: path.contains(.allBackup) ? allBackup.observationID : nil) {
            guard path.contains(.allBackup) else { return }
            await allBackup.observe()
        }
        // Both wallet details and its password page observe the same backup.
        // Moving between them must not destroy the job or its progress state.
        .task(id: route.walletID) {
            guard let id = route.walletID else { cloudBackup.cancelPreparation(); return }
            await cloudBackup.observe(walletID: id)
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if unlocked {
                if route == .restoreWallet { cloudRestore.start() }
                if switcherRoot == nil, let id = session.pendingCustomizationID, route.walletID == nil, !showsMultisigCreation {
                    showAddedWallet(id)
                }
                return
            }
            cloudBackup.cancelPreparation()
            allBackup.cancelPreparation()
            cloudRestore.stop()
            if route == .restorePassword { path.removeLast() }
            security.cancel()
            securityAccess.cancel()
            reset.cancel()
            walletRemoval.cancel()
            recovery?.cancelAuthentication()
            privateKeys?.cancelAuthentication()
            // A completed vault creation retains its customization destination
            // under the lock. Ordinary Settings editors keep their old behavior.
            if route.editsText && route.walletID != addingWalletID {
                if path.isEmpty { dismiss() }
                else { path.removeLast() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Face ID can temporarily make the scene inactive. Only a real
            // background transition cancels its pending authentication.
            if phase == .background {
                allBackup.cancelPreparation()
                if route == .allBackupPassword { path.removeLast() }
                cloudRestore.stop()
                if route == .restorePassword { path.removeLast() }
                security.cancel()
                securityAccess.cancel()
                reset.cancel()
                walletRemoval.cancel()
                recovery?.cancelAuthentication()
                privateKeys?.cancelAuthentication()
            } else if phase == .active, route == .restoreWallet, session.isUnlocked {
                cloudRestore.start()
            }
        }
        .onChange(of: securityAccess.phase) { _, phase in
            switch phase {
            case .authorized:
                guard session.isUnlocked else { return }
                if route == .securityAccess { path[path.count - 1] = .security }
                else if route == .settings { path.append(.security) }
            case .passcode:
                if route == .settings { path.append(.securityAccess) }
            case .idle:
                if rootRoute == .security, securityAccess.notice == nil { dismiss(); return }
                if let index = path.firstIndex(where: \.isSecurity) { path = Array(path.prefix(index)) }
            case .authenticating: break
            }
        }
        .onChange(of: security.phase) { _, phase in
            switch phase {
            case .verify:
                if route == .security { path.append(.securityVerify) }
            case .newPasscode:
                if route == .security || route == .securityVerify { path.append(.securityNewPasscode) }
            case .idle:
                if let index = path.firstIndex(of: .security), route == .securityVerify || route == .securityNewPasscode {
                    path = Array(path.prefix(through: index))
                }
            }
        }
        .onChange(of: reset.phase) { _, phase in
            switch phase {
            case .passcode:
                if route == .settings { path.append(.resetPasscode) }
            case .warning:
                if route == .settings || route == .resetPasscode { path.append(.resetWarning) }
            case .idle:
                if let index = path.firstIndex(where: { $0 == .resetPasscode || $0 == .resetWarning }) {
                    path = Array(path.prefix(index))
                }
            case .authenticating: break
            }
        }
        .onChange(of: walletRemoval.phase) { _, phase in
            if phase == .passcode, route.canStartWalletRemoval {
                path.append(.walletRemovalPasscode)
            } else if phase == .idle, route == .walletRemovalPasscode {
                path.removeLast()
            }
        }
        .onChange(of: route) { old, route in
            if !route.isSecurity && (old.isSecurity || route != .settings) { securityAccess.cancel() }
            if old == .walletRemovalPasscode, route != .walletRemovalPasscode {
                walletRemoval.cancel(preserveNotice: true)
            } else if route != .walletRemovalPasscode && (old.isWalletSettings || !route.canStartWalletRemoval) {
                walletRemoval.cancel()
                walletEditMode = .inactive
            }
            if route == .resetPasscode, reset.phase == .warning { reset.cancel() }
            else if route != .resetPasscode && route != .resetWarning && route != .settings { reset.cancel() }
            switch route {
            case .securityVerify:
                if security.phase == .newPasscode { security.returnToVerification() }
            case .securityNewPasscode: break
            default: security.cancel()
            }
        }
        .onChange(of: recovery?.phase) { _, phase in
            guard let recovery else { return }
            let id = recovery.walletID
            if phase == .warning {
                // The warning can be the modal root or a pushed Settings page.
                if let index = path.firstIndex(where: { $0 == .recoveryPasscode(id) || $0 == .recoveryWords(id) }) {
                    path.removeSubrange(index...)
                }
                return
            }
            guard session.isUnlocked else { return }
            switch (route, phase) {
            case (.recoveryWarning(let current), .passcode) where current == id:
                path.append(.recoveryPasscode(id))
            case (.recoveryWarning(let current), .revealed) where current == id,
                 (.recoveryPasscode(let current), .revealed) where current == id:
                path.append(.recoveryWords(id))
            default: break
            }
        }
        .onChange(of: privateKeys?.phase) { _, phase in
            guard let privateKeys else { return }
            let id = privateKeys.walletID
            // The imported-key flow changes authentication/warning states in
            // one page. It must not push the HD browser behind the sidebar sheet.
            guard route != .importedPrivateKey(id) else { return }
            if phase == .chains {
                // Authentication may start from the network or type picker
                // when redundant choices were skipped. Pop to an actual page.
                if let index = path.lastIndex(where: {
                    $0 == .privateKeys(id) || (privateKeys.browserAccount != nil &&
                        ($0 == .privateKeyTypes(id) || $0 == .privateKeyAddresses(id)))
                }), index < path.count - 1 {
                    path.removeSubrange((index + 1)...)
                }
                return
            }
            guard session.isUnlocked else { return }
            switch (route, phase) {
            case (.privateKeys(let current), .passcode) where current == id,
                 (.privateKeyTypes(let current), .passcode) where current == id,
                 (.privateKeyAddresses(let current), .passcode) where current == id:
                path.append(.privateKeyPasscode(id))
            case (.privateKeys(let current), .warning) where current == id,
                 (.privateKeyTypes(let current), .warning) where current == id,
                 (.privateKeyAddresses(let current), .warning) where current == id,
                 (.privateKeyPasscode(let current), .warning) where current == id:
                path.append(.privateKeyWarning(id))
            case (.privateKeyWarning(let current), .revealed) where current == id:
                path.append(.privateKeyValue(id))
            default: break
            }
        }
        .onChange(of: path) { _, _ in
            OathHaptics.shared.play(.navigate)
            if !path.contains(.allBackup) { allBackup.cancelPreparation() }
            if !path.contains(.restoreWallet) { cloudRestore.stop() }
            else if route == .restoreWallet, cloudRestore.selected != nil { cloudRestore.backToList() }
            updateRecoveryNavigation()
            updatePrivateKeyNavigation()
            if let contactEditor, !path.contains(.contactEditor(contactEditor.id)) { self.contactEditor = nil }
            if route == .settings, reset.phase != .authenticating { reset.cancel(preserveNotice: true) }
        }
        .onDisappear {
            creation?.cancel()
            creation = nil
            cloudBackup.cancelPreparation()
            allBackup.cancelPreparation()
            cloudRestore.stop()
            recovery?.returnToWarning()
            recovery = nil
            privateKeys?.returnToChains()
            privateKeys = nil
            contactEditor = nil
            security.cancel()
            securityAccess.cancel()
            reset.cancel()
            walletRemoval.cancel()
        }
        .onChange(of: cloudRestore.selected?.id) { _, selected in
            if selected == nil, route == .restorePassword { path.removeLast() }
        }
    }

    private var feedbackContent: some View {
        navigationContent
        .oathErrorFeedback(privateKeys?.notice)
        .oathErrorFeedback(recovery?.notice)
        .oathErrorFeedback(securityAccess.notice)
        .oathErrorFeedback(security.notice)
        .oathErrorFeedback(reset.notice)
        .oathErrorFeedback(walletRemoval.notice)
        .oathHapticFeedback(.success, trigger: privateKeys?.phase, when: privateKeys?.phase == .revealed)
        .oathHapticFeedback(.success, trigger: recovery?.phase, when: recovery?.phase == .revealed)
    }

    private var securityAlerts: some View {
        feedbackContent
        .alert(strings.text(.security), isPresented: Binding(
            get: { securityAccess.notice != nil && !requestsSecurityPIN },
            set: { if !$0 && !requestsSecurityPIN { securityAccess.notice = nil } }
        )) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) { securityAccess.notice = nil }
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) { securityAccess.notice = nil }
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            if let notice = securityAccess.notice { Text(strings.text(notice)) }
        }
    }

    private var resetAlerts: some View {
        securityAlerts
        .alert(strings.text(.resetApp), isPresented: Binding(
            get: { reset.notice != nil && route != .resetPasscode },
            set: { if !$0 { reset.notice = nil } }
        )) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) { reset.notice = nil }
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) { reset.notice = nil }
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            if let notice = reset.notice { Text(strings.text(notice)) }
        }
    }

    private var removalAlerts: some View {
        resetAlerts
        .alert(strings.text(removalConfirmationTitle), isPresented: Binding(
            get: { (walletRemoval.phase == .confirmation || walletRemoval.phase == .recentlyDeletedConfirmation) && !walletRemoval.confirming },
            set: { _ in } // The explicit buttons consume or revoke the authorization.
        )) {
            OathButton(strings.text(removalConfirmationButton), role: .destructive) {
                if walletRemoval.phase == .recentlyDeletedConfirmation {
                    walletRemoval.confirmRecentlyDeleted()
                } else {
                    walletRemoval.confirm(onRemoved: walletRemovalCompleted)
                }
            }
            OathButton(strings.text(.cancel), role: .cancel) { walletRemoval.cancel() }
        } message: {
            Text(removalConfirmationDetail)
        }
        .alert(strings.text(.removeWallets), isPresented: Binding(
            get: { walletRemoval.notice != nil && route != .walletRemovalPasscode },
            set: { if !$0 { walletRemoval.notice = nil } }
        )) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) { walletRemoval.notice = nil }
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) { walletRemoval.notice = nil }
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            if let notice = walletRemoval.notice { Text(strings.text(notice)) }
        }
    }

    private var removalConfirmationTitle: OathStringKey {
        if walletRemoval.phase == .recentlyDeletedConfirmation { return .recentlyDeleted }
        if walletRemoval.action?.resetsApp == true { return .resetWarningTitle }
        return walletRemoval.action?.permanently == true ? .walletPermanentRemovalTitle : .walletRemovalTitle
    }

    private var removalConfirmationButton: OathStringKey {
        if walletRemoval.phase == .recentlyDeletedConfirmation { return .deleteWalletsPermanently }
        if walletRemoval.action?.resetsApp == true { return .resetConfirm }
        return walletRemoval.action?.permanently == true ? .deleteWalletsPermanently : .moveToRecentlyDeleted
    }

    private var removalConfirmationDetail: String {
        if walletRemoval.phase == .recentlyDeletedConfirmation {
            return strings.text(.walletPermanentRemovalDetail)
        }
        if walletRemoval.action?.resetsApp == true {
            return strings.text(.resetWalletsDetail) + "\n\n" + strings.text(.resetDataDetail)
        }
        return strings.text(walletRemoval.action?.permanently == true ? .walletPermanentRemovalDetail : .walletRemovalDetail)
    }

    var body: some View {
        removalAlerts
        .interactiveDismissDisabled(dismissDisabled || walletRemoval.confirming || reset.confirming || cloudRestore.phase == .saving)
        .oathHapticFeedback(.error, trigger: creationFailed, when: creationFailed)
        .alert(strings.text(.walletChangeFailed), isPresented: $creationFailed) {
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
        } message: { Text(strings.text(.walletChangeFailedDetail)) }
    }

    private func walletRemovalCompleted(_ action: OathWalletRemovalAction) {
        if let id = rootRoute.walletID, action.ids.contains(id) {
            dismiss()
        } else if let index = path.firstIndex(where: {
            $0.walletID.map { action.ids.contains($0) } == true
        }) {
            // Drop both the deleted wallet's page and any passcode destination,
            // returning to the Wallets list that opened it.
            path = Array(path.prefix(index))
        }
    }

    private var securityPasscodePage: some View {
        OathSecretPasscodePage(session: session, busy: securityAccess.busy,
            notice: Binding(get: { securityAccess.notice }, set: { securityAccess.notice = $0 }),
            title: .security, identifier: "security.access", onSubmit: securityAccess.submit)
    }

    private func page(_ destination: Route) -> some View {
        Group {
            if destination == .security, rootRoute == .security, !securityAccess.isAuthorized {
                // The shortcut owns a single protected root. Do not present the
                // settings list or create a back path through the passcode prompt.
                if securityAccess.phase == .passcode {
                    securityPasscodePage
                } else if securityAccess.phase == .authenticating || !didStartDestination {
                    ProgressView()
                } else {
                    Button(strings.text(.tryAgain)) { securityAccess.begin(reason: strings.text(.securityAuthenticationReason)) }
                }
            } else if destination.isSecurity && destination != .securityAccess && !securityAccess.isAuthorized {
                // Revoke the contents immediately, before the navigation pop
                // completes after a background/lock transition.
                Color.clear
            } else if destination == .securityAccess {
                securityPasscodePage
            } else if destination == .wallets {
                OathWalletManagementPage(session: session, removal: walletRemoval, editMode: $walletEditMode,
                    onWallet: { path.append(.wallet($0)) }, onRecentlyDeleted: { path.append(.recentlyDeleted) }) {
                    OathWalletActions(identifier: "settings.wallets",
                        onCreate: createWallet, onCreateMultisig: { showsMultisigCreation = true }, onImport: { path.append(.importWallet) },
                        onImportPrivateKey: { path.append(.chooseImportChain) },
                        onRestore: { path.append(.restoreWallet) })
                }
                .disabled(creation != nil)
                .navigationBarBackButtonHidden(creation != nil || walletRemoval.confirming)
            } else if destination == .allBackup {
                OathAllWalletBackupPage(session: session, model: allBackup) { path.append(.allBackupPassword) }
            } else if destination == .recentlyDeleted {
                OathRecentlyDeletedWalletsPage(session: session, removal: walletRemoval)
                    .navigationBarBackButtonHidden(walletRemoval.confirming || session.changingWallet)
            } else if destination == .about {
                // About owns its viewport so its native bottom bar is anchored
                // to the screen, not to the generic settings scroll content.
                OathAboutPage()
            } else if destination == .walletRemovalPasscode {
                OathSecretPasscodePage(session: session, busy: walletRemoval.busy || walletRemoval.confirming,
                    notice: Binding(get: { walletRemoval.notice }, set: { walletRemoval.notice = $0 }),
                    title: .removeWallets, identifier: "wallets.remove.passcode", onSubmit: walletRemoval.submit)
                    .navigationBarBackButtonHidden(walletRemoval.confirming)
            } else if destination == .restorePassword {
                ScrollView {
                    OathCloudRestorePasswordPage(model: cloudRestore) { restored in
                        try await session.restoreWallet(restored)
                        try Task.checkCancellation()
                        dismiss()
                    }
                    .frame(maxWidth: 700).frame(maxWidth: .infinity)
                }
                .navigationBarBackButtonHidden(cloudRestore.phase == .saving)
            } else if case .accountChains(let id) = destination {
                OathChooseChainScreen(allowedNetworks: OathImportChain.enabledCases.filter { $0.hdAccountFamily != nil },
                                      accessibilityPrefix: "walletAccounts") { choice in
                    guard session.isUnlocked, !session.changingWallet, route == destination,
                          let family = choice.networks.first?.hdAccountFamily else { return }
                    path.append(.accounts(id, family))
                }
            } else if case .accounts(let id, let family) = destination {
                OathHDAccountsPage(session: session, walletID: id, family: family)
            } else if case .passphraseIntroduction(let id) = destination {
                OathPassphraseIntroductionPage(walletName: session.walletName(session.wallets.first { $0.id == id }, strings: strings)) {
                    guard session.isUnlocked, !session.changingWallet else { return }
                    path.append(.passphraseEntry(id))
                }
            } else if case .passphraseEntry(let id) = destination {
                OathPassphraseWalletPage(session: session, sourceID: id,
                    onCreated: showAddedWallet, onOpenExisting: openPassphraseWallet)
            } else if case .seedPasswordEntry(let id) = destination {
                OathPassphraseWalletPage(session: session, sourceID: id, usesSeedPassword: true,
                    onCreated: showAddedWallet, onOpenExisting: openPassphraseWallet)
            } else if destination == .resetWarning {
                OathResetWarningPage(session: session, model: reset)
            } else if destination == .resetPasscode {
                OathSecretPasscodePage(session: session, busy: reset.busy,
                    notice: Binding(get: { reset.notice }, set: { reset.notice = $0 }),
                    title: .resetApp, identifier: "reset.passcode", onSubmit: reset.submit)
            } else if destination == .permissions {
                OathPermissionsPage(session:session)
            } else if destination == .walletConnect {
                OathWalletConnectPage(session: session)
            } else if case .hiddenAssets(let id) = destination {
                OathHiddenAssetsPage(session: session, walletID: id)
            } else if case .manageTokens(let id) = destination {
                OathManageTokensScreen(session: session, walletID: id, currency: settings.currency)
            } else if destination == .currency {
                OathCurrencyPage()
            } else if destination == .helpCenter {
                OathHelpCenterPage()
            } else if destination == .appIcon {
                OathAppIconPage()
                    .toolbarBackground(Color.clear, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
            } else if destination == .security {
                OathSecurityPage(session: session, model: security, onLockDelay: { path.append(.securityDelay) })
            } else if destination == .securityDelay {
                OathLockDelayPage()
            } else if destination == .securityVerify {
                OathSecretPasscodePage(session: session, busy: security.busy,
                    notice: Binding(get: { security.notice }, set: { security.notice = $0 }),
                    title: .verifyCurrentPasscode, identifier: "security.verify") {
                    security.verify($0, strings: strings)
                }
            } else if destination == .securityNewPasscode {
                OathPasscodeSetupScreen(
                    store: OathSecurityPasscodeStore(session: session, authorization: security.authorization),
                    biometrics: OathSecurityBiometrics(session: session, shouldEnroll: security.enrollBiometricsAfterPasscode),
                    onComplete: security.completed)
            } else if destination == .languages {
                OathLanguageSettingsPage(configuration: languageConfiguration)
            } else if case .customize(let id) = destination {
                OathWalletCustomizationScreen(session: session, walletID: id,
                                              mode: customizationMode(for: id)) {
                    if addingWalletID == id || destination == rootRoute { dismiss() }
                    else { pop(.customize(id)) }
                }
                .navigationBarBackButtonHidden(addingWalletID == id)
            } else if destination == .importWallet {
                OathAdditionalWalletImportPage(session: session, onImported: showAddedWallet)
            } else if destination == .chooseImportChain {
                OathChooseChainScreen { path.append(.importPrivateKey($0)) }
            } else if case .importPrivateKey(let choice) = destination {
                OathPrivateKeyImportScreen(choice: choice, isAllowed: session.isUnlocked) { key, requestID in
                    let id = try await session.addWallet(requestID: requestID, privateKey: key)
                    try Task.checkCancellation()
                    showAddedWallet(id)
                }
            } else if destination == .contacts {
                OathContactsPage(onAdd: { editContact(nil) }, onSelect: { path.append(.contact($0)) })
            } else if case .contact(let id) = destination {
                OathContactDetailPage(id: id, session: session,
                    onEdit: { editContact($0) }, onDeleted: { pop(.contact(id)) })
            } else if case .contactEditor(let id) = destination, let contactEditor, contactEditor.id == id {
                OathContactEditorPage(model: contactEditor, isAllowed: session.isUnlocked,
                    onSaved: {
                        guard route == .contactEditor(id) else { return }
                        let isNew = contactEditor.revision == nil
                        path.removeLast()
                        if isNew { path.append(.contact(id)) }
                    })
            } else if case .recoveryWarning(let id) = destination, let recovery, recovery.walletID == id {
                OathRecoveryWarningPage(model: recovery, session: session)
            } else if case .recoveryPasscode(let id) = destination, let recovery, recovery.walletID == id {
                OathRecoveryPasscodePage(model: recovery, session: session)
            } else if case .recoveryWords(let id) = destination, let recovery, recovery.walletID == id {
                OathRecoveryWordsPage(model: recovery, session: session)
            } else if case .importedPrivateKey(let id) = destination, let privateKeys, privateKeys.walletID == id {
                OathDirectPrivateKeyPage(model: privateKeys, session: session)
            } else if case .privateKeys(let id) = destination, let privateKeys, privateKeys.walletID == id {
                OathPrivateKeyChainsPage(model: privateKeys, session: session) { next in
                    guard route == .privateKeys(id) else { return }
                    continuePrivateKeyBrowser(next, model: privateKeys)
                }
            } else if case .privateKeyTypes(let id) = destination, let privateKeys, privateKeys.walletID == id {
                OathPrivateKeyTypesPage(model: privateKeys, session: session) { next in
                    guard route == .privateKeyTypes(id) else { return }
                    continuePrivateKeyBrowser(next, model: privateKeys)
                }
            } else if case .privateKeyAddresses(let id) = destination, let privateKeys, privateKeys.walletID == id {
                OathPrivateKeyAddressesPage(model: privateKeys, session: session)
            } else if case .privateKeyPasscode(let id) = destination, let privateKeys, privateKeys.walletID == id {
                OathSecretPasscodePage(session: session, busy: privateKeys.busy,
                    notice: Binding(get: { privateKeys.notice }, set: { privateKeys.notice = $0 }),
                    title: .viewPrivateKey, identifier: "privateKey.passcode", onSubmit: privateKeys.submit)
            } else if case .privateKeyWarning(let id) = destination, let privateKeys, privateKeys.walletID == id {
                OathPrivateKeyWarningPage(model: privateKeys, session: session)
            } else if case .privateKeyValue(let id) = destination, let privateKeys, privateKeys.walletID == id {
                OathPrivateKeyValuePage(model: privateKeys, session: session)
            } else {
                OathEmptyStateScrollView(centersContent:
                    destination == .restoreWallet && (cloudRestore.entries.isEmpty || cloudRestore.notice != nil)
                    ) {
                    content(for: destination)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 700, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("settings.scrollContent")
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(contactPageTitle(destination)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            // The selected root dismisses its sheet or full-screen presentation.
            // Every pushed destination uses the NavigationStack's native Back.
            if destination == .wallets {
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        if walletEditMode.isEditing {
                            OathDoneButton {
                                guard scenePhase != .background, !walletRemoval.busy else { return }
                                withAnimation { walletEditMode = .inactive }
                            }
                        } else {
                            OathButton(strings.text(.editWallets)) {
                                guard scenePhase != .background, !walletRemoval.busy else { return }
                                withAnimation { walletEditMode = .active }
                            }
                            .oathNeutralControl()
                        }
                    }
                    .disabled(!session.isUnlocked || session.changingWallet || creation != nil || walletRemoval.confirming)
                    .oathInteractionBlocked(walletRemoval.busy)
                    .accessibilityIdentifier("wallets.edit")
                }
            }
            if destination == rootRoute {
                ToolbarItem(placement: .topBarLeading) {
                    OathCloseButton {
                        guard scenePhase != .background, !security.busy else { return }
                        dismiss()
                    }
                    .disabled(session.changingWallet || contactEditor?.saving == true || reset.confirming)
                    .disabled(walletRemoval.confirming)
                    .oathInteractionBlocked(security.busy || walletRemoval.busy)
                    .accessibilityLabel(strings.text(.close))
                    .accessibilityIdentifier("options.close")
                }
                if destination == .settings, session.security.passcodeEnabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        OathButton {
                            guard scenePhase != .background, !security.busy, !reset.busy else { return }
                            Task { await session.lock() }
                        } label: {
                            Image(systemName: "lock")
                        }
                        .oathNeutralControl()
                        .disabled(!session.isUnlocked || session.changingWallet || reset.confirming)
                        .oathInteractionBlocked(security.busy || reset.busy)
                        .accessibilityLabel(strings.text(.lockWallet))
                        .accessibilityIdentifier("settings.lock")
                    }
                }
            }
        }
        // Configure the native Back item; never replace it with a custom button
        // (which would disable the system's interactive back gesture).
        .oathNativeLocalization(onArtwork: destination == .appIcon,
            // A visible, clear bar honors the dark scheme while showing the artwork underneath.
            navigationBackground: destination == .appIcon ? .visible : .automatic,
            navigationMaterial: destination == .appIcon ? nil : .regular)
        // Keep this destination dark from its first frame without changing the
        // enclosing presentation, saved appearance, or adjacent settings pages.
        .environment(\.colorScheme, destination == .appIcon ? .dark : colorScheme)
    }

    @ViewBuilder private func content(for destination: Route) -> some View {
        switch destination {
        case .settings: settingsContent
        case .allBackup: EmptyView() // Owns its scroll view and native bottom actions in page(_:).
        case .allBackupPassword:
            OathBackupPasswordForm { password in
                guard session.isUnlocked, !session.changingWallet, route == .allBackupPassword else { return }
                allBackup.create(walletIDs: session.wallets.map(\.id), password: password, vault: session.vault)
                pop(.allBackupPassword)
            }
            .padding(20)
        case .about: EmptyView()
        case .permissions: EmptyView()
        case .wallets, .recentlyDeleted, .walletRemovalPasscode, .walletConnect, .helpCenter: EmptyView()
        case .restoreWallet:
            OathCloudRestoreList(model: cloudRestore) { entry in
                cloudRestore.choose(entry)
                if cloudRestore.selected != nil { path.append(.restorePassword) }
            }
            .onAppear { if session.isUnlocked { cloudRestore.start() } }
        case .preferences: preferencesContent
        case .browser:
            VStack(spacing: 0) {
                settingsButton(.browserSearchEngine, icon: "magnifyingglass", value: settings.browserSearchEngine.name) {
                    path.append(.searchEngine)
                }
                .accessibilityIdentifier("settings.searchEngine")
                Toggle(isOn: Binding(get: { settings.browserShowsRecentSites }, set: settings.setBrowserShowsRecentSites)) {
                    OathSettingsRow(title: strings.text(.browserShowRecentSites), icon: "clock", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("settings.browser.showRecentSites")
            }
        case .searchEngine:
            VStack(spacing: 0) {
                ForEach(BrowserSearchEngine.allCases, id: \.self) { engine in
                    OathButton(feedback: .selection) { settings.selectBrowserSearchEngine(engine) } label: {
                        OathSettingsRow(title: engine.name, accessory: .selection(settings.browserSearchEngine == engine))
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityAddTraits(settings.browserSearchEngine == engine ? .isSelected : [])
                    .accessibilityIdentifier("settings.searchEngine.\(engine.rawValue)")
                }
            }
        case .wallet(let id):
            OathWalletNameSettings(session: session, walletID: id, cloudBackup: cloudBackup,
                onCustomize: { path.append(.customize(id)) },
                onHiddenAssets: { path.append(.hiddenAssets(id)) },
                onManageTokens: { path.append(.manageTokens(id)) },
                onBackupPassword: { path.append(.backupPassword(id)) },
                onRecovery: { startRecovery(walletID: id) },
                onPrivateKeys: { startPrivateKeys(walletID: id) },
                onAccounts: { path.append(.accountChains(id)) },
                onAddPassphrase: { path.append(.passphraseIntroduction(id)) },
                onAddSeedPassword: { path.append(.seedPasswordEntry(id)) },
                onDelete: {
                    guard scenePhase != .background, route == .wallet(id) else { return }
                    let retainInTrash: Bool
                    if case .sidebar = initialDestination { retainInTrash = true } else { retainInTrash = false }
                    walletRemoval.begin(.init(ids: [id], permanently: false, recentlyDeletedOnly: retainInTrash),
                        reason: strings.text(.walletRemovalAuthentication))
                })
                .disabled(walletRemoval.confirming)
                .oathInteractionBlocked(walletRemoval.busy)
                .navigationBarBackButtonHidden(walletRemoval.confirming)
        case .backupPassword(let id):
            OathBackupPasswordForm { password in
                guard session.isUnlocked, !session.changingWallet, route == .backupPassword(id) else { return }
                cloudBackup.create(walletID: id, password: password, vault: session.vault)
                pop(.backupPassword(id))
            }
            .padding(20)
        case .languages, .customize, .hiddenAssets, .manageTokens, .importWallet, .chooseImportChain, .importPrivateKey, .recoveryWarning, .recoveryPasscode, .recoveryWords,
             .importedPrivateKey, .privateKeys, .privateKeyTypes, .privateKeyAddresses, .privateKeyPasscode, .privateKeyWarning, .privateKeyValue,
             .contacts, .contact, .contactEditor,
             .security, .securityAccess, .securityVerify, .securityNewPasscode, .securityDelay, .currency, .appIcon,
             .resetPasscode, .resetWarning, .accountChains, .accounts, .passphraseIntroduction, .passphraseEntry, .seedPasswordEntry, .restorePassword: EmptyView()
        }
    }

    private func editContact(_ snapshot: ContactSnapshot?) {
        guard session.isUnlocked else { return }
        let editor = OathContactEditorModel(snapshot: snapshot)
        contactEditor = editor
        path.append(.contactEditor(editor.id))
    }

    private func contactPageTitle(_ destination: Route) -> OathStringKey {
        if destination == .securityNewPasscode, !session.security.passcodeEnabled { return .passcode }
        if case .contactEditor(let id) = destination, contactEditor?.id == id, contactEditor?.revision == nil { return .addContact }
        switch destination {
        case .recoveryWarning(let id), .recoveryPasscode(let id), .recoveryWords(let id):
            if ["bitcoinMultisig", "litecoinMultisig", "bitcoinCashMultisig", "dogecoinMultisig", "evmMultisig", "tronMultisig", "solanaMultisig", "xrplMultisig", "stellarMultisig", "aptosMultisig", "tonMultisig", "thorchainMultisig", "nearMultisig", "suiMultisig"].contains(session.wallets.first(where: { $0.id == id })?.kind ?? "") { return .multisigRecovery }
        default: break
        }
        return destination.title
    }

    private func showAddedWallet(_ id: String) {
        guard session.isUnlocked else { return }
        addingWalletID = id
        if path.last != .customize(id) { path.append(.customize(id)) }
    }

    private func openPassphraseWallet(_ id: UUID) {
        guard creation == nil, session.isUnlocked, !session.changingWallet else { return }
        creation = Task {
            defer { creation = nil }
            do {
                try await session.selectWallet(id)
                guard !Task.isCancelled, session.isUnlocked else { return }
                if session.wallets.first(where: { $0.id == id.uuidString })?.needsCustomization == true {
                    showAddedWallet(id.uuidString)
                } else { path = [.wallets, .wallet(id.uuidString)] }
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled { creationFailed = true } }
        }
    }

    private func createWallet() {
        guard creation == nil, session.isUnlocked, !session.changingWallet, route == .wallets else { return }
        let request = UUID()
        newWalletRequest = request
        showAddedWallet(request.uuidString)
    }

    private func customizationMode(for id: String) -> OathWalletCustomizationScreen.Mode {
        if let newWalletRequest, newWalletRequest.uuidString == id, addingWalletID == id {
            return .create(newWalletRequest)
        }
        return addingWalletID == id ? .setup : .edit
    }

    private func startRecovery(walletID: String) {
        guard session.isUnlocked, !session.changingWallet,
              session.wallets.contains(where: { $0.id == walletID }) else { return }
        recovery?.returnToWarning()
        recovery = OathRecoveryPhraseModel(walletID: walletID, reader: session.vault)
        path.append(.recoveryWarning(walletID))
    }

    private func updateRecoveryNavigation() {
        guard let recovery else { return }
        let id = recovery.walletID
        switch route {
        case .recoveryWarning(let current) where current == id: recovery.returnToWarning()
        case .recoveryPasscode(let current) where current == id: recovery.returnToPasscode()
        case .recoveryWords(let current) where current == id: break
        default:
            recovery.returnToWarning()
            self.recovery = nil
        }
    }

    private func startPrivateKeys(walletID: String) {
        guard session.isUnlocked, !session.changingWallet,
              session.wallets.contains(where: { $0.id == walletID }) else { return }
        privateKeys?.returnToChains()
        privateKeys = OathPrivateKeyModel(walletID: walletID, reader: session.vault)
        let destination: Route = session.wallets.first(where: { $0.id == walletID })?.kind == "privateKey"
            ? .importedPrivateKey(walletID) : .privateKeys(walletID)
        if route != destination { path.append(destination) }
    }

    private func continuePrivateKeyBrowser(_ next: OathPrivateKeyModel.BrowserDestination, model: OathPrivateKeyModel) {
        guard session.isUnlocked, !session.changingWallet, scenePhase != .background else { return }
        switch next {
        case .types: path.append(.privateKeyTypes(model.walletID))
        case .addresses: path.append(.privateKeyAddresses(model.walletID))
        case .singleAddress(let account):
            model.select(account, reason: strings.format(.privateKeyAuthenticationReason,
                strings.invariant(account.displayName)))
        }
    }

    private func updatePrivateKeyNavigation() {
        guard let privateKeys else { return }
        let id = privateKeys.walletID
        switch route {
        case .importedPrivateKey(let current) where current == id: break
        case .privateKeys(let current) where current == id:
            if privateKeys.phase != .chains || privateKeys.browserAccount != nil { privateKeys.returnToChains() }
        case .privateKeyTypes(let current) where current == id,
             .privateKeyAddresses(let current) where current == id:
            if privateKeys.phase != .chains { privateKeys.returnToBrowser() }
        case .privateKeyPasscode(let current) where current == id:
            if privateKeys.phase != .passcode { privateKeys.returnToPasscode() }
        case .privateKeyWarning(let current) where current == id: privateKeys.returnToWarning()
        case .privateKeyValue(let current) where current == id: break
        default:
            privateKeys.returnToChains()
            self.privateKeys = nil
        }
    }

    private func pop(_ expected: Route) {
        // Async form completion must not navigate away from a newer screen.
        guard path.last == expected else { return }
        path.removeLast()
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            settingsButton(.wallets, icon: "square.3.layers.3d", value: strings.number(session.wallets.count)) {
                path.append(.wallets)
            }
                .disabled(!session.isUnlocked || session.changingWallet)
                .accessibilityIdentifier("settings.wallets")
            settingsButton(.contacts, icon: "person.crop.circle") { path.append(.contacts) }
                .disabled(!session.isUnlocked)
                .accessibilityIdentifier("settings.contacts")
            settingsButton(.backup, icon: "icloud") { path.append(.allBackup) }
                .disabled(!session.isUnlocked || session.changingWallet)
                .accessibilityIdentifier("settings.backup")
            OathSettingsSectionRule()
            settingsButton(.currency, icon: "banknote", value: settings.currency) { path.append(.currency) }
                .accessibilityIdentifier("settings.currency")
            if settings.browserEnabled {
                settingsButton(.browserTitle, icon: "safari") { path.append(.browser) }
                    .accessibilityIdentifier("settings.browser")
            }
            settingsButton(.language, icon: "globe", value: settings.language.nativeName) { path.append(.languages) }
                .accessibilityIdentifier("settings.language")
            settingsButton(.preferences, icon: "slider.horizontal.3", value: strings.text(settings.appearance.title)) {
                path.append(.preferences)
            }
            .accessibilityIdentifier("settings.appearance")
            Toggle(isOn: Binding(get: { settings.hapticFeedbackEnabled }, set: settings.selectHapticFeedback)) {
                OathSettingsRow(title: strings.text(.hapticFeedback), icon: "waveform", accessory: .none)
            }
            .oathSwitchStyle()
            .padding(.trailing, 20)
            .accessibilityIdentifier("settings.hapticFeedback")
            OathSettingsSectionRule()
            OathButton {
                guard scenePhase != .background else { return }
                securityAccess.begin(reason: strings.text(.securityAuthenticationReason))
            } label: {
                OathSettingsRow(title: strings.text(.security), icon: "lock.shield", isWorking: securityAccess.busy)
            }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("settings.security")
                .disabled(!session.isUnlocked || session.changingWallet)
                .oathInteractionBlocked(securityAccess.busy)
            settingsButton(.permissions, icon: "hand.raised") { path.append(.permissions) }
                .accessibilityIdentifier("settings.permissions")
            settingsButton(.walletConnect, icon: "link") { path.append(.walletConnect) }
                .disabled(!session.isUnlocked || session.changingWallet)
                .accessibilityIdentifier("settings.walletconnect")
            OathSettingsSectionRule()
            settingsButton(.helpCenter, icon: "questionmark.circle") { path.append(.helpCenter) }
                .accessibilityIdentifier("settings.help")
            OathSupportLinkRow(title: .requestFeature, icon: "lightbulb", url: OathSupportLinks.issues, identifier: "settings.feature")
            OathSupportLinkRow(title: .submitBug, icon: "ladybug", url: OathSupportLinks.issues, identifier: "settings.bug")
            OathSupportLinkRow(title: .contactUs, icon: "envelope", url: OathSupportLinks.contact, identifier: "settings.contactUs")
            settingsButton(.aboutOath, icon: "info.circle") { path.append(.about) }
                .accessibilityIdentifier("settings.about")
            OathSettingsSectionRule()
            OathButton(role: .destructive) {
                guard scenePhase != .background else { return }
                reset.begin(reason: strings.text(.resetAuthenticationReason))
            } label: {
                OathSettingsRow(title: strings.text(.resetApp), icon: "trash", isWorking: reset.busy, color: .red)
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .disabled(!session.isUnlocked || session.changingWallet || reset.confirming)
            .oathInteractionBlocked(reset.busy)
            .accessibilityIdentifier("settings.reset")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.list")
    }

    private var preferencesContent: some View {
        VStack(spacing: 0) {
            ForEach([AppAppearance.light, .dark, .system], id: \.self) { choice in
                OathButton(feedback: .selection) { settings.selectAppearance(choice) } label: {
                    OathSettingsRow(title: strings.text(choice.title), icon: appearanceIcon(choice),
                                    accessory: .selection(settings.appearance == choice))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityAddTraits(settings.appearance == choice ? .isSelected : [])
                .accessibilityIdentifier("settings.appearance.\(choice.rawValue)")
            }
            OathSettingsSectionRule()
            settingsButton(.appIcon, icon: "app", value: settings.appIcon.map { strings.text($0.titleKey) }) { path.append(.appIcon) }
                .accessibilityIdentifier("settings.appIcon")
            OathSettingsSectionRule()
            Text(strings.text(.tabBar))
                .oathFont(.subheadline, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .accessibilityAddTraits(.isHeader)
            Toggle(isOn: Binding(get: { settings.showsPendingTransactionBadge }, set: settings.setPendingTransactionBadgeEnabled)) {
                OathSettingsRow(title: strings.text(.showPendingTransactionCount), icon: "number.circle", accessory: .none,
                                subtitle: strings.format(.pendingTransactionCountDetail, strings.text(.historyTab)),
                                subtitleLineLimit: nil)
            }
            .oathSwitchStyle()
            .padding(.trailing, 20)
            .accessibilityIdentifier("settings.pendingTransactionBadge")
        }
    }

    private func appearanceIcon(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .light: "sun.max"
        case .dark: "moon"
        case .system: "circle.lefthalf.filled"
        }
    }

    private func settingsButton(_ title: OathStringKey, icon: String, value: String? = nil,
                                action: @escaping () -> Void) -> some View {
        OathButton(action: action) {
            OathSettingsRow(title: strings.text(title), icon: icon, value: value)
        }.buttonStyle(OathSettingsRowButtonStyle())
    }

    private var languageConfiguration: OathLanguageSheetConfiguration {
        OathLanguageSheetConfiguration(strings: strings, preference: settings.preference,
            onChoose: { settings.select($0); pop(.languages) },
            onBack: { pop(.languages) }, onClose: { dismiss() }, style: .settings)
    }
}

private struct OathWalletNameSettings: View {
    let session: OathWalletSession
    let walletID: String
    let cloudBackup: OathCloudBackupModel
    let onCustomize: () -> Void
    let onHiddenAssets: () -> Void
    let onManageTokens: () -> Void
    let onBackupPassword: () -> Void
    let onRecovery: () -> Void
    let onPrivateKeys: () -> Void
    let onAccounts: () -> Void
    let onAddPassphrase: () -> Void
    let onAddSeedPassword: () -> Void
    let onDelete: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var canAddAccounts = false
    @State private var canAddSeedPassword = false
    @State private var activating = false
    @State private var activationFailed = false
    @State private var showsStellarSetup = false
    @State private var showsXrplSetup = false
    @State private var showsTronSetup = false
    @State private var showsNearSetup = false

    private var wallet: WalletRecord? { session.wallets.first { $0.id == walletID } }
    private var isActive: Bool { session.displayedProfile?.id.uuidString == walletID }
    private var actionsDisabled: Bool { wallet == nil || !session.isUnlocked || session.changingWallet || activating }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            walletOptions
            OathSettingsSectionRule()
            OathButton(action: onManageTokens) {
                OathSettingsRow(title: strings.text(.manageTokens), icon: "slider.horizontal.3")
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier("walletSettings.manageTokens")
            OathSettingsSectionRule()
            if canAddAccounts {
                OathButton(action: onAccounts) {
                    OathSettingsRow(title: strings.text(.walletAccounts), icon: "person.2")
                }.buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityIdentifier("walletSettings.account")
                OathSettingsFooter { Text(strings.text(.evmAccountsDetail)) }
                OathSettingsSectionRule()
            }
            // Use the selected settings wallet, including when it is inactive.
            // Passphrase-derived wallets already have their own passphrase.
            if let wallet, wallet.kind == "hd" || wallet.kind == "imported" {
                OathButton(action: onAddPassphrase) {
                    OathSettingsRow(title: strings.text(.addPassphrase), icon: "externaldrive.badge.plus")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("walletSettings.addPassphrase")
                OathSettingsFooter { Text(strings.text(.passphraseRowDetail)) }
                OathSettingsSectionRule()
            }
            if canAddSeedPassword {
                OathButton(action: onAddSeedPassword) {
                    OathSettingsRow(title: strings.text(.addSeedPassword), icon: "externaldrive.badge.plus")
                }.buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityIdentifier("walletSettings.addSeedPassword")
                OathSettingsFooter { Text(strings.text(.seedPasswordRowDetail)) }
                OathSettingsSectionRule()
            }
            if wallet?.kind == "stellarMultisig" {
                OathButton { showsStellarSetup = true } label: {
                    OathSettingsRow(title: strings.text(.multisigStellarSetup), icon: "signature")
                }.buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsSectionRule()
            }
            if wallet?.kind == "xrplMultisig" {
                OathButton { showsXrplSetup = true } label: {
                    OathSettingsRow(title: strings.text(.multisigXrplSetup), icon: "signature")
                }.buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsSectionRule()
            }
            if wallet?.kind == "tronMultisig" {
                OathButton { showsTronSetup = true } label: {
                    OathSettingsRow(title: strings.text(.multisigTronSetup), icon: "signature")
                }.buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsSectionRule()
            }
            if wallet?.kind == "nearMultisig" {
                OathButton { showsNearSetup = true } label: {
                    OathSettingsRow(title: strings.text(.multisigNearSetup), icon: "signature")
                }.buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsSectionRule()
            }
            backupAndKeys
            OathSettingsSectionRule()
            OathButton(role: .destructive, action: onDelete) {
                OathSettingsRow(title: strings.text(.deleteWallet), icon: "trash", accessory: .none, color: .red)
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier("walletSettings.delete")
        }
        .task(id: session.isUnlocked ? walletID : "") {
            let eligible = await session.vault.canAddSeedPasswordWallet(sourceID: walletID)
            guard !Task.isCancelled else { return }
            canAddSeedPassword = eligible
            let accountsEligible = await session.vault.canAddHDAccounts(walletID: walletID)
            guard !Task.isCancelled else { return }
            canAddAccounts = accountsEligible
        }
        .disabled(actionsDisabled)
        .sheet(isPresented: $showsStellarSetup) {
            NavigationStack { OathStellarMultisigSetupScreen(session: session, walletID: walletID) }
                .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        }
        .sheet(isPresented: $showsXrplSetup) {
            NavigationStack { OathXrplMultisigSetupScreen(session: session, walletID: walletID) }
                .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        }
        .sheet(isPresented: $showsTronSetup) {
            NavigationStack { OathTronMultisigSetupScreen(session: session, walletID: walletID) }
                .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        }
        .sheet(isPresented: $showsNearSetup) {
            NavigationStack { OathNearMultisigSetupScreen(session: session, walletID: walletID) }
                .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        }
        .alert(strings.text(.walletChangeFailed), isPresented: $activationFailed) {
            OathButton(strings.text(.done), feedback: nil) { activationFailed = false }
        } message: {
            Text(strings.text(.walletChangeFailedDetail))
        }
    }

    private var walletOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if wallet != nil && (!isActive || activating) {
                OathButton(feedback: nil, action: makeActive) {
                    OathSettingsRow(title: strings.text(.makeWalletActive), icon: "checkmark.circle",
                                    accessory: .none, isWorking: activating)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("walletSettings.makeActive")
            }
            OathButton(action: onCustomize) {
                OathSettingsRow(title: strings.text(.customizeWallet), icon: "paintpalette",
                                value: session.walletName(wallet, strings: strings))
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier("walletSettings.customize")
            OathButton(action: onHiddenAssets) {
                OathSettingsRow(title: strings.text(.hiddenAssets), icon: "eye.slash")
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier("walletSettings.hiddenAssets")
        }
    }

    private var backupAndKeys: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !["aezeed", "electrum", "electrum2fa"].contains(wallet?.kind ?? "") {
                OathCloudBackupSection(session: session, walletID: walletID, model: cloudBackup,
                                       onChoosePassword: onBackupPassword)
            }
            if wallet?.kind != "privateKey" {
                OathButton(action: onRecovery) {
                    OathSettingsRow(title: strings.text(["bitcoinMultisig", "litecoinMultisig", "bitcoinCashMultisig", "dogecoinMultisig", "evmMultisig", "tronMultisig", "solanaMultisig", "xrplMultisig", "stellarMultisig", "aptosMultisig", "tonMultisig", "thorchainMultisig", "nearMultisig", "suiMultisig"].contains(wallet?.kind ?? "") ? .multisigRecovery : .viewRecoveryPhrase), icon: "key.horizontal")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("walletSettings.recovery")
                OathSettingsFooter { Text(strings.text(["bitcoinMultisig", "litecoinMultisig", "bitcoinCashMultisig", "dogecoinMultisig", "evmMultisig", "tronMultisig", "solanaMultisig", "xrplMultisig", "stellarMultisig", "aptosMultisig", "tonMultisig", "thorchainMultisig", "nearMultisig", "suiMultisig"].contains(wallet?.kind ?? "") ? .multisigRecoveryDetail : .recoveryRowDetail)) }
            }
            if !["electrum2fa", "bitcoinMultisig", "litecoinMultisig", "bitcoinCashMultisig", "dogecoinMultisig", "evmMultisig", "tronMultisig", "solanaMultisig", "xrplMultisig", "stellarMultisig", "aptosMultisig", "tonMultisig", "thorchainMultisig", "nearMultisig", "suiMultisig"].contains(wallet?.kind ?? "") {
                OathButton(action: onPrivateKeys) {
                    OathSettingsRow(title: strings.text(.viewPrivateKeys), icon: "key.2.on.ring")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("walletSettings.privateKeys")
                OathSettingsFooter { Text(strings.text(.privateKeyRowDetail)) }
            }
        }
    }

    private func makeActive() {
        guard scenePhase != .background, !actionsDisabled, !isActive,
              let id = UUID(uuidString: walletID) else { return }
        activating = true
        // Keep the selected settings destination open. The session owns the
        // persisted selection, portfolio replacement and lock-race protection.
        Task {
            defer { activating = false }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do { try await session.selectWallet(id) }
                catch is CancellationError { /* A lock or session transition superseded selection. */ }
                catch {
                    OathDiagnostics.record(error, component: "wallet_settings", operation: "make_active")
                    if session.isUnlocked { activationFailed = true }
                }
            }
        }
    }
}

/// Public account/path management. Derivation and encrypted commits stay in the vault.
private extension OathImportChain {
    var hdAccountFamily: HDAccountFamily? {
        if isEVM { return .evm }
        if self == .solana { return .solana }
        return nil
    }
}

extension HDAccountFamily {
    var accountsTitleKey: OathStringKey { self == .evm ? .evmAccounts : .solanaAccounts }
    var accountNumberKey: OathStringKey { self == .evm ? .evmAccountNumber : .solanaAccountNumber }
}

private struct OathHDAccountsPage: View {
    let session: OathWalletSession
    let walletID: String
    let family: HDAccountFamily
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var balances = OathWalletListBalances()
    @State private var details: OathHDAccountDestination?
    @State private var accounts: [EVMAccountGroup] = []
    @State private var loaded = false
    @State private var eligible = false
    @State private var custom = false
    @State private var drafts: [HDAccountPathDraft] = []
    @FocusState private var focusedPath: UUID?
    @State private var notice: OathStringKey?
    @State private var work: Task<Void, Never>?
    @State private var busy = false

    // Expected live form validation; invalid drafts disable import without logging user input.
    private var parsed: [String]? { try? HDAccountPathDraft.paths(drafts, family: family) }
    private var newPaths: [String] {
        let saved = Set(accounts.map(\.path))
        return (parsed ?? []).filter { !saved.contains($0) }
    }
    private var enabled: Bool { loaded && eligible && session.isUnlocked && !session.changingWallet && !busy }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                OathSettingsFooter { Text(strings.text(.evmAccountsDetail)) }.padding(.top, 20)
                if let wallet = session.wallets.first(where: { $0.id == walletID }) {
                    ForEach(accounts) { account in
                        OathButton {
                            details = .init(wallet: wallet, selection: .init(family: family, path: account.path))
                        } label: {
                            OathHDAccountSummary(wallet: wallet, account: account, family: family,
                                session: session, balances: balances,
                                selected: session.displayedProfile?.id.uuidString == walletID && session.selectedHomeAccount == .init(family: family, path: account.path),
                                disclosure: true)
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .accessibilityIdentifier("hdAccounts.account.\(account.index)")
                    }
                }
                if !loaded { ProgressView().padding(20) }
                OathSettingsSectionRule()
                OathButton {
                    // Expected bounded account-limit validation, not an operational failure.
                    if let path = try? family.nextDefaultPath(existing: Set(accounts.map(\.path))) { save([path]) }
                    else { notice = .evmAccountLimit }
                } label: {
                    OathSettingsRow(title: strings.text(.evmAddAccount), icon: "plus")
                }
                .buttonStyle(OathSettingsRowButtonStyle()).disabled(!enabled)
                .accessibilityIdentifier("\(family.rawValue)Accounts.add")
                OathButton {
                    custom.toggle(); notice = nil; focusedPath = nil
                    if custom && drafts.isEmpty { addPath() }
                } label: {
                    OathSettingsRow(title: strings.text(.evmCustomPaths), icon: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(OathSettingsRowButtonStyle()).disabled(!enabled)
                .accessibilityIdentifier("\(family.rawValue)Accounts.custom")
                OathSettingsFooter { Text(strings.text(.evmBackupPaths)) }
                if custom {
                    OathSettingsSectionRule()
                    OathSettingsFooter { Text(strings.text(.evmPathsHelp)) }
                    ForEach(drafts) { draft in
                        OathHDPathEditor(draft: OathHDPathBindings.draft(draft, in: $drafts),
                            number: (drafts.firstIndex(where: { $0.id == draft.id }) ?? 0) + 1,
                            focusedPath: $focusedPath) {
                                let id = draft.id
                                drafts.removeAll { $0.id == id }
                            }
                            .disabled(!enabled)
                    }
                    OathButton { addPath() } label: {
                        OathSettingsRow(title: strings.text(.hdAddPath), icon: "plus", accessory: .none)
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .disabled(!enabled || drafts.count >= HDAccountPathDraft.maximumPaths)
                    .accessibilityIdentifier("\(family.rawValue)Accounts.addPath")
                    if !drafts.isEmpty {
                        if parsed == nil { OathSettingsFooter { Text(strings.text(.evmInvalidPaths)) }.foregroundStyle(.red) }
                        else if newPaths.isEmpty { OathSettingsFooter { Text(strings.text(.evmPathsAlreadyAdded)) } }
                    }
                }
                if let notice { Text(strings.text(notice)).foregroundStyle(.red).padding(20) }
            }.padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: OathSurfaceColors.canvas))
        .sheet(item: $details) { OathHDAccountDetails(session: session, destination: $0) }
        .task(id: session.isUnlocked) { await balances.observe(session: session, walletIDs: [walletID]) }
        .navigationTitle(strings.text(family.accountsTitleKey))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedPath != nil {
                    Spacer()
                    Button { focusedPath = nil } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel(strings.text(.done))
                }
            }
            if custom || busy {
                OathToolbarAction(title: .importAction, isEnabled: enabled && !newPaths.isEmpty,
                    isWorking: busy, identifier: "\(family.rawValue)Accounts.import") { save(newPaths) }
            }
        }
        .task(id: session.isUnlocked ? walletID : "") {
            guard session.isUnlocked else { return }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    eligible = await session.vault.canAddHDAccounts(walletID: walletID)
                    let db = try await session.vault.database()
                    for try await values in db.observeHDAccounts(family: family) {
                        guard !Task.isCancelled else { return }
                        accounts = values[walletID] ?? []; loaded = true
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    OathDiagnostics.record(error, component: "hd_accounts", operation: "observe")
                    notice = .walletChangeFailedDetail
                }
            }
        }
        .onDisappear { work?.cancel(); work = nil; focusedPath = nil }
        .onChange(of: scenePhase) { _, phase in if phase == .background { work?.cancel() } }
        .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { work?.cancel(); focusedPath = nil; drafts = []; custom = false } }
    }

    private func addPath() {
        guard drafts.count < HDAccountPathDraft.maximumPaths else { return }
        let used = Set(accounts.map(\.path) + drafts.compactMap(\.canonicalPath))
        drafts.append(HDAccountPathDraft(family: family, excluding: used))
    }

    private func save(_ values: [String]) {
        guard enabled, !values.isEmpty else { return }
        focusedPath = nil; busy = true; notice = nil
        work = Task { @MainActor in
            defer { busy = false; work = nil }
            do {
                try await session.addHDAccounts(walletID: walletID, family: family, paths: values)
                guard !Task.isCancelled else { return }
                drafts = []; custom = false
            } catch is CancellationError { /* Expected navigation, lock or background cancellation. */ }
            catch let error as EVMAccountDerivation.ValidationError {
                // diagnostics: hd-account-form-validation; expected user input or account limit.
                notice = error == .accountLimit ? .evmAccountLimit : .evmInvalidPaths
            } catch {
                // diagnostics: hd-account-commit-propagation; changeWallet reports and reconciles the original failure.
                notice = .walletChangeFailedDetail
            }
        }
    }
}

extension EVMAccountGroup {
    func displayName(family: HDAccountFamily, strings: OathLocalizer) -> String {
        name ?? strings.format(family.accountNumberKey, strings.number(index + 1))
    }
}

struct OathHDAccountDestination: Identifiable {
    let wallet: WalletRecord
    let selection: HomeAccountSelection
    var id: String { selection.balanceID(walletID: wallet.id) }
}

/// Its balance dependency is deliberately owned by the row, not the sidebar.
struct OathHDAccountSummary: View {
    let wallet: WalletRecord
    let account: EVMAccountGroup
    let family: HDAccountFamily
    let session: OathWalletSession
    let balances: OathWalletListBalances
    var selected = false
    var disclosure = false
    var showsAddress = true
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathListRow {
            OathWalletListIcon(colorHex: wallet.colorHex, isActive: selected)
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                Text(account.displayName(family: family, strings: strings)).oathFont(.body)
                    .foregroundStyle(.primary).lineLimit(2)
                Text(balances.amount(walletID: wallet.id, selection: .init(family: family, path: account.path),
                    session: session, locale: strings.language.locale))
                    .oathFont(.body, weight: .medium).foregroundStyle(.primary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75).environment(\.layoutDirection, .leftToRight)
                    .oathBalanceConcealed(session.balancesHidden)
                    .accessibilityIdentifier("hdAccount.balance")
                if showsAddress {
                    Text(strings.invariant(account.address)).oathFont(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        } accessory: {
            if disclosure { Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
    }
}

struct OathHDAccountDetails: View {
    private enum CopyField: String { case address, path }
    let session: OathWalletSession
    let destination: OathHDAccountDestination
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var balances = OathWalletListBalances()
    @State private var accounts: [EVMAccountGroup] = []
    @State private var eligible = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmingRemoval = false
    @State private var busy = false
    @State private var notice: OathStringKey?
    @State private var work: Task<Void, Never>?
    @State private var copiedField: CopyField?
    @State private var privateKeys: OathPrivateKeyModel?
    @State private var privateKeyAccount: OathPrivateKeyAccount?
    @State private var privateKeyNavigation = OathAccountPrivateKeyNavigation()
    @State private var privateKeyRequestID: UUID?
    @State private var removal: OathHDAccountRemovalModel?
    @State private var showsRemovalPasscode = false
    @FocusState private var nameFocused: Bool

    private var account: EVMAccountGroup? { accounts.first { $0.path == destination.selection.path } }
    private var enabled: Bool {
        eligible && account != nil && session.isUnlocked && !session.changingWallet && !busy &&
            (removal == nil || removal?.phase == .idle)
    }
    private var validName: Bool {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 80 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    var body: some View {
        NavigationStack(path: $privateKeyNavigation.path) {
            ScrollView {
                VStack(spacing: 0) {
                    if let account {
                        OathHDAccountSummary(wallet: destination.wallet, account: account,
                            family: destination.selection.family, session: session, balances: balances, showsAddress: false)
                            .padding(.top, 12)
                        OathSettingsSectionRule()
                        detail(strings.text(.walletTab), value: session.walletName(destination.wallet, strings: strings))
                        detail(strings.text(.tokenNetwork), value: destination.selection.family == .solana ? "Solana" : "EVM")
                        detail(strings.text(.contactAddress), value: account.address, copyField: .address)
                        detail(strings.text(.privateKeyPath), value: account.path, copyField: .path)
                        OathSettingsSectionRule()
                        if renaming {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(strings.text(.hdAccountName)).oathFont(.footnote).foregroundStyle(.secondary)
                                TextField(strings.text(.hdAccountName), text: $draftName)
                                    .oathSettingsField().focused($nameFocused).submitLabel(.done)
                                    .disabled(busy).onSubmit { if enabled && validName { rename() } }
                                    .accessibilityIdentifier("hdAccount.name")
                            }.padding(.horizontal, 20).padding(.bottom, 20)
                        } else {
                            OathButton {
                                draftName = account.displayName(family: destination.selection.family, strings: strings)
                                renaming = true; nameFocused = true; notice = nil
                            } label: {
                                OathSettingsRow(title: strings.text(.hdAccountRename), icon: "pencil")
                            }.buttonStyle(OathSettingsRowButtonStyle()).disabled(!enabled)
                                .accessibilityIdentifier("hdAccount.rename")
                        }
                        OathButton { beginPrivateKeyExport() } label: {
                            OathSettingsRow(title: strings.text(.sidebarRevealKey), icon: "key")
                        }.buttonStyle(OathSettingsRowButtonStyle()).disabled(!enabled)
                            .accessibilityIdentifier("hdAccount.exportPrivateKey")
                        OathSettingsSectionRule()
                        OathButton(role: .destructive) { confirmingRemoval = true } label: {
                            OathSettingsRow(title: strings.text(.hdAccountRemove), icon: "trash", accessory: .none, color: .red)
                        }.buttonStyle(OathSettingsRowButtonStyle()).disabled(!enabled || accounts.count <= 1)
                            .accessibilityIdentifier("hdAccount.remove")
                        OathSettingsFooter {
                            Text(strings.text(accounts.count > 1 ? .hdAccountRemovalHelp : .hdAccountKeepOne))
                        }
                    } else if notice == nil { ProgressView().padding(32) }
                    if removal?.busy == true { ProgressView().padding(20) }
                    if let notice = removal?.notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(20) }
                    if let notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(20) }
                }.padding(.bottom, 24)
            }
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .navigationTitle(strings.text(.hdAccountDetails)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if privateKeyNavigation.path.isEmpty && !showsRemovalPasscode {
                    ToolbarItem(placement: .topBarLeading) {
                        OathCloseButton { removal?.cancel(); dismiss() }.disabled(busy || removal?.phase == .removing)
                    }
                }
                if privateKeyNavigation.path.isEmpty && !showsRemovalPasscode && (renaming || busy) {
                    OathToolbarAction(title: .save, isEnabled: enabled && validName, isWorking: busy,
                        identifier: "hdAccount.save") { rename() }
                }
            }
            .alert(strings.text(.hdAccountRemove), isPresented: $confirmingRemoval) {
                Button(strings.text(.cancel), role: .cancel) {}
                Button(strings.text(.hdAccountRemove), role: .destructive) { remove() }
            } message: { Text(strings.text(.hdAccountRemovalHelp)) }
            .navigationDestination(for: OathAccountPrivateKeyNavigation.Route.self, destination: privateKeyScreen)
            .navigationDestination(isPresented: $showsRemovalPasscode) {
                if let removal {
                    OathSecretPasscodePage(session: session, busy: removal.busy,
                        notice: Binding(get: { removal.notice }, set: { removal.notice = $0 }),
                        title: .hdAccountRemove, identifier: "hdAccount.remove.passcode", onSubmit: removal.submit)
                        .background(Color(uiColor: OathSurfaceColors.canvas))
                        .navigationTitle(strings.text(.hdAccountRemove)).navigationBarTitleDisplayMode(.inline)
                        .navigationBarBackButtonHidden(removal.phase == .removing)
                }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        .interactiveDismissDisabled(busy || removal?.phase == .removing)
        .onChange(of: removal?.phase) { _, phase in
            if phase == .passcode { showsRemovalPasscode = true }
            else if phase == .removed { dismiss() }
            else if phase == .idle { showsRemovalPasscode = false }
        }
        .onChange(of: showsRemovalPasscode) { _, presented in
            if !presented && removal?.phase == .passcode { removal?.cancel() }
        }
        .task(id: privateKeyRequestID) {
            guard privateKeyRequestID != nil, let privateKeys, let privateKeyAccount,
                  session.isUnlocked, scenePhase != .background else { return }
            await privateKeys.selectAccount(privateKeyAccount, reason:
                strings.format(.privateKeyAuthenticationReason, strings.invariant(privateKeyAccount.displayName)))
        }
        .onChange(of: privateKeys?.phase) { _, phase in
            if let phase { privateKeyNavigation.update(phase: phase) }
        }
        .onChange(of: privateKeyNavigation.path) { _, path in
            if let privateKeys { privateKeyNavigation.reconcile(model: privateKeys) }
            if path.isEmpty { clearPrivateKeyExport() }
        }
        .task(id: session.isUnlocked) { await balances.observe(session: session, walletIDs: [destination.wallet.id]) }
        .task(id: session.isUnlocked) {
            guard session.isUnlocked else { dismiss(); return }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    eligible = await session.vault.canAddHDAccounts(walletID: destination.wallet.id)
                    let db = try await session.vault.database()
                    for try await values in db.observeHDAccounts(family: destination.selection.family) {
                        guard !Task.isCancelled else { return }
                        accounts = values[destination.wallet.id] ?? []
                        if !busy && removal?.phase != .removing && !accounts.contains(where: { $0.path == destination.selection.path }) { dismiss(); return }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    OathDiagnostics.record(error, component: "hd_accounts", operation: "observe_details")
                    notice = .walletChangeFailedDetail
                }
            }
        }
        .task(id: copiedField) {
            guard copiedField != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); copiedField = nil }
            catch is CancellationError { /* A new copy or dismissed details cancels feedback. */ }
            catch { OathDiagnostics.record(error, component: "hd_accounts", operation: "copy_feedback") }
        }
        .onDisappear { work?.cancel(); work = nil; clearPrivateKeyExport(); removal?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            // System authentication may briefly be inactive; only backgrounding
            // abandons this export and its pending authorization.
            if phase == .background { work?.cancel(); clearPrivateKeyExport(); removal?.cancel() }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { clearPrivateKeyExport(); removal?.cancel() } }
    }

    private func detail(_ title: String, value: String, copyField: CopyField? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).oathFont(.footnote).foregroundStyle(.secondary)
                if copyField != nil {
                    Text(strings.invariant(value)).oathFont(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else { Text(value).oathFont(.body) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let copyField {
                OathButton {
                    guard session.isUnlocked, scenePhase != .background else { return }
                    OathClipboard.copy(value)
                    copiedField = copyField
                } label: {
                    Image(systemName: copiedField == copyField ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(copiedField == copyField ? OathOnboardingColors.blue : Color(uiColor: .secondaryLabel))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(copyField == .address ? strings.text(.copyAddress) : strings.text(.recoveryCopy) + ", " + title)
                    .accessibilityValue(copiedField == copyField ? strings.text(.recoveryCopied) : "")
                    .accessibilityIdentifier("hdAccount.copy." + copyField.rawValue)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func beginPrivateKeyExport() {
        guard enabled, scenePhase != .background, let account,
              let record = account.accounts.first,
              let chain = OathImportChain(rawValue: record.networkID) else { return }
        nameFocused = false; renaming = false
        privateKeys?.returnToChains()
        privateKeys = OathPrivateKeyModel(walletID: destination.wallet.id, reader: session.vault)
        privateKeyAccount = .init(id: record.id, chain: chain, address: record.address, path: record.derivationPath)
        privateKeyNavigation.begin()
        privateKeyRequestID = UUID()
    }

    @ViewBuilder private func privateKeyScreen(_ route: OathAccountPrivateKeyNavigation.Route) -> some View {
        Group {
            if let privateKeys {
                switch route {
                case .authorization:
                    VStack(spacing: 20) {
                        if privateKeys.busy || (!privateKeys.loaded && privateKeys.notice == nil) { ProgressView() }
                        else {
                            if let notice = privateKeys.notice {
                                Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red)
                            }
                            OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) {
                                guard session.isUnlocked, !session.changingWallet, scenePhase != .background else { return }
                                privateKeys.returnToChains()
                                privateKeyRequestID = UUID()
                            }
                            .accessibilityIdentifier("privateKey.retry")
                        }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .passcode:
                    OathSecretPasscodePage(session: session, busy: privateKeys.busy,
                        notice: Binding(get: { privateKeys.notice }, set: { privateKeys.notice = $0 }),
                        title: .viewPrivateKey, identifier: "privateKey.passcode", onSubmit: privateKeys.submit)
                case .warning:
                    OathPrivateKeyWarningPage(model: privateKeys, session: session)
                case .value:
                    OathPrivateKeyValuePage(model: privateKeys, session: session)
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas))
        .navigationTitle(strings.text(.viewPrivateKey)).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
    }

    private func clearPrivateKeyExport() {
        privateKeys?.returnToChains()
        privateKeyRequestID = nil
        privateKeyNavigation.path = []
        privateKeys = nil; privateKeyAccount = nil
    }

    private func rename() {
        guard enabled, validName else { return }
        busy = true; notice = nil; nameFocused = false
        let name = draftName
        work = Task { @MainActor in
            defer { busy = false; work = nil }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let db = try await session.vault.database()
                    try Task.checkCancellation()
                    guard session.isUnlocked else { return }
                    try await db.renameHDAccount(walletID: destination.wallet.id, selection: destination.selection, name: name)
                    renaming = false
                    OathHaptics.shared.play(.success)
                } catch is CancellationError { /* Expected dismissal or background cancellation. */ }
                catch is OathDatabase.AccountManagementError {
                    // diagnostics: hd-account-form-validation; expected name validation.
                    notice = .walletRenameFailed
                }
                catch {
                    OathDiagnostics.record(error, component: "hd_accounts", operation: "rename")
                    notice = .walletRenameFailed
                }
            }
        }
    }

    private func remove() {
        guard enabled, accounts.count > 1, scenePhase != .background else { return }
        nameFocused = false; renaming = false; notice = nil
        if removal == nil { removal = OathHDAccountRemovalModel(session: session) }
        removal?.begin(walletID: destination.wallet.id, selection: destination.selection, reason: strings.text(.hdAccountRemove))
    }
}
