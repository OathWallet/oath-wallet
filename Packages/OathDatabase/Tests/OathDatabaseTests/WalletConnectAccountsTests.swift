import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class WalletConnectAccountsTests: XCTestCase {
    private let evm0 = "m/44'/60'/0'/0/0"
    private let evmCustom = "m/44'/60'/7'/0/12"
    private let sol0 = "m/44'/501'/0'/0'"
    private let solCustom = "m/44'/501'/7'/3'"
    private let solAddress0 = "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL"
    private let solAddress1 = "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"

    private func fixture(_ url: URL) async throws -> OathDatabase {
        let db = try await OathDatabase.open(at: url)
        let chains = ["ethereum", "bnb", "solana", "tron"]
        try await db.seed(networks: chains.map {
            NetworkRecord(id: $0, name: $0, family: ["ethereum", "bnb"].contains($0) ? "evm" : "account",
                symbol: "TEST", decimals: 0, derivationPath: evm0, logo: "", sortOrder: 0)
        }, assets: [])
        var accounts: [AccountRecord] = []
        for chain in chains {
            for index in 0...1 where chain != "tron" || index == 0 {
                let solana = chain == "solana"
                accounts.append(.init(id: chain + String(index), walletID: "w", networkID: chain,
                    address: solana ? (index == 0 ? solAddress0 : solAddress1) : "0x" + String(repeating: index == 0 ? "1" : "2", count: 40),
                    derivationPath: solana ? (index == 0 ? sol0 : solCustom) : (index == 0 ? evm0 : evmCustom), accountIndex: index))
            }
        }
        try await db.importWalletIfNeeded(.init(id: "w", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: accounts)
        return db
    }

    func testNewConnectionsFollowHomeForEveryAccountFamilyAndPersist() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("db.sqlite"), db = try await fixture(url)
        let root = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        XCTAssertEqual(Set(root.map(\.id)), ["ethereum0", "bnb0", "solana0", "tron0"])
        for (selection, expected) in [
            (HomeAccountSelection(family: .evm, path: evmCustom), Set(["ethereum1", "bnb1", "solana0", "tron0"])),
            (.init(family: .solana, path: solCustom), Set(["solana1", "ethereum0", "bnb0", "tron0"]))
        ] {
            try await db.setHomeAccount(walletID: "w", selection: selection)
            let records = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
            let home = try await db.homeSnapshot(walletID: "w", currency: "USD")
            XCTAssertEqual(Set(records.map(\.id)), expected)
            XCTAssertEqual(Set(records.map(\.id)), Set(home.accounts.map(\.id)))
            let familyNetworks = Set(home.networks.filter { selection.family.contains($0) }.map(\.id))
            XCTAssertTrue(records.filter { familyNetworks.contains($0.networkID) }.allSatisfy { $0.derivationPath == selection.path })
            let reopened = try await OathDatabase.open(at: url)
            let restored = try await reopened.walletConnectAccounts(walletID: "w", scope: .connection)
            XCTAssertEqual(Set(restored.map(WalletConnectAccountIdentity.init)), Set(records.map(WalletConnectAccountIdentity.init)))
        }
    }

    func testExistingSessionStillFindsApprovedCustomAccountAfterHomeChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await fixture(dir.appendingPathComponent("db.sqlite"))
        try await db.setHomeAccount(walletID: "w", selection: .init(family: .evm, path: evmCustom))
        let approved = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        try await db.setHomeAccount(walletID: "w", selection: .init(family: .solana, path: solCustom))
        let owned = try await db.walletConnectAccounts(walletID: "w", scope: .session)
        for record in approved {
            let signing = try XCTUnwrap(owned.first { $0.networkID == record.networkID && $0.address == record.address })
            XCTAssertEqual(signing.id, record.id); XCTAssertEqual(signing.derivationPath, record.derivationPath)
        }
        let other = try await db.walletConnectAccounts(walletID: "other", scope: .session)
        XCTAssertTrue(other.isEmpty)
        try await db.pool.write { try $0.execute(sql: "UPDATE wallets SET deletedAt=1 WHERE id='w'") }
        let deleted = try await db.walletConnectAccounts(walletID: "w", scope: .session)
        let deletedConsent = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        XCTAssertTrue(deleted.isEmpty); XCTAssertTrue(deletedConsent.isEmpty)
    }

    func testSolanaSessionResolvesApprovedReceivePathAndRejectsUnownedAddresses() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await fixture(dir.appendingPathComponent("db.sqlite"))
        let alternate = "11111111111111111111111111111111", path = "m/44'/501'/0'"
        _ = try await db.prepareSolanaReceive(accountID: "solana0", addresses: [
            .init(path: sol0, address: solAddress0), .init(path: path, address: alternate)
        ], preferredPath: path)
        let consent = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        let approved = try XCTUnwrap(consent.first { $0.networkID == "solana" })
        XCTAssertEqual(approved.address, alternate); XCTAssertEqual(approved.derivationPath, path)
        _ = try await db.selectSolanaReceivePath(accountID: "solana0", path: sol0)
        try await db.setHomeAccount(walletID: "w", selection: .init(family: .solana, path: solCustom))
        let owned = try await db.walletConnectAccounts(walletID: "w", scope: .session)
        XCTAssertEqual(owned.filter { $0.id == "solana0" }.count, 2)
        let signing = try await db.solanaSigningAccount(accountID: "solana0", approvedAddress: alternate)
        XCTAssertEqual(signing.address, alternate); XCTAssertEqual(signing.derivationPath, path)
        let ordinarySend = try await db.solanaSigningAccount(accountID: "solana0")
        XCTAssertEqual(ordinarySend.address, solAddress0)
        do {
            _ = try await db.solanaSigningAccount(accountID: "solana1", approvedAddress: alternate)
            XCTFail("Another account's address was accepted")
        } catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        do {
            _ = try await db.solanaSigningAccount(accountID: "solana0", approvedAddress: solAddress1)
            XCTFail("Another independent account was accepted")
        } catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        let current = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        XCTAssertEqual(Set(current.map(\.id)), ["solana1", "ethereum0", "bnb0", "tron0"])
    }

    func testConsentIdentityDetectsReceiveChangesButIgnoresSyncWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await fixture(dir.appendingPathComponent("db.sqlite"))
        let records = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        var record = try XCTUnwrap(records.first)
        let identity = WalletConnectAccountIdentity(record)
        record.syncGeneration += 1
        XCTAssertEqual(identity, WalletConnectAccountIdentity(record))
        record.derivationPath = "m/999'"
        XCTAssertNotEqual(identity, WalletConnectAccountIdentity(record))
        record = records[0]; record.address = "different"
        XCTAssertNotEqual(identity, WalletConnectAccountIdentity(record))
        record = records[0]; record.walletID = "other"
        XCTAssertNotEqual(identity, WalletConnectAccountIdentity(record))
    }

    func testRootNeverFallsBackToFirstAddedAccountForMissingOriginalNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await fixture(dir.appendingPathComponent("db.sqlite"))
        try await db.setOriginalHomeAccount(walletID: "w", family: .solana, path: nil)
        let records = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        XCTAssertFalse(records.contains { $0.networkID == "solana" })
        try await db.setHomeAccount(walletID: "w", selection: .init(family: .solana, path: solCustom))
        let selected = try await db.walletConnectAccounts(walletID: "w", scope: .connection)
        XCTAssertEqual(Set(selected.map(\.id)), ["solana1", "ethereum0", "bnb0", "tron0"])
    }
}
