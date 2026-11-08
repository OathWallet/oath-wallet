import Foundation
import GRDB
import OathAnkr
import OathDiagnostics

extension OathDatabase {
    func knownAnkrBalanceAssets(account: AccountRecord) async throws -> [AssetRecord] {
        try await pool.read { db in
            let unverified = !(try Self.portfolioFilter(db, walletID: account.walletID)).hidesUnverifiedTokens
            return try AssetRecord.fetchAll(db, sql: """
                SELECT DISTINCT a.* FROM assets a
                LEFT JOIN balances b ON b.assetID=a.id AND b.accountID=?
                LEFT JOIN ankrAssets aa ON aa.assetID=a.id AND aa.accountID=?
                LEFT JOIN trackedAssets t ON t.assetID=a.id AND t.accountID=?
                WHERE a.networkID=? AND (a.reference='native' OR t.assetID IS NOT NULL
                    OR (b.assetID IS NOT NULL AND (? OR aa.onlyWhitelisted=1)))
                """, arguments: [account.id,account.id,account.id,account.networkID,unverified])
        }
    }

    /// Quantity authority is a validated RPC snapshot. Indexer payloads are
    /// archived separately and can never replace these units or synthesize zero.
    func commitVerifiedAnkrBalances(_ value: EVMPortfolioBalances, ticket: AnkrSyncTicket,
        pages: [AnkrPage<AnkrBalanceResult>] = [], verifiedReferences: Set<String> = [],
        discoveryComplete: Bool, final: Bool) async throws {
        guard value.networkID == ticket.account.networkID,
              value.owner.lowercased() == ticket.account.address.lowercased(), value.height >= 0 else {
            throw StoreError.conflictingIdentity
        }
        try await storageWrite { db in
            var state = try Self.validateAnkr(ticket, db: db)
            let now = value.observedAt.timeIntervalSince1970
            for page in pages {
                for item in page.value.assets {
                    guard item.blockchain == AnkrChain(networkID: ticket.account.networkID)?.rawValue,
                          item.holderAddress.lowercased() == ticket.account.address.lowercased() else { throw StoreError.conflictingIdentity }
                    // Failed reads do not create an unvalidated asset identity.
                    guard value.amounts[item.reference] != nil else { continue }
                    if let known = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID=? AND reference=?", arguments: [ticket.account.networkID,item.reference]),
                       known.decimals != item.tokenDecimals { continue }
                    let asset = try Self.ankrAsset(networkID: ticket.account.networkID, reference: item.reference,
                        name: item.tokenName, symbol: item.tokenSymbol, decimals: item.tokenDecimals, logo: item.thumbnail, db: db)
                    let old = try Bool.fetchOne(db, sql: "SELECT onlyWhitelisted FROM ankrAssets WHERE accountID=? AND assetID=?", arguments: [ticket.account.id,asset.id]) ?? false
                    try db.execute(sql: """
                        INSERT INTO ankrAssets(accountID,assetID,detail,balanceUsd,fetchedAt,onlyWhitelisted) VALUES(?,?,?,?,?,?)
                        ON CONFLICT(accountID,assetID) DO UPDATE SET detail=excluded.detail,balanceUsd=excluded.balanceUsd,
                            fetchedAt=excluded.fetchedAt,onlyWhitelisted=excluded.onlyWhitelisted
                        """, arguments: [ticket.account.id,asset.id,try JSONEncoder().encode(item),item.balanceUsd,page.fetchedAt.timeIntervalSince1970,
                            item.reference == "native" || verifiedReferences.contains(item.reference) || old])
                    // Keep quotes on their provider timestamp, not the RPC's.
                    if let stamp = page.value.syncStatus?.timestamp, stamp <= now + 60, now - stamp <= 900,
                       !item.tokenPrice.isEmpty, item.tokenPrice.utf8.contains(where: { (49...57).contains($0) }) {
                        // A malformed optional quote cannot roll back verified quantities.
                        if OathDiagnostics.attempt("validate_indexer_quote", body: { try Validation.price(item.tokenPrice) }) != nil {
                            try PriceRecord(assetID: asset.id, currency: "USD", value: item.tokenPrice, observedAt: stamp, source: "ankr").upsert(db)
                            try db.execute(sql: """
                                DELETE FROM prices WHERE assetID=? AND currency='USD' AND observedAt NOT IN (
                                    SELECT observedAt FROM prices WHERE assetID=? AND currency='USD' ORDER BY observedAt DESC LIMIT 256)
                                """, arguments: [asset.id,asset.id])
                        }
                    }
                }
            }
            for (reference, amount) in value.amounts {
                guard let asset = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID=? AND reference=?",
                    arguments: [ticket.account.networkID,reference]) else { throw StoreError.missingRecord }
                try Validation.amount(amount)
                let old = try BalanceRecord.fetchOne(db, key: ["accountID": ticket.account.id, "assetID": asset.id])
                guard old?.blockHeight.map({ $0 <= value.height }) ?? true,
                      old?.blockHeight != value.height || (old?.observedAt ?? 0) <= now else { continue }
                try BalanceRecord(accountID: ticket.account.id, assetID: asset.id, networkID: asset.networkID,
                    amountAtomic: amount, observedAt: now, blockHeight: value.height, source: "rpc").upsert(db)
            }
            if final {
                let complete = discoveryComplete && value.failedReferences.isEmpty
                state.complete = complete; state.failure = complete ? nil : "incompleteInventory"
                if complete { state.lastSuccess = now }
                state.syncStatus = try pages.last?.value.syncStatus.map { try JSONEncoder().encode($0) }
                state.cursor = nil; state.runID = nil
                try state.update(db)
                for (index, page) in pages.enumerated() {
                    try Self.saveAnkrResponse(page.raw, ticket: ticket, key: String(index), date: page.fetchedAt, db: db)
                }
            }
        }
    }
}
