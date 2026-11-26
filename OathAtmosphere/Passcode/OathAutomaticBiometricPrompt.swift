import Foundation

/// One automatic attempt per foreground visit. Local Authentication can make
/// the scene inactive itself, so only a real background transition rearms it.
struct OathAutomaticBiometricPrompt {
    private var attempted = false

    mutating func claim(isActive: Bool, isBusy: Bool, canUseBiometrics: Bool,
                        hasPasscodeInput: Bool, hasNotice: Bool) -> Bool {
        guard !attempted, isActive, !isBusy, canUseBiometrics,
              !hasPasscodeInput, !hasNotice else { return false }
        attempted = true
        return true
    }

    mutating func userChoseAuthentication() { attempted = true }
    mutating func didEnterBackground() { attempted = false }
}

enum OathUnlockGreetings {
    static let phrases: [OathStringKey] = [
        .greetingOhHey, .greetingWellHello, .greetingLookWhosBack, .greetingThereYouAre,
        .greetingFancySeeingYou, .greetingWhereWereWe, .greetingWhatsTheMove, .greetingReadyWhenYouAre,
        .greetingShallWe, .greetingGoodTiming, .greetingLetsRoll, .greetingRightThisWay
    ]

    static func next(in defaults: UserDefaults = .standard) -> OathStringKey {
        let key = "oath.lastUnlockGreeting"
        let last = defaults.string(forKey: key)
        let next = phrases.filter { $0.rawValue != last }.randomElement() ?? .greetingOhHey
        defaults.set(next.rawValue, forKey: key)
        return next
    }
}
