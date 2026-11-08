import Foundation

/// Anonymous TonAPI quotas belong to the app's network connection, not an
/// individual wallet/client. Keep this shared across discovery and history.
actor TonIndexRequests {
    static let shared = TonIndexRequests(spacing: .milliseconds(4_200))
    let permits = AnkrPermits(count: 1)
    private let spacing: Duration
    private let cooldownDuration: Duration
    private var nextStart: ContinuousClock.Instant = .now
    private var cooldown: ContinuousClock.Instant?

    init(spacing: Duration = .zero, cooldown: Duration = .seconds(60)) {
        self.spacing = spacing
        self.cooldownDuration = cooldown
    }

    func reserve() async throws {
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            if let cooldown, now < cooldown { throw TonError.indexCooldown }
            if now >= nextStart {
                nextStart = now.advanced(by: spacing)
                return
            }
            try await Task.sleep(for: now.duration(to: nextStart))
        }
    }

    func rateLimited() {
        cooldown = .now.advanced(by: cooldownDuration)
    }
}
