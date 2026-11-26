import Foundation
import CryptoKit
import OathDatabase
import OathCloudBackup

/// Production vault, encrypted storage, SQL and session; host derivation is synthetic.
@main struct CheckEVMAccounts {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oath-evm-accounts-" + UUID().uuidString)
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
        let path = "m/44'/60'/0'/0/1", custom = "m/44'/60'/7'/0/0"
        try await session.addEVMAccounts(walletID: id.uuidString, paths: [path, custom])
        let all = try await db.accounts(walletID: id.uuidString)
        let groups = EVMAccountGroup.grouped(all, networks: Set(OathImportChain.allCases.filter(\.isEVM).map(\.id)))
        check(groups.count == 3 && groups.map(\.index) == [0,1,2], "Three numbered EVM accounts")
        check(base.allSatisfy { all.contains($0) }, "Existing public accounts are unchanged")
        check(groups[1].accounts.count == OathImportChain.enabledCases.filter(\.isEVM).count, "Account spans every enabled EVM network")
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let key = try envelope.key(for: pin)
        let contents = try envelope.openContents(using: key)
        check(envelope.version == 28, "Old clients must reject unsupported account metadata")
        check(contents.activeWallets.first?.additionalEVMAccounts?.map(\.path) == [path,custom], "Encrypted metadata preserves exact paths")
        try await session.addEVMAccounts(walletID: id.uuidString, paths: [path])
        let retried = try await db.accounts(walletID: id.uuidString)
        check(retried == all, "Retry is idempotent")
        try await session.selectWalletAccount(id, path: custom)
        check(session.portfolio?.accounts.filter { HDAccountFamily.evm.owns(network: $0.networkID) }.allSatisfy { $0.derivationPath == custom } == true, "Home uses the selected EVM path")
        check(session.displayedProfile?.addresses.filter { $0.chain.isEVM }.allSatisfy { $0.path == custom } == true, "Receive uses the selected EVM path")
        check(base.filter { !HDAccountFamily.evm.owns(network: $0.networkID) }.allSatisfy { session.portfolio?.accounts.contains($0) == true }, "Other chains retain their original accounts")
        let backup = try await vault.encryptedCloudBackup(walletID: id.uuidString, password: "synthetic-backup-password")
        let restored = try BackupDocument.open(backup, password: "synthetic-backup-password")
        check(restored.accounts.count == all.count, "Backup includes every account even while Home is scoped")
        check(restored.accounts.contains { $0.derivationPath == custom }, "Custom paths survive portable backup")
        let importedBackup = try OathRestoredWallet(backup: restored)
        check(try importedBackup.secret.derivationAccounts().count == all.count, "Restore validates and preserves every saved path")
        check(importedBackup.profile.addresses.count == all.count, "Restore reconstructs every account")
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.selectedEVMAccountPath == custom, "Account selection survives lock and reopen")
        try await session.selectWallet(id)
        check(session.portfolio?.accounts.count == base.count, "Selecting root restores only original accounts")
        storage.rejectNextUpdate()
        do { try await session.addEVMAccounts(walletID: id.uuidString, paths: ["m/44'/60'/0'/0/2"]); preconditionFailure("Failed encrypted save accepted") }
        catch { check(session.isUnlocked, "Failed save recovers usable session") }
        let afterFailure = try await db.accounts(walletID: id.uuidString)
        check(afterFailure == all, "Failed encrypted save cannot add public accounts")
        await session.lock()
        try await db.deleteWalletMetadata(id.uuidString)
        await session.unlock(pin)
        let repaired = try await db.accounts(walletID: id.uuidString)
        check(repaired == all, "Encrypted metadata repairs missing public rows on unlock")
        DerivationGate.shared.arm()
        let pending = Task { try await session.addEVMAccounts(walletID: id.uuidString, paths: ["m/44'/60'/0'/0/2"]) }
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
        try await session.addEVMAccounts(walletID: passphraseID, paths: [path])
        let passphraseEnvelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let passphraseContents = try passphraseEnvelope.openContents(using: key)
        check(passphraseContents.activeWallets.first { $0.id.uuidString == passphraseID }?.passphrase == "synthetic extension", "Account additions preserve the wallet's passphrase")
        check(WalletTree(session.wallets).roots.count == 2, "Passphrase wallet is an independent root")
        let keyID = try await session.addWallet(requestID: UUID(), privateKey: .init(bytes: Data(repeating: 9, count: 32), networks: [.ethereum]))
        let canAdd = await vault.canAddEVMAccounts(walletID: keyID)
        check(!canAdd, "Raw private keys cannot create HD accounts")
        await session.lock()
        print("EVM account host checks passed: \(checks) (synthetic derivation; no network or device)")
    }
}
