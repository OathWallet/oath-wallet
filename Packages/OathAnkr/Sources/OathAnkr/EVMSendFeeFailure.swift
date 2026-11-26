import OathDiagnostics

/// Public, bounded reasons. No transaction fields or provider text enter the UI
/// or diagnostics. In particular, an inadequate fee is not an excessive fee.
public enum EVMSendFeeFailure: Int, Error, Sendable, Equatable, DiagnosticErrorProviding {
    case feeCapTooLow = 1
    case gasLimitTooLow
    case gasLimitTooHigh
    case feeLimitExceeded
    case invalidEstimate

    /// Classify only recognized fee failures, after the original provider error
    /// has been reported. Arbitrary provider text is never displayed to users.
    static func rpcReason(_ message: String?) -> Self? {
        guard let message else { return nil }
        let text = message.prefix(1_024).lowercased()
        if text.contains("max fee per gas less than block base fee") ||
            text.contains("maxfeepergas cannot be less than the block base fee") ||
            text.contains("transaction underpriced") || text.contains("gas price below minimum") {
            return .feeCapTooLow
        }
        if text.contains("intrinsic gas too low") {
            return .gasLimitTooLow
        }
        // "gas required exceeds allowance" is ambiguous: the node can cap
        // allowance by the account balance as well as by the supplied gas.
        // Keep that provider rejection instead of inventing a funding reason.
        return nil
    }

    public var diagnosticCode: Int { rawValue }
    public var diagnosticMessage: String {
        switch self {
        case .feeCapTooLow: "Fee cap below network requirement"
        case .gasLimitTooLow: "Gas limit below execution requirement"
        case .gasLimitTooHigh: "Gas limit exceeds supported safety limit"
        case .feeLimitExceeded: "Fee exceeds supported safety limit"
        case .invalidEstimate: "Invalid network fee estimate"
        }
    }
}
