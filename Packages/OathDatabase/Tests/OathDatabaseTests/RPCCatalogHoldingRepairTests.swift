import Foundation
import GRDB
import XCTest
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class RPCCatalogHoldingRepairTests: XCTestCase {
    nonisolated private static let chains: [IndexedEVMChain] = [.plasma, .worldchain, .elysium, .unichain]
    nonisolated private static func reference(_ number: Int) -> String {
        "0x" + String(repeating: "0", count: 39) + String(number)
    }

    private func legacyDatabase(resetPending: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RPCCatalogRepair-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wallet.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase {
            $0.add(function: HistorySafety.metadataFunction)
            $0.add(function: ReceiveQRImage.function)
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Schema.migrator.migrate(queue, upTo: "v111_refresh_relationship_indexes")
        try queue.write { db in
            for wallet in ["first", "second"] {
                try WalletRecord(id: wallet, name: "Fixture", kind: "hd", vaultReference: wallet, createdAt: 1).insert(db)
            }
            for chain in Self.chains {
                let network = chain.rawValue
                try NetworkRecord(id: network, name: chain.name, family: "evm", symbol: chain.symbol, decimals: 18,
                    derivationPath: "", logo: "", sortOrder: 0).insert(db)
                for wallet in ["first", "second"] {
                    try AccountRecord(id: wallet + ":" + network, walletID: wallet, networkID: network,
                        address: "0x1111111111111111111111111111111111111111", derivationPath: "").insert(db)
                }
                for number in 0...7 {
                    let ref = number == 0 ? "native" : Self.reference(number)
                    let asset = network + ":" + ref
                    let token = try IndexedEVMToken(reference: ref, name: "Fixture", symbol: "TKN", decimals: 18)
                    try AssetRecord(id: asset, networkID: network, reference: ref, name: token.name,
                        symbol: token.symbol, decimals: token.decimals).insert(db)
                    for wallet in number <= 2 ? ["first", "second"] : ["first"] {
                        try db.execute(sql: """
                            INSERT INTO indexedEVMHoldings(accountID,reference,assetID,detail,amountAtomic,observedAt,checkpoint,verified)
                            VALUES(?,?,?,?,?,1,100,1)
                            """, arguments: [wallet + ":" + network, ref, asset, try JSONEncoder().encode(token),
                                number == 2 && wallet == "first" ? "1" : "0"])
                    }
                }
                let account = "first:" + network
                try db.execute(sql: "INSERT INTO trackedAssets(accountID,assetID,networkID,addedAt) VALUES(?,?,?,1)",
                    arguments: [account, network + ":" + Self.reference(3), network])
                try db.execute(sql: "INSERT INTO hiddenAssets(walletID,assetID) VALUES('first',?)",
                    arguments: [network + ":" + Self.reference(4)])
                try db.execute(sql: """
                    INSERT INTO sends(id,walletID,accountID,networkID,assetID,senderAddress,idempotencyKey,recipient,amountAtomic,state,createdAt,updatedAt)
                    VALUES(?,'first',?,?,?,'fixture',?,'fixture','1','draft',1,1)
                    """, arguments: [network + ":send", account, network, network + ":" + Self.reference(5), network + ":send"])
                let tx = network + ":history"
                try TransactionRecord(id: tx, networkID: network, hash: "fixture", state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
                try ActivityRecord(id: tx, walletID: "first", accountID: account, networkID: network, transactionID: tx,
                    assetID: network + ":" + Self.reference(6), direction: "outgoing", amountAtomic: "1", counterparty: "fixture", timestamp: 1).insert(db)
                try db.execute(sql: """
                    INSERT INTO balances(accountID,assetID,networkID,amountAtomic,observedAt,source) VALUES(?,?,?,'0',1,'fixture')
                    """, arguments: [account, network + ":" + Self.reference(7), network])
            }
            if resetPending { try db.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletReset','fixture')") }
        }
        try queue.close()
        return url
    }

    func testUpgradeRepairsOldCatalogRowsWithoutRemovingWalletChoicesOrEvidence() async throws {
        let url = try legacyDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for attempt in 0..<2 {
            let database = try await OathDatabase.open(at: url)
            let first = try await database.snapshot(walletID: "first", currency: "USD")
            XCTAssertEqual(first.holdings.count, 29)
            XCTAssertEqual(Set(first.holdings.map(\.id)).count, first.holdings.count,
                "A generic cached balance must not duplicate the authoritative RPC holding")
            for chain in Self.chains {
                let references = try await database.pool.read { db in
                    try String.fetchAll(db, sql: "SELECT reference FROM indexedEVMHoldings WHERE accountID=?",
                        arguments: ["first:" + chain.rawValue])
                }
                XCTAssertEqual(references.count, chain.usesRPCCatalog ? 7 : 8)
                XCTAssertEqual(references.contains(Self.reference(1)), !chain.usesRPCCatalog)
                for number in 2...7 { XCTAssertTrue(references.contains(Self.reference(number))) }
                let second = try await database.snapshot(walletID: "second", currency: "USD")
                XCTAssertEqual(second.holdings.filter { $0.networkID == chain.rawValue }.count, chain.usesRPCCatalog ? 1 : 3,
                    "The same address/contract in another wallet does not inherit ownership or tracking")
            }
            let counts = try await database.pool.read { db in
                try ["wallets", "assets", "trackedAssets", "hiddenAssets", "activity", "sends"].map {
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")!
                }
            }
            XCTAssertEqual(counts, [2, 32, 4, 4, 4, 4])
            if attempt == 0 {
                // After repair, an owned token reaching zero stays known across
                // subsequent launches; the cleanup must not run on every open.
                try await database.pool.write { db in
                    try db.execute(sql: "UPDATE indexedEVMHoldings SET amountAtomic='0' WHERE reference=?",
                        arguments: [Self.reference(2)])
                }
            }
        }
    }

    func testPendingResetKeepsItsOwnCleanupInControl() async throws {
        let url = try legacyDatabase(resetPending: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try await OathDatabase.open(at: url)
        let count = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM indexedEVMHoldings") }
        XCTAssertEqual(count, 44)
    }
}
