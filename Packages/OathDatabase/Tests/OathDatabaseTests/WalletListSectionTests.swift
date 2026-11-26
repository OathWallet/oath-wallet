import XCTest
@testable import OathDatabase

@MainActor final class WalletListSectionTests: XCTestCase {
    private func wallet(_ id: String, kind: String = "hd", group: String? = nil,
                        parent: String? = nil) -> WalletRecord {
        .init(id: id, name: "Renamed wallet", kind: kind, vaultReference: id,
              createdAt: 1, nameGroup: group, parentWalletID: parent)
    }

    func testClassificationUsesProvenanceNotUserVisibleNames() {
        let cases: [(String, String?, WalletListCategory)] = [
            ("hd", nil, .wallets), ("hd", "main", .wallets), ("hd", "restored", .wallets),
            ("imported", nil, .imported), ("imported", "restored", .imported),
            ("hd", "imported", .imported), ("aezeed", nil, .imported),
            ("electrum", nil, .imported), ("electrum2fa", nil, .imported),
            ("privateKey", nil, .privateKey), ("privateKey", "imported", .privateKey),
            ("privateKey", "network:ethereum", .privateKey), ("privateKey", "restored", .privateKey),
            ("passphrase", nil, .passphrase), ("passphrase", "restored", .passphrase),
            ("electrum", "passphrase", .passphrase), ("electrum2fa", "passphrase", .passphrase),
            ("hd", "passphrase", .passphrase), ("bitcoinMultisig", "multisig", .wallets),
            ("watchOnly", nil, .wallets), ("futureKind", nil, .wallets)
        ]
        for (kind, group, expected) in cases {
            var record = wallet("test", kind: kind, group: group)
            record.name = "Private Key Wallets"
            record.confirmedName = "Imported Wallet"
            XCTAssertEqual(record.listCategory, expected, "kind=\(kind), group=\(group ?? "nil")")
        }
    }

    func testFixedSectionOrderPreservesSavedOrderAndIncludesEveryWalletOnce() {
        let records = [wallet("p", kind: "passphrase", parent: "a"), wallet("i2", kind: "imported"),
                       wallet("k", kind: "privateKey"), wallet("a"), wallet("i1", kind: "electrum"), wallet("b")]
        let sections = WalletTree(records + [records[0]]).sections
        XCTAssertEqual(sections.map(\.category), [.wallets, .imported, .privateKey, .passphrase])
        XCTAssertEqual(sections.map { $0.wallets.map(\.id) }, [["a", "b"], ["i2", "i1"], ["k"], ["p"]])
        XCTAssertEqual(Set(sections.flatMap(\.wallets).map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(sections.last?.wallets.first?.parentWalletID, "a")
    }

    func testEmptyAndSingleCategoryListsHaveOnlyTheirOwnSections() {
        XCTAssertTrue(WalletTree([]).sections.isEmpty)
        let sections = WalletTree([wallet("imported", kind: "imported")]).sections
        XCTAssertEqual(sections.map(\.category), [.imported])
        XCTAssertEqual(sections[0].tree.rows.map(\.id), ["imported"])
    }

    func testCrossCategoryDropKeepsCategoriesAndOnlyReordersWithinThem() {
        let tree = WalletTree([wallet("a"), wallet("b"), wallet("i", kind: "imported"),
                               wallet("p1", kind: "passphrase", parent: "a"),
                               wallet("p2", kind: "electrum", group: "passphrase", parent: "i")])
        let reordered = tree.reorderingWithinSections(["p2", "b", "i", "p1", "a"])
        XCTAssertEqual(reordered.flattened.map(\.id), ["b", "a", "i", "p2", "p1"])
        XCTAssertEqual(reordered.flattened.first { $0.id == "p2" }?.kind, "electrum")
        XCTAssertEqual(reordered.flattened.first { $0.id == "p2" }?.parentWalletID, "i")
        let created = tree.sections[0].tree.movingRows([0], to: 2)
        XCTAssertEqual(created, ["b", "a"])
    }

    func testStalePartialDuplicateAndUnknownDragSnapshotsDoNotHideWallets() {
        let tree = WalletTree([wallet("i", kind: "imported"), wallet("a"), wallet("b")])
        for invalid in [[], ["a", "b"], ["a", "a", "i"], ["a", "b", "unknown"], ["a", "b", "i", "i"]] {
            XCTAssertEqual(tree.reorderingWithinSections(invalid).flattened, tree.flattened)
        }
    }

    func testSectionOrderPersistsAndDeletionDoesNotChangeCategory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.saveNetwork(.init(id: "bitcoin", name: "Bitcoin", family: "bitcoin", symbol: "BTC",
                                      decimals: 8, derivationPath: "m/84'/0'/0'", logo: "network-bitcoin", sortOrder: 0))
        let records = [wallet("a"), wallet("i2", kind: "imported"), wallet("i1", kind: "imported"),
                       wallet("p", kind: "electrum", group: "passphrase", parent: "i1"),
                       wallet("k", kind: "privateKey")]
        for record in records {
            let accounts: [AccountRecord] = record.kind == "electrum" ? [
                .init(id: record.id + ":bitcoin", walletID: record.id, networkID: "bitcoin",
                      address: "test-account", derivationPath: "m/0/0")
            ] : []
            try await db.importWalletIfNeeded(record, accounts: accounts)
        }
        let ordered = WalletTree(try await db.wallets()).reorderingWithinSections(["a", "i1", "i2", "p", "k"])
        try await db.reorderWallets(ordered.flattened.map(\.id))
        let saved = try await db.wallets()
        XCTAssertEqual(saved.map(\.id), ["a", "i1", "i2", "k", "p"])
        try await db.reconcileWalletLifecycle([.init(id: "i1", deletedAt: 10)])
        let active = WalletTree(try await db.wallets()).sections
        XCTAssertEqual(active.last?.wallets.map(\.id), ["p"])
        let deleted = try await db.wallet("i1")
        XCTAssertEqual(deleted?.listCategory, .imported)
        try await db.reconcileWalletLifecycle([.init(id: "i1", deletedAt: nil)])
        let restored = WalletTree(try await db.wallets()).sections
        XCTAssertEqual(restored.first { $0.category == .imported }?.wallets.map(\.id), ["i1", "i2"])
        XCTAssertEqual(restored.last?.wallets.first?.parentWalletID, "i1")
    }
}
