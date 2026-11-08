import Foundation

/// Same-endpoint READ retries only. Never applies to broadcasts or relaxes TLS.
enum AnkrReadRetry {
    static func transientTransport(_ error: any Error) -> Bool {
        // Compatibility for injected/older transports with no native cause.
        if case AnkrError.transport = error { return true }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
