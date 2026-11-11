import Foundation

/// Recovery classification for read-only requests.
enum AnkrReadRetry {
    static func indexRateLimitDelay(_ header:String?, now:Date) -> Double? {
        let fallback = Double.random(in:1...2)
        guard let header else { return fallback }
        let value = header.trimmingCharacters(in:.whitespacesAndNewlines)
        let delay:Double
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            delay = seconds
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT:0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from:value) else { return fallback }
            delay = max(0,date.timeIntervalSince(now))
        }
        guard delay <= 10 else { return nil }
        return max(delay,fallback)
    }

    // ANKR gateway failures are distinct from deterministic node rejections.
    // Replay only known reads, unchanged, on the next configured provider.
    // https://www.ankr.com/docs/rpc-service/errors/overview/
    static let gatewayRecoveryCodes: Set<Int> = [
        -32603, -32055, -32056, -32057, -32059, -32061, -32063, -32064,
        -32065, -32071, -32072, -32073, -32076
    ]

    static func transientTransport(_ error: any Error) -> Bool {
        // Compatibility for injected/older transports with no native cause.
        if case AnkrError.transport = error { return true }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
