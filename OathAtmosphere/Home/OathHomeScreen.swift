import OathDiagnostics
import SwiftUI
import OathNativeRefresh
import OathSidebar
import OathDatabase
import OathAnkr

struct OathHomeScreen: View {
    private static let multisigCheck = OathTokenRPCConfiguration.bundled().makePublicMultisigCheck()
    // A legacy cold launch can render the Home layout before SQL metadata has
    // been migrated. The root keeps it noninteractive beneath the lock.
    let profile: OathWalletProfile?
    let session: OathWalletSession
    let settings: OathAppSettings
    let lockCoverHidden: Bool
    @State private var sidebarRemoval: OathWalletRemovalModel

    init(profile: OathWalletProfile?, session: OathWalletSession, settings: OathAppSettings, lockCoverHidden: Bool) {
        self.profile = profile
        self.session = session
        self.settings = settings
        self.lockCoverHidden = lockCoverHidden
        _sidebarRemoval = State(initialValue: OathWalletRemovalModel(session: session))
        _browser = State(initialValue: settings.browserEnabled ? OathBrowserController() : nil)
    }

    private var sidebarRemovalActive: Bool { sidebarRemoval.action != nil || sidebarRemoval.notice != nil }
    // A committed offer waits here if another sheet takes priority before presentation.
    @State private var claimedBackupOffers: [UUID: WalletBackupOffer] = [:]
    @State private var claimingBackupOffers: Set<UUID> = []
    @State private var homeHasAppeared = false
    // A nil binding can precede UIKit's dismissal completion. Keep the modal
    // slot occupied until onDismiss, including the create/import editor.
    @State private var presentedSheetID: String?
    @State private var backupStatus: (walletID: UUID, cloud: WalletCloudBackupStatus)?
    private var backupStatusWalletID: UUID? {
        guard scenePhase != .background, session.isUnlocked, !session.changingWallet, !session.resetting else { return nil }
        if case .backup(let id, _) = sheet { return id }
        guard let id = profile?.id else { return nil }
        return claimingBackupOffers.contains(id) || claimedBackupOffers[id] != nil || currentWallet?.pendingBackupOffer != nil ? id : nil
    }

