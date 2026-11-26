import Foundation

/// Authentication timing only. Does not change device time or relax server JWT
/// validation. The sample expires on monotonic time and never enters telemetry.
struct HTTPServerClock {
    private var sample: (date: Date, received: ContinuousClock.Instant)?

    mutating func observe(_ response: HTTPURLResponse, request: URLRequest, now: ContinuousClock.Instant = .now) {
        guard let expected = request.url, let actual = response.url,
              expected.scheme == "https", actual.scheme == "https",
              expected.host == actual.host, expected.port == actual.port,
              let value = response.value(forHTTPHeaderField: "Date"), value.utf8.count <= 64,
              let age = Double(response.value(forHTTPHeaderField: "Age") ?? "0"), age == 0 else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value,
              date.timeIntervalSince1970 >= 0, abs(date.timeIntervalSinceNow) <= 86_400 else { return }
        sample = (date, now)
    }

    func date(at now: ContinuousClock.Instant = .now) -> Date? {
        guard let sample else { return nil }
        let elapsed = sample.received.duration(to: now)
        guard elapsed >= .zero, elapsed < .seconds(300) else { return nil }
        let parts = elapsed.components
        return sample.date.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }
}
