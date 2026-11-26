import Foundation
import GRDB

/// Historical assets remain readable even when they have no current balance.
public struct ChainHistoryItem: Sendable, Equatable, Identifiable {
    public let entry: HistoryEntry
    public let holding: Holding
    public var outputHolding: Holding? = nil
    public var receivedAtomic: String? = nil
    public var bridgeProtocol: String? = nil
    public var outputTransactionID: String? = nil
    public var outputTransactionHash: String? = nil
    public var id: String { entry.id }

    public init(entry: HistoryEntry, holding: Holding) {
        self.entry = entry
        self.holding = holding
    }


}

extension OathDatabase {
    // Views expand to their source tables. Include conditional receipt reads even
    // when the initial page is empty or contains no self-transfers.
    static let historyObservationTables = [
        "projectedHistoryActivity", "transactions", "walletAccounts", "assets", "networks",
        "transactionEvidence", "prices", "exchangeRates", "settings", "solanaActivity",
        "solanaReceiveAddresses", "transfers", "transactionParticipants", "evmHistorySwaps",
        "indexedEVMEvents", "suiTransactions", "sends", "solanaTransactions", "stellarEvents",
        "xrplTransactions", "aptosTransactions"
    ]

    public func chainHistory(walletID: String, networkID: String? = nil,
                             accountID: String? = nil, assetID: String? = nil, currency: String,
                             before: HistoryCursor? = nil, limit: Int = 50, search: String = "", filter: HistoryFilter = .init(),
                             localeIdentifier: String = Locale.autoupdatingCurrent.identifier, homeScope: Bool = false) async throws -> [ChainHistoryItem] {
        try await pool.read {
            try Self.readChainHistory($0, walletID: walletID, networkID: networkID, accountID: accountID, assetID: assetID, currency: currency,
                                      before: before, limit: Self.pageSize(limit), search: search, filter: filter, localeIdentifier: localeIdentifier, homeScope: homeScope)
        }
    }

    /// Grow the visible window without losing live updates to earlier pages.
    public func observeChainHistory(walletID: String, networkID: String? = nil,
                                    accountID: String? = nil, assetID: String? = nil, currency: String,
                                    limit: Int = 51, search: String = "", filter: HistoryFilter = .init(),
                                    localeIdentifier: String = Locale.autoupdatingCurrent.identifier, homeScope: Bool = false) -> AsyncThrowingStream<[ChainHistoryItem], Error> {
        stream(observing: Self.historyObservationTables) {
            try Self.readChainHistory($0, walletID: walletID, networkID: networkID, accountID: accountID, assetID: assetID, currency: currency,
                                      before: nil, limit: max(1, limit), search: search, filter: filter, localeIdentifier: localeIdentifier, homeScope: homeScope)
        }
    }

