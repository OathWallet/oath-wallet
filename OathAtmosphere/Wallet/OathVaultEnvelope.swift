import OathDiagnostics
import OathAezeed
import OathBitcoin
import Foundation
import CryptoKit
import Security
import OathCloudBackup
import OathDatabase

/// Secret payload exists only in protected vault work, its generation-scoped
/// background worker, or the explicit backup view.
/// Never place this in navigation paths, preferences, analytics, or diagnostics.
struct OathWalletSecret: Codable, Sendable {
    let id: UUID
    let mnemonic: String
    let language: String
    let createdAt: Date
    var backedUp: Bool
    // Optional for backward-compatible decoding of existing local wallets.
    // Bitcoin-specific mnemonic formats remain distinct from BIP39 wallets.
    var aezeed: AezeedMaterial? = nil
    var electrum: ElectrumSeedMaterial? = nil
    var isLocalMnemonic: Bool { aezeed != nil || electrum != nil }
    var isDerivedWallet: Bool { passphrase != nil || (electrum != nil && passphraseIndex != nil) }
    // Acknowledged only after their upload job is durably persisted.
    // A durable acknowledgement also backfills multisig wallets made before sync support.
    var imported: Bool? = nil
    // Recovery of a new wallet's missing SQL row must also recover its pending
    // setup step. Legacy payloads decode nil and retain their current flow.
    var createdWithCustomization: Bool? = nil
    // Seeds only the initial SQL insert, including recovery after an interrupted creation.
    // Absent in vaults created before offer tracking, and on iCloud restores.
    var initialBackupOffer: WalletBackupOffer? = nil

    /// Presentation policy only. Never read mnemonic words or key bytes to classify a wallet.
    var backupOfferByOrigin: WalletBackupOffer? {
        if let initialBackupOffer { return initialBackupOffer }
        if restoration != nil {
            // Vault handoff uses the restore machinery but explicitly requests customization.
            return createdWithCustomization == true ? .cloudOnly : nil
        }
        if imported == true || privateKey != nil { return .cloudOnly }
        if isDerivedWallet || isMultisig { return .cloudOrManual }
        if isLocalMnemonic { return .cloudOnly }
        // The earliest format had no origin field. Imported phrases started with backedUp
        // set; manually verified created wallets could have the same bit. Offer cloud only
        // when ambiguous. This bit never establishes that a cloud backup exists.
        return imported == nil && backedUp ? .cloudOnly : .cloudOrManual
    }
    // Missing on existing HD wallets; raw keys are never stored in SQL.
    var privateKey: OathImportedPrivateKey? = nil
    // BIP-39 material, encrypted together with the words. Never a SQL setting,
    // wallet name or password hint. Nil is the original, empty-passphrase wallet.
    var passphrase: String? = nil
    // Optional presentation metadata; never used to derive keys or authorize
    // recovery. The source and child keep independent lifecycle/backup state.
    var parentWalletID: UUID? = nil
    var passphraseIndex: Int? = nil
    var restoration: OathWalletRestorationMetadata? = nil
    /// Account additions are journaled with the seed before their public SQL rows.
    var additionalEVMAccounts: [EVMAccountDerivation]? = nil
    var additionalSolanaAccounts: [HDAccountDerivation]? = nil
    /// Authenticated removals are replayed into public storage after interruption.
    var removedHDAccounts: [HomeAccountSelection]? = nil
    // Retained only inside authenticated ciphertext until the seven-day expiry.
    var deletedAt: Date? = nil
    var legacy: OathLegacyWalletMetadata? = nil
    var bitcoinMultisig: BackupWallet.BitcoinMultisig? = nil
    var tronMultisig: BackupWallet.TronMultisig? = nil
    var solanaMultisig: BackupWallet.SolanaMultisig? = nil
    var xrplMultisig: BackupWallet.XrplMultisig? = nil
    var evmMultisig: BackupWallet.EVMMultisig? = nil
    var tonMultisig: BackupWallet.TonMultisig? = nil
    var thorchainMultisig: BackupWallet.ThorchainMultisig? = nil
    var nearMultisig: BackupWallet.NearMultisig? = nil
    var suiMultisig: BackupWallet.SuiMultisig? = nil
    var aptosMultisig: BackupWallet.AptosMultisig? = nil
    var stellarMultisig: BackupWallet.StellarMultisig? = nil
    var isMultisig: Bool { evmMultisig != nil || tonMultisig != nil || thorchainMultisig != nil || nearMultisig != nil || suiMultisig != nil || aptosMultisig != nil || stellarMultisig != nil || xrplMultisig != nil || bitcoinMultisig != nil || tronMultisig != nil || solanaMultisig != nil }

