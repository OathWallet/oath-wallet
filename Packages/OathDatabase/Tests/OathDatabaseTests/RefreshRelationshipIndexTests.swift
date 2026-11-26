import Foundation
import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class RefreshRelationshipIndexTests: XCTestCase {
    func testEveryRelationshipLookupUsesAnIndex() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let scans = try await store.pool.read { try Self.relationshipScans($0) }
        XCTAssertEqual(scans, [], "Refresh metadata writes must not scan child ledgers for foreign keys")
    }

    func testUpgradeIndexesExistingDatabaseWithoutChangingWalletData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("db.sqlite").path
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: HistorySafety.metadataFunction)
            db.add(function: ReceiveQRImage.function)
        }
        let legacy = try DatabaseQueue(path: path, configuration: configuration)
        try Schema.migrator.migrate(legacy, upTo: "v110_thorchain_protocol_history")
        try await legacy.write { db in
            try NetworkRecord(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18,
                              derivationPath: "", logo: "", sortOrder: 0).insert(db)
            try AssetRecord(id: "asset", networkID: "ethereum", reference: "native", name: "Ethereum",
                            symbol: "ETH", decimals: 18).insert(db)
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('wallet','Synthetic','hd','fixture',1,0)")
            try AccountRecord(id: "account", walletID: "wallet", networkID: "ethereum",
                              address: "fixture", derivationPath: "").insert(db)
            try BalanceRecord(accountID: "account", assetID: "asset", networkID: "ethereum",
                              amountAtomic: "123456789", observedAt: 42, source: "fixture").insert(db)
        }
        let before = try await legacy.read { try Self.relationshipScans($0) }
        XCTAssertTrue(before.contains { $0.hasPrefix("evmHistorySwaps(transactionID)") })
        XCTAssertTrue(before.contains { $0.hasPrefix("hiddenAssets(assetID)") })
        try Schema.migrator.migrate(legacy)
        let after = try await legacy.read { db in
            (try Self.relationshipScans(db), try BalanceRecord.fetchOne(db, sql: "SELECT * FROM balances"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='index'"))
        }
        XCTAssertEqual(after.0, [])
        XCTAssertEqual(after.1?.amountAtomic, "123456789")
        XCTAssertEqual(after.1?.observedAt, 42)
        // Reopening an already migrated database must not add redundant indexes.
        try Schema.migrator.migrate(legacy)
        let count = try await legacy.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE type='index'") }
        XCTAssertEqual(count, after.2)
        try legacy.close()
    }

    private nonisolated static func relationshipScans(_ db: Database) throws -> [String] {
        var scans: [String] = []
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        for table in tables {
            for key in try db.foreignKeys(on: table) {
                let predicate = key.originColumns.map { "\($0.quotedDatabaseIdentifier)=?" }.joined(separator: " AND ")
                let arguments = StatementArguments(key.originColumns.map { _ in "fixture" })
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT 1 FROM \(table.quotedDatabaseIdentifier) WHERE \(predicate)",
                                           arguments: arguments).map { (row: Row) -> String in row["detail"] }
                if !plan.contains(where: { $0.hasPrefix("SEARCH ") }) {
                    scans.append(table + "(" + key.originColumns.joined(separator: ",") + "): " + plan.joined(separator: "; "))
                }
            }
        }
        return scans
    }
}
