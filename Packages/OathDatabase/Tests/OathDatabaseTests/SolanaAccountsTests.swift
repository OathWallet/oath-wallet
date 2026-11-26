import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class SolanaAccountsTests: XCTestCase {
    func testHardenedPathsAndDefaultAccountAllocation() throws {
        let family = HDAccountFamily.solana
        XCTAssertEqual(try family.canonicalPath(" m/044h/501H/01'/0' "), "m/44'/501'/1'/0'")
        XCTAssertEqual(try family.paths(in: "m/44'/501'/1'\nm/44'/501'/7'/9'"), ["m/44'/501'/1'", "m/44'/501'/7'/9'"])
        for invalid in ["m/44'/501'/0/0'", "m/44'/501'/2147483648'", "m/44'/501'/*'", "m/0", "m/"] {
            XCTAssertThrowsError(try family.canonicalPath(invalid))
        }
        XCTAssertThrowsError(try family.paths(in: "m/1h\nm/1'"))
        XCTAssertEqual(try family.nextDefaultPath(existing: ["m/44'/501'/0'", "m/44'/501'/1'/0'"]), "m/44'/501'/2'/0'")
    }

    func testSolanaAndEVMSelectionsPreserveOtherFamilyAcrossReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("db.sqlite")
        let db = try await OathDatabase.open(at: url)
        let first = "m/44'/501'/0'/0'", second = "m/44'/501'/1'/0'"
        // The same custom path can exist on two curves; family is part of the identity.
        try await db.seed(networks: ["solana", "ethereum"].map {
            NetworkRecord(id: $0, name: $0, family: $0 == "solana" ? "account" : "evm", symbol: "TEST", decimals: 0, derivationPath: first, logo: "", sortOrder: 0)
        }, assets: ["solana", "ethereum"].map {
            AssetRecord(id: $0, networkID: $0, reference: "native", name: $0, symbol: "TEST", decimals: 0)
        })
        let wallet = WalletRecord(id: "w", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1)
        let accounts = ["solana", "ethereum"].flatMap { network in
            [first, second].enumerated().map { index, path in
                AccountRecord(id: network + String(index), walletID: "w", networkID: network,
                    address: index == 0 ? "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL" : "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk", derivationPath: path, accountIndex: index)
            }
        }
        try await db.importWalletIfNeeded(wallet, accounts: accounts)
        try await db.savePrices(["solana", "ethereum"].map { .init(assetID: $0, currency: "USD", value: "2", observedAt: 1, source: "fixture") })
        try await db.pool.write { sql in
            for (i, account) in accounts.enumerated() {
                try BalanceRecord(accountID: account.id, assetID: account.networkID, networkID: account.networkID,
                    amountAtomic: String(i + 1), observedAt: 100, source: "fixture").insert(sql)
                if account.networkID == "solana" {
                    try sql.execute(sql: "INSERT INTO solanaHoldings(accountID,owner,assetID,amountAtomic,observedAt,slot,verified) VALUES(?,?,?,?,?,?,?)",
                        arguments: [account.id, account.address, "solana", String(i + 1), 100, 100, true])
                }
                try TransactionRecord(id: account.id, networkID: account.networkID, hash: account.id, state: "confirmed", timestamp: 100, updatedAt: 100).insert(sql)
                try ActivityRecord(id: account.id, walletID: "w", accountID: account.id, networkID: account.networkID,
                    transactionID: account.id, assetID: account.networkID, direction: "incoming", amountAtomic: "1", counterparty: "public", timestamp: 100).insert(sql)
                if account.networkID == "solana" {
                    try sql.execute(sql: "INSERT INTO solanaActivity(activityID,owner) VALUES(?,?)", arguments: [account.id, account.address])
                }
            }
        }
        for (selection, ids, total) in [
            (HomeAccountSelection(family: .evm, path: second), ["ethereum1", "solana0"], Decimal(10)),
            (.init(family: .solana, path: second), ["solana1", "ethereum0"], Decimal(10))
        ] {
            try await db.setHomeAccount(walletID: "w", selection: selection)
            let home = try await db.homeSnapshot(walletID: "w", currency: "USD")
            XCTAssertEqual(home.selectedAccount, selection)
            XCTAssertEqual(Set(home.accounts.map(\.id)), Set(ids)); XCTAssertEqual(home.totalFiat, total)
            let history = try await db.chainHistory(walletID: "w", currency: "USD", homeScope: true)
            XCTAssertEqual(Set(history.map(\.id)), Set(ids))
        }
        let reopened = try await OathDatabase.open(at: url)
        let home = try await reopened.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(home.selectedAccountIdentity, "solana:" + second)
        XCTAssertNil(home.selectedEVMAccountPath)
        var observer = db.observeAccountGroups().makeAsyncIterator()
        let groups = try await observer.next()
        XCTAssertEqual(groups?[.solana]?["w"]?.count, 2); XCTAssertEqual(groups?[.evm]?["w"]?.count, 2)
        try await db.recordCurrentBalance(walletID: "w", currency: "USD", reason: .refresh, settled: true)
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE solanaHoldings SET amountAtomic='5' WHERE accountID='solana1'")
            try sql.execute(sql: "UPDATE balances SET amountAtomic='999' WHERE accountID='ethereum1'")
        }
        try await db.recordCurrentBalance(walletID: "w", currency: "USD", reason: .refresh, settled: true)
        let day = try await db.balanceDay(walletID: "w", currency: "USD", interval: BalanceDaySummary.interval(containing: Date()), homeScope: true)
        XCTAssertEqual(day.opening?.total, 10); XCTAssertEqual(day.latest?.total, 16)
        try await db.setHomeAccount(walletID: "w", selection: nil)
        let root = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(Set(root.accounts.map(\.id)), ["ethereum0", "solana0"])
        XCTAssertEqual(root.totalFiat, 8)
        let history = try await db.chainHistory(walletID: "w", currency: "USD", homeScope: true)
        XCTAssertEqual(Set(history.map(\.id)), ["ethereum0", "solana0"])
        let totals = try await db.walletValuations(walletIDs: ["w"], currency: "USD")
        XCTAssertEqual(totals.first?.totalFiat, 8)
        let original = accounts.first { $0.id == "solana1" }!
        let state = try await db.prepareSolanaReceive(accountID: original.id,
            addresses: [.init(path: second, address: original.address)], preferredPath: second, singlePath: true)
        XCTAssertEqual(state.addresses.count, 1)
        let signing = try await db.solanaSigningAccount(accountID: original.id)
        XCTAssertEqual(signing.address, original.address); XCTAssertEqual(signing.derivationPath, second)
        let ticket = try await db.beginSolanaSync(accountID: original.id)
        XCTAssertEqual(ticket.account.id, original.id); XCTAssertEqual(ticket.owner, original.address)
        do { _ = try await db.selectSolanaReceivePath(accountID: original.id, path: first); XCTFail("Selected another account's path") } catch { }
        do { try await db.setHomeAccount(walletID: "w", selection: .init(family: .solana, path: "m/999'")); XCTFail("Selected missing account") } catch { }
        let unchanged = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertNil(unchanged.selectedAccount)
        // Restoring a wallet with no original Solana account must not merge a
        // newly imported Solana account into its root just because it is first.
        try await db.setOriginalHomeAccount(walletID: "w", family: .solana, path: nil)
        let noOriginalSolana = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(noOriginalSolana.accounts.map(\.id), ["ethereum0"])
        let noOriginalHistory = try await db.chainHistory(walletID: "w", currency: "USD", homeScope: true)
        XCTAssertEqual(noOriginalHistory.map(\.id), ["ethereum0"])
        try await db.setHomeAccount(walletID: "w", selection: .init(family: .solana, path: first))
        let independent = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(Set(independent.accounts.map(\.id)), ["ethereum0", "solana0"])
    }
}
