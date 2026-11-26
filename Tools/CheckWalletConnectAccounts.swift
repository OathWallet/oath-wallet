import Foundation
import XCTest
import OathDatabase
import OathDiagnostics
import OathAnkr
import OathBitcoin
@testable import WalletConnectSign

// Public synthetic addresses only. The real account/namespace methods are
// inserted by CheckWalletConnectNamespaces.py; no app, relay or signer runs.
@MainActor private final class AccountVaultFixture {
    let db: OathDatabase
    init(_ db: OathDatabase) { self.db = db }
    func database() async throws -> OathDatabase { db }
    func prepareBitcoin(accountID: String) async throws {
        if try await db.bitcoinState(accountID: accountID) == nil {
            try await db.prepareBitcoin(accountID: accountID, descriptor: BitcoinKeys.wallet(seed: Data(0..<32)))
        }
    }
}
@MainActor private final class AccountSessionFixture {
    let vault: AccountVaultFixture
    var isUnlocked = true
    var wallets: [WalletRecord]
    init(db: OathDatabase, wallet: WalletRecord) { vault = .init(db); wallets = [wallet] }
}
@MainActor private final class AccountServiceFixture {
    enum ConfigurationFailure: Error { case invalid }
    var session: AccountSessionFixture?
    let operation = UUID()
    var failure: OathWalletConnectPolicy.ConnectionFailure?
    init(_ session: AccountSessionFixture) { self.session = session }
    private func failConnection(_ failure: OathWalletConnectPolicy.ConnectionFailure) { self.failure = failure }

    // PRODUCTION_ACCOUNT_METHODS
}

@MainActor final class WalletConnectAccountServiceTests: XCTestCase {
    private let customEVM = "m/44'/60'/7'/0/12"
    private let customSolana = "m/44'/501'/7'/3'"
    private let firstAddress = "0x" + String(repeating: "1", count: 40)
    private let customAddress = "0x" + String(repeating: "2", count: 40)
    private let solFirst = "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL"
    private let solAdded = "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"

    private func fixture(_ url: URL) async throws -> (OathDatabase, AccountServiceFixture) {
        let db = try await OathDatabase.open(at: url)
        let chains = OathTokenNetwork.all.filter { $0.chain.isEVM }.map(\.chain) + [.solana]
        try await db.seed(networks: chains.map {
            .init(id: $0.rawValue, name: $0.rawValue, family: $0.isEVM ? "evm" : "account", symbol: "TEST", decimals: 0,
                derivationPath: "fixture", logo: "", sortOrder: 0)
        }, assets: [])
        let wallet = WalletRecord(id: "fixture", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1)
        let records = chains.flatMap { chain in (0...1).map { index in
            AccountRecord(id: chain.rawValue + String(index), walletID: wallet.id, networkID: chain.rawValue,
                address: chain.isEVM ? (index == 0 ? firstAddress : customAddress) : (index == 0 ? solFirst : solAdded),
                derivationPath: chain.isEVM ? (index == 0 ? "m/44'/60'/0'/0/0" : customEVM) : (index == 0 ? "m/44'/501'/0'/0'" : customSolana), accountIndex: index)
        } }
        try await db.importWalletIfNeeded(wallet, accounts: records)
        return (db, .init(.init(db: db, wallet: wallet)))
    }

    private func proposal(namespace: String, chains: Set<String>, methods: Set<String>) throws -> Session.Proposal {
        let metadata = AppMetadata(name: "Account regression", description: "Public host fixture", url: "https://example.org", icons: [],
            redirect: try .init(native: "namespace-test://", universal: nil))
        let required = [namespace: ProposalNamespace(chains: chains.sorted().map { Blockchain($0)! }, methods: methods, events: [])]
        return .init(id: "fixture", pairingTopic: "fixture", proposer: metadata, requiredNamespaces: required, optionalNamespaces: nil,
            sessionProperties: nil, scopedProperties: nil,
            proposal: .init(relays: [], proposer: .init(publicKey: "", metadata: metadata), requiredNamespaces: required, optionalNamespaces: nil), requests: nil)
    }

