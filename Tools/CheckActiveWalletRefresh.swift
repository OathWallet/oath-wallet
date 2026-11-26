import Foundation
import OathDatabase
import OathAnkr

/// Production session/vault/SQLite, synthetic keys and captured network boundaries.
@main struct CheckActiveWalletRefresh {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("active-refresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let vault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: db)
        try await vault.create(digits: [8,6,2,9,1,4], importing: .init(
            phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", language: "english"))
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let wallet = session.displayedProfile!.id
        let originalAccounts = session.portfolio!.accounts
        let originalIDs = Set(session.portfolio!.accounts.map(\.id))
        let evmPath = "m/44'/60'/0'/0/1", solanaPath = "m/44'/501'/1'/0'"
        try await session.addHDAccounts(walletID: wallet.uuidString, family: .evm, paths: [evmPath])
        try await session.addHDAccounts(walletID: wallet.uuidString, family: .solana, paths: [solanaPath])
        let allAccounts = try await db.accounts(walletID: wallet.uuidString)

        func verify(_ name: String, expected: Set<String>) async throws {
            // Finish any automatic initial refresh before capturing the next pull.
            try await session.refresh()
            await RefreshScopeCapture.shared.reset()
            try await session.refresh()
            let calls = await RefreshScopeCapture.shared.calls
            precondition(!calls.isEmpty && !expected.isEmpty)
            let actual = Set(session.portfolio!.accounts.map(\.id))
            precondition(actual == expected, "Refresh scope changed: \(name); expected \(expected.count), actual \(actual.count); missing networks \(allAccounts.filter { expected.subtracting(actual).contains($0.id) }.map(\.networkID)); extra networks \(session.portfolio!.accounts.filter { !expected.contains($0.id) }.map(\.networkID))")
            precondition(calls.allSatisfy { $0.accountIDs.isSubset(of: expected) }, "Refresh escaped selected account")
            precondition(calls.allSatisfy { $0.walletID == nil || $0.walletID == session.displayedProfile!.id.uuidString })
            // SQL retains forward-compatible/disabled networks. The live profile
            // is the subset this build can actually operate, as on the phone.
            let addresses = session.displayedProfile!.addresses
            let activeIDs = Set(addresses.compactMap(\.accountID))
            precondition(!activeIDs.isEmpty && activeIDs.isSubset(of: expected))
            let evmIDs = Set(addresses.filter { AnkrSynchronizer.supports(networkID: $0.chain.id) }.compactMap(\.accountID))
            let cronosIDs = Set(addresses.filter { $0.chain == .cronos }.compactMap(\.accountID))
            for (operation, ids) in [("evm", evmIDs), ("cronos", cronosIDs), ("quotes", activeIDs)] {
                precondition(calls.contains { $0.operation == operation && $0.accountIDs == ids }, "Missing captured refresh scope: \(name) \(operation), expected \(ids.count), got \(calls.filter { $0.operation == operation }.map { $0.accountIDs.count })")
            }
            print("PASS active refresh: \(name)")
        }

        try await session.selectWallet(wallet)
        try await verify("original wallet excludes added accounts", expected: originalIDs)
        try await session.selectWalletAccount(wallet, selection: .init(family: .evm, path: evmPath))
        let evmIDs = Set(originalAccounts.filter { !HDAccountFamily.evm.owns(network: $0.networkID) }.map(\.id))
            .union(allAccounts.filter { HDAccountFamily.evm.owns(network: $0.networkID) && $0.derivationPath == evmPath }.map(\.id))
        try await verify("selected EVM account plus unchanged original chains", expected: evmIDs)
        try await session.selectWalletAccount(wallet, selection: .init(family: .solana, path: solanaPath))
        let solanaIDs = Set(originalAccounts.filter { $0.networkID != "solana" }.map(\.id))
            .union(allAccounts.filter { $0.networkID == "solana" && $0.derivationPath == solanaPath }.map(\.id))
        try await verify("selected Solana account plus unchanged original chains", expected: solanaIDs)
        _ = try await session.addWallet(requestID: UUID(), privateKey: .init(bytes: Data(repeating: 9, count: 32), networks: [.ethereum]))
        let importedIDs = Set(session.portfolio!.accounts.map(\.id))
        precondition(session.displayedProfile!.id != wallet && importedIDs.isDisjoint(with: originalIDs.union(evmIDs).union(solanaIDs)))
        try await verify("another active wallet", expected: importedIDs)
        try await session.selectWallet(wallet)
        try await verify("return to original wallet", expected: originalIDs)
        await session.lock()
    }
}