    var bip39Passphrase: String {
        get throws {
            guard !isLocalMnemonic else { throw OathWalletError.invalidPhrase }
            if legacy != nil || restoration?.legacyPassphrase == true {
                return try RecoveryPassphrase.normalizedLegacy(passphrase ?? "")
            }
            return try passphrase.map(RecoveryPassphrase.normalized) ?? ""
        }
    }

    var hasValidMaterial: Bool {
        if additionalEVMAccounts != nil || additionalSolanaAccounts != nil || removedHDAccounts != nil,
           isLocalMnemonic || isMultisig || privateKey != nil || (try? derivationAccounts()) == nil { return false }
        if let electrum {
            return electrum.isValid && ElectrumMnemonic.kind(mnemonic) == electrum.kind && language == "electrum"
                && aezeed == nil && !isMultisig && privateKey == nil && passphrase == nil && legacy == nil
                && restoration == nil && (passphraseIndex == nil ? parentWalletID == nil : (passphraseIndex! > 0 && !ElectrumMnemonic.normalize(electrum.passphrase).isEmpty))
        }
        if let aezeed {
            return aezeed.isValid && Aezeed.recognizes(mnemonic) && language == "english"
                && !isMultisig && privateKey == nil && passphrase == nil && legacy == nil
                && restoration == nil && parentWalletID == nil && passphraseIndex == nil
        }
        if let evmMultisig {
            return evmMultisig.isValidStructure && tonMultisig == nil && thorchainMultisig == nil && nearMultisig == nil && suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let tonMultisig {
            return tonMultisig.isValidStructure && thorchainMultisig == nil && nearMultisig == nil && suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let thorchainMultisig {
            return thorchainMultisig.isValidStructure && nearMultisig == nil && suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let nearMultisig {
            return nearMultisig.isValidStructure && suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let suiMultisig {
            return suiMultisig.isValidStructure && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let aptosMultisig {
            return aptosMultisig.isValidStructure && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let stellarMultisig {
            return stellarMultisig.isValidStructure && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let xrplMultisig {
            return xrplMultisig.isValidStructure && solanaMultisig == nil && tronMultisig == nil && bitcoinMultisig == nil
                && mnemonic.isEmpty && language.isEmpty && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let solanaMultisig {
            return solanaMultisig.isValidStructure && tronMultisig == nil && bitcoinMultisig == nil && mnemonic.isEmpty && language.isEmpty
                && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let tronMultisig {
            return tronMultisig.isValidStructure && bitcoinMultisig == nil && mnemonic.isEmpty && language.isEmpty
                && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let bitcoinMultisig {
            return bitcoinMultisig.isValidStructure && mnemonic.isEmpty && language.isEmpty
                && privateKey == nil && passphrase == nil && legacy == nil
        }
        if let privateKey {
            return mnemonic.isEmpty && language.isEmpty && privateKey.isValidStructure && passphrase == nil
        }
        return !mnemonic.isEmpty && !language.isEmpty
            && (try? bip39Passphrase) != nil
    }
}

enum OathWalletError: Error, Equatable {
    case unavailable, invalidPhrase, derivationFailed, locked, wrongPasscode, corruptVault
    case invalidPrivateKey
    case duplicatePassphraseWallet(UUID)
    case throttled(Date)
}

/// Every wallet shares the app lock, but keeps its own immutable identity and
/// recovery material. The original root ID remains the credential anchor even
/// after its wallet is permanently removed by the v9 lifecycle format.
struct OathVaultContents: Codable, Sendable {
    var wallets: [OathWalletSecret]
    var lifecycleVersion: Int? = nil
    // Crash-recovery journal: erase these public SQL records after their keys
    // have already been removed from the atomic encrypted payload.
    var purgedWalletIDs: [UUID]? = nil
    var legacyUpgrade: LegacyUpgradeBatch? = nil
    var legacyBiometricTransition: Bool? = nil
    // Retained after permanent deletion so default numbers are not reused.
    var lastPassphraseIndex: Int? = nil

    var requiresLegacyFormat: Bool {
        legacyBiometricTransition != nil || legacyUpgrade != nil ||
            wallets.contains { $0.legacy != nil || $0.restoration?.legacyPassphrase == true }
    }

    static let retention: TimeInterval = 7 * 24 * 60 * 60
    var activeWallets: [OathWalletSecret] { wallets.filter { $0.deletedAt == nil } }

    func validate(rootID: UUID) throws {
        guard lifecycleVersion == 1 || wallets.first?.id == rootID else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "contents_root_identity")
        }
        guard lifecycleVersion == nil || lifecycleVersion == 1 else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "unsupported_lifecycle_version")
        }
        guard Set(wallets.map(\.id)).count == wallets.count else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "duplicate_wallet_identity")
        }
        guard wallets.allSatisfy(\.hasValidMaterial) else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_material_structure")
        }
        guard wallets.allSatisfy({ $0.deletedAt?.timeIntervalSince1970.isFinite != false }) else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_wallet_deletion_date")
        }
        guard lifecycleVersion == 1 || (wallets.allSatisfy({ $0.deletedAt == nil }) && purgedWalletIDs == nil) else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "lifecycle_metadata_mismatch")
        }
        guard Set(purgedWalletIDs ?? []).count == (purgedWalletIDs ?? []).count else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "duplicate_purged_identity")
        }
        guard Set(purgedWalletIDs ?? []).isDisjoint(with: wallets.map(\.id)) else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "purged_identity_still_present")
        }
        if let batch = legacyUpgrade {
            // SQL recovery is authorized only by the authenticated vault's
            // own members. A receipt can never grant access to other wallets.
            guard Set(batch.wallets.map(\.id)) == Set(wallets.map { $0.id.uuidString }),
                  batch.wallets.allSatisfy({ record in
                      guard let id = UUID(uuidString: record.id) else { return false }
                      return record.vaultReference == Self.reference(for: id, rootID: rootID)
                  }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "legacy_receipt_membership") }
        }
    }

    static func reference(for id: UUID, rootID: UUID) -> String {
        id == rootID ? "vault-v1" : "vault-v1:" + id.uuidString
    }

    func selectedWalletID(_ storedID: String?) throws -> UUID {
        guard let first = activeWallets.first else { throw OathWalletError.unavailable }
        return activeWallets.first(where: { $0.id.uuidString == storedID })?.id ?? first.id
    }

    func walletFamilies(rootID: UUID) -> [WalletFamily] {
        wallets.compactMap { wallet in
            guard wallet.isDerivedWallet, let index = wallet.passphraseIndex, index > 0 else { return nil }
            return WalletFamily(id: wallet.id.uuidString, parentID: wallet.parentWalletID?.uuidString, index: index,
                                vaultReference: Self.reference(for: wallet.id, rootID: rootID))
        }
    }

    private var highestPassphraseIndex: Int {
        max(0, lastPassphraseIndex ?? 0, wallets.compactMap(\.passphraseIndex).max() ?? 0)
    }

    func nextPassphraseIndex() throws -> Int {
        let highest = highestPassphraseIndex
        guard highest < Int.max else { throw OathWalletError.unavailable }
        return highest + 1
    }

    /// Upgrade old metadata only after authentication. Shared recovery words
    /// stay inside the vault; only a unique original wallet establishes a
    /// missing relationship. An absent parent is normal for standalone restores.
    @discardableResult mutating func reconcilePassphraseFamilies(records: [WalletRecord] = []) -> Bool {
        var changed = false
        var next = highestPassphraseIndex
        let old = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set(wallets.compactMap(\.passphraseIndex))
        var recoveredIndex = 1
        lazy var reserved = Set(records.lazy.filter { $0.nameGroup == "passphrase" }.map(\.nameIndex))
        for index in wallets.indices where wallets[index].isDerivedWallet {
            if (wallets[index].passphraseIndex ?? 0) <= 0 {
                let row = old[wallets[index].id.uuidString]
                let previous = row?.nameGroup == "passphrase" ? row?.nameIndex : nil
                let number: Int
                if let previous, previous > 0, !used.contains(previous) { number = previous }
                else if next < Int.max { number = next + 1 }
                else {
                    // Existing secrets still need a display index when authenticated
                    // historical metadata has exhausted the monotonic counter.
                    while used.contains(recoveredIndex) || reserved.contains(recoveredIndex) { recoveredIndex += 1 }
                    number = recoveredIndex
                }
                wallets[index].passphraseIndex = number; used.insert(number)
                next = max(next, number); changed = true
            }
            if let parent = wallets[index].parentWalletID,
               parent == wallets[index].id || wallets.contains(where: {
                   $0.id == parent && ($0.privateKey != nil || $0.mnemonic != wallets[index].mnemonic || $0.language != wallets[index].language)
               }) {
                wallets[index].parentWalletID = nil; changed = true
            }
            if wallets[index].parentWalletID == nil {
                let originals = wallets.filter {
                    $0.id != wallets[index].id && $0.privateKey == nil && !$0.isDerivedWallet
                    && $0.mnemonic == wallets[index].mnemonic && $0.language == wallets[index].language
                }
                if originals.count == 1 { wallets[index].parentWalletID = originals[0].id; changed = true }
            }
        }
        if next > (lastPassphraseIndex ?? 0) { lastPassphraseIndex = next; changed = true }
        return changed
    }
}

