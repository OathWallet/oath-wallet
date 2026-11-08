import Foundation

/// An original failure already submitted at an owning boundary. Carry it through
/// presentation/Result layers without producing unrelated, chainless copies.
/// Do not wrap below retry/domain classification; `underlying` preserves the cause.
public struct ReportedDiagnosticFailure: Error, DiagnosticControlFlowError {
    public let underlying: any Error
    public var isExpectedDiagnosticControlFlow: Bool { true }
    fileprivate init(_ underlying: any Error) { self.underlying = underlying }
}

extension OathDiagnostics {
    /// Records once before creating the propagation marker. Existing markers and
    /// cancellation/deferral keep their identity and behavior unchanged.
    public static func recordedForPropagation(_ error: any Error, component: String? = nil,
        operation: String? = nil, context: [String: String] = [:],
        file: String = #fileID, function: String = #function, line: UInt = #line) -> any Error {
        if isExpectedCancellation(error) || error is DiagnosticDeferral ||
            (error as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow == true { return error }
        record(error, component: component, operation: operation, context: context,
               file: file, function: function, line: line)
        return ReportedDiagnosticFailure(error)
    }
}
