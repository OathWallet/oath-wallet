import Foundation
import GRDB

/// Public derivation metadata. Recovery material stays in the existing vault.
public struct HDAccountDerivation: Codable, Equatable, Sendable {
    public let index: Int
    public let path: String
    public let networks: [String]

    public init(index: Int, path: String, networks: [String]) {
        self.index = index; self.path = path; self.networks = networks
    }

    public enum ValidationError: Error, Equatable { case invalidPath, tooManyPaths, duplicatePath, accountLimit }

    /// Accept explicit BIP32 paths only; never expand ranges or wildcards.
    public static func canonicalPath(_ input: String) throws -> String {
        guard input.utf8.count <= 256 else { throw ValidationError.invalidPath }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "m", (2...11).contains(parts.count) else { throw ValidationError.invalidPath }
        let children = try parts.dropFirst().map { part -> String in
            let hardened = part.last == "'" || part.last == "h" || part.last == "H"
            let digits = hardened ? part.dropLast() : part
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let index = UInt32(digits), index < 0x8000_0000 else { throw ValidationError.invalidPath }
            return String(index) + (hardened ? "'" : "")
        }
        return "m/" + children.joined(separator: "/")
    }

    public static func paths(in input: String) throws -> [String] {
        guard input.utf8.count <= 8_192 else { throw ValidationError.tooManyPaths }
        let lines = input.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, lines.count <= 20 else { throw ValidationError.tooManyPaths }
        let paths = try lines.map { try canonicalPath(String($0)) }
        guard Set(paths).count == paths.count else { throw ValidationError.duplicatePath }
        return paths
    }

    public static func nextDefaultPath(existing: Set<String>) throws -> String {
        for index in 0..<1_024 {
            let path = "m/44'/60'/0'/0/\(index)"
            if !existing.contains(path) { return path }
        }
        throw ValidationError.accountLimit
    }
}

// Keep the EVM API and persisted selection key compatible with existing installs.
public typealias EVMAccountDerivation = HDAccountDerivation

public enum HDAccountFamily: String, CaseIterable, Codable, Sendable {
    case evm, solana
    public func contains(_ network: NetworkRecord) -> Bool {
        self == .solana ? network.id == "solana" : network.family == "evm"
    }
    public func originalKey(walletID: String) -> String { "homeOriginalAccount:" + rawValue + ":" + walletID }
    public func selectionKey(walletID: String) -> String {
        (self == .evm ? "homeEVMAccount:" : "homeSolanaAccount:") + walletID
    }
    public func canonicalPath(_ input: String) throws -> String {
        let path = try HDAccountDerivation.canonicalPath(input)
        if self == .solana, !path.split(separator: "/").dropFirst().allSatisfy({ $0.last == "'" }) {
            throw HDAccountDerivation.ValidationError.invalidPath
        }
        return path
    }
    public func paths(in input: String) throws -> [String] {
        try HDAccountDerivation.paths(in: input).map { try canonicalPath($0) }
    }
    public func nextDefaultPath(existing: Set<String>) throws -> String {
        if self == .evm { return try HDAccountDerivation.nextDefaultPath(existing: existing) }
        let usedIndices = Set(existing.compactMap(SolanaDerivation.accountIndex(in:)))
        for index in 0..<1_024 where !usedIndices.contains(index) {
            let path = try SolanaDerivation.phantom.path(accountIndex: index)
            if !existing.contains(path) { return path }
        }
        throw HDAccountDerivation.ValidationError.accountLimit
    }
}

public struct HomeAccountSelection: Equatable, Hashable, Codable, Sendable {
    public let family: HDAccountFamily
    public let path: String
    public init(family: HDAccountFamily, path: String) { self.family = family; self.path = path }
    public var identity: String { family.rawValue + ":" + path }
    public func balanceID(walletID: String) -> String { "account:\(walletID.utf8.count):\(walletID):\(identity)" }
    public func nameKey(walletID: String) -> String { "accountName:" + balanceID(walletID: walletID) }
}

