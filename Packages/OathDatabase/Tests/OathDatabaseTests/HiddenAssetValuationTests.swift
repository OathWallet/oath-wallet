import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class HiddenAssetValuationTests: XCTestCase {
    private let firstPath = "m/44'/60'/0'/0/0"
    private let secondPath = "m/44'/60'/0'/0/1"
    private let tokenID = "ethereum:fixture"

    private func fixture() async throws -> (OathDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("fixture.sqlite"))
        try await db.seed(networks: [
            .init(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "btc", logo: "", sortOrder: 0),
            .init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: firstPath, logo: "", sortOrder: 1),
            .init(id: "base", name: "Base", family: "evm", symbol: "ETH", decimals: 18, derivationPath: firstPath, logo: "", sortOrder: 2)
        ], assets: [
            .init(id: "btc", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8),
            .init(id: "eth", networkID: "ethereum", reference: "native", name: "Ether", symbol: "ETH", decimals: 18),
            .init(id: "base-eth", networkID: "base", reference: "native", name: "Ether", symbol: "ETH", decimals: 18)
        ])
        let token = AssetRecord(id: tokenID, networkID: "ethereum", reference: "0xabcdef0000000000000000000000000000000001",
                                name: "Fixture", symbol: "FXT", decimals: 6)
        for wallet in ["one", "two"] {
            try await db.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "hd", vaultReference: wallet, createdAt: 1), accounts: [
                .init(id: wallet + "-btc", walletID: wallet, networkID: "bitcoin", address: "public-btc-" + wallet, derivationPath: "btc"),
                .init(id: wallet + "-eth0", walletID: wallet, networkID: "ethereum", address: "public-eth0-" + wallet, derivationPath: firstPath),
                .init(id: wallet + "-eth1", walletID: wallet, networkID: "ethereum", address: "public-eth1-" + wallet, derivationPath: secondPath, accountIndex: 1),
                .init(id: wallet + "-base", walletID: wallet, networkID: "base", address: "public-base-" + wallet, derivationPath: firstPath)
            ])
            try await db.trackAsset(token, walletID: wallet)
            var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
            try await db.savePortfolioFilter(filter, walletID: wallet)
            try await db.saveBalances([
                .init(accountID: wallet + "-btc", assetID: "btc", networkID: "bitcoin", amountAtomic: "100000000", observedAt: 100, source: "fixture"),
                .init(accountID: wallet + "-eth0", assetID: "eth", networkID: "ethereum", amountAtomic: "2000000000000000000", observedAt: 100, source: "fixture"),
                .init(accountID: wallet + "-eth1", assetID: "eth", networkID: "ethereum", amountAtomic: "3000000000000000000", observedAt: 100, source: "fixture"),
                .init(accountID: wallet + "-base", assetID: "base-eth", networkID: "base", amountAtomic: "4000000000000000000", observedAt: 100, source: "fixture"),
                .init(accountID: wallet + "-eth0", assetID: tokenID, networkID: "ethereum", amountAtomic: "5000000", observedAt: 100, source: "fixture"),
                .init(accountID: wallet + "-eth1", assetID: tokenID, networkID: "ethereum", amountAtomic: "7000000", observedAt: 100, source: "fixture")
            ])
        }
        try await db.savePrices([("btc", "100"), ("eth", "10"), ("base-eth", "5"), (tokenID, "2")].map {
            .init(assetID: $0.0, currency: "USD", value: $0.1, observedAt: 100, source: "fixture")
        })
        return (db, directory)
    }

    func testChartReprojectsAllHistoryForHiddenAssetsAndSelectedAccounts() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let interval = BalanceDaySummary.interval(containing: Date())
        try await db.recordCurrentBalance(walletID: "one", currency: "USD", reason: .refresh, settled: true)
        let original = try await db.balanceChartHistory(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(original.points.first?.total, 150)
        try await db.setAssetHidden(true, assetID: "btc", walletID: "one")
        let hidden = try await db.balanceChartHistory(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(hidden.points.first?.total, 50)
        XCTAssertEqual(hidden.hiddenAssetIDs, ["btc"])
        try await db.setHomeAccount(walletID: "one", selection: .init(family: .evm, path: secondPath))
        let second = try await db.balanceChartHistory(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(second.points.first?.total, 44)
        XCTAssertNotEqual(second.accountIDs, original.accountIDs)
        try await db.setAssetHidden(false, assetID: "btc", walletID: "one")
        let restored = try await db.balanceChartHistory(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(restored.points.first?.total, 144)
        try await db.reconcileWalletLifecycle([.init(id: "one", deletedAt: 100)])
        let removed = try await db.balanceChartHistory(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertTrue(removed.points.isEmpty)
    }

    func testHiddenAmountsAreExcludedAcrossWalletAccountsAndReopenButQuantitiesRemain() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let before = try await db.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(before.totalFiat, 150)
        try await db.setAssetHidden(true, assetID: tokenID, walletID: "one")
        try await db.setAssetHidden(true, assetID: "eth", walletID: "one")
        let reopened = try await OathDatabase.open(at: directory.appendingPathComponent("fixture.sqlite"))
        let hidden = try await reopened.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(hidden.totalFiat, 120, "Bitcoin and Base ETH still count; hidden Ethereum assets do not")
        XCTAssertEqual(hidden.holdings, before.holdings, "Hiding must preserve exact quantities and signing inputs")
        let other = try await reopened.homeSnapshot(walletID: "two", currency: "USD")
        XCTAssertEqual(other.totalFiat, 150)
        try await reopened.setHomeAccount(walletID: "one", selection: .init(family: .evm, path: secondPath))
        let second = try await reopened.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(second.totalFiat, 100, "The same hidden assets are excluded on the other path")
        try await reopened.saveBalances([.init(accountID: "one-eth1", assetID: tokenID, networkID: "ethereum", amountAtomic: "9000000", observedAt: 101, source: "fixture")])
        let stillHidden = try await reopened.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(stillHidden.totalFiat, 100)
        try await reopened.setAssetHidden(false, assetID: tokenID, walletID: "one")
        let restored = try await reopened.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(restored.totalFiat, 118, "Unhide uses the newest observed quantity without another refresh")
    }

    func testBalanceAndHistoryObserversReactToHideAndUnhideAlone() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await db.recordCurrentBalance(walletID: "one", currency: "USD", reason: .refresh, settled: true)
        var home: Decimal?, wallet: Decimal?, accounts: [WalletValuation] = []
        var day: BalanceDaySummary?
        let homeTask = Task {
            for try await value in db.observeHomeWallet(walletID: "one", currency: "USD") { home = value.totalFiat }
        }
        let walletTask = Task {
            for try await value in db.observeWalletValuations(walletIDs: ["one"], currency: "USD") { wallet = value.first?.totalFiat }
        }
        let accountsTask = Task {
            for try await value in db.observeWalletAndAccountValuations(walletIDs: ["one"], currency: "USD") { accounts = value }
        }
        let dayTask = Task {
            for try await value in db.observeBalanceDay(walletID: "one", currency: "USD",
                interval: BalanceDaySummary.interval(containing: Date()), homeScope: true) { day = value }
        }
        defer { homeTask.cancel(); walletTask.cancel(); accountsTask.cancel(); dayTask.cancel() }
        let firstID = HomeAccountSelection(family: .evm, path: firstPath).balanceID(walletID: "one")
        let secondID = HomeAccountSelection(family: .evm, path: secondPath).balanceID(walletID: "one")
        try await waitFor { home == 150 && wallet == 150 && accounts.first { $0.id == secondID }?.totalFiat == 44 && day?.opening?.total == 150 }
        try await db.setAssetHidden(true, assetID: tokenID, walletID: "one")
        try await waitFor { home == 140 && wallet == 140 && accounts.first { $0.id == secondID }?.totalFiat == 30 && day?.opening?.total == 140 }
        XCTAssertEqual(accounts.first { $0.id == firstID }?.totalFiat, 40)
        XCTAssertEqual(accounts.first { $0.id == "one" }?.totalFiat, 140)
        try await db.setAssetHidden(false, assetID: tokenID, walletID: "one")
        try await waitFor { home == 150 && wallet == 150 && accounts.first { $0.id == secondID }?.totalFiat == 44 && day?.opening?.total == 150 }
    }

    func testHiddenUnpricedAssetsDoNotMakeVisibleValuationIncompleteAndAllHiddenIsZero() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let unpriced = AssetRecord(id: "unpriced", networkID: "ethereum", reference: "0xabcdef0000000000000000000000000000000002", name: "No quote", symbol: "NONE", decimals: 0)
        try await db.trackAsset(unpriced, walletID: "one")
        try await db.saveBalances([.init(accountID: "one-eth0", assetID: unpriced.id, networkID: "ethereum", amountAtomic: "2", observedAt: 100, source: "fixture")])
        let incomplete = try await db.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertFalse(incomplete.valuationComplete)
        try await db.setAssetHidden(true, assetID: unpriced.id, walletID: "one")
        let complete = try await db.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(complete.totalFiat, 150); XCTAssertTrue(complete.valuationComplete)
        for id in ["btc", "eth", "base-eth", tokenID] { try await db.setAssetHidden(true, assetID: id, walletID: "one") }
        let empty = try await db.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(empty.totalFiat, 0); XCTAssertTrue(empty.valuationComplete)
        XCTAssertFalse(empty.holdings.isEmpty); XCTAssertTrue(empty.valuationHoldings.isEmpty)
        let record = try await db.recordCurrentBalance(walletID: "one", currency: "USD", reason: .refresh, settled: true)
        XCTAssertEqual(record?.total, 0); XCTAssertEqual(record?.usdAmount, "0")
        let summary = try await db.balanceDay(walletID: "one", currency: "USD", interval: BalanceDaySummary.interval(containing: Date()), homeScope: true)
        XCTAssertEqual(summary.change(for: empty)?.amount, 0)
        try await db.setAssetHidden(false, assetID: unpriced.id, walletID: "one")
        let restored = try await db.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertFalse(restored.valuationComplete)
    }

    func testHistoryRevaluesBothEndsAndRejectsMismatchedLiveVisibility() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let interval = BalanceDaySummary.interval(containing: Date())
        try await db.recordCurrentBalance(walletID: "one", currency: "USD", reason: .refresh, settled: true)
        let before = try await db.balanceDay(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(before.opening?.total, 150)
        try await db.setAssetHidden(true, assetID: "btc", walletID: "one")
        let hidden = try await db.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(hidden.totalFiat, 50)
        XCTAssertNil(before.change(for: hidden), "An old summary must not show hiding as a loss")
        let filtered = try await db.balanceDay(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(filtered.opening?.total, 50); XCTAssertEqual(filtered.change(for: hidden)?.amount, 0)
        try await db.recordCurrentBalance(walletID: "one", currency: "USD", reason: .balanceUpdate)
        try await db.savePrices([.init(assetID: tokenID, currency: "USD", value: "3", observedAt: 101, source: "fixture")])
        try await db.recordCurrentBalance(walletID: "one", currency: "USD", reason: .balanceUpdate)
        let changed = try await db.balanceDay(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(changed.change?.amount, 5)
        try await db.setAssetHidden(false, assetID: "btc", walletID: "one")
        let restored = try await db.homeSnapshot(walletID: "one", currency: "USD")
        XCTAssertNil(changed.change(for: restored), "An old hidden summary must not show unhiding as a gain")
        let full = try await db.balanceDay(walletID: "one", currency: "USD", interval: interval, homeScope: true)
        XCTAssertEqual(full.opening?.total, 150); XCTAssertEqual(full.latest?.total, 155)
        XCTAssertEqual(full.change(for: restored)?.amount, 5)
        for period in BalanceHistoryPeriod.allCases {
            let summary = try await db.balanceDay(walletID: "one", currency: "USD",
                interval: period.interval(containing: Date()), homeScope: true)
            XCTAssertEqual(summary.change(for: restored)?.amount, 5, period.rawValue)
        }
    }

    func testHiddenSnapshotsKeepMatchingUSDBasisAndCanRestoreHistoricalAssets() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "EUR": "0.8"], observedAt: 100, fetchedAt: 100, source: "fixture"))
        try await db.setSetting("currency", value: "EUR")
        try await db.setAssetHidden(true, assetID: "btc", walletID: "one")
        let recordValue = try await db.recordCurrentBalance(walletID: "one", currency: "EUR", reason: .refresh, settled: true)
        let record = try XCTUnwrap(recordValue)
        XCTAssertEqual(record.total, Decimal(string: "75.2")); XCTAssertEqual(record.usdAmount, "94")
        XCTAssertEqual(try XCTUnwrap(record.assets()).first { $0.assetID == "btc" }?.excludedFromTotal, true)
        let interval = BalanceDaySummary.interval(containing: Date())
        let hidden = try await db.balanceDay(walletID: "one", currency: "EUR", interval: interval, homeScope: true)
        XCTAssertEqual(hidden.opening?.total, 40); XCTAssertEqual(hidden.latest?.total, 40)
        try await db.setAssetHidden(false, assetID: "btc", walletID: "one")
        let shown = try await db.balanceDay(walletID: "one", currency: "EUR", interval: interval, homeScope: true)
        XCTAssertEqual(shown.opening?.total, 120); XCTAssertEqual(shown.latest?.total, 120)
        XCTAssertEqual(shown.change?.amount, 0)
        let allAccounts = try await db.balanceDay(walletID: "one", currency: "EUR", interval: interval)
        XCTAssertEqual(allAccounts.opening?.total, Decimal(string: "155.2"), "Unhide also restores totals when no account projection is needed")
        let home = try await db.homeSnapshot(walletID: "one", currency: "EUR")
        let wallets = try await db.walletValuations(walletIDs: ["one"], currency: "EUR")
        XCTAssertEqual(home.totalFiat, 120); XCTAssertEqual(wallets.first?.totalFiat, 120)
    }

    func testLegacyTotalsOnlyCannotIncludeHiddenAssetsInComparison() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let interval = BalanceDaySummary.interval(containing: Date())
        try await db.appendBalanceSnapshot(walletID: "one", currency: "USD", total: 194, complete: true, reason: .refresh)
        try await db.setAssetHidden(true, assetID: "btc", walletID: "one")
        let hidden = try await db.balanceDay(walletID: "one", currency: "USD", interval: interval)
        XCTAssertNil(hidden.opening); XCTAssertNil(hidden.change)
        try await db.setAssetHidden(false, assetID: "btc", walletID: "one")
        let restored = try await db.balanceDay(walletID: "one", currency: "USD", interval: interval)
        XCTAssertEqual(restored.opening?.total, 194)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Balance observation did not publish the visibility change")
    }
}
