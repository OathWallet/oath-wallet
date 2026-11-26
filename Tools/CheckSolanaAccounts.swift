import Foundation
import CryptoKit
import OathDatabase
import OathCloudBackup

/// Production vault, encrypted storage, SQL and session; host derivation is synthetic.
@main struct CheckSolanaAccounts {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oath-solana-accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,6,2,9,1,4]
        try await vault.create(digits: pin, importing: .init(phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", language: "english"))
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let id = session.displayedProfile!.id
        let base = try await db.accounts(walletID: id.uuidString)
        let path = "m/44'/501'/1'/0'", custom = "m/44'/501'/7'/9'"
        try await session.addHDAccounts(walletID: id.uuidString, family: .solana, paths: [path, custom])
        let all = try await db.accounts(walletID: id.uuidString)
        let groups = EVMAccountGroup.grouped(all, networks: ["solana"])
        check(groups.count == 3 && groups.map(\.index) == [0,1,2], "Three numbered Solana accounts")
        check(base.allSatisfy { all.contains($0) }, "Existing public accounts are unchanged")
        check(groups[1].accounts.count == 1, "Account contains only Solana")
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let key = try envelope.key(for: pin)
        let contents = try envelope.openContents(using: key)
        check(envelope.version == 29, "Old clients must reject unsupported account metadata")
        check(contents.activeWallets.first?.additionalSolanaAccounts?.map(\.path) == [path,custom], "Encrypted metadata preserves exact paths")
        try await session.addHDAccounts(walletID: id.uuidString, family: .solana, paths: [path])
        let retried = try await db.accounts(walletID: id.uuidString)
        check(retried == all, "Retry is idempotent")
        try await session.selectWalletAccount(id, selection: .init(family: .solana, path: custom))
        check(session.portfolio?.accounts.filter { $0.networkID == "solana" }.allSatisfy { $0.derivationPath == custom } == true, "Home uses the selected Solana path")
        check(session.displayedProfile?.addresses.filter { $0.chain == .solana }.allSatisfy { $0.path == custom } == true, "Receive uses the selected Solana path")
        check(base.filter { $0.networkID != "solana" }.allSatisfy { session.portfolio?.accounts.contains($0) == true }, "Other chains retain their original accounts")
        let selected = session.portfolio!.accounts.first { $0.networkID == "solana" }!
        let receive = try await vault.solanaReceiveState(accountID: selected.id)
        check(receive.addresses.count == 1 && receive.selected.path == custom, "Custom Solana account cannot change to another derivation path")
        let standard = all.first { $0.networkID == "solana" && $0.derivationPath == path }!
        let standardReceive = try await vault.solanaReceiveState(accountID: standard.id)
        check(standardReceive.addresses.count == 1 && standardReceive.selected.path == path, "Default added account owns exactly its path")
        do {
            try await session.addHDAccounts(walletID: id.uuidString, family: .solana, paths: ["m/44'/501'/0'"])
            preconditionFailure("Created an overlapping legacy receive address")
        } catch { check(error is HDAccountDerivation.ValidationError, "Legacy alternate receive path cannot become a duplicate account") }
        do {
            try await session.addHDAccounts(walletID: id.uuidString, family: .solana, paths: ["m/44'/501'/3'/0"])
            preconditionFailure("Accepted nonhardened Ed25519 path")
        } catch { check(error is HDAccountDerivation.ValidationError, "Reject nonhardened paths before deriving") }
        let backup = try await vault.encryptedCloudBackup(walletID: id.uuidString, password: "synthetic-backup-password")
        let restored = try BackupDocument.open(backup, password: "synthetic-backup-password")
        check(restored.accounts.filter { $0.solanaPathOnly == true }.count == 2, "Backup preserves independent-account receive policy")
        check(restored.accounts.count == all.count, "Backup includes every account even while Home is scoped")
        check(restored.accounts.contains { $0.derivationPath == custom }, "Custom paths survive portable backup")
        let importedBackup = try OathRestoredWallet(backup: restored)
        check(try importedBackup.secret.derivationAccounts().count == all.count, "Restore validates and preserves every saved path")
        check(importedBackup.profile.addresses.count == all.count, "Restore reconstructs every account")
        let recoveryDB = try await OathDatabase.open(at: dir.appendingPathComponent("recovery.sqlite"))
        try await OathDataEnvironment.seed(recoveryDB)
        let recoveryStorage = WalletMemory()
        let recoveryVault = OathWalletVault(storage: recoveryStorage, biometricStore: MemoryBiometrics(), database: recoveryDB)
        try await recoveryVault.createRestoredWallet(digits: pin, restoration: importedBackup)
        let recovered = try await recoveryDB.accounts(walletID: id.uuidString)
        check(Set(recovered.map(\.derivationPath)) == Set(all.map(\.derivationPath)), "Restore into an empty vault keeps all paths")
        let restoredAccount = recovered.first { $0.networkID == "solana" && $0.derivationPath == custom }!
        let restoredReceive = try await recoveryVault.solanaReceiveState(accountID: restoredAccount.id)
        check(restoredReceive.addresses.count == 1 && restoredReceive.selected.path == custom, "Portable restore preserves the exact receive address")
        let recoveredEnvelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: recoveryStorage.read("vault-v1")!)
        check(recoveredEnvelope.version == 29, "Restored single-path policy remains protected against older clients")
        let recoveredSession = OathWalletSession(vault: recoveryVault)
        await recoveredSession.finishedSetup(); await recoveredSession.lock(); await recoveredSession.unlock(pin)
        check(recoveredSession.isUnlocked, "Restored version 29 unlocks after restart")
        let reopenedReceive = try await recoveryVault.solanaReceiveState(accountID: restoredAccount.id)
        check(reopenedReceive == restoredReceive, "Restored account retains its receive policy after unlock")

        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.selectedAccount == .init(family: .solana, path: custom), "Account selection survives lock and reopen")
        try await session.selectWallet(id)
        check(session.portfolio?.accounts.count == base.count, "Selecting root restores only original accounts")
        storage.rejectNextUpdate()
        do { try await session.addHDAccounts(walletID: id.uuidString, family: .solana, paths: ["m/44'/501'/2'/0'"]); preconditionFailure("Failed encrypted save accepted") }
        catch { check(session.isUnlocked, "Failed save recovers usable session") }
        let afterFailure = try await db.accounts(walletID: id.uuidString)
        check(afterFailure == all, "Failed encrypted save cannot add public accounts")
        await session.lock()
        try await db.deleteWalletMetadata(id.uuidString)
        await session.unlock(pin)
        let repaired = try await db.accounts(walletID: id.uuidString)
        check(repaired == all, "Encrypted metadata repairs missing public rows on unlock")
        DerivationGate.shared.arm()
        let pending = Task { try await session.addHDAccounts(walletID: id.uuidString, family: .solana, paths: ["m/44'/501'/2'/0'"]) }
        for _ in 0..<1000 {
            if DerivationGate.shared.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(DerivationGate.shared.isWaiting, "Derivation is off the UI actor")
        await session.lock(); DerivationGate.shared.release()
        do { try await pending.value; preconditionFailure("Late derivation committed after lock") }
        catch { check(error is CancellationError, "Lock cancels pending account addition") }
        await session.unlock(pin)
        let afterLock = try await db.accounts(walletID: id.uuidString)
        check(afterLock == all, "Cancelled account is never persisted")
        let passphraseID = try await session.addPassphraseWallet(sourceID: id.uuidString, passphrase: "synthetic extension", requestID: UUID())
        try await session.addHDAccounts(walletID: passphraseID, family: .solana, paths: [path])
        let passphraseEnvelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let passphraseContents = try passphraseEnvelope.openContents(using: key)
        check(passphraseContents.activeWallets.first { $0.id.uuidString == passphraseID }?.passphrase == "synthetic extension", "Account additions preserve the wallet's passphrase")
        check(WalletTree(session.wallets).roots.count == 2, "Passphrase wallet is an independent root")
        try await session.addEVMAccounts(walletID: id.uuidString, paths: ["m/44'/60'/0'/0/1"])
        try await session.selectWalletAccount(id, path: "m/44'/60'/0'/0/1")
        check(session.portfolio?.accounts.first { $0.networkID == "solana" } == base.first { $0.networkID == "solana" }, "EVM selection preserves original Solana account")
        try await session.selectWalletAccount(id, selection: .init(family: .solana, path: custom))
        check(session.portfolio?.accounts.count == base.count && session.portfolio?.accounts.first { $0.networkID == "solana" }?.derivationPath == custom, "Switching back selects Solana and preserves other networks")
        let scopedBackup = BackupWallet(id: UUID(), name: "Scoped fixture", mnemonic: restored.mnemonic,
            language: restored.language, createdAt: Date(),
            accounts: [.init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0)])
        let isolatedDB = try await OathDatabase.open(at: dir.appendingPathComponent("isolated.sqlite"))
        try await OathDataEnvironment.seed(isolatedDB)
        let isolatedVault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: isolatedDB)
        try await isolatedVault.createRestoredWallet(digits: pin, restoration: OathRestoredWallet(backup: scopedBackup))
        let isolatedSession = OathWalletSession(vault: isolatedVault)
        await isolatedSession.finishedSetup()
        try await isolatedSession.addHDAccounts(walletID: scopedBackup.id.uuidString, family: .solana, paths: ["m/44'/501'/0'/0'"])
        check(isolatedSession.portfolio?.accounts.allSatisfy { $0.networkID != "solana" } == true, "First added Solana account stays outside an EVM-only restored root")
        try await isolatedSession.selectWalletAccount(scopedBackup.id, selection: .init(family: .solana, path: "m/44'/501'/0'/0'"))
        check(Set(isolatedSession.portfolio?.accounts.map(\.networkID) ?? []) == ["ethereum", "solana"], "First added Solana account keeps the original Ethereum network available")
        let keyID = try await session.addWallet(requestID: UUID(), privateKey: .init(bytes: Data(repeating: 9, count: 32), networks: [.ethereum]))
        let canAdd = await vault.canAddHDAccounts(walletID: keyID)
        check(!canAdd, "Raw private keys cannot create HD accounts")
        await session.lock()
        print("Solana account host checks passed: \(checks) (synthetic derivation; no network or device)")
    }
}
