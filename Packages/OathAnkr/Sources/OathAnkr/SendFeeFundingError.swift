import Foundation
import OathDiagnostics

/// A verified shortage of the native asset needed for fees, separate from the
/// transferred asset, provider failures, and account activation/reserve rules.
/// Contains no account identifiers or provider payloads.
public enum SendFeeFundingError: Error, Sendable, Equatable {
    case insufficientNativeBalance
}

// This is an expected funding prerequisite shown to the user, not an app
// failure. Keep throwing it so quoting/signing stay blocked and the fee-funding
// message survives every boundary. Only this typed outcome is excluded; RPC
// failures, invalid balances, fee caps and untrusted lookalike errors remain
// reportable through their original diagnostics boundaries.
extension SendFeeFundingError: DiagnosticControlFlowError {
    public var isExpectedDiagnosticControlFlow: Bool {
        switch self {
        case .insufficientNativeBalance: true
        }
    }
}

extension SendFeeFundingError {
    static func isEVMFundingMessage(_ message: String?) -> Bool {
        guard let message, message.utf8.count <= 2_048 else { return false }
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["insufficient funds for gas * price + value", "insufficient funds for gas * price + value + gatewayfee",
                "insufficient funds for transfer", "insufficient balance to pay for gas"].contains {
            value == $0 || value.hasPrefix($0 + ":")
        }
    }
}

/// Geth/Nitro cap estimation by both the gas limit and what the sender can
/// afford. The allowance message alone cannot distinguish those two causes.
/// Keep this local quote evidence out of diagnostics and provider messages.
struct EVMGasEstimateFunding: Sendable {
    let nativeBalance: String
    let value: String
    let feePerGas: UInt64
    let gasLimit: UInt64

    func provesShortage(_ message: String?) -> Bool {
        guard let message, message.utf8.count <= 128, feePerGas > 0 else { return false }
        let prefix = "gas required exceeds allowance ("
        guard message.hasPrefix(prefix), message.hasSuffix(")") else { return false }
        let digits = message.dropFirst(prefix.count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let allowance = UInt64(digits), allowance < gasLimit else { return false }
        // Invalid or mismatched evidence does not classify the rejection; the
        // original RPC error still reaches its existing reporting boundary.
        guard let available = try? EVMSendAmount.subtract(nativeBalance, value) else { return false }
        // Prove allowance == floor((balance - call value) / fee cap), without
        // truncating wei to Double or overflowing UInt64 on large balances.
        guard let lower = try? EVMSendAmount.multiply(String(allowance), String(feePerGas)),
              let upper = try? EVMSendAmount.multiply(String(allowance + 1), String(feePerGas)) else { return false }
        return !EVMSendAmount.less(available, lower) && EVMSendAmount.less(available, upper)
    }
}