    static func readChainHistory(_ db: Database, walletID: String, networkID: String?,
                                         accountID: String?, assetID: String?, currency: String,
                                         before: HistoryCursor?, limit: Int, search: String, filter: HistoryFilter,
                                         localeIdentifier: String, transactionID: String? = nil, homeScope: Bool = false) throws -> [ChainHistoryItem] {
        guard filter.isValid else { throw StoreError.invalidValue("history filter") }
        let scopeIDs = homeScope ? try homeAccountIDs(db, walletID: walletID) : nil
        let selectedOwner = """
            (a.networkID<>'solana' OR EXISTS (SELECT 1 FROM solanaActivity sa WHERE sa.activityID=a.id
                AND sa.owner=COALESCE((SELECT address FROM solanaReceiveAddresses WHERE accountID=a.accountID AND isSelected=1),owner.address)))
            """
        var source = "projectedHistoryActivity"
        var sourceArguments: StatementArguments = []
        if networkID == nil, accountID == nil, assetID == nil, transactionID == nil,
           search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, filter == HistoryFilter() {
            // Home keeps this first page ready during balance refresh. Apply
            // visibility, account ownership and pagination before enriching rows
            // with current quotes. Otherwise every price commit joins/prices the
            // entire wallet history just to retain the newest 51 entries.
            var page = """
                SELECT a.* FROM projectedHistoryActivity a WHERE a.walletID=?
                AND EXISTS (SELECT 1 FROM walletAccounts owner WHERE owner.id=a.accountID
                    AND owner.walletID=? AND \(selectedOwner)
                """
            sourceArguments = [walletID, walletID]
            if let scopeIDs {
                page += " AND owner.id IN (" + Array(repeating: "?", count: scopeIDs.count).joined(separator: ",") + ")"
                sourceArguments += StatementArguments(scopeIDs.sorted())
            }
            page += ")"
            if let before {
                page += " AND (a.sortTimestamp,a.id) < (?,?)"
                sourceArguments += [before.timestamp, before.id]
            }
            page += " ORDER BY a.sortTimestamp DESC,a.id DESC LIMIT ?"
            sourceArguments += [limit]
            source = "(" + page + ")"
        }
        var sql = """
            SELECT a.id,a.accountID,a.networkID,a.transactionID,a.assetID,a.direction,
                   a.amountAtomic,a.counterparty,a.sortTimestamp AS timestamp,a.outputAssetID,a.received,a.outputAccountID,a.outputTransactionID,a.bridgeProtocol,(SELECT hash FROM transactions WHERE id=a.outputTransactionID) AS outputHash,
                   COALESCE(e.outcome,t.state) AS state,t.hash,
                   s.reference,s.name,s.symbol,s.decimals,
                   CASE WHEN s.reference='native' THEN COALESCE(s.logo,n.logo) ELSE s.logo END AS logo,COALESCE((SELECT owner FROM solanaActivity WHERE activityID=a.id),owner.address) AS address,
                   p.value AS usdPrice,p.observedAt AS priceObservedAt,p.source AS priceSource
            FROM \(source) a JOIN transactions t ON t.id=a.transactionID
            JOIN walletAccounts owner ON owner.id=a.accountID
            JOIN assets s ON s.id=a.assetID
            JOIN networks n ON n.id=a.networkID
            LEFT JOIN assets output ON output.id=a.outputAssetID
            LEFT JOIN transactionEvidence e ON e.accountID=a.accountID AND e.transactionID=a.transactionID
            LEFT JOIN prices p ON p.assetID=a.assetID AND p.currency='USD'
                AND p.observedAt=(SELECT observedAt FROM prices WHERE assetID=a.assetID AND currency='USD' AND \(PriceRecord.currentSourcePredicate) ORDER BY \(PriceRecord.preferredOrder) LIMIT 1)
            WHERE a.walletID=? AND owner.walletID=?
            """
        sql += " AND " + selectedOwner
        var args = sourceArguments + [walletID, walletID]
        if let ids = scopeIDs {
            sql += " AND owner.id IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")"
            args += StatementArguments(ids.sorted())
        }
        let rate = try Self.exchangeRates(db)?.rate(for: currency) ?? (currency == "USD" ? 1 : nil)
        if let networkID {
            sql += " AND (a.networkID=? OR a.outputNetworkID=?)"
            args += [networkID, networkID]
        }
        // Asset View All keeps exactly the preview's account and asset scope,
        // including when searching, paging, and observing background updates.
        if let transactionID { sql += " AND (a.transactionID=? OR a.outputTransactionID=?)"; args += [transactionID, transactionID] }
        if let accountID {
            sql += " AND (a.accountID=? OR a.outputAccountID=?)"
            args += [accountID, accountID]
        }
        if let assetID {
            sql += " AND (a.assetID=? OR a.outputAssetID=?)"
            args += [assetID, assetID]
        }
        func selected(_ values: [String], column: String) {
            guard !values.isEmpty else { return }
            sql += " AND \(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))"
            args += StatementArguments(values.sorted())
        }
        if !filter.networkIDs.isEmpty {
            let ids = filter.networkIDs.sorted(), marks = Array(repeating: "?", count: filter.networkIDs.count).joined(separator: ",")
            sql += " AND (a.networkID IN (\(marks)) OR a.outputNetworkID IN (\(marks)))"
            args += StatementArguments(ids + ids)
        }
        if !filter.assetIDs.isEmpty {
            let ids = filter.assetIDs.sorted()
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            sql += " AND (a.assetID IN (\(marks)) OR a.outputAssetID IN (\(marks)))"
            args += StatementArguments(ids + ids)
        }
        var directions = filter.directions.map(\.rawValue)
        if filter.directions.contains(.swap) { directions += ["bridge", "bridgeOutgoing", "bridgeIncoming"] }
        selected(directions, column: "a.direction")
        selected(filter.statuses.map(\.rawValue), column: "COALESCE(e.outcome,t.state)")
        if let start = filter.startDate {
            sql += " AND a.sortTimestamp>=?"
            args += [start.timeIntervalSince1970]
        }
        if let end = filter.endDate {
            sql += " AND a.sortTimestamp<? AND a.sortTimestamp>0"
            args += [end.timeIntervalSince1970]
        }
        if filter.minimumAmount != nil || filter.maximumAmount != nil {
            func amountPredicate(_ atomic: String, _ decimals: String) -> String {
                let predicate = "oath_history_amount_in_range(\(atomic),\(decimals),?,?)"
                args += [filter.minimumAmount, filter.maximumAmount]
                return "(" + predicate + ")"
            }
            let sent = amountPredicate("a.amountAtomic", "s.decimals")
            let received = amountPredicate("a.received", "output.decimals")
            sql += " AND (\(sent) OR (a.outputAssetID IS NOT NULL AND \(received)))"
        }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Search the entire wallet/chain BEFORE LIMIT. Transfers include all
            // senders/recipients, not only the representative counterparty.
            sql += "\n" + """
                AND oath_history_matches(
                    s.name || ' ' || s.symbol || ' ' || s.reference || ' ' || COALESCE(output.name || ' ' || output.symbol || ' ' || output.reference,'') || ' ' || n.name || ' ' || a.networkID || ' ' || COALESCE(a.outputNetworkID,'') || ' ' || COALESCE((SELECT name FROM networks WHERE id=a.outputNetworkID),'') || ' ' ||
                    t.hash || ' ' || COALESCE((SELECT hash FROM transactions WHERE id=a.outputTransactionID),'') || ' ' || a.direction || ' ' || COALESCE(e.outcome,t.state) || ' ' ||
                    COALESCE(a.counterparty,'') || ' ' || owner.address || ' ' ||
                    COALESCE((SELECT owner FROM solanaActivity WHERE activityID=a.id),'') || ' ' ||
                    COALESCE((SELECT group_concat(fromAddress || ' ' || toAddress,' ') FROM transfers tr
                              WHERE tr.transactionID=a.transactionID AND tr.assetID=a.assetID),'') || ' ' ||
                    COALESCE((SELECT group_concat(address,' ') FROM transactionParticipants tp
                              WHERE tp.accountID=a.accountID AND tp.transactionID=a.transactionID),''),
                    a.amountAtomic,s.decimals,p.value,?,?,?,?)
                """
            args += [rate.map { NSDecimalNumber(decimal: $0).stringValue }, currency, localeIdentifier, search]
        }
        if let before {
            sql += " AND (a.sortTimestamp,a.id) < (?,?)"
            args += [before.timestamp, before.id]
        }
        sql += " ORDER BY a.sortTimestamp DESC,a.id DESC LIMIT ?"
        args += [limit]
        // Live price/history commits reuse the same query shape. Keep the
        // prepared statement on its reader connection, with fresh bindings and
        // a fresh database snapshot on every fetch (never cache transaction rows).
        let items = try Row.fetchAll(db, SQLRequest<Row>(sql: sql, arguments: args, cached: true)).map { row in
            let entry = try Self.projectSelfTransferFee(HistoryEntry(row: row), db: db)
            let holding = Holding(accountID: entry.accountID, networkID: entry.networkID, address: row["address"],
                assetID: entry.assetID, reference: row["reference"], name: row["name"], symbol: row["symbol"],
                decimals: row["decimals"], logo: row["logo"], amountAtomic: nil, balanceObservedAt: nil,
                usdPrice: row["usdPrice"], exchangeRate: rate.map { NSDecimalNumber(decimal: $0).stringValue },
                priceObservedAt: row["priceObservedAt"], priceSource: row["priceSource"], transactionCount: 0)
            var item = ChainHistoryItem(entry: entry, holding: holding)
            item.bridgeProtocol = row["bridgeProtocol"]
            item.outputTransactionID = row["outputTransactionID"]
            item.outputTransactionHash = row["outputHash"]
            if let outputID: String = row["outputAssetID"] {
                item.outputHolding = try Self.historyHolding(db, accountID: row["outputAccountID"] ?? entry.accountID, assetID: outputID, currency: currency)
                item.receivedAtomic = row["received"]
            }
            return item
        }
        return items
    }

    static func historyHolding(_ db: Database, accountID: String, assetID: String, currency: String) throws -> Holding? {
        guard let asset = try AssetRecord.fetchOne(db, key: assetID), let account = try AccountRecord.fetchOne(db,key: accountID) else { return nil }
        let row = try Row.fetchOne(db, sql: "SELECT value,observedAt,source FROM prices WHERE assetID=? AND currency='USD' AND \(PriceRecord.currentSourcePredicate) ORDER BY \(PriceRecord.preferredOrder) LIMIT 1", arguments: [assetID])
        let rate = try exchangeRates(db)?.rate(for: currency) ?? (currency == "USD" ? 1 : nil)
        return Holding(accountID: accountID, networkID: asset.networkID, address: account.address,
            assetID: assetID, reference: asset.reference, name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
            logo: asset.logo, amountAtomic: nil, balanceObservedAt: nil, usdPrice: row?["value"],
            exchangeRate: rate.map { NSDecimalNumber(decimal: $0).stringValue }, priceObservedAt: row?["observedAt"],
            priceSource: row?["source"], transactionCount: 0)
    }
}
