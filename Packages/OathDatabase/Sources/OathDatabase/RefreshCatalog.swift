import Foundation
import GRDB
import OathDiagnostics

struct RefreshAssetMetadata: Sendable {
    let name: String
    let symbol: String
    let logo: String?
}

extension OathDatabase {
    /// Never waits for a public metadata service before publishing quantities.
    func refreshCatalog<T: Decodable & Sendable>(key: String, fallback: T) async -> T {
        await OathDiagnostics.attempt("cached_refresh_catalog") {
            guard let saved = try await marketCache(key: key) else { return fallback }
            return try JSONDecoder().decode(T.self, from: saved.payload)
        } ?? fallback
    }

    /// Enrichment writes display metadata and verification, never old balances,
    /// timestamps or checkpoints over newer refresh/send results.
    func applyRefreshCatalog(account: AccountRecord, runID: String, owner: String? = nil,
                             enrichment: @escaping @Sendable (AssetRecord) -> RefreshAssetMetadata? = { _ in nil },
                             verifies: @escaping @Sendable (AssetRecord) -> Bool) async throws {
        let prefix: String
        switch account.networkID {
        case "unichain", "monad", "celo", "chiliz", "filecoin", "sei", "zerog", "iotex", "story": prefix = "indexedEVM"
        case "hyperevm", "robinhood", "arc", "solana", "tron", "aptos", "sui", "near", "xrpl", "stellar": prefix = account.networkID
        default: throw StoreError.invalidValue("Refresh catalog network")
        }
        try Task.checkCancellation()
        try await storageWrite { db in
            try Self.requireWalletSyncAllowed(db)
            guard let current = try AccountRecord.fetchOne(db, key: account.id),
                  current.syncGeneration == account.syncGeneration, current.address == account.address,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(prefix)Sync WHERE accountID=? AND runID=?)",
                                    arguments: [account.id,runID]) == true else { throw StoreError.staleSync }
            if let owner {
                let selected = try String.fetchOne(db, sql: "SELECT address FROM solanaReceiveAddresses WHERE accountID=? AND isSelected=1", arguments: [account.id]) ?? account.address
                guard selected == owner else { throw StoreError.staleSync }
            }
            let assets = try AssetRecord.fetchAll(db, sql: "SELECT a.* FROM assets a JOIN \(prefix)Holdings h ON h.assetID=a.id WHERE h.accountID=?", arguments: [account.id])
            for asset in assets where verifies(asset) {
                if asset.reference != "native", let metadata = enrichment(asset) {
                    var updated = asset
                    updated.name = metadata.name; updated.symbol = metadata.symbol; updated.logo = metadata.logo ?? asset.logo
                    if updated != asset { try updated.update(db) }
                }
                if let owner {
                    try db.execute(sql: "UPDATE \(prefix)Holdings SET verified=1 WHERE accountID=? AND assetID=? AND owner=?", arguments: [account.id,asset.id,owner])
                } else {
                    try db.execute(sql: "UPDATE \(prefix)Holdings SET verified=1 WHERE accountID=? AND assetID=?", arguments: [account.id,asset.id])
                }
            }
        }
    }
}
