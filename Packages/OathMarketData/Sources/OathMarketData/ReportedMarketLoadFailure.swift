import Foundation
import OathDiagnostics

/// Only load may create this marker: its original failure was already recorded,
/// or this consumer read the cooldown for that same failure. Classification uses
/// the underlying cause; presentation reporting ignores the already-owned copy.
struct ReportedMarketLoadFailure: Error, DiagnosticControlFlowError {
    let underlying: any Error
    var isExpectedDiagnosticControlFlow: Bool { true }
    private init(_ error: any Error) { underlying = error }

    static func cause(_ error: any Error) -> any Error {
        (error as? Self)?.underlying ?? error
    }

    static func mark(_ error: any Error) -> any Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled ||
            error is DiagnosticDeferral || error as? MarketDataError == .notListed ||
            (error as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow == true { return error }
        return Self(error)
    }
}