public struct EVMAccountGroup: Identifiable, Equatable, Sendable {
    public let path: String
    public let index: Int
    public let accounts: [AccountRecord]
    public var name: String? = nil
    public var isAdditional = false
    public var id: String { path }
    public var address: String { accounts.first?.address ?? "" }
    public static func selectionKey(walletID: String) -> String { "homeEVMAccount:" + walletID }

    public static func grouped(_ accounts: [AccountRecord], networks: Set<String>) -> [Self] {
        Dictionary(grouping: accounts.filter { networks.contains($0.networkID) && $0.derivationPath.hasPrefix("m/") }, by: \.derivationPath)
            .map { path, accounts in
                Self(path: path, index: accounts.map(\.accountIndex).min() ?? 0,
                     accounts: accounts.sorted { $0.networkID < $1.networkID })
            }.sorted { ($0.index, $0.path) < ($1.index, $1.path) }
    }
}

extension OathDatabase {
    public enum AccountManagementError: Error, Equatable { case lastAccount, invalidName }

    private static func namedAccountGroups(_ accounts: [AccountRecord], networks: Set<String>, family: HDAccountFamily,
                                          settings: [String: String]) -> [EVMAccountGroup] {
        let groups = EVMAccountGroup.grouped(accounts, networks: networks)
        return groups.map { group in
            var value = group
            if let walletID = group.accounts.first?.walletID {
                value.name = settings[HomeAccountSelection(family: family, path: group.path).nameKey(walletID: walletID)]
                // An empty persisted original path means this family was added
                // to a wallet that did not originally contain it.
                let originalPath = settings[family.originalKey(walletID: walletID)] ?? groups.first?.path
                value.isAdditional = group.path != originalPath
            }
            return value
        }
    }

    private static func hasAdditionalHDAccounts(_ db: Database, walletID: String) throws -> Bool {
        let accounts = try accounts(db, walletID: walletID)
        let networks = try NetworkRecord.fetchAll(db)
        let settings = try settings(db)
        return HDAccountFamily.allCases.contains { family in
            Self.namedAccountGroups(accounts, networks: Set(networks.filter { family.contains($0) }.map(\.id)),
                family: family, settings: settings).contains(where: \.isAdditional)
        }
    }

    /// Earlier releases allowed selecting a default child even without added
    /// accounts. Collapse that obsolete selection back to the complete wallet.
    public func normalizeHomeAccountSelection(walletID: String) async throws {
        try await storageWrite { db in try Self.normalizeHomeAccountSelection(db, walletID: walletID) }
    }

    private static func normalizeHomeAccountSelection(_ db: Database, walletID: String) throws {
        let keys = HDAccountFamily.allCases.map { $0.selectionKey(walletID: walletID) }
        guard try keys.contains(where: { try SettingRecord.fetchOne(db, key: $0) != nil }),
              try !Self.hasAdditionalHDAccounts(db, walletID: walletID) else { return }
        for key in keys { try db.execute(sql: "DELETE FROM settings WHERE key=?", arguments: [key]) }
    }

