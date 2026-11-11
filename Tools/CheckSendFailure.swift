import Foundation
import OathAnkr

extension CheckMultiWallet {
    static func checkSendFailure() {
        let fallback = OathStringKey.sendLoadFailed
        let marker = "SYNTHETIC_PRIVATE_PROVIDER_MESSAGE"
        let unknown = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: marker])
        let cases: [(any Error, OathStringKey)] = [
            (unknown, fallback),
            (NSError(domain: "GRDB.DatabaseError", code: 1, userInfo: [NSLocalizedDescriptionKey: marker]), .sendLoadFailed),
            (URLError(.notConnectedToInternet), .wcConnectionOfflineTitle),
            (URLError(.timedOut), .wcConnectionRelayTimeoutTitle),
            (URLError(.badServerResponse), .sendInvalidResponse),
            (CancellationError(), .sendReviewChanged),
            (OathWalletError.locked, .wcConnectionLockedTitle),
            (OathWalletError.wrongPasscode, .unlockIncorrect),
            (XrplSendError.rpc(marker), .sendNodeRejected),
            (XrplSendError.rpc("tecFROZEN"), .sendAssetFrozen),
        ]
        for (error, expected) in cases {
            let result = OathSendFailure.reason(error, fallback: fallback)
            precondition(result.key == expected)
            precondition(!(result.code ?? "").contains(marker))
        }
        precondition(OathSendFailure.reason(XrplSendError.rpc(marker), fallback: fallback).code == nil)
        precondition(OathSendFailure.reason(XrplSendError.rpc("tecFROZEN"), fallback: fallback).code == "tecFROZEN")
        precondition(OathSendFailure.canRetryFeeCheck(after: .wcConnectionOfflineTitle))
        precondition(!OathSendFailure.canRetryFeeCheck(after: .sendSigningFailed))
        print("Passed 24 send-failure presentation checks using production mappings and synthetic errors.")
    }
}
