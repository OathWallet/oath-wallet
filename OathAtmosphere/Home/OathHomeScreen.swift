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
    }

    private var sidebarRemovalActive: Bool { sidebarRemoval.action != nil || sidebarRemoval.notice != nil }
    // A committed offer waits here if another sheet takes priority before presentation.
    @State private var claimedBackupOffers: [UUID: WalletBackupOffer] = [:]
    @State private var backupStatus: (walletID: UUID, cloud: WalletCloudBackupStatus)?
    private var backupStatusWalletID: UUID? {
        guard scenePhase != .background, session.isUnlocked, !session.changingWallet, !session.resetting else { return nil }
        if case .backup(let id, _) = sheet { return id }
        guard let id = profile?.id else { return nil }
        return claimedBackupOffers[id] != nil || currentWallet?.pendingBackupOffer != nil ? id : nil
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
    @State private var showsAppSettings = false
    @State private var scanError: OathRecoveryScanError?
    @State private var pendingScanError: OathRecoveryScanError?
    @State private var pendingWalletDestination: WalletDestination?
    @State private var scrollEffects = OathHomeScrollEffects()
    @State private var query = ""
    @State private var searchScope: OathAssetSearchScope = .all
    @State private var historyQuery = ""
    @State private var historyFilters = OathHistoryFilterSelection()
    private var assetFilters: PortfolioFilter {
        portfolioPresentation.filter.adjusted(for: assetFilterCurrency)
    }
    private var portfolioPresentation: OathHomePortfolioModel { session.homePortfolio }
    @State private var selectedTab: OathHomeTab = .wallet
    @State private var browserTabs = OathBrowserSession(makePage: OathBrowserModel.init)
    @State private var silentAssetTabSelection = false
    @State private var searchContext: OathHomeTab = .wallet
    @State private var searchPresented = false
    @State private var tokenSearch = OathTokenSearchModel()
    @State private var tokenSearchAttempt = 0
    private var tokenSearchRequest: OathTokenSearchRequest {
        var request = OathTokenSearchRequest(query: query, walletID: profile?.id.uuidString,
            active: session.isUnlocked && !session.changingWallet && !session.resetting
                && selectedTab == .search && searchContext == .wallet,
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
    private var walletColorHex: String? {
        currentWallet?.colorHex
    }
    @State private var walletActionFailed = false

    private enum Sheet: Identifiable {
        case wallets, send, receive, address(OathWalletAddress), assetFilters, tronMultisigSetup(String), evmMultisigSetup(String), solanaMultisigSetup(String), xrplMultisigSetup(String), stellarMultisigSetup(String)
        case wallet(WalletDestination)
        case backup(UUID, WalletBackupOffer)
        case multisig(UUID, [PublicMultisigEvidence])
        case stablecoin(UUID, [StablecoinRestrictionToken])
        case priceUntracked
        var id: String {
            switch self {
            case .wallets: "wallets"
            case .wallet(.add(let start)): "additionalWallet-" + start.id
            case .wallet(.settings(let destination)): "walletSettings-" + destination.id
            case .send: "send"
            case .receive: "receive"
            case .assetFilters: "assetFilters"
            case .priceUntracked: "priceUntracked"
            case .xrplMultisigSetup: "xrplMultisigSetup"
            case .stellarMultisigSetup: "stellarMultisigSetup"
            case .evmMultisigSetup: "evmMultisigSetup"
            case .solanaMultisigSetup: "solanaMultisigSetup"
            case .tronMultisigSetup: "tronMultisigSetup"
            case .backup(let id, _): "backup-" + id.uuidString
            case .multisig: "multisig"
            case .stablecoin: "stablecoin"
            case .address(let address): address.id
            }
        }
    }

    private typealias SettingsDestination = OathWalletSettingsScreen.Destination

    private enum WalletDestination {
        case add(OathAdditionalWalletDestination)
        case settings(SettingsDestination)
    }

    private var searchBinding: Binding<String> {
        searchContext == .history ? $historyQuery : $query
    }
    private var searchPrompt: String {
        strings.text(searchContext == .history ? .searchTransactions : .searchAssets)
    }
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
        guard shouldPreparePortfolio, let profile else { return "" }
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
        guard shouldPreparePortfolio, let profile else { return "" }
        return profile.id.uuidString + stablecoinAccounts.map { "|\($0.network):\($0.address)" }.joined()
    }
    private var nextSecurityNotice: WalletSecurityNoticeQueue.Notice? {
        let state = profile.flatMap { session.stablecoinSecurityStates[$0.id] }
        let available = balanceHistoryVisible && !searchPresented && scannedRecipient == nil && pendingWalletDestination == nil &&
            session.pendingCustomizationID == nil && !OathWalletConnectService.shared.needsPresentation &&
            OathWalletLinkInbox.shared.pending == nil
        return securityNotices.next(walletID: profile?.id, homeAvailable: available,
            multisigPending: hasPendingMultisigNotice,
            stablecoinPending: state.map { !$0.acknowledged && !$0.restricted.isEmpty } == true,
            backupPending: visibleBackupOffer != nil &&
                lockCoverHidden && !session.presentsOnboarding && portfolioPresentation.hasPrepared &&
                !walletActionFailed && scanError == nil && OathVaultImportInbox.shared.pending == nil &&
                OathVaultImportInbox.shared.active == nil)
    }
    private func presentNextSecurityNotice(afterHomeAppearance: Bool = false) {
        // Re-evaluate current wallet/navigation state instead of presenting a
        // candidate captured before a wallet switch or another modal opened.
        guard let next = nextSecurityNotice else { return }
        switch next.kind {
        case .backup:
            guard afterHomeAppearance else { return }
            if let offer = claimedBackupOffers[next.walletID] {
                guard securityNotices.begin(next) else { return }
                sheet = .backup(next.walletID, offer)
                claimedBackupOffers.removeValue(forKey: next.walletID)
            } else {
                Task {
                    let offer = await OathDiagnostics.$operationID.withValue(UUID()) {
                        await OathDiagnostics.attemptOptional("claim_backup_offer") {
                            let db = try await session.vault.database()
                            return try await db.claimBackupOffer(walletID: next.walletID.uuidString)
                        }
                    }
                    if let offer { claimedBackupOffers[next.walletID] = offer }
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
        if shouldPreparePortfolio, selectedTab != .history, let walletID = profile?.id.uuidString {
            let currency = assetFilterCurrency
            let locale = strings.language.locale.identifier
            Color.clear.task(id: "\(walletID):\(currency):\(locale)") {
                await session.observeHomeHistory(walletID: walletID, currency: currency, localeIdentifier: locale)
            }
        }
    }

    var body: some View {
        sidebarContainer
        .disabled(sidebarRemovalActive)
        .allowsHitTesting(!sidebarRemovalActive)
        .modifier(OathSidebarRemovalPresentation(session: session, removal: sidebarRemoval))
        .tint(Color(uiColor: .label))
        .background {
            // This narrow observation boundary consumes checkpoint/timestamp
            // updates without rebuilding tabs, navigation and the scroll host.
            OathHomePortfolioUpdates(session: session, query: query, active: shouldPreparePortfolio)
                .background { savedHistoryUpdates }
        }
        .environment(\.oathScanSession, session)
        .task(id: sidebarBalances.scope(session: session).joined(separator: "|") + assetFilterCurrency) {
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
        // A separate asynchronous read of public metadata. Neither initial
        // rendering, wallet import, unlock nor navigation awaits this task.
        .task(id: multisigScope) { await loadMultisigNotice() }
        .task(id: scenePhase == .active && session.isUnlocked) {
            guard scenePhase == .active, session.isUnlocked else { return }
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
            if tab == .search && searchContext == .wallet { searchPresented = true }
            if tab != .search {
                searchScope = .all
                searchPresented = false
                if tab == .wallet || tab == .history { searchContext = tab }
            }
        }
        .task(id: session.isUnlocked) {
            guard session.isUnlocked else { return }
            // Let the first Home frame and wallet navigation settle. Catalog
            // download/indexing live on their own actor and never gate Home.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            _ = await TokenDiscoveryCatalog.shared.refreshIfNeeded()
        }
        // Preserve the presenting hierarchy while the native lock covers it.
        .onChange(of: session.changingWallet) { _, changing in
            if changing, case .backup = sheet { sheet = nil }
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
                case .evmMultisigSetup(let walletID):
                    NavigationStack { OathEVMMultisigSetupScreen(session: session, walletID: walletID) }
                case .solanaMultisigSetup(let walletID):
                    NavigationStack { OathSolanaMultisigSetupScreen(session: session, walletID: walletID) }
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
                    OathWalletSwitcherSheet(session: session, startsAtAddWallet: true,
                        onCreate: { continueFromWalletSwitcher(.add(.create($0))) },
                        onCreated: { continueFromWalletSwitcher(.add(.customize($0))) },
                        onCustomize: { continueFromWalletSwitcher(.settings(.customize($0))) })
                        .environment(settings)
                        .presentationCompactAdaptation(.sheet)
                case .wallet(let destination):
                    walletContent(destination)
                        .presentationDetents([.large])
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
            .oathLanguage(strings.language)
            .environment(\.oathScanSession, session)
        }
        .fullScreenCover(isPresented: $showsAppSettings, onDismiss: resumeCustomization) {
            walletContent(.settings(.app))
        }
        .onChange(of: session.isUnlocked, initial: true) { _, unlocked in
            if unlocked { resumeCustomization(); OathWalletConnectService.shared.resumeRequests() }
            else {
                sidebar.invalidate()
                sidebarRemoval.cancel()
                pendingWalletDestination = nil
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
        scanError = pendingScanError
        pendingScanError = nil
        scannedRecipient = nil
        if paymentLinkActive {
            paymentLinkActive = false
            OathWalletLinkInbox.shared.didDismiss()
        }
        // Present the next native flow only after the switcher has finished
        // dismissing so UIKit can start the next sheet presentation.
        finishWalletSwitcherDismissal()
    }

    private var tabs: some View {
        nativeTabs.tint(Color(uiColor: OathTabBarStyle.selectedColor))
            .modifier(OathBrowserTabBehavior(visible: selectedTab == .browser))
            // The owner observes wallet lifecycle even when SwiftUI has not
            // mounted the Browser tab. Inactive tabs must not retain old-wallet
            // website sessions behind a different selected app tab.
            .onChange(of: session.isUnlocked) { _, value in if !value { clearBrowserSession() } }
            .onChange(of: session.changingWallet) { _, value in if value { clearBrowserSession() } }
            .onChange(of: session.resetting) { _, value in if value { clearBrowserSession() } }
            .onChange(of: session.displayedProfile?.id) { _, _ in clearBrowserSession() }
            .onChange(of: selectedTab) { _, value in
                if value != .browser { browserTabs.setActive(false) }
            }
    }

    private func clearBrowserSession() {
        browserTabs.setActive(false)
        browserTabs.reset()
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
                }
                .accessibilityLabel(strings.text(.historyTab))
                Tab(value: .browser) { OathBrowserScreen(session: session, tabs: browserTabs, selected: selectedTab == .browser) } label: {
                    Image(systemName: "globe")
                }
                .accessibilityLabel(strings.text(.browserTitle))
                Tab(value: .search, role: .search) { searchNavigation } label: {
                    tabLabel(.searchTitle, symbol: "magnifyingglass")
                }
                .accessibilityLabel(strings.text(.searchTitle))
            }
            .modifier(OathSearchTabActivation())
        } else {
            TabView(selection: $selectedTab) {
                walletNavigation.tabItem {
                    Label(strings.text(.walletTab), systemImage: OathTabBarStyle.walletSymbol)
                }.tag(OathHomeTab.wallet)
                historyNavigation.tabItem {
                    Label(strings.text(.historyTab), systemImage: "clock.arrow.circlepath")
                }.tag(OathHomeTab.history)
                OathBrowserScreen(session: session, tabs: browserTabs, selected: selectedTab == .browser).tabItem {
                    Image(systemName: "globe").accessibilityLabel(strings.text(.browserTitle))
                }.tag(OathHomeTab.browser)
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
                    if let candidate = nextSecurityNotice, candidate.kind == .backup {
                        Color.clear.frame(width: 0, height: 0)
                            .oathAfterAppearance {
                                guard candidate == nextSecurityNotice else { return }
                                presentNextSecurityNotice(afterHomeAppearance: true)
                            }
                            .id(claimedBackupOffers[candidate.walletID])
                            .id(candidate.walletID)
                    }
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
        .tint(nil)
    }

    private var historyNavigation: some View {
        NavigationStack {
            walletHistory(query: "", visible: selectedTab == .history, showsWalletSidebar: true)
        }
        // The stack owns pushed receipts even when this tab is inactive.
        // Replacing only its root list leaves the previous wallet's receipt open.
        .id(profile?.id)
        .tint(nil)
    }

    private var searchNavigation: some View {
        NavigationStack {
            Group {
                if searchContext == .history {
                    walletHistory(query: historyQuery, visible: selectedTab == .search)
                } else {
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
            }
        }
        // History search can also retain a pushed transaction across tab changes.
        .id(profile?.id)
        .tint(Color(uiColor: .label))
        .modifier(OathHomeSearchField(query: searchBinding, isPresented: $searchPresented, prompt: searchPrompt, isEnabled: searchContext == .history))
    }

    @ViewBuilder private func walletHistory(query: String, visible: Bool, showsWalletSidebar: Bool = false) -> some View {
        if let walletID = profile?.id.uuidString {
            OathChainActivityScreen(walletID: walletID, session: session, query: query, isVisible: visible,
                                    filterSelection: $historyFilters, showsWalletSidebar: showsWalletSidebar)
                .id(walletID)
        }
    }

    private var homeContent: some View {
        GeometryReader { geometry in
            let visibleHoldings = portfolioPresentation.layout
            // The native bars own the safe area. The scroll viewport starts
            // below navigation, without a second inset or a toolbar spacer.
            NativeRefreshScroll(identifier: "home.scroll", tint: .white,
                                indicator: .progressRing, timing: .brief,
                                labels: NativeRefreshLabels(pull: strings.text(.pullToRefresh),
                                    refreshing: strings.text(.refreshing),
                                    succeeded: strings.text(.refreshSucceeded), failed: strings.text(.refreshFailed)),
                                isEnabled: session.isUnlocked && !session.changingWallet,
                                refreshIdentity: profile?.id.uuidString, action: {
                // Coalesced with foreground refresh and independent of the
                // selected currency. Failed FX updates preserve cached rates.
                async let rates = await OathExchangeRateEnvironment.shared.refresh()
                try await session.refresh()
                _ = await rates
            }, onFailure: {}, onScroll: { _ in },
                onDraggingChanged: { scrollEffects.setDragging($0) },
                onPresentationChanged: { scrollEffects.setRefreshing($0) },
                feedback: { event in
                    switch event {
                    case .pullStep: OathHaptics.shared.play(.selection)
                    case .started: OathHaptics.shared.play(.refresh)
                    case .succeeded: OathHaptics.shared.play(.success)
                    case .finished: OathHaptics.shared.play(.success)
                    case .failed: OathHaptics.shared.play(.error)
                    }
                }) {
                OathHeaderScrollContent(viewportHeight: geometry.size.height, fillsViewport: visibleHoldings.isEmpty) {
                    summary()
                } content: {
                    OathEmptyStateLayout(centersContent: visibleHoldings.isEmpty) {
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
                        assetsHeader.padding(.bottom, 16)
                        if visibleHoldings.isEmpty || !portfolioPresentation.hasPrepared {
                            assetList(searching: false, values: visibleHoldings)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, visibleHoldings.isEmpty ? 20 : 0)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                // Each asset is a native reusable row. Nesting the complete
                // LazyVStack inside one List cell would eagerly build it all.
                if portfolioPresentation.hasPrepared && !visibleHoldings.isEmpty {
                    assetRows(searching: false, values: visibleHoldings)
                    Color.clear.frame(height: 20)
                }
            }
            // A different wallet starts at its balance header, including when
            // creation replaces the wallet under the switcher/customization.
            // The backup offer's appearance gate then runs above the new list.
            // Same-wallet balance updates keep the user's scroll position.
            .id(strings.language.isRightToLeft)
            .id(profile?.id)
            .modifier(OathWalletHeaderBackground(
                animates: session.isUnlocked && !sidebar.isVisible && !showsAppSettings && sheet == nil && !showsScanner
                        && !OathWalletConnectService.shared.presentationOpen && assetPath.isEmpty && selectedTab == .wallet,
                colorHex: walletColorHex, effects: scrollEffects))
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.home")
    }

    private func walletContent(_ destination: WalletDestination) -> some View {
        Group {
            switch destination {
            case .settings(let start): OathWalletSettingsScreen(session: session, destination: start)
            case .add(let start): OathAdditionalWalletFlow(session: session, start: start)
            }
        }
        // The native presenter can have a separate environment on iOS-on-Mac.
        .environment(settings)
        .oathLanguage(strings.language)
        .environment(\.oathScanSession, session)
    }

    private func resumeCustomization() {
        guard session.isUnlocked, !sidebar.isVisible, !sidebarRemovalActive, !showsAppSettings,
              sheet == nil, pendingWalletDestination == nil, let id = session.pendingCustomizationID else { return }
        sheet = .wallet(.add(.customize(id)))
    }

    private func continueFromWalletSwitcher(_ destination: WalletDestination) {
        guard session.isUnlocked, case .wallets = sheet,
              pendingWalletDestination == nil else { return }
        pendingWalletDestination = destination
        sheet = nil
    }

    private func finishWalletSwitcherDismissal() {
        guard let destination = pendingWalletDestination else { resumeCustomization(); return }
        pendingWalletDestination = nil
        guard session.isUnlocked, !showsAppSettings, sheet == nil else { return }
        if case .settings(let start) = destination {
            // A wallet can be removed while the switcher is dismissing.
            guard let id = start.walletID, session.wallets.contains(where: { $0.id == id }) else { return }
        }
        sheet = .wallet(destination)
    }

    private var sidebarEnabled: Bool {
        // A system authentication prompt may temporarily make an open scene inactive.
        session.isUnlocked && !session.resetting && scenePhase != .background &&
        (sidebar.isPresented || (scenePhase == .active && !sidebarRemovalActive)) &&
        sheet == nil && !showsAppSettings && !showsScanner &&
        !OathWalletConnectService.shared.presentationOpen
    }

    private var sidebarContainer: some View {
        SidebarContainer(isPresented: Binding(get: { sidebar.isPresented }, set: { sidebar.setPresented($0) }),
            isEnabled: sidebarEnabled, allowsOpeningSwipe: !session.changingWallet && assetPath.isEmpty,
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
            OathWalletSidebar(session: session, model: sidebar, balances: sidebarBalances, onSelect: selectSidebarWallet,
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
            sheet = .wallet(.settings(.sidebar(action, id)))
        case .navigate(.recentlyDeleted): sheet = .wallet(.settings(.recentlyDeleted))
        case .navigate(.addWallet): sheet = .wallets
        case .navigate(.security): sheet = .wallet(.settings(.sidebarSecurity))
        case .navigate(.settings): showsAppSettings = true
        case .navigate(.support): openURL(OathSupportLinks.help)
        case .navigate(.contactSupport): openURL(OathSupportLinks.contact)
        case .none: break
        }
    }

    private func selectSidebarWallet(_ id: String) {
        sidebar.select(id, currentID: session.displayedProfile?.id.uuidString,
            isValid: { id in session.isUnlocked && !session.resetting && session.wallets.contains { $0.id == id } },
            actualID: { session.displayedProfile?.id.uuidString }, operation: { id in
                guard let uuid = UUID(uuidString: id) else { throw CancellationError() }
                try await OathDiagnostics.$operationID.withValue(UUID()) {
                    try await session.selectWallet(uuid)
                }
            }, report: { _ in
                // selectWallet/changeWallet already reports the original failure
                // and reconciles committed selection.
            })
    }

    private var homeToolbar: some ToolbarContent {
        OathHomeToolbar(onScan: {
            guard session.isUnlocked, !session.changingWallet else { return }
            scannedRecipient = nil; showsScanner = true
        })
    }

    private var totalBalance: String {
        if !portfolioPresentation.total.isEmpty { return portfolioPresentation.total }
        let currency = portfolioPresentation.currency
        let amount = OathAssetAmounts(native: nil, fiat: nil, currencyCode: currency)
        return String(OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: currency).fiat(amount).characters)
    }

    private func summary() -> some View {
        OathWalletSummary {
            OathButton(action: toggleBalancesHidden) {
                OathWalletBalance(value: totalBalance, concealed: balancesHidden, title: strings.text(.totalBalance))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(.totalBalance))
            .accessibilityValue(balancesHidden ? strings.text(.balanceHidden) : totalBalance)
            .accessibilityHint(strings.text(.hideBalance))
            .accessibilityIdentifier("home.balance")
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
        OathActionButton(title: strings.text(.receive), icon: "qrcode", appearance: .secondary, foreground: .white) {
            sheet = .receive
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.receive")
    }

    private var sendAction: some View {
        OathActionButton(title: strings.text(.send), icon: "paperplane", appearance: .secondary, foreground: .white) {
            sheet = .send
        }
        .disabled(profile == nil)
        .accessibilityIdentifier("home.send")
    }

    private var assetsHeader: some View {
        HStack {
            Text(strings.text(.assets))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            OathAssetsToolbar(activeCount: assetFilters.activeCount,
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
                OathEmptyState(title: strings.text(assetFilters.activeCount > 0 ? .assetFilterNoResults : .assetFilterNoAssets),
                    systemImage: assetFilters.activeCount > 0 ? "line.3.horizontal.decrease" : "square.stack.3d.up",
                    description: strings.text(assetFilters.activeCount > 0 ? .assetFilterNoResultsDetail : .assetFilterNoAssetsDetail)) {
                    if assetFilters.activeCount > 0 {
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
            }
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityIdentifier(item.reference == "native" ? "home.network.\(item.networkID)" : "home.token.\(item.assetID)")
        .oathUntrackedPriceAction(enabled: !searching && presentation.unitPrice == nil) { sheet = .priceUntracked }
        .frame(maxWidth: searching ? .infinity : 700)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }
}

private struct OathHomeListCell<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { VStack(spacing: 0, content: content) }
}

/// Observe raw database snapshots here, outside the expensive Home hierarchy.
/// The presentation model publishes only changed display values, immediately
/// after its background builder finishes (no timer or UI refresh throttling).
private struct OathHomePortfolioUpdates: View {
    let session: OathWalletSession
    let query: String
    let active: Bool
    @Environment(\.oathLocalizer) private var strings

    private struct Trigger: Equatable {
        let revision: UInt64
        let query: String
        let locale: String
        let active: Bool
    }

    private var input: OathHomePortfolioInput {
        let snapshot = session.portfolio
        let currency = snapshot?.currency ?? "USD"
        return .init(walletID: snapshot?.wallet.id, holdings: snapshot?.holdings ?? [],
            currency: currency, total: snapshot?.totalFiat ?? .zero,
            filter: (snapshot?.assetFilter ?? .init()).adjusted(for: currency), query: query,
            formattingLocale: strings.language.locale.identifier,
            sortingLocale: strings.language.locale.identifier, hiddenAssetIDs: snapshot?.hiddenAssetIDs ?? [])
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: Trigger(revision: session.portfolioRevision, query: query,
                                  locale: strings.language.locale.identifier, active: active), initial: true) {
                if active { session.homePortfolio.update(input) }
            }
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