    private var visibleBackupOffer: WalletBackupOffer? {
        guard let backupStatus, backupStatus.walletID == profile?.id else { return nil }
        return backupStatus.cloud.visibleOffer(for: claimedBackupOffers[backupStatus.walletID] ?? currentWallet?.pendingBackupOffer)
    }
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.colorScheme) private var colorScheme
    @State private var sidebar = OathWalletSidebarModel()
    @State private var sidebarBalances = OathWalletListBalances()
    @State private var sheet: Sheet?
    @State private var multisigFindings: [PublicMultisigEvidence] = []
    @State private var multisigFindingsWalletID: UUID?
    @State private var securityNotices = WalletSecurityNoticeQueue()
    @State private var showsScanner = false
    @State private var scannedRecipient: OathScannedRecipient?
    @State private var paymentLinkActive = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var assetPath: [OathAssetRoute] = []
    @State private var addressCopyTask: Task<Void, Never>?
    @State private var copiedAsset: OathHomeCopiedAsset?
    @State private var showsAppSettings = false
    @State private var scanError: OathRecoveryScanError?
    @State private var pendingScanError: OathRecoveryScanError?
    @State private var query = ""
    @State private var searchScope: OathAssetSearchScope = .all
    @State private var historyQuery = ""
    @State private var historyFilters = OathHistoryFilterSelection()
    @State private var historyBadge: (scope: String, count: Int)?
    @State private var toolbarBalance = OathHomeToolbarBalanceState()
    private var assetFilters: PortfolioFilter {
        portfolioPresentation.filter.adjusted(for: assetFilterCurrency)
    }
    private var portfolioPresentation: OathHomePortfolioModel { session.homePortfolio }
    @State private var selectedTab: OathHomeTab = .wallet
    @State private var browser: OathBrowserController?
    @State private var silentAssetTabSelection = false
    @State private var searchPresented = false
    @State private var tokenSearch = OathTokenSearchModel()
    @State private var tokenSearchAttempt = 0
    private var tokenSearchRequest: OathTokenSearchRequest {
        var request = OathTokenSearchRequest(query: query, walletID: profile?.id.uuidString,
            active: session.isUnlocked && !session.changingWallet && !session.resetting
                && selectedTab == .search,
            snapshot: session.portfolio, scope: searchScope)
        request.attempt = tokenSearchAttempt
        return request
    }
    private var balancesHidden: Bool { session.balancesHidden }
    private var searchRows: [OathHomeRowLayout] {
        portfolioPresentation.searchLayout.filter { searchScope.includes(networkID: $0.chain.id) }
    }
    private var currentWallet: WalletRecord? {
        session.wallets.first(where: { $0.id == profile?.id.uuidString })
    }
    @State private var walletActionFailed = false

    private enum Sheet: Identifiable {
        case wallets, send, receive, address(OathWalletAddress), assetFilters, tronMultisigSetup(String), xrplMultisigSetup(String), stellarMultisigSetup(String)
        case wallet(SettingsDestination)
        case backup(UUID, WalletBackupOffer)
        case multisig(UUID, [PublicMultisigEvidence])
        case stablecoin(UUID, [StablecoinRestrictionToken])
        case priceUntracked
        var id: String {
            switch self {
            case .wallets: "wallets"
            case .wallet(let destination): "walletSettings-" + destination.id
            case .send: "send"
            case .receive: "receive"
            case .assetFilters: "assetFilters"
            case .priceUntracked: "priceUntracked"
            case .xrplMultisigSetup: "xrplMultisigSetup"
            case .stellarMultisigSetup: "stellarMultisigSetup"
            case .tronMultisigSetup: "tronMultisigSetup"
            case .backup(let id, _): "backup-" + id.uuidString
            case .multisig: "multisig"
            case .stablecoin: "stablecoin"
            case .address(let address): address.id
            }
        }
    }

    private typealias SettingsDestination = OathWalletSettingsScreen.Destination

    private var historyVisible: Bool { selectedTab == .history }
    private var assetFilterCurrency: String { portfolioPresentation.currency }
    private var shouldPreparePortfolio: Bool {
        scenePhase == .active && session.isUnlocked && !session.changingWallet && !session.resetting
    }
    private var balanceHistoryVisible: Bool {
        shouldPreparePortfolio && !session.changingWallet && !session.resetting &&
        selectedTab == .wallet && assetPath.isEmpty && !showsAppSettings && !sidebarRemovalActive &&
        sheet == nil && !sidebar.isVisible && !showsScanner && !OathWalletConnectService.shared.presentationOpen &&
        profile?.id.uuidString == portfolioPresentation.walletID
    }

    private var addressCopyScope: String? {
        balanceHistoryVisible && lockCoverHidden ? accountScopeIdentity : nil
    }

    private var canPresentVaultImport: Bool {
        session.isUnlocked && !session.changingWallet && !session.resetting && !sidebarRemovalActive &&
        !sidebar.isVisible && !showsScanner && scannedRecipient == nil && sheet == nil && !showsAppSettings && !OathWalletConnectService.shared.presentationOpen
    }

    private var canPresentWalletLink: Bool {
        !sidebarRemovalActive && OathVaultImportInbox.shared.pending == nil && OathVaultImportInbox.shared.active == nil &&
        (OathWalletLinkInbox.shared.pending != nil && !OathWalletLinkInbox.shared.hasWalletConnectRequest) &&
        session.isUnlocked && scenePhase == .active && !session.changingWallet && !session.resetting &&
        !sidebar.isVisible && !showsScanner && scannedRecipient == nil && sheet == nil && !showsAppSettings && !OathWalletConnectService.shared.presentationOpen
    }
    private var multisigAccounts: [PublicMultisigAccount] {
        Array(Set((profile?.addresses ?? []).compactMap { item in
            PublicMultisigChain(rawValue: item.chain.id).map { PublicMultisigAccount(chain: $0, address: item.address) }
        })).sorted { ($0.chain.rawValue, $0.address) < ($1.chain.rawValue, $1.address) }
    }
    private var multisigScope: String {
        guard shouldPreparePortfolio, !session.usesSyntheticPortfolio, let profile else { return "" }
        return profile.id.uuidString + multisigAccounts.map { "|\($0.chain.rawValue):\($0.address)" }.joined()
    }
    private var hasPendingMultisigNotice: Bool {
        profile.map { $0.id == multisigFindingsWalletID && session.multisigNoticeStates[$0.id]?.acknowledged == false } == true &&
        !multisigFindings.isEmpty
    }
    private var stablecoinAccounts: [StablecoinRestrictionAccount] {
        Array(Set((profile?.addresses ?? []).compactMap { item in
            StablecoinRestrictionRegistry.tokens(network: item.chain.id).isEmpty ? nil :
                StablecoinRestrictionAccount(network: item.chain.id, address: item.address)
        })).sorted { ($0.network, $0.address) < ($1.network, $1.address) }
    }
    private var stablecoinScope: String {
        guard shouldPreparePortfolio, !session.usesSyntheticPortfolio, let profile else { return "" }
        return profile.id.uuidString + stablecoinAccounts.map { "|\($0.network):\($0.address)" }.joined()
    }
    private var nextSecurityNotice: WalletSecurityNoticeQueue.Notice? {
        let state = profile.flatMap { session.stablecoinSecurityStates[$0.id] }
        // Presentation depends only on the current foreground screen. Portfolio
        // formatting, history, discovery and security checks run independently.
        let available = homeHasAppeared && shouldPreparePortfolio && lockCoverHidden &&
            selectedTab == .wallet && assetPath.isEmpty && !showsAppSettings && !sidebarRemovalActive &&
            sheet == nil && presentedSheetID == nil && !sidebar.isVisible && !showsScanner &&
            !OathWalletConnectService.shared.presentationOpen &&
            !searchPresented && scannedRecipient == nil &&
            session.pendingCustomizationID == nil && !OathWalletConnectService.shared.needsPresentation &&
            OathWalletLinkInbox.shared.pending == nil
        return securityNotices.next(walletID: profile?.id, homeAvailable: available,
            multisigPending: hasPendingMultisigNotice,
            stablecoinPending: state.map { !$0.acknowledged && !$0.restricted.isEmpty } == true,
            backupPending: visibleBackupOffer != nil &&
                !session.presentsOnboarding &&
                !walletActionFailed && scanError == nil && OathVaultImportInbox.shared.pending == nil &&
                OathVaultImportInbox.shared.active == nil)
    }
    private func presentNextSecurityNotice() {
        // Re-evaluate current wallet/navigation state instead of presenting a
        // candidate captured before a wallet switch or another modal opened.
        guard let next = nextSecurityNotice else { return }
        switch next.kind {
        case .backup:
            if let offer = claimedBackupOffers[next.walletID] {
                guard securityNotices.begin(next) else { return }
                sheet = .backup(next.walletID, offer)
                claimedBackupOffers.removeValue(forKey: next.walletID)
            } else {
                // Do not start a second SQL claim when observation/rendering
                // changes while the first one is suspended.
                guard claimingBackupOffers.insert(next.walletID).inserted else { return }
                Task {
                    let offer = await OathDiagnostics.$operationID.withValue(UUID()) {
                        await OathDiagnostics.attemptOptional("claim_backup_offer") {
                            let db = try await session.vault.database()
                            return try await db.claimBackupOffer(walletID: next.walletID.uuidString)
                        }
                    }
                    if let offer { claimedBackupOffers[next.walletID] = offer }
                    claimingBackupOffers.remove(next.walletID)
                    // The SQL write is the only asynchronous prerequisite. A
                    // second native appearance may never occur on visible Home.
                    if offer != nil { presentNextSecurityNotice() }
                }
            }
        case .multisig:
            guard securityNotices.begin(next) else { return }
            sheet = .multisig(next.walletID, multisigFindings)
        case .stablecoin:
            guard let state = session.stablecoinSecurityStates[next.walletID],
                  securityNotices.begin(next) else { return }
            sheet = .stablecoin(next.walletID, state.restricted)
        }
    }
    @ViewBuilder private var savedHistoryUpdates: some View {
        if shouldPreparePortfolio, !historyVisible, let walletID = profile?.id.uuidString {
            let currency = assetFilterCurrency
            let locale = strings.language.locale.identifier
            Color.clear.task(id: "\(accountScopeIdentity):\(currency):\(locale)") {
                await session.observeHomeHistory(walletID: walletID, currency: currency, localeIdentifier: locale)
            }
        }
    }

    private var observedSidebar: some View {
        sidebarContainer
        .disabled(sidebarRemovalActive)
        .allowsHitTesting(!sidebarRemovalActive)
        .modifier(OathSidebarRemovalPresentation(session: session, removal: sidebarRemoval))
        .tint(Color(uiColor: .label))
        .background {
            // Only view context is observed here. The session delivers accepted
            // database snapshots directly to the row presentation model.
            OathHomePortfolioUpdates(session: session, query: query, active: shouldPreparePortfolio)
                .background { savedHistoryUpdates }
        }
        .environment(\.oathScanSession, session)
        .task(id: sidebarBalances.scope(session: session).joined(separator: "|") + assetFilterCurrency + String(sidebar.isVisible)) {
            guard sidebar.isVisible else { return }
            await sidebarBalances.observe(session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { sidebar.invalidate(); sidebarRemoval.cancel() }
            else if phase == .inactive && !sidebarRemovalActive { sidebar.invalidate() }
        }
        .onChange(of: sidebarEnabled) { _, enabled in
            if !enabled { sidebar.invalidate() }
        }
        .onChange(of: session.resetting) { _, resetting in
            if resetting { sidebar.invalidate(); sidebarRemoval.cancel() }
        }
        .onDisappear { sidebar.invalidate(); sidebarRemoval.cancel() }
    }

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        let _ = OathHomeScrollFixture.recordHomeBody()
        #endif
        observedSidebar
        .task(id: backupStatusWalletID) {
            let id = backupStatusWalletID
            backupStatus = nil
            guard let id else { return }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let db = try await session.vault.database()
                    for try await status in db.observeBackupOfferStatus(walletID: id.uuidString) {
                        guard !Task.isCancelled, backupStatusWalletID == id else { return }
                        backupStatus = (id, status)
                    }
                } catch is CancellationError { }
                catch {
                    if !Task.isCancelled, backupStatusWalletID == id { backupStatus = nil }
                    OathDiagnostics.record(error, component: "wallet", operation: "observe_backup_offer_status")
                }
            }
        }
        .task(id: stablecoinScope) {
            guard !stablecoinScope.isEmpty, let walletID = profile?.id else { return }
            await session.checkStablecoinRestrictions(walletID: walletID, accounts: stablecoinAccounts)
        }
        .onChange(of: nextSecurityNotice, initial: true) { _, _ in
            presentNextSecurityNotice()
        }
        .onChange(of: sheet?.id) { _, id in
            if let id { presentedSheetID = id }
        }
        // A separate asynchronous read of public metadata. Neither initial
        // rendering, wallet import, unlock nor navigation awaits this task.
        .task(id: multisigScope) { await loadMultisigNotice() }
        .task(id: scenePhase == .active && session.isUnlocked) {
            // The keyless scrolling fixture exercises Home and SQL observation,
            // not external relay/push services or their app-group entitlement.
            guard scenePhase == .active, session.isUnlocked, !session.usesSyntheticPortfolio else { return }
            OathWalletConnectService.shared.configure(session: session)
            await OathWalletConnectService.shared.retryDisconnections()
            OathWalletConnectService.shared.resumeRequests()
        }
        .oathScannerCover(isPresented: $showsScanner, onDismiss: {
            if scannedRecipient != nil, session.isUnlocked, !session.changingWallet, !session.resetting {
                sheet = .send
            } else { scannedRecipient = nil }
        }) {
            OathScanner(strings: strings, onPayload: { _ in showsScanner = false },
                onFailure: { _ in showsScanner = false }, onClose: { showsScanner = false },
                title: .scan, identifier: "home.scanner.camera", context: .home,
                onSelectAsset: { result in
                    guard session.isUnlocked, !session.changingWallet, !session.resetting else { showsScanner = false; return }
                    scannedRecipient = result; showsScanner = false
                }).environment(\.oathScanSession, session)
        }
        .oathWalletConnectPresentation(session: session)
        .oathVaultImport(session: session, canPresent: canPresentVaultImport)
        .onChange(of: canPresentWalletLink, initial: true) { _, ready in
            if ready, let entry = OathWalletLinkInbox.shared.take(), case .payment(let recipient) = entry.route {
                paymentLinkActive = true
                scannedRecipient = recipient
                sheet = .send
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if !silentAssetTabSelection || tab != .wallet { OathHaptics.shared.play(.selection) }
            silentAssetTabSelection = false
            if tab == .search { searchPresented = true }
            if tab != .search {
                searchScope = .all
                searchPresented = false
            }
        }
        .task(id: session.isUnlocked) { await prepareDiscoveryCatalog() }
        // Preserve the presenting hierarchy while the native lock covers it.
        .onChange(of: session.changingWallet) { _, changing in
            if changing, case .backup = sheet { sheet = nil }
        }
        .onChange(of: session.selectedHomeAccount?.identity) { _, _ in
            assetPath.removeAll()
            query = ""; historyQuery = ""; historyFilters = .init(); tokenSearch.reset()
        }
        .onChange(of: profile?.id) { previous, id in
            sidebar.walletChanged(to: id?.uuidString, previousWalletIsInTrash:
                session.recentlyDeletedWallets.contains { $0.id == previous?.uuidString })
            searchPresented = false
            if case .backup = sheet { sheet = nil }
            multisigFindings = []
            if sheet?.id == "multisig" { sheet = nil }
            if sheet?.id == "stablecoin" { sheet = nil }
            assetPath.removeAll()
            query = ""; searchScope = .all; historyQuery = ""; historyFilters = .init(); tokenSearch.reset()
            if sheet?.id == "assetFilters" { sheet = nil }
        }
        .sheet(item: $sheet, onDismiss: finishSheetDismissal) { selection in
            Group {
                switch selection {
                case .backup(let id, let offer):
                    OathWalletBackupOfferSheet(walletID: id.uuidString, offer: offer,
                        cloudStatus: backupStatus?.walletID == id ? backupStatus?.cloud : nil, session: session)
                case .stellarMultisigSetup(let walletID):
                    NavigationStack { OathStellarMultisigSetupScreen(session: session, walletID: walletID) }
                case .xrplMultisigSetup(let walletID):
                    NavigationStack { OathXrplMultisigSetupScreen(session: session, walletID: walletID) }
                case .tronMultisigSetup(let walletID):
                    NavigationStack { OathTronMultisigSetupScreen(session: session, walletID: walletID) }
                case .stablecoin(let walletID, let tokens):
                    OathStablecoinRestrictionNotice(tokens: tokens) {
                        try await session.acknowledgeStablecoinSecurity(walletID: walletID)
                        if session.isUnlocked, !session.changingWallet, session.displayedProfile?.id == walletID {
                            sheet = nil
                        }
                    }
                case .multisig(let walletID, let evidence):
                    OathMultisigNotice(evidence: evidence) {
                        try await session.acknowledgeMultisigNotice(walletID: walletID)
                        if session.isUnlocked, !session.changingWallet,
                           session.displayedProfile?.id == walletID, multisigFindingsWalletID == walletID {
                            multisigFindings = []
                            sheet = nil
                        }
                    }
                case .wallets:
                    OathWalletSwitcherSheet(session: session, startsAtAddWallet: true)
                        .environment(settings)
                        .presentationCompactAdaptation(.sheet)
                case .wallet(let destination):
                    walletContent(destination)
                        .presentationDragIndicator(.visible)
                        .presentationCompactAdaptation(.sheet)
                case .send: OathSendFlow(session: session, scannedRecipient: scannedRecipient)
                case .receive: OathReceivePicker(addresses: profile?.addresses ?? [], session: session)
                case .assetFilters:
                    let walletID = profile?.id.uuidString ?? ""
                    OathAssetFilterSheet(session: session, walletID: walletID, currency: assetFilterCurrency,
                                         selection: assetFilters)
                case .address(let address): OathReceiveSheet(address: address, session: session)
                case .priceUntracked:
                    OathWalletInfoSheet(title: .assetPriceUnavailable, icon: "exclamationmark.circle",
                                        detail: .assetPriceUntrackedDetail)
                        .accessibilityIdentifier("asset.priceUntracked.sheet")
                }
            }
            .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
            .oathLanguage(strings.language)
            .environment(\.oathScanSession, session)
        }
        .fullScreenCover(isPresented: $showsAppSettings, onDismiss: resumeCustomization) {
            walletContent(.app)
        }
        .onChange(of: session.isUnlocked, initial: true) { _, unlocked in
            if unlocked { resumeCustomization(); OathWalletConnectService.shared.resumeRequests() }
            else {
                sidebar.invalidate()
                sidebarRemoval.cancel()
                if case .backup = sheet { sheet = nil }
                multisigFindings = []
                if sheet?.id == "multisig" { sheet = nil }
                if sheet?.id == "stablecoin" { sheet = nil }
                if sheet?.id == "assetFilters" { sheet = nil }
            }
        }
        .oathHapticFeedback(.error, trigger: walletActionFailed, when: walletActionFailed)
        .alert(strings.text(.walletUnavailable), isPresented: $walletActionFailed) {
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
        }
        .alert(strings.text(.scan), isPresented: Binding(
            get: { scanError != nil }, set: { if !$0 { scanError = nil } }
        ), presenting: scanError) { error in
            if error == .denied {
                OathButton(strings.text(.openSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
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
        } message: { error in
            Text(strings.text(error.message))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            Task { await OathDiagnostics.attempt("refresh_portfolio") { try await session.refresh() } }
        }
    }

    private func prepareDiscoveryCatalog() async {
        guard session.isUnlocked else { return }
        // Let first presentation settle; catalog work never gates Home.
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        _ = await TokenDiscoveryCatalog.shared.refreshIfNeeded()
    }

    private func loadMultisigNotice() async {
        let scope = multisigScope
        guard !scope.isEmpty, let walletID = profile?.id else { return }
        let noticeState: MultisigNoticeState? = await OathDiagnostics.$operationID.withValue(UUID()) {
            await OathDiagnostics.attempt("load_multisig_notice_acknowledgement") {
                try await session.loadMultisigNoticeState(walletID: walletID)
            }
        }
        guard let noticeState, !Task.isCancelled, scope == multisigScope else { return }
        guard !noticeState.acknowledged else { return }
        let accounts = multisigAccounts
        var findings: [PublicMultisigEvidence] = []
        // At most four concurrent checks, including restored wallets with
        // many public accounts. No request on every balance refresh/frame.
        for start in stride(from: 0, to: accounts.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = Array(accounts[start..<min(start + 4, accounts.count)])
            findings += await withTaskGroup(of: PublicMultisigEvidence?.self) { group in
                for account in batch {
                    group.addTask {
                        if case .confirmed(let evidence) = await Self.multisigCheck.check(account) { return evidence }
                        return nil
                    }
                }
                var result: [PublicMultisigEvidence] = []
                for await item in group { if let item { result.append(item) } }
                return result
            }
        }
        guard !Task.isCancelled, scope == multisigScope else { return }
        multisigFindingsWalletID = walletID
        multisigFindings = findings
            .sorted { ($0.account.chain.rawValue, $0.account.address) < ($1.account.chain.rawValue, $1.account.address) }
    }

    private func finishSheetDismissal() {
        // One slot for both warnings. Acknowledging either must not allow
        // the other to race the outgoing sheet's native animation.
        securityNotices.didDismiss()
        presentedSheetID = nil
        scanError = pendingScanError
        pendingScanError = nil
        scannedRecipient = nil
        if paymentLinkActive {
            paymentLinkActive = false
            OathWalletLinkInbox.shared.didDismiss()
        }
        resumeCustomization()
        presentNextSecurityNotice()
    }

    private var tabs: some View {
        nativeTabs
            .tint(Color(uiColor: OathTabBarStyle.selectedColor))
            .task(id: historyBadgeScope) { await observeHistoryBadge() }
            .onChange(of: selectedTab) { previous, current in
                if previous == .browser, current != .browser { browser?.leaveBrowser() }
            }
            .onChange(of: session.displayedProfile?.id) { browser?.walletChanged() }
            .onChange(of: session.selectedHomeAccount) { browser?.walletChanged() }
            .onChange(of: session.isUnlocked) { if !session.isUnlocked { browser?.locked() } }
    }

    private var historyBadgeScope: String? {
        guard settings.loaded, settings.showsPendingTransactionBadge,
              profile != nil, session.isUnlocked, !session.changingWallet, !session.resetting,
              scenePhase != .background else { return nil }
        return accountScopeIdentity
    }

    private var pendingHistoryCount: Int {
        guard let historyBadge, historyBadge.scope == historyBadgeScope else { return 0 }
        return historyBadge.count
    }

    private func observeHistoryBadge() async {
        guard !Task.isCancelled else { return }
        guard let scope = historyBadgeScope, let walletID = profile?.id else {
            historyBadge = nil
            return
        }
        await OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                let db = try await session.vault.database()
                try Task.checkCancellation()
                for try await count in db.observeHomePendingTransactionCount(walletID: walletID.uuidString) {
                    guard !Task.isCancelled, historyBadgeScope == scope else { return }
                    historyBadge = (scope, count)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), historyBadgeScope == scope else { return }
                historyBadge = nil
                OathDiagnostics.record(error, component: "history", operation: "observe_pending_transaction_count")
            }
        }
    }

    private func browserNavigation(_ controller: OathBrowserController) -> some View {
        OathBrowserRoot(controller: controller, session: session, searchEngine: settings.browserSearchEngine,
                        showsRecentSites: settings.browserShowsRecentSites, active: selectedTab == .browser)
    }

    @ViewBuilder private var nativeTabs: some View {
        if #available(iOS 18, *) {
            TabView(selection: $selectedTab) {
                Tab(value: .wallet) { walletNavigation } label: {
                    tabLabel(.walletTab, symbol: OathTabBarStyle.walletSymbol)
                        .environment(\.symbolVariants, .none)
                }
                .accessibilityLabel(strings.text(.walletTab))
                Tab(value: .history) { historyNavigation } label: {
                    tabLabel(.historyTab, symbol: "clock.arrow.circlepath")
                        .environment(\.symbolVariants, .none)
                }
                .badge(pendingHistoryCount)
                .accessibilityLabel(strings.text(.historyTab))
                if let browser {
                    Tab(value: .browser) { browserNavigation(browser) } label: {
                        tabLabel(.browserTitle, symbol: "safari")
                            .environment(\.symbolVariants, .none)
                    }
                    .accessibilityLabel(strings.text(.browserTitle))
                }
                Tab(value: .search, role: .search) { searchNavigation } label: {
                    tabLabel(.searchTitle, symbol: "magnifyingglass")
                }
                .accessibilityLabel(strings.text(.searchTitle))
            }
            .modifier(OathHomeTabBehavior(browserSelected: selectedTab == .browser))
        } else {
            TabView(selection: $selectedTab) {
                walletNavigation.tabItem {
                    Label(strings.text(.walletTab), systemImage: OathTabBarStyle.walletSymbol)
                }.tag(OathHomeTab.wallet)
                historyNavigation.tabItem {
                    Label(strings.text(.historyTab), systemImage: "clock.arrow.circlepath")
                        .environment(\.symbolVariants, .none)
                }.tag(OathHomeTab.history)
                .badge(pendingHistoryCount)
                if let browser {
                    browserNavigation(browser).tabItem {
                        Label(strings.text(.browserTitle), systemImage: "safari")
                            .environment(\.symbolVariants, .none)
                    }.tag(OathHomeTab.browser)
                }
                searchNavigation.tabItem {
                    Label(strings.text(.searchTitle), systemImage: "magnifyingglass")
                }.tag(OathHomeTab.search)
            }
        }
    }

    @ViewBuilder private func tabLabel(_ title: OathStringKey, symbol: String) -> some View {
        if #available(iOS 26, *) {
            Image(systemName: symbol)
        } else {
            Label(strings.text(title), systemImage: symbol)
        }
    }

    private var walletNavigation: some View {
        NavigationStack(path: $assetPath) {
            homeContent
                .background(OathSearchTabTransition())
                .background {
                    // Track native Home readiness once, independently of the
                    // offer/claim and any animation inside the page.
                    Color.clear.frame(width: 0, height: 0)
                        .oathAfterAppearance(waitForContentAnimations: false) {
                            homeHasAppeared = true
                            presentNextSecurityNotice()
                        }
                        .onDisappear { homeHasAppeared = false }
                }
                // Asset details hide the tab bar. Restore it as part of the
                // pop transition, before Home's viewport sizes its header.
                .toolbar(.visible, for: .tabBar)
                .toolbar { homeToolbar }
                .oathNativeAppBar()
                .navigationDestination(for: OathAssetRoute.self) { route in
                    OathAssetDetailScreen(route: route, session: session).oathLanguage(strings.language)
                }
        }
        .walletRefreshNavigation()
        .tint(nil)
        .overlay(alignment: .top) { OathHomeAddressCopyBanner(asset: $copiedAsset) }
        .onChange(of: addressCopyScope) { clearAddressCopy() }
        .onDisappear { clearAddressCopy() }
    }

    private var historyNavigation: some View {
        NavigationStack {
            walletHistory(query: historyQuery, visible: historyVisible)
                .searchable(text: $historyQuery, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Text(strings.text(.searchTransactions)))
                .toolbar(.visible, for: .tabBar)
        }
        // Discard pushed receipts when the wallet or account changes.
        .id(accountScopeIdentity)
        .tint(nil)
    }

    private var searchNavigation: some View {
        NavigationStack {
            Group {
                if selectedTab == .search {
                    let request = tokenSearchRequest
                    let rows = searchRows
                    OathEmptyStateScrollView(centersContent: rows.isEmpty && tokenSearch.results.isEmpty) {
                        assetList(searching: true, values: rows, request: request)
                            .padding(.horizontal, 20).padding(.bottom, 20)
                            .frame(maxWidth: 700).frame(maxWidth: .infinity)
                    }
                    .task(id: request) { await tokenSearch.search(request) }
                    .id(searchScope)
                } else { Color.clear }
            }
            .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
            .navigationTitle(strings.text(.assets))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(OathHomeAssetSearch(query: $query, scope: $searchScope,
                isPresented: $searchPresented, selectedTab: $selectedTab))
            .oathNativeLocalization()
        }
        .id(accountScopeIdentity)
        .tint(Color(uiColor: .label))
    }

    @ViewBuilder private func walletHistory(query: String, visible: Bool) -> some View {
        if let walletID = profile?.id.uuidString {
            OathHomeHistoryContent(walletID: walletID, session: session, query: query, isVisible: visible,
                                   filters: $historyFilters)
                .id(walletID)
        }
    }

    private var homeContent: some View {
        ScrollViewReader { scroll in
            GeometryReader { geometry in
                let visibleHoldings = portfolioPresentation.layout
                // The native bars own the safe area. The scroll viewport starts
                // below navigation, without a second inset or a toolbar spacer.
                OathWalletRefreshScroll(identifier: "home.scroll", colorHex: currentWallet?.colorHex,
                    timing: .fixed(.seconds(2)),
                    isEnabled: session.isUnlocked && !session.changingWallet && selectedTab == .wallet
                        && assetPath.isEmpty,
                    refreshIdentity: profile?.id.uuidString, action: {
                    #if DEBUG && targetEnvironment(simulator)
                    if session.usesSyntheticPortfolio {
                        try await session.refresh()
                        return
                    }
                    #endif
                    // Coalesced with foreground refresh and independent of the
                    // selected currency. Failed FX updates preserve cached rates.
                    async let rates = await OathExchangeRateEnvironment.shared.refresh()
                    try await session.refresh()
                    _ = await rates
                }, onScroll: { toolbarBalance.scroll(to: $0) }) {
                    OathHeaderScrollContent(viewportHeight: geometry.size.height, fillsViewport: visibleHoldings.isEmpty,
                                           headerSpacing: 0) {
                        summary()
                    } content: {
                        OathEmptyStateLayout(centersContent: visibleHoldings.isEmpty) {
                            VStack(spacing: 0) {
                                if currentWallet?.kind == "tronMultisig", let walletID = currentWallet?.id {
                                    OathButton { sheet = .tronMultisigSetup(walletID) } label: {
                                        OathSettingsRow(title: strings.text(.multisigTronSetup), icon: "signature",
                                            subtitle: strings.text(.multisigTronHomeDetail))
                                    }.buttonStyle(OathSettingsRowButtonStyle())
                                }
                                if currentWallet?.kind == "stellarMultisig", let walletID = currentWallet?.id {
                                    OathButton { sheet = .stellarMultisigSetup(walletID) } label: {
                                        OathSettingsRow(title: strings.text(.multisigStellarSetup), icon: "signature",
                                            subtitle: strings.text(.multisigStellarHomeDetail))
                                    }.buttonStyle(OathSettingsRowButtonStyle())
                                }
                                if currentWallet?.kind == "xrplMultisig", let walletID = currentWallet?.id {
                                    OathButton { sheet = .xrplMultisigSetup(walletID) } label: {
                                        OathSettingsRow(title: strings.text(.multisigXrplSetup), icon: "signature",
                                            subtitle: strings.text(.multisigXrplHomeDetail))
                                    }.buttonStyle(OathSettingsRowButtonStyle())
                                }
                                if portfolioPresentation.hasPrepared && portfolioPresentation.eligibleAssetCount > 0 {
                                    assetsHeader.padding(.bottom, 16)
                                }
                            }
                            if visibleHoldings.isEmpty || !portfolioPresentation.hasPrepared {
                                assetList(searching: false, values: visibleHoldings)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, visibleHoldings.isEmpty ? 20 : 0)
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: "home.summary.content")
                    .id("home.summary")
                    // Each asset is a native reusable row. Nesting the complete
                    // LazyVStack inside one List cell would eagerly build it all.
                    if portfolioPresentation.hasPrepared && !visibleHoldings.isEmpty {
                        assetRows(searching: false, values: visibleHoldings)
                        Color.clear.frame(height: 20)
                    }
                }
                // Keep the balance Text alive across snapshots. Wallet changes reset the scroll position.
                .onChange(of: accountScopeIdentity) { _, _ in
                    toolbarBalance.reset()
                    scroll.scrollTo("home.summary", anchor: .top)
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.home")
    }

    private func walletContent(_ destination: SettingsDestination) -> some View {
        OathWalletSettingsScreen(session: session, destination: destination)
            .presentationDetents([.large])
            .environment(settings)
            .oathLanguage(strings.language)
            .environment(\.oathScanSession, session)
    }

    private func resumeCustomization() {
        guard session.isUnlocked, !sidebar.isVisible, !sidebarRemovalActive, !showsAppSettings,
              sheet == nil, session.pendingCustomizationID != nil else { return }
        sheet = .wallets
    }

    private var sidebarEnabled: Bool {
        // A verified unlock can precede Face ID's finishing animation. Do not
        // discard a delivered tap/swipe while SwiftUI still reports inactive.
        sidebar.allowsInteraction(isUnlocked: session.isUnlocked, isBackgrounded: scenePhase == .background,
            resetting: session.resetting, removingWallet: sidebarRemovalActive,
            hasPresentedScreen: sheet != nil || showsAppSettings || showsScanner ||
                OathWalletConnectService.shared.presentationOpen)
    }

    private var sidebarContainer: some View {
        SidebarContainer(isPresented: Binding(get: { sidebar.isPresented }, set: { sidebar.setPresented($0) }),
            isEnabled: sidebarEnabled, allowsOpeningSwipe: !session.changingWallet && assetPath.isEmpty && !historyVisible,
            closeLabel: strings.text(.close), onWillOpen: sidebarWillOpen, onFeedback: { feedback in
                guard sidebarEnabled else { return }
                switch feedback {
                case .prepare(let open): OathHaptics.shared.prepare(open ? .expand : .collapse)
                case .impact(let open):
                    if sidebar.isVisible { OathHaptics.shared.play(open ? .expand : .collapse) }
                }
            }, onDismiss: sidebarDidDismiss) {
            tabs
                .environment(\.oathWalletSidebar, sidebarContext)
                .environment(\.oathScanSession, session)
                .environment(\.oathLanguage, strings.language)
                .environment(settings)
        } sidebar: {
            OathWalletSidebar(session: session, model: sidebar, balances: sidebarBalances, onSelect: selectSidebarWallet, onSelectAccount: selectSidebarAccount,
                onConfirmRemoval: { id in
                    guard sidebar.isPresented, sidebarEnabled, scenePhase == .active, !sidebarRemovalActive else { return }
                    sidebarRemoval.moveConfirmedWalletToRecentlyDeleted(id, reason: strings.text(.walletRemovalAuthentication))
                })
                .environment(\.oathLanguage, strings.language)
                .environment(settings)
        }
    }

    private var sidebarContext: OathWalletSidebarContext {
        // The mounted toolbar observes wallet availability directly. Interruption
        // and modal state only decide whether Home can present the drawer now.
        OathWalletSidebarContext(session: session, walletName: session.walletName(currentWallet, strings: strings),
            isVisible: sidebar.isVisible,
            open: {
                guard sidebarEnabled, !session.changingWallet else { return }
                sidebar.open(walletID: profile?.id.uuidString, searchFocused: selectedTab == .search && searchPresented)
                searchPresented = false
            })
    }

    private func sidebarWillOpen() {
        sidebar.willOpen(walletID: profile?.id.uuidString, searchFocused: selectedTab == .search && searchPresented)
        searchPresented = false
    }

    private func sidebarDidDismiss() {
        switch sidebar.didDismiss(walletID: session.displayedProfile?.id.uuidString,
            searchStillSelected: selectedTab == .search, isUnlocked: sidebarEnabled) {
        case .restoreSearch: searchPresented = true
        case .navigate(.wallet(let action, let id)):
            guard !session.changingWallet, session.wallets.contains(where: { $0.id == id }) else { return }
            sheet = .wallet(.sidebar(action, id))
        case .navigate(.recentlyDeleted): sheet = .wallet(.recentlyDeleted)
        case .navigate(.addWallet): sheet = .wallets
        case .navigate(.security): sheet = .wallet(.sidebarSecurity)
        case .navigate(.settings): showsAppSettings = true
        case .navigate(.support): openURL(OathSupportLinks.help)
        case .navigate(.contactSupport): openURL(OathSupportLinks.contact)
        case .none: break
        }
    }

    private var accountScopeIdentity: String {
        (profile?.id.uuidString ?? "") + ":" + (session.selectedHomeAccount?.identity ?? "all")
    }

    private func selectSidebarWallet(_ id: String) { selectSidebarAccount(id, selection: nil) }

    private func selectSidebarAccount(_ id: String, selection: HomeAccountSelection?) {
        sidebar.select(id, currentID: session.selectedHomeAccount == selection ? session.displayedProfile?.id.uuidString : nil,
            isValid: { id in session.isUnlocked && !session.resetting && session.wallets.contains { $0.id == id } },
            actualID: { session.selectedHomeAccount == selection ? session.displayedProfile?.id.uuidString : nil }, operation: { id in
                guard let uuid = UUID(uuidString: id) else { throw CancellationError() }
                try await OathDiagnostics.$operationID.withValue(UUID()) {
                    try await session.selectWalletAccount(uuid, selection: selection)
                }
            }, report: { _ in
                // selectWallet/changeWallet already reports the original failure
                // and reconciles committed selection. Do not upload it twice.
            })
    }

    private var homeToolbar: some ToolbarContent {
        OathHomeToolbar(walletName: session.walletName(currentWallet, strings: strings),
            balance: { totalBalance }, balanceAvailable: session.hasObservedHomeBalance,
            concealed: balancesHidden, scrollState: toolbarBalance,
            actionsEnabled: profile != nil && session.isUnlocked && !session.changingWallet && !session.resetting) {
            guard profile != nil, session.isUnlocked, !session.changingWallet, !session.resetting else { return }
            scannedRecipient = nil
            showsScanner = true
        }
    }

    private var totalBalance: String {
        if !portfolioPresentation.total.isEmpty { return portfolioPresentation.total }
        let currency = portfolioPresentation.currency
        let amount = OathAssetAmounts(native: nil, fiat: nil, currencyCode: currency)
        return String(OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: currency).fiat(amount).characters)
    }

    private func summary() -> some View {
        OathWalletSummary(topInset: 16, bottomInset: 0) {
            OathButton(action: toggleBalancesHidden) {
                OathWalletBalance(value: totalBalance, concealed: balancesHidden, fontWeight: .bold)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(.totalBalance))
            .accessibilityValue(balancesHidden ? strings.text(.balanceHidden)
                : session.hasObservedHomeBalance ? totalBalance : strings.text(.sendBalanceUnknown))
            .accessibilityHint(strings.text(.hideBalance))
            .accessibilityIdentifier("home.balance")
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("home.summary.content")).maxY
            } action: { toolbarBalance.measureBalanceBottom($0) }
        } detail: {
            OathBalanceChangePill(session: session, visible: balanceHistoryVisible)
        } send: {
            sendAction
        } receive: {
            receiveAction
        }
    }

    private func toggleBalancesHidden() {
        Task {
            do { try await session.toggleBalancesHidden() }
            catch { OathDiagnostics.record(error); walletActionFailed = true }
        }
    }

    private var receiveAction: some View {
        OathActionButton(title: strings.text(.receive), icon: "qrcode", appearance: .wallet) {
            sheet = .receive
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.receive")
    }

    private var sendAction: some View {
        OathActionButton(title: strings.text(.send), icon: "paperplane", appearance: .wallet) {
            sheet = .send
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.send")
    }

    private var assetsHeader: some View {
        HStack(spacing: 12) {
            Text(strings.text(.assets))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            OathAssetsFilterButton(activeCount: assetFilters.activeCount,
                isEnabled: session.isUnlocked && !session.changingWallet && profile != nil) {
                    sheet = .assetFilters
                }
        }
    }

    private func assetList(searching: Bool, values visibleHoldings: [OathHomeRowLayout],
                           request: OathTokenSearchRequest? = nil) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            if !portfolioPresentation.hasPrepared {
                ProgressView().tint(.secondary).frame(maxWidth: .infinity)
            } else if !searching && visibleHoldings.isEmpty {
                let hasAssets = portfolioPresentation.eligibleAssetCount > 0
                if hasAssets {
                    OathEmptyState(title: strings.text(.assetFilterNoResults),
                        systemImage: "line.3.horizontal.decrease",
                        description: strings.text(.assetFilterNoResultsDetail)) {
                        OathButton(strings.text(.historyResetFilters), feedback: .selection) {
                            guard let walletID = profile?.id.uuidString else { return }
                            let editor = session.assetFilterEditor(walletID: walletID, currency: assetFilterCurrency,
                                                                  selection: assetFilters)
                            editor.reset()
                            Task {
                                await editor.waitForPendingSave()
                                if editor.saveFailed { walletActionFailed = true }
                            }
                        }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .tint(Color(uiColor: .systemGray))
                            .foregroundStyle(.primary)
                            .oathFont(.body, weight: .medium)
                            .accessibilityIdentifier("home.assetFilters.reset")
                    }
                } else {
                    OathEmptyState(strings.text(.assetFilterNoAssets), systemImage: "tray.and.arrow.down",
                                   description: strings.text(.assetFilterNoAssetsDetail))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("home.empty.assets")
                }
            } else if searching && visibleHoldings.isEmpty && request?.showsCatalogResults != true {
                OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                               description: strings.format(.noSearchResultsDetail, query))
            } else {
                LazyVStack(spacing: 0) {
                    assetRows(searching: searching, values: visibleHoldings)
                }
                .padding(.horizontal, -20)
            }
            if let request, request.showsCatalogResults {
                OathTokenSearchResults(model: tokenSearch, session: session, walletID: request.walletID,
                    active: request.active, hasSavedMatches: !visibleHoldings.isEmpty,
                    balancesHidden: balancesHidden, permittedNetworks: request.networks, onSelected: { holding, snapshot in
                        searchPresented = false
                        query = ""
                        assetPath = [OathAssetRoute(walletID: snapshot.wallet.id, holding: holding)]
                        silentAssetTabSelection = selectedTab != .wallet
                        selectedTab = .wallet
                    }, retry: { tokenSearchAttempt += 1 })
                    .padding(.horizontal, -20)
            }
        }
    }

    private func assetRows(searching: Bool, values: [OathHomeRowLayout]) -> some View {
        let firstID = values.first?.id
        return ForEach(values) { entry in
            // Exactly one concrete List child, including synthetic network headings.
            OathHomeListCell {
                if entry.heading {
                    OathAssetTreeRow(entry: entry) { OathAssetTreeHeading(chain: entry.chain) }
                        .frame(maxWidth: 700).frame(maxWidth: .infinity)
                } else if let cell = portfolioPresentation.cell(entry.id) {
                    assetRow(searching: searching, presentation: cell.value,
                             showsSeparator: !entry.isChild && entry.id != firstID, entry: entry)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !searching && !entry.heading {
                    OathButton(feedback: nil) {
                        guard let snapshot = session.portfolio, snapshot.wallet.id == portfolioPresentation.walletID,
                              let item = portfolioPresentation.latestHolding(entry.id) else { return }
                        let walletID = snapshot.wallet.id
                        Task {
                            await OathDiagnostics.$chain.withValue(item.networkID) {
                                await OathDiagnostics.$operationID.withValue(UUID()) {
                                    do { try await session.setAssetHidden(true, assetID: item.assetID, walletID: walletID) }
                                    catch is CancellationError { /* Wallet switch or lock. */ }
                                    catch {
                                        OathDiagnostics.record(error, component: "asset_visibility", operation: "hide")
                                        walletActionFailed = true
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(strings.text(.hideAsset), systemImage: "eye.slash")
                    }
                    .buttonStyle(.automatic)
                    .tint(.gray)
                    .accessibilityIdentifier("home.asset.hide")
                }
            }
        }
    }

    private func assetRow(searching: Bool, presentation: OathHomeAssetPresentation,
                          showsSeparator: Bool, entry: OathHomeRowLayout) -> some View {
        let item = presentation.holding
        let chain = entry.chain
        return OathButton(feedback: nil) {
            guard let snapshot = session.portfolio, snapshot.wallet.id == profile?.id.uuidString,
                  let current = snapshot.holdings.first(where: { $0.id == item.id }) else { return }
            let walletID = snapshot.wallet.id
            let route = OathAssetRoute(walletID: walletID, holding: current)
            if searching {
                // End the native search session, not just keyboard focus.
                // Home owns the detail so both Back and interactive pop
                // return to normal browsing, never the search controller.
                searchPresented = false
                query = ""
                assetPath = [route]
                silentAssetTabSelection = selectedTab != .wallet
                selectedTab = .wallet
            } else {
                assetPath.append(route)
            }
        } label: {
            OathAssetTreeRow(entry: entry) {
                OathHomeAssetRow(chain: chain, presentation: presentation,
                    balancesHidden: balancesHidden, showsSeparator: showsSeparator, isSearchResult: searching)
                    .equatable()
                    #if DEBUG && targetEnvironment(simulator)
                    .background {
                        if OathHomeScrollFixture.verifiesRows {
                            OathScrollRowWitness(display: presentation.nativeSummary)
                        }
                    }
                    #endif
            }
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityIdentifier(item.reference == "native" ? "home.network.\(item.networkID)" : "home.token.\(item.assetID)")
        .oathUntrackedPriceAction(enabled: !searching && presentation.unitPrice == nil) { sheet = .priceUntracked }
        .homeCopyAddressAction(enabled: !searching, label: strings.text(.copyAddress)) {
            copyReceiveAddress(for: item.id)
        }
        .frame(maxWidth: searching ? .infinity : 700)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }

    private func copyReceiveAddress(for holdingID: String) {
        guard let scope = addressCopyScope, let snapshot = session.portfolio,
              snapshot.wallet.id == session.displayedProfile?.id.uuidString,
              let holding = snapshot.holdings.first(where: { $0.id == holdingID }),
              let chain = OathImportChain(rawValue: holding.networkID) else { return }
        let walletID = snapshot.wallet.id
        let network = snapshot.networks.first { $0.id == holding.networkID }
        let confirmation = OathHomeCopiedAsset(holding: holding, networkName: network?.name ?? chain.name,
                                              networkLogo: network?.logo ?? chain.logoAsset)
        let vault = session.vault
        addressCopyTask?.cancel()
        addressCopyTask = Task { @MainActor in
            await OathDiagnostics.$chain.withValue(chain.id) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let database = try await vault.database()
                        let address = try await OathReceivePreparation.copyPayload(
                            for: holding, walletID: walletID, database: database,
                            prepareBitcoin: { try await vault.prepareBitcoin(accountID: holding.accountID) },
                            prepareSolana: { try await vault.solanaReceiveState(accountID: holding.accountID) })
                        try Task.checkCancellation()
                        guard addressCopyScope == scope, session.displayedProfile?.id.uuidString == walletID else { return }
                        OathClipboard.copy(address)
                        copiedAsset = confirmation
                    } catch is CancellationError {
                        // Another press or leaving Home supersedes the request.
                    } catch {
                        guard !Task.isCancelled, addressCopyScope == scope else { return }
                        OathDiagnostics.record(error, component: "receive", operation: "copy_home_address")
                        copiedAsset = nil
                        walletActionFailed = true
                    }
                }
            }
        }
    }

    private func clearAddressCopy() {
        addressCopyTask?.cancel()
        addressCopyTask = nil
        copiedAsset = nil
    }
}

private struct OathHomeListCell<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(spacing: 0, content: content) }
}

