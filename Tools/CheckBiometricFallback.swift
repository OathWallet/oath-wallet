import Foundation
import OathDatabase
import Security

@MainActor private final class BiometricHardwareProbe {
    var kind: OathBiometricKind? = .faceID
}

private final class BiometricRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidations = 0
    private var reads = 0
    let release = DispatchSemaphore(value: 0)
    var invalidationCount: Int { lock.withLock { invalidations } }
    var readCount: Int { lock.withLock { reads } }
    func invalidate() { lock.withLock { invalidations += 1 } }
    func read() -> Data {
        lock.withLock { reads += 1 }
        _ = release.wait(timeout: .now() + 2)
        return Data([1, 2, 3]) // Synthetic credential, never wallet material.
    }
}

private final class BiometricCleanupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var finished = false
    let release = DispatchSemaphore(value: 0)
    var isEntered: Bool { lock.withLock { entered } }
    var isFinished: Bool { lock.withLock { finished } }
    func invalidate() {
        lock.withLock { entered = true }
        _ = release.wait(timeout: .now() + 3)
        lock.withLock { finished = true }
    }
}

extension CheckMultiWallet {
    @MainActor static func checkBiometricFallback() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        check(OathBiometricCredentialError.keychain(errSecAuthFailed).isExpectedAuthenticationOutcome, "Rejected biometrics are expected PIN fallback")
        check(!OathBiometricCredentialError.invalid.isExpectedAuthenticationOutcome, "Corrupt protected credentials remain reportable")
        check(!OathBiometricCredentialError.keychain(errSecDecode).isExpectedAuthenticationOutcome, "Unexpected Keychain failures remain reportable")
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<1_000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            preconditionFailure("Authentication fixture timed out")
        }
        // The production bridge must resume before a blocked OS read returns.
        let stalled = BiometricRequestProbe()
        let timeout = OathBiometricRequest(invalidate: { stalled.invalidate() })
        do {
            _ = try await timeout.read(timeout: 0.05) { stalled.read() }
            preconditionFailure("A stalled biometric request accepted a late success")
        } catch {
            check(error as? OathBiometricCredentialError == .unavailable, "Timeout routes to passcode fallback")
        }
        check(stalled.invalidationCount == 1, "Timeout invalidates the OS context before returning")
        stalled.release.signal()
        try await Task.sleep(for: .milliseconds(30))
        check(stalled.invalidationCount == 1, "Late OS success cannot finish the timed-out request again")

        let lateMatch = BiometricRequestProbe()
        let awaitingFace = OathBiometricRequest(invalidate: { lateMatch.invalidate() })
        do {
            _ = try await awaitingFace.read(timeout: 0.03, authorize: { reply in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { reply(nil) }
            }) { lateMatch.read() }
            preconditionFailure("A stalled face match opened the credential")
        } catch {
            check(error as? OathBiometricCredentialError == .unavailable, "The deadline covers the system prompt too")
        }
        try await Task.sleep(for: .milliseconds(150))
        check(lateMatch.readCount == 0 && lateMatch.invalidationCount == 1,
              "A late match cannot start a protected read after fallback")
        let rejected = BiometricRequestProbe()
        let denied = OathBiometricRequest(invalidate: { rejected.invalidate() })
        do {
            _ = try await denied.read(authorize: { $0(OathBiometricCredentialError.cancelled) }) { rejected.read() }
            preconditionFailure("A cancelled face match opened the credential")
        } catch {
            check(error as? OathBiometricCredentialError == .cancelled && rejected.readCount == 0,
                  "A cancelled system prompt skips the Keychain read")
        }

        let cancelled = BiometricRequestProbe()
        let cancelling = OathBiometricRequest(invalidate: { cancelled.invalidate() })
        let task = Task { try await cancelling.read { cancelled.read() } }
        try await wait { cancelled.readCount == 1 }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Canceled read returned a credential") }
        catch { check(error is CancellationError, "Leaving the flow cancels rather than opening a passcode page") }
        check(cancelled.invalidationCount == 1, "Task cancellation invalidates its exact OS context")
        cancelled.release.signal()

        let early = BiometricRequestProbe()
        let earlyRequest = OathBiometricRequest(invalidate: { early.invalidate() })
        let earlyTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await earlyRequest.read { early.read() }
        }
        do { _ = try await earlyTask.value; preconditionFailure("Already canceled read returned a credential") }
        catch { check(error is CancellationError, "Cancellation before registration is not lost") }
        check(early.readCount == 0 && early.invalidationCount == 1, "Already canceled requests never prompt")

        let success = BiometricRequestProbe()
        success.release.signal()
        let successfulRequest = OathBiometricRequest(invalidate: { success.invalidate() })
        let result = try await successfulRequest.read(timeout: 0.05) { success.read() }
        check(result == Data([1, 2, 3]), "Successful protected read returns its credential")
        try await Task.sleep(for: .milliseconds(80))
        check(success.invalidationCount == 1, "Deadline cannot replace completed authentication")

        // Reproduce slow Face ID/context teardown independently of any UI.
        // Success must reach the caller while cleanup is deliberately stalled.
        let cleanup = BiometricCleanupProbe()
        let prompt = OathBiometricRequest(invalidate: { cleanup.invalidate() })
        let delivered = try await prompt.read { Data([4, 5, 6]) }
        check(delivered == Data([4, 5, 6]) && !cleanup.isFinished,
              "Successful credential delivery must not wait for Face ID cleanup")
        try await wait { cleanup.isEntered }
        cleanup.release.signal()
        try await wait { cleanup.isFinished }

        var privacy = OathScenePrivacyPolicy()
        privacy.transition(to: .active, authenticating: false)
        check(!privacy.needsCover, "Active app has no privacy input cover")
        privacy.transition(to: .inactive, authenticating: true)
        check(!privacy.needsCover, "Our Face ID prompt does not install an app-wide input cover")
        privacy.biometricPresentationChanged(isPresenting: false)
        check(!privacy.needsCover, "Completed authentication stays uncovered during system dismissal")
        privacy.transition(to: .background, authenticating: true)
        check(privacy.needsCover, "Backgrounding during Face ID always protects the snapshot")
        privacy.biometricPresentationChanged(isPresenting: false)
        check(privacy.needsCover, "A late biometric reply never removes the background cover")
        privacy.biometricPresentationChanged(isPresenting: true)
        check(privacy.needsCover, "Even a late begin callback cannot uncover the background")
        privacy.transition(to: .inactive, authenticating: false)
        check(privacy.needsCover, "Returning from background stays covered until active")
        privacy.transition(to: .active, authenticating: false)
        privacy.transition(to: .inactive, authenticating: false)
        check(privacy.needsCover, "The next unrelated interruption is still covered")

        let presentation = OathBiometricPresentation()
        let otherScene = OathBiometricPresentation()
        var presentationEvents = 0
        let observer = NotificationCenter.default.addObserver(forName: OathBiometricPresentation.didChange,
            object: presentation, queue: .main) { _ in
            MainActor.assumeIsolated { presentationEvents += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let unrelatedPrompt = otherScene.begin()
        otherScene.end(unrelatedPrompt)
        check(presentationEvents == 0, "Another scene's prompt cannot change this scene's privacy cover")
        let firstPrompt = presentation.begin()
        check(presentationEvents == 1, "Presentation observers run synchronously before authentication starts")
        let secondPrompt = presentation.begin()
        presentation.end(firstPrompt)
        check(presentation.isPresenting, "Finishing one request cannot clear another request's presentation")
        presentation.end(firstPrompt)
        check(presentation.isPresenting, "Duplicate completion cannot clear the remaining prompt")
        presentation.end(secondPrompt)
        check(!presentation.isPresenting, "Finishing the last prompt releases presentation bookkeeping")
        check(presentationEvents == 4, "Only real begin/end transitions notify the owning scene")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathFallback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [1, 6, 9, 2, 8, 4]
        try await vault.create(digits: pin, importing: .init(phrase: "synthetic fallback fixture", language: "english"))
        await biometrics.enroll(try await vault.biometricCredential())
        await biometrics.allowEnrollment()
        let hardware = BiometricHardwareProbe()
        let session = OathWalletSession(vault: vault, availableUnlockBiometrics: { hardware.kind })
        await session.finishedSetup()
        let root = session.displayedProfile!.id.uuidString
        session.finishInitialCustomization()
        let access = OathSecurityAccessModel(session: session)
        let recovery = OathRecoveryPhraseModel(walletID: root, reader: vault)
        let privateKey = OathPrivateKeyModel(walletID: root, reader: vault)
        await privateKey.load()
        let account = privateKey.accounts.first!
        let removal = OathWalletRemovalModel(session: session)
        let reset = OathResetModel(session: session)
        let action = OathWalletRemovalAction(ids: [root], permanently: false)
        // The existing last-wallet policy binds a full reset before requesting
        // authentication. Fallback must preserve that normalized authorization.
        let boundRemoval = OathWalletRemovalAction(ids: [root], permanently: false, resetsApp: true)
        reset.begin(reason: "Synthetic successful reset authorization")
        try await wait { !reset.busy }
        check(reset.phase == .warning && !reset.confirming && session.wallets.count == 1,
              "Successful Face ID advances directly to reset confirmation without erasing a wallet")
        reset.cancel()
        await session.lock()
        check(session.unlockGreeting == nil, "Manual lock opens the keypad")
        await session.unlockWithBiometrics()
        check(session.isUnlocked && !session.busy && !session.animatesUnlock,
              "Successful Face ID opens the app without an activation callback or second lock animation")

        let departure = ContinuousClock.now
        session.enteredBackground(delay: .oneMinute, now: departure)
        session.enteringForeground(now: departure.advanced(by: .seconds(30)))
        check(session.isUnlocked, "Returning within the grace period resumes the existing screen")
        session.enteredBackground(delay: .oneMinute, now: departure)
        session.enteringForeground(now: departure.advanced(by: .seconds(61)))
        let visit = session.lockVisitID
        let phrase = session.unlockGreeting
        check(session.isLocked && phrase != nil, "Expired grace selects the Face ID greeting before input")
        await biometrics.pauseNextRead()
        let pending = Task { await session.attemptAutomaticUnlock(visit: visit, hasPasscodeInput: false) }
        for _ in 0..<1_000 where !(await biometrics.isWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "A visible protected visit starts the credential read")
        let reads = await biometrics.reads
        await session.attemptAutomaticUnlock(visit: visit, hasPasscodeInput: false)
        check(await biometrics.reads == reads && session.unlockGreeting == phrase,
              "Repeated presentations share the pending read and greeting")
        session.enteredBackground(delay: .immediately)
        await biometrics.releaseRead()
        await pending.value
        check(session.isLocked, "Leaving during a read rejects a late match")
        session.enteringForeground()
        check(session.lockVisitID != visit && session.unlockGreeting != nil && session.unlockGreeting != phrase,
              "A new foreground visit gets a different greeting")
        await session.attemptAutomaticUnlock(visit: visit, hasPasscodeInput: false)
        check(await biometrics.reads == reads, "A previous view cannot start a new visit's authentication")
        await session.attemptAutomaticUnlock(visit: session.lockVisitID, hasPasscodeInput: false)
        check(session.isUnlocked && session.animatesUnlock && session.unlockGreeting != nil,
              "The authenticated greeting stays mounted for the native dissolve")
        check(await biometrics.lastReadRequiredFreshMatch, "Automatic Face ID requires a fresh foreground match")

        await session.lock(reason: .automatic)
        await biometrics.failNextRead(.keychain(errSecAuthFailed))
        await session.attemptAutomaticUnlock(visit: session.lockVisitID, hasPasscodeInput: false)
        check(session.isLocked && session.unlockGreeting == nil && !session.busy, "A mismatch shows the fallback PIN")
        let failedReads = await biometrics.reads
        await session.attemptAutomaticUnlock(visit: session.lockVisitID, hasPasscodeInput: false)
        check(await biometrics.reads == failedReads, "The PIN fallback survives view reconstruction without reprompting")
        await session.unlock(pin)

        hardware.kind = nil
        await session.lock(reason: .automatic)
        check(session.unlockGreeting == nil && session.unlockBiometrics == nil, "Unavailable hardware uses the keypad immediately")
        await session.unlock(pin)
        hardware.kind = .touchID
        await session.lock(reason: .automatic)
        check(session.unlockGreeting == nil && session.unlockBiometrics == .touchID, "Touch ID retains its keypad")
        await session.attemptAutomaticUnlock(visit: session.lockVisitID, hasPasscodeInput: false)
        check(session.isUnlocked && !session.animatesUnlock, "Touch ID can still unlock automatically")
        check(!(await biometrics.lastReadRequiredFreshMatch), "Touch ID retains its existing protected-item interaction")
        hardware.kind = .faceID
        let failures: [OathBiometricCredentialError] = [.cancelled, .unavailable, .missing, .invalid,
            .keychain(errSecAuthFailed), .keychain(errSecInteractionNotAllowed), .keychain(errSecNotAvailable)]

        for failure in failures {
            await biometrics.failNextRead(failure)
            access.begin(reason: "Synthetic Security access")
            try await wait { !access.busy }
            check(access.phase == .passcode && !access.isAuthorized && access.notice == nil,
                  "Every biometric error offers a passcode before Security access")
            access.submit(pin); try await wait { !access.busy }
            check(access.isAuthorized, "Correct fallback PIN resumes Security access")
            access.cancel()

            await biometrics.failNextRead(failure)
            recovery.acknowledge(reason: "Synthetic recovery access")
            try await wait { !recovery.busy }
            check(recovery.phase == .passcode && recovery.words.isEmpty && recovery.notice == nil,
                  "Every biometric error keeps recovery material hidden until the PIN")
            recovery.submit(pin); try await wait { !recovery.busy }
            check(recovery.phase == .revealed, "Correct fallback PIN resumes recovery disclosure")
            recovery.returnToWarning()

            await biometrics.failNextRead(failure)
            privateKey.select(account, reason: "Synthetic key access")
            try await wait { !privateKey.busy }
            check(privateKey.phase == .passcode && privateKey.key == nil && privateKey.selected == account,
                  "Every biometric error preserves the chosen account and keeps its key hidden")
            privateKey.submit(pin); try await wait { !privateKey.busy }
            check(privateKey.phase == .warning && privateKey.key == nil, "Fallback PIN still requires the export warning")
            privateKey.returnToChains()

            await biometrics.failNextRead(failure)
            removal.begin(action, reason: "Synthetic removal")
            try await wait { !removal.busy }
            check(removal.phase == .passcode && removal.action == boundRemoval, "Every biometric error preserves the requested removal and last-wallet reset binding")
            removal.submit(pin); try await wait { !removal.busy }
            check(removal.phase == .confirmation && session.wallets.count == 1,
                  "Fallback PIN shows removal confirmation without removing the wallet")
            removal.cancel()

            await biometrics.failNextRead(failure)
            reset.begin(reason: "Synthetic reset")
            try await wait { !reset.busy }
            check(reset.phase == .passcode, "Every biometric error offers the PIN before reset")
            reset.submit(pin); try await wait { !reset.busy }
            check(reset.phase == .warning && session.wallets.count == 1, "Fallback PIN opens reset warning without erasing anything")
            reset.cancel()

            await session.lock()
            let unlockReads = await biometrics.reads
            await biometrics.failNextRead(failure)
            await session.unlockWithBiometrics()
            check(await biometrics.reads == unlockReads + 1, "Each unlock fixture exercises an actual biometric attempt")
            check(session.isLocked && !session.busy && session.notice == nil,
                  "Failed app unlock leaves a usable passcode screen without a blocking alert")
            await session.unlock(pin)
            check(session.isUnlocked && session.animatesUnlock, "Fallback PIN keeps its ordinary native reveal")
        }

        // A flow canceled by navigation must never reopen from a delayed reply.
        await biometrics.pauseNextRead()
        removal.begin(action, reason: "Synthetic late removal")
        for _ in 0..<1_000 where !(await biometrics.isWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "Removal has a pending biometric request")
        removal.cancel()
        await biometrics.releaseRead()
        try await Task.sleep(for: .milliseconds(30))
        check(removal.phase == .idle && removal.action == nil && !removal.busy,
              "Leaving removal ignores a late biometric reply and does not open passcode")
        check(try await db.pendingWalletReset() == nil && session.wallets.count == 1,
              "Fallback checks never reset or delete a wallet")
        return checks
    }
}
