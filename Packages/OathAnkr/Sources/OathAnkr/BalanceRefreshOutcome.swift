import Foundation
import OathDiagnostics

/// Completeness is independent of the refresh control's presentation lifetime.
public enum BalanceRefreshError: Error, Equatable, Sendable {
    case incomplete
    case observationEnded
}

public enum BalanceRefreshOutcome: Sendable {
    case complete
    case partial(any Error)
    case failed(any Error)
    case cancelled

    public init(_ result: Result<Void, any Error>) {
        switch result {
        case .success: self = .complete
        case .failure(let error):
            let cause = (error as? ReportedDiagnosticFailure)?.underlying ?? error
            if cause is CancellationError { self = .cancelled }
            else if cause as? BalanceRefreshError == .incomplete { self = .partial(error) }
            else { self = .failed(error) }
        }
    }

    public func get() throws {
        switch self {
        case .complete: return
        case .partial(let error), .failed(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }
}
