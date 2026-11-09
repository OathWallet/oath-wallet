import Foundation
import GRDB

/// A wallet-scoped inventory for management, independent of all Home filters.
public struct ManagedAssetsSnapshot: Sendable, Equatable {
    public let walletID: String
    public let networks: [NetworkRecord]
    public let assets: [AssetRecord]
    public let holdings: [Holding]
    public let hiddenAssetIDs: Set<String>

    public func matchingCount(filter: PortfolioFilter, currency: String, locale: Locale) -> Int {
        filter.applying(to: holdings.filter {
            !hiddenAssetIDs.contains($0.assetID) && (!filter.hidesUnverifiedTokens || $0.isVerifiedForHome)
        }, currency: currency, locale: locale).count
    }
}

extension OathDatabase {
    public func managedAssets(walletID: String, currency: String) async throws -> ManagedAssetsSnapshot {
        try await pool.read { try Self.managedAssets($0, walletID: walletID, currency: currency) }
    }

    public func observeManagedAssets(walletID: String, currency: String) -> AsyncThrowingStream<ManagedAssetsSnapshot, Error> {
        stream { try Self.managedAssets($0, walletID: walletID, currency: currency) }
    }

    private static func managedAssets(_ db: Database, walletID: String, currency: String) throws -> ManagedAssetsSnapshot {
        guard let wallet = try WalletRecord.fetchOne(db, key: walletID), wallet.deletedAt == nil else { throw StoreError.missingRecord }
        try Validation.currency(currency)
        let holdings = try holdings(db, walletID: walletID, currency: currency, hidesUnverifiedTokens: false, includeAllAssets: false)
        let hidden = Set(try String.fetchAll(db, sql: "SELECT assetID FROM hiddenAssets WHERE walletID=?", arguments: [walletID]))
        // Discovery may know an identity before a valid quantity is available.
        // Neither a failed fresh ANKR read nor an unresolved NEAR balance should
        // turn an already discovered asset into a disabled catalog-only row.
        let discovered = try String.fetchAll(db, sql: """
            SELECT h.assetID FROM ankrAssets h JOIN walletAccounts c ON c.id=h.accountID WHERE c.walletID=?
            UNION SELECT h.assetID FROM nearHoldings h JOIN walletAccounts c ON c.id=h.accountID
            WHERE c.walletID=? AND h.assetID IS NOT NULL
            """, arguments: [walletID, walletID])
        let ids = Set(holdings.map(\.assetID)).union(hidden).union(discovered)
        let assets = try AssetRecord.fetchAll(db, sql: """
            SELECT a.* FROM assets a JOIN networks n ON n.id=a.networkID WHERE n.enabled=1
            AND EXISTS(SELECT 1 FROM walletAccounts c WHERE c.walletID=? AND c.networkID=a.networkID)
            ORDER BY a.name COLLATE NOCASE,a.id
            """, arguments: [walletID]).filter { ids.contains($0.id) }
        let networks = try NetworkRecord.fetchAll(db, sql: """
            SELECT * FROM networks WHERE enabled=1 AND id IN (SELECT networkID FROM walletAccounts WHERE walletID=?)
            """, arguments: [walletID])
        return .init(walletID: walletID, networks: networks, assets: assets, holdings: holdings, hiddenAssetIDs: hidden)
    }

    /// Identity, tracking and visibility commit together, or none of them do.
    @discardableResult
    public func enableManagedToken(_ input: AssetRecord, walletID: String) async throws -> AssetRecord {
        try await storageWrite { db in
            let asset = try Self.trackAsset(input, walletID: walletID, db: db)
            try db.execute(sql: "DELETE FROM hiddenAssets WHERE walletID=? AND assetID=?", arguments: [walletID, asset.id])
            return asset
        }
    }
}
