import SwiftUI
import OathAnkr
import OathBrowser
import OathDiagnostics

struct OathBrowserApprovalSheet: View {
    let controller: OathBrowserController
    let session: OathWalletSession
    let requestID: UUID
    @State private var passcode = false
    @State private var digits: [UInt8] = []
    @State private var notice: OathStringKey?
    @Environment(\.oathLocalizer) private var strings
    private var title: OathStringKey {
        guard let review = controller.review else { return .browserRequest }
        return switch review.payload {
        case .connect: .browserConnect
        case .network: .wcSwitchNetwork
        case .message: .scannerWCSign
        case .typed: .wcSignData
        case .transaction: .wcSubmitTransaction
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                if controller.approvalID != requestID {
                    ProgressView()
                } else if passcode {
                    OathPasscodeEntry(title: strings.text(title), filledCount: digits.count, isEnabled: !controller.signing,
                        isDeleteEnabled: !digits.isEmpty, errorMessage: notice.map(strings.text), titleIdentifier: "browser.passcode") { key in
                        guard !controller.signing else { return }
                        switch key {
                        case .digit(let digit): if digits.count < 6 { digits.append(UInt8(digit)); if digits.count == 6 { approve(digits) } }
                        case .delete: if !digits.isEmpty { digits.removeLast() }
                        default: break
                        }
                    }
                } else if let review = controller.review {
                    ScrollView {
                        VStack(spacing: 16) {
                            VStack(spacing: 8) {
                                Image(systemName: "globe").font(.system(size: 32)).foregroundStyle(.blue)
                                Text(review.context.origin.string).oathFont(.headline).textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                                Text(strings.text(.browserRequestOrigin)).oathFont(.caption).foregroundStyle(.secondary)
                            }.padding(20)
                            payload(review)
                            if let notice { Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(.horizontal, 24) }
                        }
                    }.safeAreaInset(edge: .bottom) {
                        VStack(spacing: 12) {
                            OathActionButton(title: strings.text(title), isWorking: controller.signing, isInteractionBlocked: controller.signing) { approve(nil) }
                                .accessibilityIdentifier("browser.approve")
                            OathActionButton(title: strings.text(.scannerWCReject), appearance: .destructiveSecondary, role: .destructive, isInteractionBlocked: controller.signing) { close() }
                                .accessibilityIdentifier("browser.reject")
                        }.padding(20).background(.regularMaterial)
                    }
                } else { ProgressView(strings.text(.exploreLoading)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton { close() }.disabled(controller.signing) } }
            .oathNativeAppBar(title: strings.text(title))
        }.interactiveDismissDisabled(controller.signing)
            .onChange(of: controller.review?.id) { _, _ in digits = []; passcode = false; notice = nil }
    }
    @ViewBuilder private func payload(_ review: OathBrowserReview) -> some View {
        switch review.payload {
        case .connect, .network:
            VStack(alignment: .leading, spacing: 20) {
                Text(strings.text(.browserConnectDetail)).oathFont(.body)
                OathWCValue(title: strings.text(.scannerWCAccount), value: review.account.address, leftToRight: true)
                OathWCValue(title: strings.text(.tokenNetwork), value: OathImportChain(rawValue: review.network.rawValue)?.name ?? review.network.rawValue)
                if controller.selected?.isPrivate == true { Text(strings.text(.browserPrivateConnectionDetail)).oathFont(.footnote).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20)
        case .message(let bytes, let signIn):
            OathWCMessageReview(message: String(data: bytes, encoding: .utf8) ?? "0x" + bytes.map { String(format: "%02x", $0) }.joined(),
                signIn: signIn, account: review.account.address, network: review.network.rawValue, close: { close() })
        case .typed(let data):
            OathWalletConnectTypedReview(data: data, account: review.account.address, network: review.network.rawValue, close: { close() })
        case .transaction(let request, let quote, let token, let swap):
            if let swap {
                OathWCThorchainSwapReview(inputAsset: swap.inputAsset, inputAmount: swap.deposit.amount, inputDecimals: swap.decimals,
                    sender: request.sender, quote: swap.quote, gasAmount: OathSendAmount.units(String(quote.plan.fee), decimals: 18) ?? "—",
                    gasSymbol: quote.plan.network.symbol, currency: session.portfolio?.currency ?? "USD", exchangeRate: session.portfolio?.displayExchangeRate)
            } else {
                OathWCEVMReview(request: request, plan: quote.plan, close: { close() }, approvalToken: token, saveLimit: { try await controller.reviseApproval(amount: $0) })
            }
        }
    }
    private func close() {
        guard controller.approvalID == requestID else { return }
        controller.cancelApproval()
    }
    private func approve(_ input: [UInt8]?) {
        guard !controller.signing, controller.approvalID == requestID else { return }; notice = nil
        Task {
            await OathDiagnostics.$chain.withValue(controller.review?.network.rawValue) {
                await OathDiagnostics.$operationID.withValue(controller.review?.id ?? UUID()) {
                    defer { digits = [] }
                    do { try await controller.approve(digits: input, reason: strings.text(title)); passcode = false }
                    catch is CancellationError { }
                    catch {
                        if error is OathBiometricCredentialError { passcode = true }
                        else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                        else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                        else if error as? OathWalletConnectService.ReviewFailure == .quoteUpdated { passcode = false; notice = .wcQuoteUpdated }
                        else if error is BrowserRPCError { close() }
                        else {
                            passcode = false; notice = OathSendFailure.reason(error, fallback: .sendSubmitFailed).key
                            OathDiagnostics.record(error, component: "browser", operation: "approve_request")
                        }
                    }
                }
            }
        }
    }
}