/// View context changes independently of database commits. Raw snapshots are
/// delivered by the session so no portfolio revision is observed by Home.
private struct OathHomePortfolioUpdates: View {
    let session: OathWalletSession
    let query: String
    let active: Bool
    @Environment(\.oathLocalizer) private var strings

    private struct Trigger: Equatable {
        let query: String
        let locale: String
        let active: Bool
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: Trigger(query: query,
                                  locale: strings.language.locale.identifier, active: active), initial: true) {
                session.homePortfolio.configure(query: query,
                    formattingLocale: strings.language.locale.identifier, active: active)
            }
    }
}

/// Activity initializes its model from a saved session snapshot. Construct it
/// inside its own body so those reads cannot subscribe the parent Home/List to
/// every portfolio commit, including while History is hidden.
private struct OathHomeHistoryContent: View {
    let walletID: String
    let session: OathWalletSession
    let query: String
    let isVisible: Bool
    @Binding var filters: OathHistoryFilterSelection

    var body: some View {
        OathChainActivityScreen(walletID: walletID, session: session, query: query, isVisible: isVisible,
            filterSelection: $filters)
    }
}

struct OathHomeNetworkRow: View {
    let address: OathWalletAddress
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathSettingsRow(title: strings.invariant(address.networkName), icon: "network",
            value: strings.invariant(address.ticker),
            subtitle: strings.invariant(String(address.address.prefix(8)) + "…" + String(address.address.suffix(6))),
            networkLogo: address.logo)

    }
}