/// With a passcode, v3 wraps the payload key with a PIN-derived key. Without a
/// passcode, the key remains protected by the installation-encrypted Keychain.
/// Keychain adds device-bound, unlocked-only OS protection. The storage layer
/// additionally binds every record to a key deleted with the app's container.
struct OathVaultEnvelope: Codable, Sendable {
    let version: Int
    let id: UUID
    let salt: Data
    let iterations: UInt32
    let sealed: Data
    // Nonsecret identities allow a cold launch to render the selected wallet
    // behind the lock. Version 2 authenticates this index with the ciphertext.
    var walletIDs: [UUID]? = nil
    var protection: OathVaultProtection? = nil
    // nil preserves enrollment detection for existing v1/v2 installations.
    var biometricAccess: Bool? = nil

    var passcodeEnabled: Bool { protection?.deviceKey == nil }

    static func seal(_ secret: OathWalletSecret, digits: [UInt8]) throws -> (Self, SymmetricKey) {
        var salt = Data(count: 32)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            throw OathWalletError.unavailable
        }
        let key = try derive(digits, salt: salt, iterations: 600_000)
        return (try seal(secret, key: key, salt: salt, iterations: 600_000), key)
    }

    static func seal(_ secret: OathWalletSecret, key: SymmetricKey, salt: Data, iterations: UInt32) throws -> Self {
        if secret.removedHDAccounts != nil || secret.additionalEVMAccounts != nil || secret.additionalSolanaAccounts != nil || secret.restoration?.accounts.contains(where: { $0.solanaPathOnly == true }) == true || secret.isLocalMnemonic || secret.isMultisig || secret.legacy != nil || secret.restoration?.legacyPassphrase == true || secret.passphrase != nil || secret.privateKey?.requiresBitcoinV2 == true || secret.privateKey?.requiresDogecoinV2 == true || secret.privateKey?.requiresLitecoinV2 == true || secret.privateKey?.requiresBitcoinCashV2 == true {
            return try seal(OathVaultContents(wallets: [secret]), rootID: secret.id,
                            key: key, salt: salt, iterations: iterations)
        }
        guard secret.hasValidMaterial else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_single_wallet_material") }
        var plaintext = try JSONEncoder().encode(secret)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard let sealed = try AES.GCM.seal(plaintext, using: key,
                                           authenticating: authenticationData(secret.id)).combined else {
            throw OathWalletError.unavailable
        }
        return Self(version: 1, id: secret.id, salt: salt, iterations: iterations, sealed: sealed)
    }

    static func seal(_ contents: OathVaultContents, rootID: UUID, key: SymmetricKey,
                     salt: Data, iterations: UInt32, protection: OathVaultProtection? = nil,
                     biometricAccess: Bool? = nil) throws -> Self {
        var contents = contents
        // Validate the original lifecycle, including its root and membership,
        // before supplying a missing marker that the new format requires.
        try contents.validate(rootID: rootID)
        if contents.lifecycleVersion == nil,
           contents.requiresLegacyFormat || contents.wallets.contains(where: { $0.isLocalMnemonic || $0.isMultisig || $0.removedHDAccounts != nil || $0.additionalEVMAccounts != nil || $0.additionalSolanaAccounts != nil || $0.restoration?.accounts.contains(where: { $0.solanaPathOnly == true }) == true }) {
            contents.lifecycleVersion = 1
        }
        let ids = contents.wallets.map(\.id)
        // Old binaries must reject passphrase vaults rather than silently
        // ignoring an unknown field and deriving the wrong wallet on recovery.
        let version = contents.wallets.contains(where: { $0.removedHDAccounts != nil }) ? 30 : contents.wallets.contains(where: { $0.additionalSolanaAccounts != nil || $0.restoration?.accounts.contains(where: { $0.solanaPathOnly == true }) == true }) ? 29 : contents.wallets.contains(where: { $0.additionalEVMAccounts != nil }) ? 28 : contents.wallets.contains(where: { $0.electrum != nil && $0.isDerivedWallet }) ? 27 : contents.wallets.contains(where: { $0.electrum != nil }) ? 26 : contents.wallets.contains(where: { $0.aezeed != nil }) ? 25 : contents.wallets.contains(where: { $0.evmMultisig != nil }) ? 24 : contents.wallets.contains(where: { $0.bitcoinMultisig?.chainID == "dogecoin" }) ? 23 : contents.wallets.contains(where: { $0.bitcoinMultisig?.chainID == "bitcoincash" }) ? 22 : contents.wallets.contains(where: { $0.bitcoinMultisig?.chainID == "litecoin" }) ? 21 : contents.wallets.contains(where: { $0.tonMultisig != nil }) ? 20 : contents.wallets.contains(where: { $0.thorchainMultisig != nil }) ? 19 : contents.wallets.contains(where: { $0.nearMultisig != nil }) ? 18 : contents.wallets.contains(where: { $0.suiMultisig != nil }) ? 17 : contents.wallets.contains(where: { $0.aptosMultisig != nil }) ? 16 : contents.wallets.contains(where: { $0.stellarMultisig != nil }) ? 15 : contents.wallets.contains(where: { $0.xrplMultisig != nil }) ? 14 : contents.wallets.contains(where: { $0.solanaMultisig != nil }) ? 13 : contents.wallets.contains(where: { $0.tronMultisig != nil }) ? 12 : contents.wallets.contains(where: { $0.bitcoinMultisig != nil }) ? 11 : contents.requiresLegacyFormat ? 10 : contents.lifecycleVersion == 1 ? 9 : contents.wallets.contains { $0.privateKey?.requiresBitcoinCashV2 == true } ? 8 :
            contents.wallets.contains { $0.privateKey?.requiresLitecoinV2 == true } ? 7 :
            contents.wallets.contains { $0.privateKey?.requiresDogecoinV2 == true } ? 6 :
            contents.wallets.contains { $0.privateKey?.requiresBitcoinV2 == true } ? 5 :
            (contents.wallets.contains { $0.passphrase != nil } ? 4 : (protection == nil ? 2 : 3))
        var plaintext = try JSONEncoder().encode(contents)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard let sealed = try AES.GCM.seal(plaintext, using: key,
            authenticating: authenticationData(rootID, walletIDs: ids, version: version)).combined else {
            throw OathWalletError.unavailable
        }
        return Self(version: version, id: rootID, salt: salt, iterations: iterations,
                    sealed: sealed, walletIDs: ids, protection: protection, biometricAccess: biometricAccess)
    }

    var memberIDs: [UUID] { version == 1 ? [id] : walletIDs ?? [] }

    func key(for digits: [UInt8], beforeAttempt: () throws -> Void = {}) throws -> SymmetricKey {
        try validate()
        guard passcodeEnabled else { throw OathWalletError.wrongPasscode }
        try beforeAttempt()
        let derived = try Self.derive(digits, salt: salt, iterations: iterations)
        guard let protection else { return derived }
        guard let wrapped = protection.wrappedKey else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "missing_wrapped_key") }
        var data: Data
        do {
            data = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: derived,
                                    authenticating: Self.keyAuthenticationData(id))
        } catch { OathDiagnostics.record(error, context: ["stage": "key_unwrap"]); throw OathWalletError.wrongPasscode }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        guard data.count == 32 else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_unwrapped_key_size") }
        return SymmetricKey(data: data)
    }

    func deviceKey() throws -> SymmetricKey {
        try validate()
        guard let data = protection?.deviceKey, data.count == 32 else { throw OathWalletError.locked }
        return SymmetricKey(data: data)
    }

    /// One Keychain replacement commits the new credential and all wallets.
    /// Changing an enabled PIN preserves the payload key and Face ID enrollment.
    func replacingPasscode(_ digits: [UInt8]?, contents: OathVaultContents,
                           currentKey: SymmetricKey) throws -> (Self, SymmetricKey) {
        let key = passcodeEnabled && digits != nil ? currentKey : SymmetricKey(size: .bits256)
        var salt = Data(count: 32)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            throw OathWalletError.unavailable
        }
        var rawKey = key.withUnsafeBytes { Data($0) }
        defer { rawKey.resetBytes(in: rawKey.startIndex..<rawKey.endIndex) }
        let protection: OathVaultProtection
        if let digits {
            let wrappingKey = try Self.derive(digits, salt: salt, iterations: 600_000)
            guard let wrapped = try AES.GCM.seal(rawKey, using: wrappingKey,
                authenticating: Self.keyAuthenticationData(id)).combined else { throw OathWalletError.unavailable }
            protection = OathVaultProtection(wrappedKey: wrapped, deviceKey: nil)
        } else {
            protection = OathVaultProtection(wrappedKey: nil, deviceKey: rawKey)
        }
        let updated = try Self.seal(contents, rootID: id, key: key, salt: salt, iterations: 600_000,
            protection: protection, biometricAccess: digits == nil || !passcodeEnabled ? false : biometricAccess)
        return (updated, key)
    }

    private static func keyAuthenticationData(_ id: UUID) -> Data {
        Data(("org.oathwallet.vault.pin-key.v3:" + id.uuidString).utf8)
    }

    func open(using key: SymmetricKey) throws -> OathWalletSecret {
        // Retained for version-1 callers. Vault operations use the full contents.
        guard let first = try openContents(using: key).wallets.first else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "missing_legacy_wallet") }
        return first
    }

    func openContents(using key: SymmetricKey, authenticatingLegacyPasscode: Bool = false,
                      didAuthenticate: () throws -> Void = {}) throws -> OathVaultContents {
        try validate()
        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                authenticating: Self.authenticationData(id, walletIDs: version >= 2 ? walletIDs : nil, version: version))
        } catch CryptoKitError.authenticationFailure where authenticatingLegacyPasscode && protection == nil {
            // diagnostics: legacy-passcode-rejection
            // A legacy envelope authenticates the candidate PIN here. Rejection
            // is expected form feedback; attempts were already charged by the
            // caller. Verified/wrapped keys, biometrics and internal reads use
            // the reporting path below, even if this flag is passed by mistake.
            throw OathWalletError.wrongPasscode
        } catch { OathDiagnostics.record(error, context: ["stage": "vault_decrypt"]); throw OathWalletError.wrongPasscode }
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        try didAuthenticate()
        var contents = try version == 1
            ? OathVaultContents(wallets: [JSONDecoder().decode(OathWalletSecret.self, from: plaintext)])
            : JSONDecoder().decode(OathVaultContents.self, from: plaintext)
        try contents.validate(rootID: id)
        // Older writers could select v10 for legacy restoration metadata while
        // leaving lifecycleVersion absent. Authentication and all pre-lifecycle
        // invariants have already passed. Normalize only this writer-produced
        // shape, in memory, before the ordinary format and membership checks.
        if version == 10, contents.lifecycleVersion == nil, contents.requiresLegacyFormat {
            contents.lifecycleVersion = 1
        }
        guard version >= 9 ? contents.lifecycleVersion == 1 : contents.lifecycleVersion == nil else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "payload_lifecycle_mismatch") }
        guard version >= 30 || contents.wallets.allSatisfy({ $0.removedHDAccounts == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_account_removals") }
        guard version >= 29 || contents.wallets.allSatisfy({ $0.additionalSolanaAccounts == nil && $0.restoration?.accounts.contains(where: { $0.solanaPathOnly == true }) != true }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_solana_accounts") }
        guard version >= 28 || contents.wallets.allSatisfy({ $0.additionalEVMAccounts == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_evm_accounts") }
        guard version >= 27 || contents.wallets.allSatisfy({ $0.electrum == nil || !$0.isDerivedWallet }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_derived_electrum") }
        guard version >= 26 || contents.wallets.allSatisfy({ $0.electrum == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_electrum") }
        guard version >= 25 || contents.wallets.allSatisfy({ $0.aezeed == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_aezeed") }
        guard version >= 24 || contents.wallets.allSatisfy({ $0.evmMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_evm_multisig") }
        guard version >= 23 || contents.wallets.allSatisfy({ $0.bitcoinMultisig?.chainID != "dogecoin" }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_dogecoin_multisig") }
        guard version >= 22 || contents.wallets.allSatisfy({ $0.bitcoinMultisig?.chainID != "bitcoincash" }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_bitcoincash_multisig") }
        guard version >= 21 || contents.wallets.allSatisfy({ $0.bitcoinMultisig?.chainID != "litecoin" }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_litecoin_multisig") }
        guard version >= 20 || contents.wallets.allSatisfy({ $0.tonMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_ton_multisig") }
        guard version >= 19 || contents.wallets.allSatisfy({ $0.thorchainMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_thorchain_multisig") }
        guard version >= 18 || contents.wallets.allSatisfy({ $0.nearMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_near_multisig") }
        guard version >= 17 || contents.wallets.allSatisfy({ $0.suiMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_sui_multisig") }
        guard version >= 16 || contents.wallets.allSatisfy({ $0.aptosMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_aptos_multisig") }
        guard version >= 15 || contents.wallets.allSatisfy({ $0.stellarMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_stellar_multisig") }
        guard version >= 14 || contents.wallets.allSatisfy({ $0.xrplMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_xrpl_multisig") }
        guard version >= 13 || contents.wallets.allSatisfy({ $0.solanaMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_solana_multisig") }
        guard version >= 12 || contents.wallets.allSatisfy({ $0.tronMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_tron_multisig") }
        guard version >= 11 || contents.wallets.allSatisfy({ $0.bitcoinMultisig == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_bitcoin_multisig") }
        guard version >= 10 || (contents.legacyBiometricTransition == nil && contents.legacyUpgrade == nil && contents.wallets.allSatisfy({ $0.legacy == nil && $0.restoration?.legacyPassphrase != true })) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_legacy") }
        guard version >= 4 || contents.wallets.allSatisfy({ $0.passphrase == nil }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_passphrase") }
        guard version >= 5 || contents.wallets.allSatisfy({ $0.privateKey?.requiresBitcoinV2 != true }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_bitcoin_key") }
        guard version >= 8 || contents.wallets.allSatisfy({ $0.privateKey?.requiresBitcoinCashV2 != true }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_bitcoincash_key") }
        guard version >= 7 || contents.wallets.allSatisfy({ $0.privateKey?.requiresLitecoinV2 != true }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_litecoin_key") }
        guard version >= 6 || contents.wallets.allSatisfy({ $0.privateKey?.requiresDogecoinV2 != true }) else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "format_dogecoin_key") }
        guard contents.wallets.map(\.id) == memberIDs else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "member_identity_mismatch") }
        return contents
    }

    private func validate() throws {
        guard (1...30).contains(version) else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "unsupported_envelope_version")
        }
        guard salt.count == 32 else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_envelope_salt_size")
        }
        guard iterations == 600_000 else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_derivation_rounds")
        }
        guard sealed.count > 28 else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "truncated_ciphertext")
        }
        guard version >= 9 || memberIDs.first == id else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "envelope_root_identity")
        }
        guard Set(memberIDs).count == memberIDs.count else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "duplicate_envelope_member")
        }
        guard version < 9 || walletIDs != nil else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "missing_envelope_members")
        }
        guard version != 1 || walletIDs == nil else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "unexpected_legacy_members")
        }
        if version == 3 || (version >= 4 && protection != nil) {
            guard let protection,
                  (protection.wrappedKey?.count == 60 && protection.deviceKey == nil) ||
                  (protection.wrappedKey == nil && protection.deviceKey?.count == 32 && biometricAccess == false)
            else { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_key_protection") }
        } else if protection != nil { throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "unexpected_key_protection") }
    }

    private static func derive(_ digits: [UInt8], salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // Reuse the reviewed PBKDF2 implementation, but NEVER persist its output
        // as a verifier. It is the AES key, held only for the unlocked session.
        let derived = try OathPasscodeRecord.make(digits: digits, salt: Array(salt), iterations: iterations)
        return SymmetricKey(data: derived.verifier)
    }

    private static func authenticationData(_ id: UUID, walletIDs: [UUID]? = nil, version: Int = 2) -> Data {
        if let walletIDs {
            let format = version >= 30 ? "org.oathwallet.vault.v30:" : version >= 29 ? "org.oathwallet.vault.v29:" : version >= 28 ? "org.oathwallet.vault.v28:" : version >= 27 ? "org.oathwallet.vault.v27:" : version >= 26 ? "org.oathwallet.vault.v26:" : version >= 25 ? "org.oathwallet.vault.v25:" : version >= 11 ? "org.oathwallet.vault.v11:" : version >= 10 ? "org.oathwallet.vault.v10:" : version >= 9 ? "org.oathwallet.vault.v9:" : version >= 8 ? "org.oathwallet.vault.v8:" : version >= 7 ? "org.oathwallet.vault.v7:" : version >= 6 ? "org.oathwallet.vault.v6:" : version >= 5 ? "org.oathwallet.vault.v5:" : (version >= 4 ? "org.oathwallet.vault.v4:" : "org.oathwallet.vault.v2:")
            return Data((format + id.uuidString + ":" +
                         walletIDs.map(\.uuidString).joined(separator: ":")).utf8)
        }
        return Data("org.oathwallet.vault.v1:\(id.uuidString)".utf8)
    }
}

struct OathVaultProtection: Codable, Sendable {
    let wrappedKey: Data?
    let deviceKey: Data?
}
