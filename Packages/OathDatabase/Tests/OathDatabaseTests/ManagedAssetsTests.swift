import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class ManagedAssetsTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18,
            derivationPath: "", logo: "", sortOrder: 0)], assets: [.init(id: "ethereum:native", networkID: "ethereum",
            reference: "native", name: "Ether", symbol: "ETH", decimals: 18)])
        for wallet in ["one", "two"] {
            try await db.importWalletIfNeeded(.init(id: wallet, name: wallet, kind: "hd", vaultReference: wallet, createdAt: 1),
                accounts: [0, 1].map { .init(id: wallet + String($0), walletID: wallet, networkID: "ethereum", address: "public\($0)", derivationPath: "") })
        }
        return (db, url)
    }
    private var token: AssetRecord {
        .init(id: "legacy-token-id", networkID: "ethereum", reference: "0xabcdef0000000000000000000000000000000001", name: "Fixture", symbol: "FXT", decimals: 6)
    }
    func testDiscoveredIdentityRemainsManageableBeforeBalanceIsKnown() async throws {
        let (db, url) = try await fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = token
        try await db.pool.write { sql in
            try asset.insert(sql)
            try sql.execute(sql: "INSERT INTO ankrAssets(accountID,assetID,detail,balanceUsd,fetchedAt,onlyWhitelisted) VALUES('one0',?,?,'',1,1)", arguments: [asset.id, Data()])
        }
        let managed = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertTrue(managed.assets.contains { $0.id == asset.id })
        XCTAssertFalse(managed.hiddenAssetIDs.contains(asset.id))
        XCTAssertTrue(managed.holdings.filter { $0.assetID == asset.id }.allSatisfy { $0.amountAtomic == nil && $0.balanceObservedAt == nil })
        let other = try await db.managedAssets(walletID: "two", currency: "USD")
        XCTAssertFalse(other.assets.contains { $0.id == asset.id })
        try await db.setAssetHidden(true, assetID: asset.id, walletID: "one")
        try await db.pool.write { try $0.execute(sql: "DELETE FROM ankrAssets WHERE assetID=?", arguments: [asset.id]) }
        let hidden = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertTrue(hidden.assets.contains { $0.id == asset.id })
        XCTAssertTrue(hidden.hiddenAssetIDs.contains(asset.id))
    }
    func testNearUnknownQuantityAndUnresolvedIdentityDoNotBreakProjection() async throws {
        let (db, url) = try await fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.seed(networks: [.init(id: "near", name: "NEAR", family: "near", symbol: "NEAR", decimals: 24,
            derivationPath: "", logo: "", sortOrder: 1)], assets: [
                .init(id: "near:native", networkID: "near", reference: "native", name: "NEAR", symbol: "NEAR", decimals: 24)])
        try await db.importWalletIfNeeded(.init(id: "near-wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "near-account", walletID: "near-wallet", networkID: "near", address: "fixture.near", derivationPath: "")])
        try await db.pool.write { sql in
            try AssetRecord(id: "near:token.near", networkID: "near", reference: "token.near", name: "Fixture", symbol: "FXT", decimals: 6).insert(sql)
            try sql.execute(sql: """
                INSERT INTO nearHoldings(accountID,reference,assetID,amountAtomic,observedAt,blockHeight,verified) VALUES
                ('near-account','token.near','near:token.near',NULL,1,1,0),
                ('near-account','unresolved.near',NULL,NULL,1,1,0)
                """)
        }
        let managed = try await db.managedAssets(walletID: "near-wallet", currency: "USD")
        XCTAssertEqual(Set(managed.assets.map(\.id)), ["near:native", "near:token.near"])
        XCTAssertTrue(managed.holdings.allSatisfy { $0.amountAtomic == nil && $0.balanceObservedAt == nil })
    }
    func testAtomicTrackingAllAccountsNoFakeBalanceReopenAndVerificationFilter() async throws {
        let (db, url) = try await fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.enableManagedToken(token, walletID: "one")
        try await db.setAssetHidden(true, assetID: token.id, walletID: "one")
        var replacement = token; replacement.id = "new-id"; replacement.reference = replacement.reference.uppercased()
        let result = try await db.enableManagedToken(replacement, walletID: "one")
        XCTAssertEqual(result.id, token.id)
        let reopened = try await OathDatabase.open(at: url)
        let managed = try await reopened.managedAssets(walletID: "one", currency: "USD")
        let rows = managed.holdings.filter { $0.assetID == token.id }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.amountAtomic == nil && $0.balanceObservedAt == nil && !$0.isVerifiedForHome })
        XCTAssertTrue(managed.hiddenAssetIDs.isEmpty)
        XCTAssertEqual(managed.matchingCount(filter: .init(), currency: "USD", locale: .init(identifier: "en_US")), 2)
        var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false; filter.hidesZeroBalances = true
        XCTAssertEqual(managed.matchingCount(filter: filter, currency: "USD", locale: .init(identifier: "ar")), 4, "Unknown amounts stay unknown and visible")
        filter.networkIDs = ["bitcoin"]
        XCTAssertEqual(managed.matchingCount(filter: filter, currency: "USD", locale: .current), 0)
        filter.networkIDs = []; filter.minimumValue = 1; filter.rangeCurrency = "USD"
        XCTAssertEqual(managed.matchingCount(filter: filter, currency: "USD", locale: .current), 0, "Unknown valuation cannot pass a value limit")
        let other = try await reopened.managedAssets(walletID: "two", currency: "USD")
        XCTAssertFalse(other.assets.contains { $0.id == token.id })
    }
    func testFailedTransactionRollsBackTrackingMetadataAndUnhide() async throws {
        let (db, url) = try await fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = token
        try await db.pool.write { sql in
            try asset.insert(sql)
            try sql.execute(sql: "INSERT INTO hiddenAssets(walletID,assetID) VALUES('one',?)", arguments: [asset.id])
            try sql.execute(sql: "CREATE TRIGGER fail_managed_unhide BEFORE DELETE ON hiddenAssets BEGIN SELECT RAISE(ABORT,'Fixture write failure'); END")
        }
        var changed = asset; changed.name = "Replacement"
        do { try await db.enableManagedToken(changed, walletID: "one"); XCTFail("Write should fail") } catch { }
        let failed = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertEqual(failed.assets.first { $0.id == asset.id }?.name, asset.name)
        XCTAssertEqual(failed.hiddenAssetIDs, [asset.id])
        let tracked = try await db.trackedAssets(walletID: "one"); XCTAssertTrue(tracked.isEmpty)
        try await db.pool.write { try $0.execute(sql: "DROP TRIGGER fail_managed_unhide") }
        var wrong = asset; wrong.decimals = 18
        do { try await db.enableManagedToken(wrong, walletID: "one"); XCTFail("Decimal conflict accepted") } catch { }
        try await db.enableManagedToken(asset, walletID: "one")
        let success = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertTrue(success.hiddenAssetIDs.isEmpty)
        _ = try await db.beginWalletReset()
        do { try await db.enableManagedToken(asset, walletID: "one"); XCTFail("Reset guard ignored") } catch { }
    }
    func testHiddenDiscoveredTokenRemainsRecoverableWithoutInventoryAndTotalIsUnchanged() async throws {
        let (db, url) = try await fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = token
        try await db.pool.write { sql in
            try asset.insert(sql)
            try BalanceRecord(accountID: "one0", assetID: asset.id, networkID: "ethereum", amountAtomic: "2000000", observedAt: 123, source: "fixture").insert(sql)
            try sql.execute(sql: "INSERT INTO ankrAssets(accountID,assetID,detail,balanceUsd,fetchedAt,onlyWhitelisted) VALUES('one0',?,?,'',1,1)", arguments: [asset.id, Data()])
        }
        try await db.savePrices([.init(assetID: asset.id, currency: "USD", value: "3", observedAt: 123, source: "fixture")])
        let before = try await db.snapshot(walletID: "one", currency: "USD")
        var observed = false
        let observer = Task {
            for try await value in db.observeManagedAssets(walletID: "one", currency: "USD") {
                if value.hiddenAssetIDs.contains(asset.id) { observed = true; return }
            }
        }
        defer { observer.cancel() }
        try await db.setAssetHidden(true, assetID: asset.id, walletID: "one")
        let after = try await db.snapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(before.totalFiat, after.totalFiat)
        XCTAssertEqual(after.holdings.first { $0.assetID == asset.id }?.balanceObservedAt, 123)
        try await observer.value; XCTAssertTrue(observed)
        try await db.pool.write { try $0.execute(sql: "DELETE FROM ankrAssets WHERE assetID=?", arguments: [asset.id]) }
        try await db.savePortfolioFilter(.init(), walletID: "one")
        let hidden = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertTrue(hidden.assets.contains { $0.id == asset.id })
        XCTAssertTrue(hidden.hiddenAssetIDs.contains(asset.id), "Reset filters must not reset visibility")
        try await db.enableManagedToken(asset, walletID: "one")
        let restored = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertFalse(restored.hiddenAssetIDs.contains(asset.id))
    }
}
