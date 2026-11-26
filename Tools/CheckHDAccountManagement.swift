import Foundation
import CryptoKit
import OathDatabase
import OathCloudBackup

/// Production session, vault and database. Only key derivation is synthetic.
@main struct CheckHDAccountManagement {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        for family in HDAccountFamily.allCases {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oath-account-management-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let db = try await OathDatabase.open(at: dir.appendingPathComponent("wallet.sqlite"))
            try await OathDataEnvironment.seed(db)
            let storage = WalletMemory(), biometrics = MemoryBiometrics()
            let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
            let pin: [UInt8] = [8,6,2,9,1,4]
            try await vault.create(digits: pin, importing: .init(phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", language: "english"))
            let session = OathWalletSession(vault: vault)
            await session.finishedSetup()
            let id = session.displayedProfile!.id
            let original = try await db.accounts(walletID: id.uuidString)
            let originalAddresses = session.displayedProfile!.addresses
            let path = family == .evm ? "m/44'/60'/0'/0/1" : "m/44'/501'/1'/0'"
            let custom = family == .evm ? "m/44'/60'/7'/0/0" : "m/44'/501'/7'/9'"
            try await session.addHDAccounts(walletID: id.uuidString, family: family, paths: [path, custom])
            let before = try await db.accounts(walletID: id.uuidString)
            let selection = HomeAccountSelection(family: family, path: path)
            func remove(_ selection: HomeAccountSelection) async throws {
                let grant = try await vault.authorizeHDAccountRemoval(walletID: id.uuidString,
                    selection: selection, digits: pin, reason: "Synthetic account removal")
                try await session.removeHDAccount(walletID: id.uuidString, selection: selection, authorization: grant)
            }
            checks += try await checkRemovalAuthentication(session: session, vault: vault, db: db,
                biometrics: biometrics, walletID: id.uuidString, selection: selection, pin: pin)

            try await db.renameHDAccount(walletID: id.uuidString, selection: selection, name: "Trading")
            var names = db.observeHDAccounts(family: family).makeAsyncIterator()
            let renamed = try await names.next()
            check(renamed?[id.uuidString]?.first { $0.path == path }?.name == "Trading", "Renaming is observed without changing identity")
            try await session.selectWalletAccount(id, selection: selection)
            let portfolio = session.portfolio!
            let addresses = session.displayedProfile!.addresses
            check(Set(addresses.map(\.chain)) == Set(originalAddresses.map(\.chain)), "Account selection preserves every original supported wallet network")
            check(original.filter { !family.owns(network: $0.networkID) }.allSatisfy { portfolio.accounts.contains($0) }, "Other chains retain exact public accounts and derivation paths")
            check(originalAddresses.filter { !family.owns(network: $0.chain.id) }.allSatisfy { addresses.contains($0) }, "Receive profile retains every unrelated address")
            check(addresses.filter { family.owns(network: $0.chain.id) }.allSatisfy { $0.path == path }, "Receive profile uses only the chosen path for the selected family")
            for chain in Set(originalAddresses.map(\.chain)) {
                let request = OathTokenSearchRequest(query: "", walletID: id.uuidString, active: true, snapshot: portfolio,
                    permittedNetworks: Set(addresses.map(\.chain)), scope: .init(chain: chain))
                check(request.active && request.networks == [chain], "Receive/Send search scope retains an original network")
            }
            try await remove(selection)
            let after = try await db.accounts(walletID: id.uuidString)
            check(after == before.filter { !selection.matches(network: $0.networkID, path: $0.derivationPath) }, "Only selected family/path removed")
            check(session.displayedProfile?.id == id && session.selectedHomeAccount == nil, "Removing selected account returns to its wallet")
            let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
            check(envelope.version == 30, "Removal journal requires supported vault version")
            let key = try envelope.key(for: pin)
            let secret = try envelope.openContents(using: key).activeWallets.first!
            check(secret.removedHDAccounts == [selection], "Encrypted removal journal persisted")
            check(try secret.derivationAccounts().allSatisfy { !selection.matches(network: $0.network, path: $0.derivationPath) }, "Derivation excludes removed account")
            let data = try await vault.encryptedCloudBackup(walletID: id.uuidString, password: "synthetic-backup-password")
            let backup = try BackupDocument.open(data, password: "synthetic-backup-password")
            check(backup.accounts.allSatisfy { !selection.matches(network: $0.network, path: $0.derivationPath) }, "New backup reflects removed accounts")
            // Simulate a crash after encrypted commit, before public removal.
            let wallet = try await db.wallet(id.uuidString)!
            try await db.importWalletIfNeeded(wallet, accounts: before)
            await session.lock(); await session.unlock(pin)
            check(try await db.accounts(walletID: id.uuidString) == after, "Unlock replays committed removal")
            try await session.addHDAccounts(walletID: id.uuidString, family: family, paths: [path])
            check(try await db.accounts(walletID: id.uuidString) == before, "Re-add restores original account IDs and indices")
            var restoredNames = db.observeHDAccounts(family: family).makeAsyncIterator()
            check(try await restoredNames.next()?[id.uuidString]?.first { $0.path == path }?.name == "Trading", "Re-added account keeps its name")
            // A failed encrypted write must not delete public accounts.
            let writeFailureGrant = try await vault.authorizeHDAccountRemoval(walletID: id.uuidString,
                selection: selection, digits: pin, reason: "Synthetic account removal")
            storage.rejectNextUpdate()
            do { try await session.removeHDAccount(walletID: id.uuidString, selection: selection, authorization: writeFailureGrant); preconditionFailure("Storage failure ignored") }
            catch { check(try await db.accounts(walletID: id.uuidString) == before, "Failed vault commit preserves accounts") }
            try await remove(selection)
            let basePath = before.first { family.owns(network: $0.networkID) && $0.accountIndex == 0 }!.derivationPath
            try await remove(.init(family: family, path: basePath))
            let last = HomeAccountSelection(family: family, path: custom)
            do { try await remove(last); preconditionFailure("Last account removed") }
            catch { check(error as? OathDatabase.AccountManagementError == .lastAccount, "Vault refuses last account") }
            do { try await db.removeHDAccount(walletID: id.uuidString, selection: last); preconditionFailure("DB removed last account") }
            catch { check(error as? OathDatabase.AccountManagementError == .lastAccount, "Database independently refuses last account") }
            await session.lock(); await session.unlock(pin)
            let remaining = try await db.accounts(walletID: id.uuidString)
            check(Set(remaining.filter { family.owns(network: $0.networkID) }.map(\.derivationPath)) == [custom], "Removed base account does not reappear on unlock")
            check(session.portfolio?.accounts.contains { family.owns(network: $0.networkID) && $0.derivationPath == custom } == true, "Wallet root falls back to remaining account")
            try await session.addHDAccounts(walletID: id.uuidString, family: family, paths: [basePath])
            check(try await db.accounts(walletID: id.uuidString).contains { family.owns(network: $0.networkID) && $0.derivationPath == basePath && $0.accountIndex == 0 }, "Removed original path can be restored")
            let otherID = try await session.addPassphraseWallet(sourceID: id.uuidString, passphrase: "synthetic extension", requestID: UUID())
            try await remove(last)
            check(session.displayedProfile?.id.uuidString == otherID, "Removing from another wallet does not switch active wallet")
            await session.lock()
        }
        print("HD account management host checks passed: \(checks) (synthetic derivation; no network or device)")
    }
    @MainActor static func checkRemovalAuthentication(session: OathWalletSession, vault: OathWalletVault,
        db: OathDatabase, biometrics: MemoryBiometrics, walletID: String,
        selection: HomeAccountSelection, pin: [UInt8]) async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func wait(_ predicate: () async -> Bool) async throws {
            for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
            preconditionFailure("Account removal authentication timed out")
        }
        func rejects(line: UInt = #line, _ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure("Unauthorized account removal accepted at test line \(line)") }
            catch { checks += 1 }
        }
        func authorize() async throws -> UUID {
            try await vault.authorizeHDAccountRemoval(walletID: walletID, selection: selection,
                digits: pin, reason: "Synthetic account removal")
        }
        let original = try await db.accounts(walletID: walletID)
        let model = OathHDAccountRemovalModel(session: session)
        func begin() { model.begin(walletID: walletID, selection: selection, reason: "Synthetic account removal") }
        func restore() async throws {
            check(model.phase == .removed, "Successful authentication removes the confirmed account")
            check(try await db.accounts(walletID: walletID) == original.filter {
                !selection.matches(network: $0.networkID, path: $0.derivationPath)
            }, "Authenticated removal changes only the selected family/path")
            try await session.addHDAccounts(walletID: walletID, family: selection.family, paths: [selection.path])
            model.cancel()
        }

