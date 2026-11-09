import Foundation
import OathAnkr

extension OathSendModel {
    func balanceIdentity(session: OathWalletSession) -> OathSendBalanceIdentity? {
        guard session.isUnlocked, !session.resetting, !session.changingWallet, supportsSend,
              let holding, !holding.isCatalogPreview, let snapshot,
              let account = snapshot.accounts.first(where: { $0.id == holding.accountID }),
              session.wallets.contains(where: { $0.id == walletID }) else { return nil }
        return .init(session: session.sendSessionGeneration, wallet: walletID, account: account.id,
                     chain: holding.networkID, asset: holding.assetID, reference: holding.reference, decimals: holding.decimals,
                     sender: account.address,
                     publicPolicy: snapshot.wallet.kind + ":" + snapshot.wallet.vaultReference + ":" + account.derivationPath + ":" + String(account.syncGeneration) + ":" + balancePreparationGeneration.uuidString,
                     observation: holding.balanceObservedAt, pending: holding.pendingTransactionCount)
    }

    func startBalancePreparation(session: OathWalletSession) async {
        let identity = balanceIdentity(session: session)
        do { _ = try await preparedSender(session: session) }
        catch {
            // diagnostics: send-balance-preparation-feedback
            // The service owns provider diagnostics. Cancellation is normal when
            // selection/lifecycle changes; no notices or signing state are added.
            if !(error is CancellationError), !Task.isCancelled,
               identity == balanceIdentity(session: session) { balancePreparationFailed = true }
        }
    }

    func preparedSender(session: OathWalletSession, retryFailure: Bool = false) async throws -> SendSenderSnapshot {
        guard let identity = balanceIdentity(session: session) else { throw CancellationError() }
        activePreparationIdentity = identity
        let scope = balancePreparationGeneration, vault = session.vault
        let value: SendSenderSnapshot
        do {
            // Continue is an explicit retry. The actor knows whether the flight
            // failed even if the earlier UI waiter has not received that result.
            value = try await balancePreparation.value(for: identity, retry: retryFailure) {
                try await OathSendBalanceService.prepare(identity, vault: vault)
            }
        } catch {
            // diagnostics: send-balance-preparation-feedback
            // Preserve a failed attempt for explicit retry; the service reports it.
            if !(error is CancellationError), !Task.isCancelled,
               scope == balancePreparationGeneration, identity == balanceIdentity(session: session) {
                balancePreparationFailed = true
            }
            throw error
        }
        try Task.checkCancellation()
        guard scope == balancePreparationGeneration, identity == balanceIdentity(session: session) else { throw CancellationError() }
        senderSnapshot = value; senderSnapshotIdentity = identity; balancePreparationFailed = false
        return value
    }

    func invalidateBalancePreparation() {
        balancePreparationGeneration = UUID()
        senderSnapshot = nil; senderSnapshotIdentity = nil; balancePreparationFailed = false
        let coordinator = balancePreparation, oldIdentity = activePreparationIdentity
        activePreparationIdentity = nil
        if let oldIdentity { Task { await coordinator.invalidate(ifIdentity: oldIdentity) } }
    }
}
