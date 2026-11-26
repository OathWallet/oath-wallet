import Foundation
import OathAnkr

// The app's balance-preparation extension is compiled unchanged against these
// session, database observation and provider fixtures. No keys or RPCs are used.
struct Wallet {
    var id = "first"
    let kind = "fixture", vaultReference = "fixture"
}

struct Account {
    let id = "account", address = "sender", derivationPath = "fixture"
    var syncGeneration = 0
}

struct Holding {
    let networkID: String
    let accountID = "account", assetID = "asset"
    var reference: String
    let decimals = 8, isCatalogPreview = false
    var amountAtomic: String? = "100"
    var pendingTransactionCount = 0
    var balanceObservedAt: Double? = 10
}

struct Snapshot {
    var wallet = Wallet()
    var accounts = [Account()]
}

actor Provider {
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func read(_ id: OathSendBalanceIdentity) async throws -> SendSenderSnapshot {
        calls += 1
        if calls == 1 { await withCheckedContinuation { pending = $0 } }
        return try SendSenderSnapshot(chain: id.chain, sender: id.sender, reference: id.reference,
                                      decimals: id.decimals, assetBalance: "100", nativeBalance: "100",
                                      spendable: "90", observedAt: .now)
    }

    func release() { pending?.resume(); pending = nil }
}

enum OathSendBalanceService {
    static func prepare(_ id: OathSendBalanceIdentity, vault: Provider) async throws -> SendSenderSnapshot {
        try await vault.read(id)
    }
}

@MainActor final class OathWalletSession {
    let isUnlocked = true, resetting = false, changingWallet = false
    let wallets = [Wallet(), Wallet(id: "second")]
    let sendSessionGeneration = UUID(), vault = Provider()
}

@MainActor final class OathSendModel {
    var walletID = "first"
    let supportsSend = true
    var holding: Holding?
    var snapshot: Snapshot? = Snapshot()
    let balancePreparation = OathSendBalancePreparation<OathSendBalanceIdentity, SendSenderSnapshot>()
    var activePreparationIdentity: OathSendBalanceIdentity?, senderSnapshotIdentity: OathSendBalanceIdentity?
    var balancePreparationGeneration = UUID(), balancePreparationFailed = false
    var senderSnapshot: SendSenderSnapshot?
}

@main enum SendReviewRefreshChecks {
    enum Change: CaseIterable { case timestamp, amount, pending, accountGeneration, wallet }

    @MainActor static func check(chain: String, reference: String, change: Change) async throws {
        let session = OathWalletSession(), model = OathSendModel()
        model.holding = Holding(networkID: chain, reference: reference)
        let initial = model.balanceIdentity(session: session)!
        let review = Task { try await model.preparedSender(session: session) }
        while await session.vault.calls == 0 { await Task.yield() }

        // The database publishes while Review is suspended inside the provider.
        model.holding?.balanceObservedAt = 11
        switch change {
        case .timestamp: break
        case .amount: model.holding?.amountAtomic = "99"
        case .pending: model.holding?.pendingTransactionCount = 1
        case .accountGeneration: model.snapshot?.accounts[0].syncGeneration += 1
        case .wallet: model.walletID = "second"
        }
        let updated = model.balanceIdentity(session: session)
        precondition((updated == initial) == (change == .timestamp))
        if change == .wallet {
            precondition(updated == nil, "The old wallet snapshot must not start new preparation")
            model.snapshot?.wallet.id = "second"
        }
        let warmup = Task { await model.startBalancePreparation(session: session) }
        await session.vault.release()
        switch await review.result {
        case .success: precondition(change == .timestamp, "Stale sender published")
        case .failure(let error): precondition(change != .timestamp && error is CancellationError)
        }
        await warmup.value
        let calls = await session.vault.calls
        precondition(calls == (change == .timestamp ? 1 : 2))
        precondition(model.senderSnapshotIdentity == model.balanceIdentity(session: session))
        precondition(model.validatedBalance == "90")
        model.holding?.balanceObservedAt = 12
        precondition(model.validatedBalance == "90", "Duplicate observation discarded spendable balance")
        model.holding?.amountAtomic = nil
        precondition(model.validatedBalance == nil, "Missing balance reused an obsolete spendable amount")
    }

    static func main() async throws {
        let chains = CommandLine.arguments.dropFirst()
        precondition(!chains.isEmpty)
        for chain in chains {
            for reference in ["native", "token"] {
                for change in Change.allCases { try await check(chain: chain, reference: reference, change: change) }
            }
        }
        print("PASS: shared review preparation, wallet scope and spendable cache (\(chains.count) chain IDs, \(chains.count * 10) scenarios)")
    }
}
