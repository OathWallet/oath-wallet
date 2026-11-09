import Foundation
import OathAnkr
import OathBitcoin
import OathDatabase
import OathDiagnostics

enum OathSendBalanceService {
    static func prepare(_ id: OathSendBalanceIdentity, vault: OathWalletVault) async throws -> SendSenderSnapshot {
        try await OathDiagnostics.$chain.withValue(id.chain) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let db = try await vault.database()
                    guard OathImportChain(rawValue: id.chain)?.isEnabled == true,
                          let account = try await db.accounts(walletID: id.wallet).first(where: { $0.id == id.account }),
                          account.networkID == id.chain, account.address == id.sender,
                          let asset = try await db.asset(networkID: id.chain, reference: id.reference),
                          asset.id == id.asset, asset.decimals == id.decimals else { throw OathWalletError.unavailable }
                    if let network = UTXONetwork(rawValue: id.chain) {
                        return try await OathBitcoinSendService.service(for: network).prepareSender(walletID: id.wallet, sender: id.sender, vault: vault)
                    }
                    let evmMultisig = try await vault.evmMultisigPolicy(walletID: id.wallet)
                    if let network = EVMSendNetwork(rawValue: id.chain), id.chain != "arc" || evmMultisig != nil {
                        let client = try await OathEVMSendService.shared.connection(network)
                        return try await client.prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals)
                    }
                    switch id.chain {
                    case "arc":
                        return try await OathArcSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals)
                    case "sui":
                        let policy = try await vault.suiMultisigPolicy(walletID: id.wallet)
                        return try await OathSuiSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals, multisig: policy)
                    case "solana":
                        let policy = try await vault.solanaMultisigPolicy(walletID: id.wallet)
                        return try await OathSolanaSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals, multisig: policy)
                    case "xrpl":
                        let policy = try await vault.xrplMultisigPolicy(walletID: id.wallet)
                        return try await OathXrplSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals, multisig: policy)
                    case "stellar":
                        let policy = try await vault.stellarMultisigPolicy(walletID: id.wallet)
                        return try await OathStellarSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals, multisig: policy)
                    case "tron":
                        let policy = try await vault.tronMultisigPolicy(walletID: id.wallet)
                        return try await OathTronSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals, multisig: policy)
                    case "ton":
                        let policy = try await vault.tonMultisigPolicy(walletID: id.wallet)
                        let key = try await vault.tonPublicKey(walletID: id.wallet, accountID: id.account)
                        return try await OathTonSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, publicKey: key, decimals: id.decimals, multisig: policy)
                    case "aptos":
                        let policy = try await vault.aptosMultisigPolicy(walletID: id.wallet)
                        let key = try await vault.aptosPublicKey(walletID: id.wallet, accountID: id.account)
                        return try await OathAptosSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, publicKey: key, decimals: id.decimals, multisig: policy)
                    case "near":
                        let policy = try await vault.nearMultisigPolicy(walletID: id.wallet)
                        let key = try await vault.nearPublicKey(walletID: id.wallet, accountID: id.account)
                        return try await OathNearSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, publicKey: key, decimals: id.decimals, multisig: policy)
                    case "thorchain":
                        let policy = try await vault.thorchainMultisigPolicy(walletID: id.wallet)
                        let key = try await vault.thorchainPublicKey(walletID: id.wallet, accountID: id.account)
                        return try await OathThorchainSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, publicKey: key, decimals: id.decimals, multisig: policy)
                    case "polkadot":
                        let token = try await db.polkadotInventory(accountID: id.account)?.holdings.first { $0.token.reference == id.reference }?.token
                        return try await OathPolkadotSendService.shared.connection().prepareSender(sender: id.sender, reference: id.reference, decimals: id.decimals, knownToken: token)
                    default: throw OathWalletError.unavailable
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    OathDiagnostics.record(error, component: "send", operation: "sender_preparation", context: ["chain": id.chain, "stage": "balance"])
                    throw error
                }
            }
        }
    }
}
