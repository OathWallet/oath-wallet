import Foundation
import GRDB

/// New consent follows Home. An existing session resolves only its already
/// approved address among owned accounts, independently of Home's selection.
public enum WalletConnectAccountScope: Sendable {
    case connection, session
}

/// Consent identity excludes mutable balance/sync metadata. Address and path
/// remain part of it even when a receive-path change keeps the account ID.
public struct WalletConnectAccountIdentity: Hashable, Sendable {
    public let id: String
    public let walletID: String
    public let networkID: String
    public let address: String
    public let path: String

    public init(_ account: AccountRecord) {
        id = account.id; walletID = account.walletID; networkID = account.networkID
        address = account.address; path = account.derivationPath
    }
}

extension OathDatabase {
    public func walletConnectAccounts(walletID: String, scope: WalletConnectAccountScope) async throws -> [AccountRecord] {
        try await pool.read { db in
            guard let wallet = try WalletRecord.fetchOne(db, key: walletID), wallet.deletedAt == nil else { return [] }
            var records = try Self.accounts(db, walletID: walletID)
            if case .connection = scope, let ids = try Self.homeAccountIDs(db, walletID: walletID) {
                records.removeAll { !ids.contains($0.id) }
            }
            // Read the selection and owned addresses in the same DB snapshot.
            // Legacy Solana wallets have multiple receive paths under one ID;
            // independent added accounts have exactly one path.
            return try records.flatMap { account -> [AccountRecord] in
                guard account.networkID == "solana" else { return [account] }
                var rows = try Row.fetchAll(db, sql: "SELECT address,path,isSelected FROM solanaReceiveAddresses WHERE accountID=? ORDER BY path", arguments: [account.id])
                guard !rows.isEmpty else { return [account] }
                if case .connection = scope {
                    rows = rows.filter { $0["isSelected"] as Bool }
                    guard rows.count == 1 else { throw StoreError.conflictingIdentity }
                }
                return rows.map { row in
                    var resolved = account
                    resolved.address = row["address"]; resolved.derivationPath = row["path"]
                    return resolved
                }
            }
        }
    }
}
