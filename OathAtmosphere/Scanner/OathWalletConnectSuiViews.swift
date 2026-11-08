import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathWCSuiReview: View {
    let request:WalletConnectSuiRequest
    let review:WalletConnectSuiReview?
    let close:@MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body:some View {
        if let message = request.message {
            OathWCMessageReview(message:messageText(message),signIn:nil,account:request.account,network:request.network.walletConnectName,close:close)
        } else if let review {
            VStack(spacing:0) {
                OathSettingsRow(title:request.network.walletConnectName,accessory:.none,networkLogo:"network-sui")
                OathWCValue(title:strings.text(.scannerWCAccount),value:request.account,leftToRight:true)
                // Security-relevant effects are on the approval surface, before
                // balances/fees and outside the optional raw-data NavigationLink.
                if let objects = review.objectChanges {
                    ForEach(objects.filter { $0.authority != .coin || $0.changesOwner }) { object in
                        VStack(spacing: 0) {
                            OathSettingsRow(title: strings.text(.wcSuiObjects), accessory: .none)
                            ForEach(Array(OathWalletConnectReviewLocalization.suiObjectFields(object, strings: strings).enumerated()), id: \.offset) { _, field in
                                OathWCValue(title: field.title, value: field.value, leftToRight: field.leftToRight)
                            }
                            if let warning = OathWalletConnectReviewLocalization.suiAuthorityWarning(object.authority) {
                                OathWCValue(title: strings.text(.scannerWCPermissions), value: strings.text(warning))
                            }
                            OathSettingsSectionRule()
                        }.accessibilityIdentifier("walletconnect.sui.object")
                    }
                }
                if let actions = transactionActions(review), !actions.isEmpty {
                    OathSettingsRow(title: strings.text(.wcTransactionData), accessory: .none)
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Text(verbatim: action).oathFont(.footnote).textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                } else if review.actions?.isEmpty == false {
                    Text(strings.text(.wcDecodedUnavailable)).oathFont(.body).padding(20)
                }
                OathWCValue(title:strings.text(.wcMaximumFee),value:(OathSendAmount.units(String(review.gasBudget),decimals:9) ?? "—") + " SUI",leftToRight:true)
                if review.gasOwner != request.account {
                    OathWCValue(title:strings.text(.wcSolanaFeePayer),value:review.gasOwner,leftToRight:true)
                }
                ForEach(Array(review.changes.enumerated()),id:\.offset) { _, change in
                    Text(changeText(change,review:review)).oathFont(.body).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(20)
                }
                NavigationLink {
                    OathWCContent {
                        if let data = transactionData(review) {
                            Text(data).font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        } else {
                            Text(strings.text(.wcDecodedUnavailable)).oathFont(.body).padding(20)
                        }
                    }.navigationTitle(strings.text(.wcSignData)).navigationBarTitleDisplayMode(.inline)
                } label: { OathSettingsRow(title:strings.text(.wcSignData),icon:"text.alignleft") }
                    .buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsFooter { Text(strings.text(.wcCallWarning)) }
            }
        }
    }
    private func changeText(_ row: String, review: WalletConnectSuiReview) -> String {
        OathWalletConnectReviewLocalization.suiChange(row, tokens: review.tokens, strings: strings)
    }
    private func transactionActions(_ review: WalletConnectSuiReview) -> [String]? {
        guard let bytes = request.transaction else { return nil }
        do {
            let transaction = try WalletConnectSuiTransaction(bytes, network: request.network,
                account: request.account, executing: request.broadcasts, now: review.createdAt)
            return try OathWalletConnectReviewLocalization.suiActions(transaction)
        } catch {
            OathDiagnostics.record(error, component: "walletconnect", operation: "localize_sui_actions",
                context: ["chain": "sui", "stage": "presentation"])
            return nil
        }
    }
    private func transactionData(_ review: WalletConnectSuiReview) -> String? {
        // Raw decoded protocol data is intentionally not translated. Never show
        // the old English prose stored in pre-localization review snapshots.
        guard let bytes = request.transaction else { return nil }
        do {
            let transaction = try WalletConnectSuiTransaction(bytes, network: request.network,
                account: request.account, executing: request.broadcasts, now: review.createdAt)
            let data = try JSONEncoder().encode(transaction.displayData)
            let object = try JSONSerialization.jsonObject(with: data)
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            return String(decoding: formatted, as: UTF8.self)
        } catch {
            OathDiagnostics.record(error, component: "walletconnect", operation: "localize_sui_review",
                context: ["chain": "sui", "stage": "presentation"])
            return nil
        }
    }

    private func messageText(_ data:Data) -> String {
        if let text = String(data:data,encoding:.utf8), !text.unicodeScalars.contains(where: {
            $0.properties.isBidiControl || ($0.value < 32 && $0.value != 10 && $0.value != 9)
        }) { return text }
        return "0x" + data.map { String(format:"%02x",$0) }.joined()
    }
}
struct OathWCSuiCompletion: View {
    let submission: WalletConnectSuiSubmission
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
                Text(SuiSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.sui.done")
            }
        }.toolbar(.hidden, for: .bottomBar)
    }
}