    public func renameHDAccount(walletID: String, selection: HomeAccountSelection, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AccountManagementError.invalidName
        }
        try await storageWrite { db in
            guard let wallet = try WalletRecord.fetchOne(db, key: walletID), wallet.deletedAt == nil,
                  try Self.accountGroups(db, walletID: walletID, family: selection.family).contains(where: { $0.path == selection.path }) else {
                throw StoreError.missingRecord
            }
            try SettingRecord(key: selection.nameKey(walletID: walletID), value: name, updatedAt: Date().timeIntervalSince1970).upsert(db)
        }
    }

    private static func accountGroups(_ db: Database, walletID: String, family: HDAccountFamily) throws -> [EVMAccountGroup] {
        let networks = Set(try NetworkRecord.fetchAll(db).filter { family.contains($0) }.map(\.id))
        return EVMAccountGroup.grouped(try accounts(db, walletID: walletID), networks: networks)
    }

    public func validateHDAccountRemoval(walletID: String, selection: HomeAccountSelection) async throws {
        try await pool.read { db in
            let groups = try Self.accountGroups(db, walletID: walletID, family: selection.family)
            guard let target = groups.first(where: { $0.path == selection.path }) else { throw StoreError.missingRecord }
            guard groups.count > 1 else { throw AccountManagementError.lastAccount }
            try Self.validateNoPendingSends(db, accounts: target.accounts)
        }
    }

    private static func validateNoPendingSends(_ db: Database, accounts: [AccountRecord]) throws {
        for account in accounts {
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM sends WHERE walletID=? AND accountID=? AND state IN ('queued','signed','broadcast') LIMIT 1",
                                   arguments: [account.walletID, account.id]) == nil else { throw StoreError.invalidTransition }
        }
    }

    /// Called after the authenticated vault commit, and replayed on unlock. The
    /// transaction enforces the last-account rule independently of presentation.
    public func removeHDAccount(walletID: String, selection: HomeAccountSelection) async throws {
        try await storageWrite { db in
            guard let wallet = try WalletRecord.fetchOne(db, key: walletID), wallet.deletedAt == nil else { throw StoreError.missingRecord }
            let groups = try Self.accountGroups(db, walletID: walletID, family: selection.family)
            if let target = groups.first(where: { $0.path == selection.path }) {
                guard groups.count > 1 else { throw AccountManagementError.lastAccount }
                try Self.validateNoPendingSends(db, accounts: target.accounts)
                for account in target.accounts { _ = try AccountRecord.deleteOne(db, key: account.id) }
            } // Otherwise this removal has already been applied; still reconcile original/selection keys.
            let selectedKey = selection.family.selectionKey(walletID: walletID)
            if try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key=?", arguments: [selectedKey]) == selection.path {
                try db.execute(sql: "DELETE FROM settings WHERE key=?", arguments: [selectedKey])
            }
            let originalKey = selection.family.originalKey(walletID: walletID)
            if try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key=?", arguments: [originalKey]) == selection.path,
               let replacement = groups.first(where: { $0.path != selection.path }) {
                try SettingRecord(key: originalKey, value: replacement.path, updatedAt: Date().timeIntervalSince1970).upsert(db)
            }
            try Self.normalizeHomeAccountSelection(db, walletID: walletID)
        }
    }

    static func homeEVMPath(_ db: Database, walletID: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT s.value FROM settings s WHERE s.key=? AND EXISTS (
              SELECT 1 FROM walletAccounts a JOIN networks n ON n.id=a.networkID
              WHERE a.walletID=? AND a.derivationPath=s.value AND n.family='evm')
            """, arguments: [EVMAccountGroup.selectionKey(walletID: walletID), walletID])
    }

    static func homeAccountIDs(_ db: Database, walletID: String) throws -> Set<String>? {
        let records = try accounts(db, walletID: walletID)
        let selected = WalletSnapshot.homeAccounts(records, networks: try NetworkRecord.fetchAll(db),
                                                   settings: try settings(db), walletID: walletID)
        return selected.count == records.count ? nil : Set(selected.map(\.id))
    }

    /// Authenticated recovery metadata identifies the original portfolio even
    /// when a restored wallet did not originally contain this network.
    public func setOriginalHomeAccount(walletID: String, family: HDAccountFamily, path: String?) async throws {
        try await storageWrite { db in
            guard try WalletRecord.fetchOne(db, key: walletID) != nil else { throw StoreError.missingRecord }
            let key = family.originalKey(walletID: walletID), value = path ?? ""
            if try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key=?", arguments: [key]) != value {
                try SettingRecord(key: key, value: value, updatedAt: Date().timeIntervalSince1970).upsert(db)
            }
        }
    }

    public func setHomeEVMAccount(walletID: String, path: String?) async throws {
        try await setHomeAccount(walletID: walletID, selection: path.map { .init(family: .evm, path: $0) })
    }

    public func setHomeAccount(walletID: String, selection: HomeAccountSelection?) async throws {
        try await storageWrite { db in
            guard let wallet = try WalletRecord.fetchOne(db, key: walletID), wallet.deletedAt == nil else { throw StoreError.missingRecord }
            if let selection {
                guard try selection.family.canonicalPath(selection.path) == selection.path,
                      try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM walletAccounts a JOIN networks n ON n.id=a.networkID
                        WHERE a.walletID=? AND a.derivationPath=? AND ((?='solana' AND n.id='solana') OR (?='evm' AND n.family='evm')))
                        """, arguments: [walletID, selection.path, selection.family.rawValue, selection.family.rawValue]) == true else { throw StoreError.missingRecord }
            }
            // One selection across all families, changed in the same transaction.
            for family in HDAccountFamily.allCases {
                try db.execute(sql: "DELETE FROM settings WHERE key=?", arguments: [family.selectionKey(walletID: walletID)])
            }
            if let selection, try Self.hasAdditionalHDAccounts(db, walletID: walletID) {
                try SettingRecord(key: selection.family.selectionKey(walletID: walletID), value: selection.path,
                    updatedAt: Date().timeIntervalSince1970).upsert(db)
            }
        }
    }

    /// Home presentation and refresh scope. Refresh callers capture these account
    /// IDs; backup still reads the full wallet and signing uses exact account IDs.
    /// A wallet row displays its original accounts. Selecting a child replaces
    /// only that family's addresses; the other chains retain their originals.
    public func homeSnapshot(walletID: String, currency: String) async throws -> WalletSnapshot {
        try await pool.read { try Self.homeSnapshot($0, walletID: walletID, currency: currency) }
    }

    public func observeHomeWallet(walletID: String, currency: String) -> AsyncThrowingStream<WalletSnapshot, Error> {
        stream(observing: Self.portfolioObservationTables) { try Self.homeSnapshot($0, walletID: walletID, currency: currency) }
    }

    private static func homeSnapshot(_ db: Database, walletID: String, currency: String) throws -> WalletSnapshot {
        // Presentation omits disabled networks, but account-family membership
        // must use complete metadata, just like history and dApp consent.
        let networks = try NetworkRecord.fetchAll(db)
        return try snapshot(db, walletID: walletID, currency: currency).scopedForHome(accountNetworks: networks)
    }

    public func observeAccountGroups() -> AsyncThrowingStream<[HDAccountFamily: [String: [EVMAccountGroup]]], Error> {
        stream { db in
            let networks = try NetworkRecord.fetchAll(db)
            let accounts = try AccountRecord.fetchAll(db, sql: """
                SELECT a.* FROM walletAccounts a JOIN wallets w ON w.id=a.walletID
                WHERE w.deletedAt IS NULL ORDER BY a.accountIndex,a.id
                """)
            let wallets = Dictionary(grouping: accounts, by: \.walletID)
            let names = try Self.settings(db)
            return Dictionary(uniqueKeysWithValues: HDAccountFamily.allCases.map { family in
                let ids = Set(networks.filter { family.contains($0) }.map(\.id))
                return (family, wallets.mapValues { Self.namedAccountGroups($0, networks: ids, family: family, settings: names) })
            })
        }
    }

    public func observeEVMAccounts() -> AsyncThrowingStream<[String: [EVMAccountGroup]], Error> {
        observeHDAccounts(family: .evm)
    }

    public func observeHDAccounts(family: HDAccountFamily) -> AsyncThrowingStream<[String: [EVMAccountGroup]], Error> {
        stream { db in
            let networks = Set(try String.fetchAll(db, sql: "SELECT id FROM networks WHERE (?='solana' AND id='solana') OR (?='evm' AND family='evm')", arguments: [family.rawValue, family.rawValue]))
            let accounts = try AccountRecord.fetchAll(db, sql: """
                SELECT a.* FROM walletAccounts a JOIN wallets w ON w.id=a.walletID
                WHERE w.deletedAt IS NULL ORDER BY a.accountIndex,a.id
                """)
            let names = try Self.settings(db)
            return Dictionary(grouping: accounts, by: \.walletID).mapValues { Self.namedAccountGroups($0, networks: networks, family: family, settings: names) }
        }
    }
}

