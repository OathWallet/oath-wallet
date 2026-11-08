import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathWCNearReview: View {
    let request:WalletConnectNearRequest
    let review:WalletConnectNearReview
    @Environment(\.oathLocalizer) private var strings
    var body:some View {
        VStack(spacing:0) {
            OathSettingsRow(title:request.network.walletConnectName,accessory:.none,networkLogo:"network-near")
            OathWCValue(title:strings.text(.scannerWCAccount),value:request.account,leftToRight:true)
            OathWCValue(title:strings.text(.wcMaximumFee),value:(OathSendAmount.units(review.fee,decimals:24) ?? "—") + " NEAR",leftToRight:true)
            let transactions = presentationTransactions
            if transactions.isEmpty { Text(strings.text(.wcInvalidDetail)).oathFont(.body).padding(20) }
            ForEach(Array(transactions.enumerated()),id:\.offset) { index, tx in
                Divider()
                OathWCValue(title:strings.text(.sendRecipient),value:tx.receiver,leftToRight:true)
                ForEach(Array(tx.actions.enumerated()),id:\.offset) { _, action in
                    Text(actionText(action)).oathFont(.body).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(20)
                }
            }
            OathSettingsFooter { Text(strings.text(.wcCallWarning)) }
        }
    }
    private func actionText(_ action: WalletConnectNearTransaction.Action) -> String {
        OathWalletConnectReviewLocalization.nearAction(action, strings: strings)
    }
    // Reparse the exact signed bytes so persisted reviews from older versions
    // receive structured display fields too, without parsing English sentences.
    private var presentationTransactions: [WalletConnectNearTransaction] {
        do { return try review.request.transactions.map(WalletConnectNearTransaction.init) }
        catch {
            OathDiagnostics.record(error, component: "walletconnect", operation: "localize_near_review",
                context: ["chain": "near", "stage": "presentation"])
            return []
        }
    }

}

struct OathWCNearCompletion: View {
    let submission: WalletConnectNearSubmission
    let identity: OathWCIdentity
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    private var checking: Bool { ["signed", "unknown"].contains(submission.state) }
    private var confirmed: Bool { submission.state == "confirmed" }
    private var failed: Bool { ["failed", "expired"].contains(submission.state) }
    var body: some View {
        OathWCResultContent(identity: identity) {
            VStack(spacing: 18) {
                Image(systemName: confirmed ? "checkmark.circle" : failed ? "exclamationmark.circle" : "clock")
                    .font(.system(size: 52)).foregroundStyle(failed ? Color.red : OathOnboardingColors.blue)
                Text(strings.text(confirmed ? .wcTransactionConfirmed : failed ? .wcTransactionFailed : checking ? .sendChecking : .wcTransactionPending))
                    .oathFont(.title2, weight: .semibold)
                Text(strings.text(confirmed ? .wcTransactionConfirmedDetail : failed ? .wcTransactionFailedDetail : checking ? .sendCheckingDetail : .wcTransactionPendingDetail))
                    .oathFont(.body).foregroundStyle(.secondary)
                Text(NearSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.near.done")
            }
        }.toolbar(.hidden, for: .bottomBar)
    }
}