    func testColdBitcoinMetadataDoesNotRemoveOtherChainsFromConsent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, service) = try await fixture(dir.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: [.init(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8,
            derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [])
        let descriptor = try BitcoinKeys.wallet(seed: Data(0..<32))
        let branch = try XCTUnwrap(descriptor.branches.first { $0.type == .nativeSegwit && $0.change == 0 })
        let address = try XCTUnwrap(BitcoinKeys.addresses(branch: branch, range: 0..<1).first)
        let wallet = try XCTUnwrap(service.session?.wallets.first)
        try await db.importWalletIfNeeded(wallet, accounts: [.init(id: "btc0", walletID: wallet.id, networkID: "bitcoin",
            address: address.address, derivationPath: address.path)])
        let cold = try await db.bitcoinState(accountID: "btc0")
        XCTAssertNil(cold, "Reproduce consent before the background Bitcoin refresh.")
        let records = await service.connectionAccounts(walletID: wallet.id)
        XCTAssertTrue(records.contains { $0.networkID == "bitcoin" && $0.address == address.address })
        XCTAssertTrue(records.contains { $0.networkID == "ethereum" })
        XCTAssertTrue(records.contains { $0.networkID == "solana" })
        XCTAssertNil(service.failure)
        let prepared = try await db.bitcoinState(accountID: "btc0")
        XCTAssertNotNil(prepared)
    }

    func testEverySupportedEVMNetworkApprovesSelectedCustomAccountInRealSDK() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, service) = try await fixture(dir.appendingPathComponent("db.sqlite"))
        try await db.setHomeAccount(walletID: "fixture", selection: .init(family: .evm, path: customEVM))
        let displayed = await service.connectionAccounts(walletID: "fixture")
        XCTAssertFalse(displayed.isEmpty)
        // Home replaces the selected family while retaining original accounts
        // from other families. Consent still grants only the selected chains.
        let evm = displayed.filter { OathImportChain(rawValue: $0.networkID)?.isEVM == true }
        XCTAssertTrue(evm.allSatisfy { $0.address == customAddress && $0.derivationPath == customEVM })
        XCTAssertEqual(displayed.first { $0.networkID == "solana" }?.address, solFirst)
        let chains = Set(evm.flatMap { AccountServiceFixture.blockchains(networkID: $0.networkID).map(\.absoluteString) })
        let paused = Set(OathTokenNetwork.registered.filter { !$0.chain.isEnabled }.compactMap { $0.chainID.map { "eip155:\($0)" } })
        XCTAssertEqual(chains, OathWalletConnectPolicy.transactionChains.subtracting(paused))
        let input = try proposal(namespace: "eip155", chains: chains, methods: ["personal_sign", "eth_sendTransaction", "eth_accounts"])
        let current = try await service.consentAccounts(walletID: "fixture", reviewed: displayed)
        let approved = try service.namespaces(for: input, accounts: current, selected: chains)
        try Namespace.validate(approved); try Namespace.validateApproved(approved, against: input.requiredNamespaces)
        XCTAssertEqual(Set(approved["eip155"]!.accounts.map(\.address)), [customAddress])
        XCTAssertEqual(approved["eip155"]?.accounts.count, chains.count)
        XCTAssertNil(approved["solana"])
        let solanaChain = SolanaSendNetwork.mainnet.walletConnectChain
        let solanaProposal = try proposal(namespace: "solana", chains: [solanaChain], methods: ["solana_signMessage"])
        let solanaApproved = try service.namespaces(for: solanaProposal, accounts: current, selected: [solanaChain])
        XCTAssertEqual(Set(solanaApproved["solana"]!.accounts.map(\.address)), [solFirst])
        XCTAssertNil(solanaApproved["eip155"])

        try await db.setHomeAccount(walletID: "fixture", selection: .init(family: .solana, path: customSolana))
        let sessionOwned = await service.accounts(walletID: "fixture")
        for account in approved["eip155"]!.accounts {
            let record = try XCTUnwrap(sessionOwned.first {
                $0.address == account.address && AccountServiceFixture.blockchains(networkID: $0.networkID).contains(account.blockchain)
            })
            XCTAssertEqual(record.derivationPath, customEVM)
        }
        do { _ = try await service.consentAccounts(walletID: "fixture", reviewed: displayed); XCTFail("Stale consent accepted") } catch { }
    }

    func testSolanaNamespacesUseSelectedAccountAndSessionRetainsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, service) = try await fixture(dir.appendingPathComponent("db.sqlite"))
        try await db.setHomeAccount(walletID: "fixture", selection: .init(family: .solana, path: customSolana))
        let records = await service.connectionAccounts(walletID: "fixture")
        let solana = records.filter { $0.networkID == "solana" }
        XCTAssertEqual(solana.map(\.address), [solAdded]); XCTAssertEqual(solana.map(\.derivationPath), [customSolana])
        let chains = Set(AccountServiceFixture.blockchains(networkID: "solana").map(\.absoluteString))
        let input = try proposal(namespace: "solana", chains: chains, methods: ["solana_signMessage", "solana_signTransaction"])
        let approved = try service.namespaces(for: input, accounts: records, selected: chains)
        try Namespace.validate(approved); try Namespace.validateApproved(approved, against: input.requiredNamespaces)
        XCTAssertEqual(Set(approved["solana"]!.accounts.map(\.address)), [solAdded])
        let evmProposal = try proposal(namespace: "eip155", chains: ["eip155:1"], methods: ["personal_sign"])
        let evmApproved = try service.namespaces(for: evmProposal, accounts: records, selected: ["eip155:1"])
        XCTAssertEqual(Set(evmApproved["eip155"]!.accounts.map(\.address)), [firstAddress])
        XCTAssertNil(evmApproved["solana"])
        try await db.setHomeAccount(walletID: "fixture", selection: nil)
        let root = await service.connectionAccounts(walletID: "fixture")
        XCTAssertEqual(root.first { $0.networkID == "solana" }?.address, solFirst)
        let existing = await service.accounts(walletID: "fixture")
        let signing = try XCTUnwrap(existing.first { $0.networkID == "solana" && $0.address == solAdded })
        let resolved = try await db.solanaSigningAccount(accountID: signing.id, approvedAddress: solAdded)
        XCTAssertEqual(resolved.derivationPath, customSolana)
        service.session?.isUnlocked = false
        let locked = await service.accounts(walletID: "fixture")
        XCTAssertTrue(locked.isEmpty)
        do { _ = try await service.consentAccounts(walletID: "fixture", reviewed: root); XCTFail("Locked consent accepted") } catch { }
    }

    func testSameIDReceivePathChangeInvalidatesReviewedConsent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, service) = try await fixture(dir.appendingPathComponent("db.sqlite"))
        _ = try await db.prepareSolanaReceive(accountID: "solana0", addresses: [
            .init(path: "m/44'/501'/0'/0'", address: solFirst), .init(path: "m/44'/501'/0'", address: "11111111111111111111111111111111")
        ], preferredPath: "m/44'/501'/0'/0'")
        let reviewed = await service.connectionAccounts(walletID: "fixture")
        _ = try await db.selectSolanaReceivePath(accountID: "solana0", path: "m/44'/501'/0'")
        let current = await service.connectionAccounts(walletID: "fixture")
        XCTAssertEqual(Set(current.map(\.id)), Set(reviewed.map(\.id)))
        do { _ = try await service.consentAccounts(walletID: "fixture", reviewed: reviewed); XCTFail("Address changed after review") } catch { }
        let accepted = try await service.consentAccounts(walletID: "fixture", reviewed: current)
        XCTAssertEqual(accepted.first { $0.networkID == "solana" }?.derivationPath, "m/44'/501'/0'")
    }
}
