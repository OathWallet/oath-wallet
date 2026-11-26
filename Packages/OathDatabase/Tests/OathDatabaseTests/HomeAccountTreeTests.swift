import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class HomeAccountTreeTests: XCTestCase {
    private let evm = "m/44'/60'/0'/0/0"
    private let solana = "m/44'/501'/0'/0'"

    private func fixture() async throws -> (OathDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("account-tree-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks: ["ethereum", "polygon", "solana"].map {
            .init(id: $0, name: $0, family: $0 == "solana" ? "account" : "evm", symbol: "TEST", decimals: 0,
                  derivationPath: $0 == "solana" ? solana : evm, logo: "", sortOrder: 0)
        }, assets: [])
        try await db.importWalletIfNeeded(.init(id: "w", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "eth0", walletID: "w", networkID: "ethereum", address: "public-evm", derivationPath: evm),
            .init(id: "poly0", walletID: "w", networkID: "polygon", address: "public-evm", derivationPath: evm),
            .init(id: "sol0", walletID: "w", networkID: "solana", address: "public-sol", derivationPath: solana)
        ])
        return (db, dir)
    }

    private func treeIsShown(_ db: OathDatabase) async throws -> Bool {
        var observer = db.observeAccountGroups().makeAsyncIterator()
        let values = try await observer.next() ?? [:]
        return HDAccountFamily.allCases.contains { family in (values[family]?["w"] ?? []).contains(where: \.isAdditional) }
    }

    func testOriginalAccountsOnMultipleNetworksDoNotExpandTree() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let showsTree = try await treeIsShown(db)
        XCTAssertFalse(showsTree, "EVM networks and the default Solana account are part of the main wallet")
        try await db.setHomeAccount(walletID: "w", selection: .init(family: .evm, path: evm))
        let home = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertNil(home.selectedAccount)
        XCTAssertEqual(Set(home.accounts.map(\.id)), ["eth0", "poly0", "sol0"])
    }

    func testAdditionalAccountInEitherFamilyExpandsThenRemovalCollapsesTree() async throws {
        for family in HDAccountFamily.allCases {
            let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = family == .evm ? "m/44'/60'/0'/0/1" : "m/44'/501'/1'/0'"
            let selection = HomeAccountSelection(family: family, path: path)
            try await db.importWalletIfNeeded(try await db.wallet("w")!, accounts: [
                .init(id: "extra", walletID: "w", networkID: family == .evm ? "ethereum" : "solana",
                      address: "public-extra", derivationPath: path, accountIndex: 1)
            ])
            let expanded = try await treeIsShown(db)
            XCTAssertTrue(expanded)
            // Keep the original child selected when its sibling is removed.
            try await db.setHomeAccount(walletID: "w", selection: .init(family: .evm, path: evm))
            try await db.removeHDAccount(walletID: "w", selection: selection)
            let collapsed = try await treeIsShown(db)
            XCTAssertFalse(collapsed)
            let home = try await db.homeSnapshot(walletID: "w", currency: "USD")
            XCTAssertNil(home.selectedAccount, "No invisible selected child after removing the last extra account")
            XCTAssertEqual(home.accounts.count, 3)
        }
    }

    func testOldDefaultChildSelectionIsClearedAndDoesNotReturnAfterAddingAccount() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // Simulate the persisted selection from the previous app version.
        try await db.setSetting(HDAccountFamily.solana.selectionKey(walletID: "w"), value: solana)
        try await db.normalizeHomeAccountSelection(walletID: "w")
        let reopened = try await OathDatabase.open(at: dir.appendingPathComponent("wallet.sqlite"))
        let settings = try await reopened.settings()
        XCTAssertNil(settings[HDAccountFamily.solana.selectionKey(walletID: "w")])
        let home = try await reopened.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertNil(home.selectedAccount)
        XCTAssertEqual(home.accounts.count, 3)
        try await reopened.importWalletIfNeeded(try await reopened.wallet("w")!, accounts: [
            .init(id: "extra", walletID: "w", networkID: "ethereum", address: "public-extra",
                  derivationPath: "m/44'/60'/0'/0/1", accountIndex: 1)
        ])
        let expanded = try await treeIsShown(reopened)
        XCTAssertTrue(expanded)
        let afterAdding = try await reopened.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertNil(afterAdding.selectedAccount, "Adding an account must not restore a hidden selection")
        XCTAssertEqual(Set(afterAdding.accounts.map(\.id)), ["eth0", "poly0", "sol0"])
    }

    func testFirstAccountAddedToAnAbsentFamilyIsStillAnAdditionalAccount() async throws {
        let (db, dir) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        // A scoped EVM backup may add Solana later; its first Solana account is
        // separate from the original EVM wallet, even though both indices are zero.
        try await db.setOriginalHomeAccount(walletID: "w", family: .solana, path: nil)
        let shown = try await treeIsShown(db)
        XCTAssertTrue(shown)
        let selection = HomeAccountSelection(family: .solana, path: solana)
        try await db.setHomeAccount(walletID: "w", selection: selection)
        try await db.normalizeHomeAccountSelection(walletID: "w")
        let home = try await db.homeSnapshot(walletID: "w", currency: "USD")
        XCTAssertEqual(home.selectedAccount, selection)
        XCTAssertEqual(Set(home.accounts.map(\.id)), ["eth0", "poly0", "sol0"])
    }
}