extension WalletSnapshot {
    public var selectedAccount: HomeAccountSelection? {
        for family in HDAccountFamily.allCases {
            let ids = Set(networks.filter { family.contains($0) }.map(\.id))
            if let path = settings[family.selectionKey(walletID: wallet.id)],
               accounts.contains(where: { $0.derivationPath == path && ids.contains($0.networkID) }) {
                return .init(family: family, path: path)
            }
        }
        return nil
    }
    public var selectedAccountIdentity: String? { selectedAccount?.identity }
    public var selectedEVMAccountPath: String? { selectedAccount?.family == .evm ? selectedAccount?.path : nil }

    /// Keep only the original account in each managed family at the wallet root.
    func originalAccountsSnapshot() -> Self {
        let selected = Self.originalAccounts(accounts, networks: networks, settings: settings, walletID: wallet.id)
        return selected.count == accounts.count ? self : scoped(to: selected)
    }

    static func originalAccounts(_ accounts: [AccountRecord], networks: [NetworkRecord],
                                 settings: [String: String], walletID: String) -> [AccountRecord] {
        var selected = accounts
        for family in HDAccountFamily.allCases {
            let ids = Set(networks.filter { family.contains($0) }.map(\.id))
            if let originalPath = settings[family.originalKey(walletID: walletID)] {
                selected.removeAll { ids.contains($0.networkID) && $0.derivationPath != originalPath }
                continue
            }
            let groups = EVMAccountGroup.grouped(accounts, networks: ids)
            if groups.count > 1, let first = groups.first {
                selected.removeAll { ids.contains($0.networkID) && $0.derivationPath != first.path }
            }
        }
        return selected
    }

