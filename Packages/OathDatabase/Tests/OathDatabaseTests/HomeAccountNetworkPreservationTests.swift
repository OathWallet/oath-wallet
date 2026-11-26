import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class HomeAccountNetworkPreservationTests: XCTestCase {
    func testDisabledNetworkMetadataDoesNotSplitHomeAndConnectionScope() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("wallet.sqlite"))
        let original = "m/44'/60'/0'/0/0", added = "m/44'/60'/0'/0/1"
        try await db.seed(networks: ["ethereum", "cronos"].map {
            .init(id: $0, name: $0, family: "evm", symbol: "TEST", decimals: 0,
                  derivationPath: original, logo: "", sortOrder: 0, enabled: $0 != "cronos")
        }, assets: [])
        try await db.importWalletIfNeeded(.init(id: "w", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "eth0", walletID: "w", networkID: "ethereum", address: "public-0", derivationPath: original),
            .init(id: "eth1", walletID: "w", networkID: "ethereum", address: "public-1", derivationPath: added, accountIndex: 1),
            .init(id: "cro0", walletID: "w", networkID: "cronos", address: "public-0", derivationPath: original)
        ])
        try await db.setHomeAccount(walletID: "w", selection: .init(family: .evm, path: added))
        let home = try await db.homeSnapshot(walletID: "w", currency: "USD")
        let connection = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        var observer = db.observeHomeWallet(walletID: "w", currency: "USD").makeAsyncIterator()
        let observed = try await observer.next()
        XCTAssertEqual(home.accounts.map(\.id), ["eth1"])
        XCTAssertEqual(connection, home.accounts)
        XCTAssertEqual(observed?.accounts, home.accounts)
        let stored = try await db.accounts(walletID: "w")
        XCTAssertEqual(stored.count, 3, "Disabled metadata stays stored without leaking into selected family")
    }

    func testSelectingAnAddedAccountPreservesOtherNetworksAndTheirData() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        let evm = "m/44'/60'/0'/0/0", solana = "m/44'/501'/0'/0'"
        // Deliberately use the same custom path on both curves: selection must
        // match the family as well as the path.
        let custom = "m/44'/501'/8'/0'"
        let chains = ["ethereum", "polygon", "solana", "bitcoincash", "bitcoin", "tron", "dogecoin", "sui"]
        let networks = chains.map { chain in
            NetworkRecord(id: chain, name: chain, family: ["ethereum", "polygon"].contains(chain) ? "evm" : "account",
                          symbol: "TEST", decimals: 0, derivationPath: chain == "solana" ? solana : evm, logo: "", sortOrder: 0)
        }
        try await db.seed(networks: networks, assets: chains.map {
            .init(id: $0, networkID: $0, reference: "native", name: $0, symbol: "TEST", decimals: 0)
        })
        let wallet = WalletRecord(id: "w", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1)
        let original = chains.map { chain in
            AccountRecord(id: chain + "0", walletID: "w", networkID: chain, address: "public-" + chain,
                          derivationPath: chain == "solana" ? solana : evm)
        }
        let added = ["ethereum", "polygon", "solana"].map { chain in
            AccountRecord(id: chain + "1", walletID: "w", networkID: chain, address: "public-added-" + chain,
                          derivationPath: custom, accountIndex: 1)
        }
        try await db.importWalletIfNeeded(wallet, accounts: original + added)
        try await db.savePrices(chains.map { .init(assetID: $0, currency: "USD", value: "1", observedAt: 1, source: "fixture") })
        try await db.pool.write { sql in
            for account in original + added {
                let amount = account.accountIndex == 0 ? "1" : "10"
                try BalanceRecord(accountID: account.id, assetID: account.networkID, networkID: account.networkID,
                                  amountAtomic: amount, observedAt: 100, source: "fixture").insert(sql)
                try TransactionRecord(id: account.id, networkID: account.networkID, hash: account.id,
                                      state: "confirmed", timestamp: 100, updatedAt: 100).insert(sql)
                try ActivityRecord(id: account.id, walletID: "w", accountID: account.id, networkID: account.networkID,
                                   transactionID: account.id, assetID: account.networkID, direction: "incoming",
                                   amountAtomic: "1", counterparty: "public", timestamp: 100).insert(sql)
                if account.networkID == "solana" {
                    try sql.execute(sql: "INSERT INTO solanaHoldings(accountID,owner,assetID,amountAtomic,observedAt,slot,verified) VALUES(?,?,?,?,?,?,?)",
                                    arguments: [account.id, account.address, "solana", amount, 100, 100, true])
                    try sql.execute(sql: "INSERT INTO solanaActivity(activityID,owner) VALUES(?,?)", arguments: [account.id, account.address])
                }
                if account.networkID == "tron" {
                    try sql.execute(sql: "INSERT INTO tronHoldings(accountID,assetID,amountAtomic,observedAt,verified) VALUES(?,?,?,?,?)",
                                    arguments: [account.id, "tron", amount, 100, true])
                }
            }
        }
        let stored = try await db.accounts(walletID: "w")
        for family in HDAccountFamily.allCases {
            let selection = HomeAccountSelection(family: family, path: custom)
            try await db.setHomeAccount(walletID: "w", selection: selection)
            let familyIDs = Set(networks.filter { family.contains($0) }.map(\.id))
            let preserved = original.filter { !familyIDs.contains($0.networkID) }
            let expected = preserved + added.filter { familyIDs.contains($0.networkID) }
            let ids = Set(expected.map(\.id))
            let home = try await db.homeSnapshot(walletID: "w", currency: "USD")
            XCTAssertEqual(home.selectedAccount, selection)
            XCTAssertEqual(Set(home.accounts.map(\.id)), ids)
            XCTAssertEqual(Set(home.networks.map(\.id)), Set(chains), "BCH and all other wallet chains must remain available")
            XCTAssertEqual(home.totalFiat, Decimal(preserved.count + (expected.count - preserved.count) * 10))
            for account in preserved { XCTAssertEqual(home.accounts.first { $0.id == account.id }, account) }
            let history = try await db.chainHistory(walletID: "w", currency: "USD", homeScope: true)
            XCTAssertEqual(Set(history.map(\.id)), ids)
            let consent = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
            XCTAssertEqual(Set(consent.map(\.id)), ids)
            let unchanged = try await db.accounts(walletID: "w")
            XCTAssertEqual(unchanged, stored, "Selection must never rewrite another chain's stored address")
            let reopened = try await OathDatabase.open(at: url)
            let reopenedHome = try await reopened.homeSnapshot(walletID: "w", currency: "USD")
            XCTAssertEqual(reopenedHome.accounts, home.accounts)
        }
        try await db.setHomeAccount(walletID: "w", selection: nil)
        let root = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(Set(root.accounts.map(\.id)), Set(original.map(\.id)))
    }
}