        await rejects { _ = try await vault.removeHDAccount(walletID: walletID, selection: selection, authorization: UUID()) }
        begin(); try await wait { model.phase == .passcode }
        check(try await db.accounts(walletID: walletID) == original, "No enrollment requires app PIN without removing anything")
        model.submit([0,0,0,0,0,0]); try await wait { !model.busy }
        check(model.phase == .passcode && model.notice == .unlockIncorrect, "Wrong app PIN stays on passcode")
        check(try await db.accounts(walletID: walletID) == original, "Wrong PIN preserves accounts")
        model.cancel()
        check(model.phase == .idle, "Back cancels removal authorization")
        begin(); try await wait { model.phase == .passcode }
        model.submit(pin); try await wait { model.phase == .removed }; try await restore()

        let grant = try await authorize()
        await rejects { _ = try await vault.removeHDAccount(walletID: UUID().uuidString, selection: selection, authorization: grant) }
        let otherPath = original.first { selection.family.owns(network: $0.networkID) && $0.derivationPath != selection.path }!.derivationPath
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID,
            selection: .init(family: selection.family, path: otherPath), authorization: grant) }
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID,
            selection: .init(family: selection.family == .evm ? .solana : .evm, path: selection.path), authorization: grant) }
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID, selection: selection,
            authorization: grant, clock: .now.advanced(by: .seconds(121))) }
        await vault.cancelHDAccountRemovalAuthorization(grant)
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID, selection: selection, authorization: grant) }
        let used = try await authorize()
        try await session.removeHDAccount(walletID: walletID, selection: selection, authorization: used)
        try await session.addHDAccounts(walletID: walletID, family: selection.family, paths: [selection.path])
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID, selection: selection, authorization: used) }
        let locked = try await authorize()
        await session.lock(); await session.unlock(pin)
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID, selection: selection, authorization: locked) }
        let changed = try await authorize()
        let security = try await vault.authorizeSecurityChange(digits: pin)
        try await vault.setPasscode(pin, authorization: security)
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID, selection: selection, authorization: changed) }
        check(try await db.accounts(walletID: walletID) == original, "Rejected grants leave membership unchanged")

        await biometrics.allowEnrollment()
        _ = try await vault.enableBiometrics(strings: .current)
        let reads = await biometrics.reads
        begin(); try await wait { model.phase == .removed }
        check(await biometrics.reads == reads + 1, "Enabled biometrics require a fresh protected credential read")
        try await restore()
        for error: OathBiometricCredentialError in [.cancelled, .unavailable, .missing] {
            await biometrics.failNextRead(error)
            begin(); try await wait { model.phase == .passcode }
            check(try await db.accounts(walletID: walletID) == original, "Biometric failure never removes the account")
            model.cancel()
        }
        await biometrics.failNextRead(.cancelled)
        begin(); try await wait { model.phase == .passcode }
        model.submit(pin); try await wait { model.phase == .removed }; try await restore()

        await biometrics.pauseNextRead()
        begin(); try await wait { await biometrics.isWaiting }
        model.cancel(); await biometrics.releaseRead()
        // Barrier through the actor plus a bounded yield for the delayed UI task.
        _ = try await vault.securityState()
        try await Task.sleep(for: .milliseconds(50))
        check(model.phase == .idle && !model.busy, "Cancelled authentication ignores a late biometric success")
        check(try await db.accounts(walletID: walletID) == original, "Late biometric success preserves account")

        let policyGrant = try await authorize()
        let staleCredential = try await vault.biometricCredential()
        try await vault.disableBiometrics()
        await rejects { _ = try await vault.removeHDAccount(walletID: walletID, selection: selection, authorization: policyGrant) }
        await biometrics.enroll(staleCredential)
        let disabledReads = await biometrics.reads
        begin(); try await wait { model.phase == .passcode }
        check(await biometrics.reads == disabledReads, "Disabled biometrics do not prompt, even with stale enrollment")
        model.cancel()

        let disabling = try await vault.authorizeSecurityChange(digits: pin)
        try await vault.setPasscode(nil, authorization: disabling)
        let unprotectedReads = await biometrics.reads
        begin(); try await wait { model.phase == .removed }
        check(await biometrics.reads == unprotectedReads, "Both protections disabled removes after confirmation without auth")
        try await restore()
        try await vault.setPasscode(pin, authorization: nil)
        return checks
    }
}
