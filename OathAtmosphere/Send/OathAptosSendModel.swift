import Foundation
import Observation
import OathAnkr
import OathDiagnostics

@MainActor @Observable final class OathAptosSendModel {
    private(set) var quote: OathAptosQuote?
    private(set) var busy = false
    private(set) var needsRefresh = false
    private(set) var needsAmountChange = false
    private(set) var needsRecipientChange = false
    private(set) var passcode = false
    private(set) var submission: OathBitcoinSubmission?
    private(set) var gasPrice: Decimal?
    private(set) var failureMessage: OathSendFailure?
    var notice: OathStringKey?
    @ObservationIgnored private var work: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()

    func prepare(model: OathSendModel, session: OathWalletSession) {
        guard !busy, submission == nil, session.isUnlocked, model.supportsAptosSend,
              let holding = model.holding, let amount = model.reviewAtomic else { return }
        cancel(); busy = true; needsRefresh = false; needsAmountChange = false; quote = nil
        gasPrice = model.snapshot?.holdings.first { $0.networkID == "aptos" && $0.reference == "native" }?.price
            .flatMap { Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX")) }
        let token = generation, walletID = model.walletID, recipient = model.address
        let maximum = model.maximumAmount != nil
        let sessionGeneration = session.sendSessionGeneration
        work = Task(priority:.userInitiated) {
            do {
                let prepared = try await model.preparedSender(session: session, retryFailure: true)
                let value = try await OathAptosSendService.shared.quote(walletID:walletID,accountID:holding.accountID,assetID:holding.assetID,
                    reference:holding.reference,recipient:recipient,amount:amount,decimals:holding.decimals,maximum:maximum,vault:session.vault,preparedSender:prepared)
                guard generation == token, !Task.isCancelled, session.isUnlocked, !session.resetting, !session.changingWallet, session.sendSessionGeneration == sessionGeneration else { return }
                guard SendReviewAmounts.isWithinRequestedAmount(String(describing: value.plan.amount), requested: String(describing: amount)) else {
                    busy = false; needsRefresh = true; needsAmountChange = true
                    return // Changed Max intent is form validation, not an app error.
                }
                SendPerformance.publish { quote = value; busy = false }
            } catch {
                OathDiagnostics.record(error,component:"aptos_send",operation:"prepare",context:["chain":"aptos","stage":"quote"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false; needsRefresh = true
                failureMessage = OathSendFailure.reason(error, fallback: .sendPreparationFailed)
                needsAmountChange = [.insufficientFunds, .amount].contains(error as? AptosSendError)
                needsRecipientChange = (error as? AptosSendError) == .sameRecipient
            }
        }
    }
    func send(session: OathWalletSession, digits: [UInt8]? = nil, reason: String) {
        guard let quote, !busy, submission == nil, session.isUnlocked else { return }
        busy = true; notice = nil
        let token = generation
        work = Task {
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) } } }
            do {
                let result = try await OathAptosSendService.shared.submit(quote,vault:session.vault,digits:digits,reason:reason)
                guard generation == token, !Task.isCancelled else { return }
                busy = false; passcode = false; submission = result

            } catch {
                OathDiagnostics.record(error,component:"aptos_send",operation:"submit",context:["chain":"aptos"])
                guard generation == token, !Task.isCancelled else { return }
                busy = false
                if error is OathBiometricCredentialError { passcode = true }
                else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode = true; notice = .unlockWait }
                else if !(error is CancellationError) { passcode = false; needsRefresh = true; failureMessage = OathSendFailure.reason(error, fallback: .sendSubmitFailed); self.quote = nil; OathHaptics.shared.play(.warning) }
            }
        }
    }


    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; passcode = false; notice = nil
        // The receipt owns this reviewed plan until the send flow is dismissed.
        guard submission == nil else { return }
        quote = nil; failureMessage = nil; needsRefresh = false; needsAmountChange = false; needsRecipientChange = false
    }
}