    func scopedForHome(accountNetworks: [NetworkRecord]) -> Self {
        let selected = Self.homeAccounts(accounts, networks: accountNetworks, settings: settings, walletID: wallet.id)
        return selected.count == accounts.count ? self : scoped(to: selected)
    }

    /// One path per managed family, plus every original unmanaged-chain
    /// account. Use this same projection for Home, history and new dApp consent
    /// so selecting a path cannot make an unrelated network disappear.
    static func homeAccounts(_ accounts: [AccountRecord], networks: [NetworkRecord],
                             settings: [String: String], walletID: String) -> [AccountRecord] {
        let original = originalAccounts(accounts, networks: networks, settings: settings, walletID: walletID)
        for family in HDAccountFamily.allCases {
            let networkIDs = Set(networks.filter { family.contains($0) }.map(\.id))
            guard let path = settings[family.selectionKey(walletID: walletID)] else { continue }
            let replacement = accounts.filter { networkIDs.contains($0.networkID) && $0.derivationPath == path }
            guard !replacement.isEmpty else { continue }
            let ids = Set(original.filter { !networkIDs.contains($0.networkID) }.map(\.id))
                .union(replacement.map(\.id))
            return accounts.filter { ids.contains($0.id) }
        }
        return original
    }

    private func scoped(to selected: [AccountRecord]) -> Self {
        let ids = Set(selected.map(\.id)), networkIDs = Set(selected.map(\.networkID))
        let holdings = holdings.filter { ids.contains($0.accountID) }
        let valuation = WalletValuation(id: wallet.id, currency: currency, holdings: holdings, hiddenAssetIDs: hiddenAssetIDs)
        return Self(wallet: wallet, accounts: selected, networks: networks.filter { networkIDs.contains($0.id) },
            holdings: holdings, settings: settings, assetFilter: assetFilter, currency: currency,
            totalFiat: valuation.totalFiat, valuationComplete: valuation.valuationComplete,
            accountSync: accountSync.filter { ids.contains($0.accountID) }, hiddenAssetIDs: hiddenAssetIDs)
    }
}
