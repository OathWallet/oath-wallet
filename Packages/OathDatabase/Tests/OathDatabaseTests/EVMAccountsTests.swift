import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class EVMAccountsTests: XCTestCase {
    let first = "m/44'/60'/0'/0/0"
    let second = "m/44'/60'/0'/0/1"

    func testPathsNormalizeAndRejectAmbiguousOrUnboundedInput() throws {
        XCTAssertEqual(try EVMAccountDerivation.canonicalPath(" m/044h/60H/0'/0/01 "), second)
        XCTAssertEqual(try EVMAccountDerivation.paths(in: first + "\n\n" + second), [first, second])
        XCTAssertEqual(try EVMAccountDerivation.nextDefaultPath(existing: [first, second]), "m/44'/60'/0'/0/2")
        for path in ["", "m", "/m/0", "m//0", "m/-1", "m/2147483648", "m/0*", "m/0-5", "m/0/", "m/١", "m/0 /1", "m/" + Array(repeating: "0", count: 11).joined(separator: "/")] {
            XCTAssertThrowsError(try EVMAccountDerivation.canonicalPath(path))
        }
        XCTAssertThrowsError(try EVMAccountDerivation.paths(in: "m/0h\nm/0'"))
        XCTAssertThrowsError(try EVMAccountDerivation.paths(in: (0..<21).map { "m/\($0)" }.joined(separator: "\n")))
    }

    func testSidebarAccountTotalsAreIndependentAndUseSameCurrencySnapshot() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var observer = db.observeWalletAndAccountValuations(walletIDs: ["w"], currency: "USD").makeAsyncIterator()
        let values = try await observer.next() ?? []
        let firstID = HomeAccountSelection(family: .evm, path: first).balanceID(walletID: "w")
        let secondID = HomeAccountSelection(family: .evm, path: second).balanceID(walletID: "w")
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.first { $0.id == "w" }?.totalFiat, 6)
        XCTAssertEqual(values.first { $0.id == firstID }?.totalFiat, 6)
        XCTAssertEqual(values.first { $0.id == secondID }?.totalFiat, 14)
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE balances SET amountAtomic='9' WHERE accountID='w1'")
        }
        let changed = try await observer.next() ?? []
        XCTAssertEqual(changed.first { $0.id == firstID }, values.first { $0.id == firstID })
        XCTAssertEqual(changed.first { $0.id == secondID }?.totalFiat, 18)
        XCTAssertEqual(Set(changed.map(\.currency)), ["USD"])
    }

    func testRenamePersistsAndIsScopedToExactWalletAndFamily() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let selection = HomeAccountSelection(family: .evm, path: second)
        try await db.renameHDAccount(walletID: "w", selection: selection, name: "  Trading  ")
        let reopened = try await OathDatabase.open(at: dir.appendingPathComponent("db.sqlite"))
        var observer = reopened.observeAccountGroups().makeAsyncIterator()
        let groups = try await observer.next()
        XCTAssertEqual(groups?[.evm]?["w"]?.last?.name, "Trading")
        XCTAssertNil(groups?[.evm]?["other"]?.last?.name)
        for invalid in ["", "  ", "name\nline", String(repeating: "a", count: 81)] {
            do { try await db.renameHDAccount(walletID: "w", selection: selection, name: invalid); XCTFail("Invalid name accepted") }
            catch { XCTAssertEqual(error as? OathDatabase.AccountManagementError, .invalidName) }
        }
    }

    func testRemovalReconcilesSelectionAndNeverDeletesLastAccount() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let selection = HomeAccountSelection(family: .evm, path: second)
        try await db.setHomeAccount(walletID: "w", selection: selection)
        try await db.setOriginalHomeAccount(walletID: "w", family: .evm, path: second)
        try await db.removeHDAccount(walletID: "w", selection: selection)
        try await db.removeHDAccount(walletID: "w", selection: selection) // replay is idempotent
        let snapshot = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertNil(snapshot.selectedAccount)
        XCTAssertEqual(snapshot.accounts.map(\.id), ["w0"])
        XCTAssertEqual(snapshot.totalFiat, 6)
        let other = try await db.accounts(walletID: "other")
        XCTAssertEqual(other.count, 3)
        do { try await db.removeHDAccount(walletID: "w", selection: .init(family: .evm, path: first)); XCTFail("Removed last account") }
        catch { XCTAssertEqual(error as? OathDatabase.AccountManagementError, .lastAccount) }
    }

    func testPendingTransferPreventsAccountRemovalWithoutLosingItsJournal() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let selection = HomeAccountSelection(family: .evm, path: second)
        try await db.pool.write { sql in
            try sql.execute(sql: """
                INSERT INTO sends(id,walletID,accountID,networkID,assetID,senderAddress,idempotencyKey,recipient,amountAtomic,state,createdAt,updatedAt)
                VALUES('pending','w','w1','ethereum','eth','public-1','pending','public-recipient','1','broadcast',1,1)
                """)
        }
        do { try await db.validateHDAccountRemoval(walletID: "w", selection: selection); XCTFail("Pending transfer passed preflight") }
        catch { XCTAssertEqual(error as? StoreError, .invalidTransition) }
        do { try await db.removeHDAccount(walletID: "w", selection: selection); XCTFail("Deleted pending transfer") }
        catch { XCTAssertEqual(error as? StoreError, .invalidTransition) }
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sends WHERE id='pending'") }
        XCTAssertEqual(count, 1)
        let remaining = try await db.accounts(walletID: "w")
        XCTAssertEqual(remaining.count, 3)
    }

    private func fixture() async throws -> (OathDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evm-accounts-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: ["ethereum", "polygon"].enumerated().map {
            NetworkRecord(id: $0.element, name: $0.element, family: "evm", symbol: "ETH", decimals: 0, derivationPath: first, logo: "", sortOrder: $0.offset)
        }, assets: [AssetRecord(id: "eth", networkID: "ethereum", reference: "native", name: "Ether", symbol: "ETH", decimals: 0)])
        for wallet in ["w", "other"] {
            try await db.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "hd", vaultReference: wallet, createdAt: 1), accounts: [
                .init(id: wallet + "0", walletID: wallet, networkID: "ethereum", address: "public-0", derivationPath: first, accountIndex: 0),
                .init(id: wallet + "1", walletID: wallet, networkID: "ethereum", address: "public-1", derivationPath: second, accountIndex: 1),
                .init(id: wallet + "p1", walletID: wallet, networkID: "polygon", address: "public-1", derivationPath: second, accountIndex: 1)])
        }
        try await db.savePrices([.init(assetID: "eth", currency: "USD", value: "2", observedAt: 1, source: "fixture")])
        try await db.pool.write { sql in
            for (id, amount) in [("w0", "3"), ("w1", "7"), ("other0", "99")] {
                try BalanceRecord(accountID: id, assetID: "eth", networkID: "ethereum", amountAtomic: amount, observedAt: 100, source: "fixture").insert(sql)
            }
            for (i, account) in ["w1", "w0", "w0", "w1"].enumerated() {
                let id = "tx-\(i)"
                try TransactionRecord(id: id, networkID: "ethereum", hash: id, state: "confirmed", timestamp: Double(i + 100), updatedAt: 100).insert(sql)
                try ActivityRecord(id: id, walletID: "w", accountID: account, networkID: "ethereum", transactionID: id, assetID: "eth", direction: "incoming", amountAtomic: "1", counterparty: "public", timestamp: Double(i + 100)).insert(sql)
            }
        }
        return (db, dir)
    }

    func testSelectionScopesPortfolioHistoryAndSurvivesReopenWithoutChangingFullWallet() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try await db.setHomeEVMAccount(walletID: "w", path: second)
        let scoped = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(Set(scoped.accounts.map(\.id)), ["w1", "wp1"])
        XCTAssertEqual(scoped.totalFiat, 14)
        let full = try await db.snapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(full.accounts.count, 3); XCTAssertEqual(full.totalFiat, 20)
        let other = try await db.homeSnapshot(walletID: "other", currency: "USD")
        XCTAssertNil(other.selectedEVMAccountPath); XCTAssertEqual(other.accounts.count, 1)
        let history = try await db.chainHistory(walletID: "w", currency: "USD", limit: 1, homeScope: true)
        XCTAssertEqual(history.first?.id, "tx-3")
        let selected = try await db.chainHistory(walletID: "w", currency: "USD", homeScope: true)
        XCTAssertEqual(selected.map(\.id), ["tx-3", "tx-0"])
        var observer = db.observeEVMAccounts().makeAsyncIterator()
        let groups = try await observer.next()
        XCTAssertEqual(groups?["w"]?.map(\.path), [first, second]); XCTAssertEqual(groups?["w"]?.last?.accounts.count, 2)
        let reopened = try await OathDatabase.open(at: dir.appendingPathComponent("db.sqlite"))
        let saved = try await reopened.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(saved.selectedEVMAccountPath, second)
        do { try await db.setHomeEVMAccount(walletID: "w", path: "m/999"); XCTFail("Unknown account selected") } catch { }
        try await db.setHomeEVMAccount(walletID: "w", path: nil)
        let original = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(original.totalFiat, 6)
        XCTAssertEqual(original.accounts.map(\.id), ["w0"])
        let originalHistory = try await db.chainHistory(walletID: "w", currency: "USD", homeScope: true)
        XCTAssertEqual(originalHistory.map(\.id), ["tx-2", "tx-1"])
        let valuations = try await db.walletValuations(walletIDs: ["w"], currency: "USD")
        XCTAssertEqual(valuations.first?.totalFiat, 6)
    }

    func testAccountDailyChangeUsesOnlyItsRecordedHoldings() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try await db.setHomeEVMAccount(walletID: "w", path: second)
        try await db.recordCurrentBalance(walletID: "w", currency: "USD", reason: .refresh, settled: true)
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE balances SET amountAtomic='9' WHERE accountID='w1'")
            try sql.execute(sql: "UPDATE balances SET amountAtomic='999' WHERE accountID='w0'")
        }
        try await db.recordCurrentBalance(walletID: "w", currency: "USD", reason: .refresh, settled: true)
        let day = try await db.balanceDay(walletID: "w", currency: "USD", interval: BalanceDaySummary.interval(containing: Date()), homeScope: true)
        XCTAssertEqual(day.opening?.total, 14); XCTAssertEqual(day.latest?.total, 18)
        XCTAssertEqual(day.change?.amount, 4)
    }
}
