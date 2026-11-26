import Foundation
import GRDB
import OathAnkr
import OathDiagnostics

/// The first RPC-catalog integration saved every successful zero probe as a
/// holding. Repair that cache once, before Home observes the stored portfolio.
/// Token metadata and user choices remain intact; no chain call is required.
enum RPCCatalogHoldingRepair {
    static func migrate(_ db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") == nil else { return }
        for chain in [IndexedEVMChain.plasma, .worldchain, .elysium] {
            try OathDiagnostics.$chain.withValue(chain.rawValue) {
                try OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        try db.execute(sql: """
                            DELETE FROM indexedEVMHoldings
                            WHERE reference<>'native' AND amountAtomic='0'
                              AND accountID IN (SELECT id FROM walletAccounts WHERE networkID=?)
                              AND NOT EXISTS(SELECT 1 FROM trackedAssets t
                                  WHERE t.accountID=indexedEVMHoldings.accountID AND t.assetID=indexedEVMHoldings.assetID)
                              AND NOT EXISTS(SELECT 1 FROM activity a
                                  WHERE a.accountID=indexedEVMHoldings.accountID AND a.assetID=indexedEVMHoldings.assetID)
                              AND NOT EXISTS(SELECT 1 FROM sends s
                                  WHERE s.accountID=indexedEVMHoldings.accountID AND s.assetID=indexedEVMHoldings.assetID)
                              AND NOT EXISTS(SELECT 1 FROM balances b
                                  WHERE b.accountID=indexedEVMHoldings.accountID AND b.assetID=indexedEVMHoldings.assetID)
                              AND NOT EXISTS(SELECT 1 FROM hiddenAssets h JOIN walletAccounts c ON c.walletID=h.walletID
                                  WHERE c.id=indexedEVMHoldings.accountID AND h.assetID=indexedEVMHoldings.assetID)
                            """, arguments: [chain.rawValue])
                    } catch {
                        OathDiagnostics.record(error, component: "storage", operation: "repair_rpc_catalog_holdings")
                        throw error // GRDB rolls back both the repair and its migration marker.
                    }
                }
            }
        }
    }
}
