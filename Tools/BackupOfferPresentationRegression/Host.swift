import Foundation

// Boundary fakes. Home's actual scheduling, eligibility and cloud-status
// policy are inserted by the runner, rather than copied into the assertions.
@MainActor final class Database {
    var calls = 0
    var pending: [String: WalletBackupOffer] = [:]
    var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    var fails = false
    func claimBackupOffer(walletID: String) async throws -> WalletBackupOffer? {
        calls += 1
        await withCheckedContinuation { continuations[walletID] = $0 }
        if fails { throw CocoaError(.fileWriteUnknown) }
        return pending.removeValue(forKey: walletID)
    }
    func finish(_ id: UUID) { continuations.removeValue(forKey: id.uuidString)?.resume() }
}
@MainActor struct Vault {
    let db: Database
    func database() async throws -> Database { db }
}
struct Restriction { var acknowledged = false; var restricted: [Int] = [] }
@MainActor final class Session {
    let vault: Vault
    var isUnlocked = true, changingWallet = false, resetting = false, presentsOnboarding = false
    var pendingCustomizationID: String?
    var stablecoinSecurityStates: [UUID: Restriction] = [:]
    init(_ db: Database) { vault = Vault(db: db) }
}
@MainActor final class OathWalletConnectService {
    static let shared = OathWalletConnectService()
    var needsPresentation = false, presentationOpen = false
}
@MainActor final class OathWalletLinkInbox {
    static let shared = OathWalletLinkInbox()
    var pending: Int?
}
@MainActor final class OathVaultImportInbox {
    static let shared = OathVaultImportInbox()
    var pending: Int?, active: Int?
}
enum OathDiagnostics {
    @TaskLocal static var operationID: UUID?
    @MainActor static func attemptOptional<T>(_ operation: String, _ action: () async throws -> T?) async -> T? {
        do { return try await action() } catch { return nil }
    }
}
struct Profile { let id: UUID }
struct Wallet { var pendingBackupOffer: WalletBackupOffer? }
struct Sidebar { var isVisible = false }
enum Phase { case active, inactive, background }
enum Tab { case wallet, explore }
enum Sheet: Equatable {
    case backup(UUID, WalletBackupOffer), multisig(UUID, [Int]), stablecoin(UUID, [Int]), editor
}
@MainActor final class Home {
    let session: Session
    var profile: Profile?
    var currentWallet: Wallet?
    var scenePhase = Phase.active
    var selectedTab = Tab.wallet
    var lockCoverHidden = true
    var assetPath: [Int] = []
    var showsHistory = false
    var showsAppSettings = false
    var sidebarRemovalActive = false
    var sidebar = Sidebar()
    var showsScanner = false
    var searchPresented = false
    var walletActionFailed = false
    var scannedRecipient: Int?
    var pendingWalletDestination: Int?
    var scanError: Int?
    var hasPendingMultisigNotice = false
    var multisigFindings: [Int] = []
    var securityNotices = WalletSecurityNoticeQueue()
    var sheet: Sheet?

    // PRODUCTION_SCHEDULING

    init(offer: WalletBackupOffer = .cloudOrManual) {
        let db = Database()
        session = Session(db)
        select(UUID(), offer: offer)
    }
    func select(_ id: UUID, offer: WalletBackupOffer) {
        profile = Profile(id: id)
        currentWallet = Wallet(pendingBackupOffer: offer)
        backupStatus = (id, .unconfirmed)
        session.vault.db.pending[id.uuidString] = offer
    }
    func dismiss() {
        sheet = nil
        presentedSheetID = nil
        securityNotices.didDismiss()
        presentNextSecurityNotice()
    }
}

@main struct Check {
    @MainActor static func main() async {
        for offer in [WalletBackupOffer.cloudOrManual, .cloudOnly, .manualOnly] {
            let home = Home(offer: offer)
            let id = home.profile!.id
            home.presentNextSecurityNotice()
            await drain()
            precondition(home.session.vault.db.calls == 0, "Do not consume before native Home appears")
            home.homeHasAppeared = true
            home.presentNextSecurityNotice()
            await drain()
            for _ in 0..<200 { home.presentNextSecurityNotice() }
            await drain()
            precondition(home.session.vault.db.calls == 1, "Coalesce updates during the asynchronous claim")
            // Simulate the wallet observation arriving before claim completion.
            home.currentWallet?.pendingBackupOffer = nil
            precondition(home.backupStatusWalletID == id, "Keep local status observation alive during claim")
            home.session.vault.db.finish(id)
            await drain()
            precondition(home.sheet == .backup(id, offer), "Claim completion must present without a second appearance")
            precondition(home.shouldPreparePortfolio, "Opening backup must not suspend background wallet work")
            home.dismiss()
            for _ in 0..<200 { home.presentNextSecurityNotice() }
            await drain()
            precondition(home.sheet == nil && home.session.vault.db.calls == 1, "Dismissal must not repeat the offer")
        }

        let home = Home()
        home.homeHasAppeared = true
        let id = home.profile!.id
        home.presentedSheetID = "create-import-editor"
        home.presentNextSecurityNotice()
        await drain()
        precondition(home.session.vault.db.calls == 0, "Wait for actual editor dismissal, not just a nil sheet binding")
        home.dismiss()
        await drain()
        precondition(home.session.vault.db.calls == 1)
        home.session.changingWallet = true
        home.session.vault.db.finish(id)
        await drain()
        precondition(home.sheet == nil && home.claimedBackupOffers[id] != nil, "Retain a claim if another flow wins")
        let other = UUID()
        home.select(other, offer: .cloudOnly)
        home.session.changingWallet = false
        home.presentNextSecurityNotice()
        await drain()
        home.session.vault.db.finish(other)
        await drain()
        precondition(home.sheet == .backup(other, .cloudOnly), "Never present a claim for the previous wallet")
        home.currentWallet?.pendingBackupOffer = nil
        home.dismiss()
        home.profile = Profile(id: id)
        home.backupStatus = (id, .unconfirmed)
        home.presentNextSecurityNotice()
        precondition(home.sheet == .backup(id, .cloudOrManual), "Resume the deferred claim when its wallet returns")

        let failed = Home()
        failed.homeHasAppeared = true
        failed.session.vault.db.fails = true
        failed.presentNextSecurityNotice()
        await drain()
        failed.session.vault.db.finish(failed.profile!.id)
        await drain()
        precondition(failed.sheet == nil && failed.claimingBackupOffers.isEmpty)
        failed.session.vault.db.fails = false
        failed.presentNextSecurityNotice()
        await drain()
        failed.session.vault.db.finish(failed.profile!.id)
        await drain()
        precondition(failed.sheet != nil, "A failed local write retains eligibility for retry")

        for blocked in 0..<9 {
            let home = Home()
            home.homeHasAppeared = true
            switch blocked {
            case 0: home.scenePhase = .inactive
            case 1: home.session.isUnlocked = false
            case 2: home.lockCoverHidden = false
            case 3: home.selectedTab = .explore
            case 4: home.session.pendingCustomizationID = "fixture"
            case 5: home.session.presentsOnboarding = true
            case 6: home.showsScanner = true
            case 7: home.assetPath = [1]
            default: home.session.resetting = true
            }
            home.presentNextSecurityNotice()
            await drain()
            precondition(home.session.vault.db.calls == 0, "Unavailable Home cannot consume its reminder")
        }
        print("PASS: created/imported offers, delayed SQL/observation ordering, 200 duplicate events, immediate completion, dismissal barrier, wallet switch, retry, once-only delivery and background-work independence")
    }
    @MainActor static func drain() async {
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
}
