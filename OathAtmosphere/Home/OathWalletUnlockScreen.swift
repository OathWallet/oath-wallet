import SwiftUI

/// UIKit owns the protective backdrop and authenticated reveal for both routes.
struct OathWalletUnlockScreen: View {
    let session: OathWalletSession
    let isVisible: Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var digits: [UInt8] = []
    @State private var presentedGreetingVisit: UUID?
    // Retain only the visual completion, never the entered PIN, during reveal.
    @State private var showsAcceptedPasscode = false
    private var biometrics: OathNumericKeypad.Biometrics? {
        guard session.security.biometricsEnabled, !session.biometricRepairNeeded else { return nil }
        switch session.unlockBiometrics {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case nil: return nil
        }
    }

    private var filledPINCount: Int { showsAcceptedPasscode ? 6 : digits.count }
    private var hasPasscodeError: Bool { session.notice == .unlockIncorrect || session.notice == .unlockWait }

    private var activeVisit: UUID? {
        guard isVisible, scenePhase == .active, session.isLocked,
              session.unlockGreeting == nil || presentedGreetingVisit == session.lockVisitID else { return nil }
        return session.lockVisitID
    }

    private var walletColor: String? {
        let selectedID = session.displayedProfile?.id.uuidString
        return session.wallets.first { $0.id == selectedID }?.colorHex ?? session.portfolio?.wallet.colorHex
    }

    var body: some View {
        Group {
            if let greeting = session.unlockGreeting {
                let visit = session.lockVisitID
                OathFaceIDGreeting(title: strings.text(greeting), colorHex: walletColor, isVisible: isVisible) {
                    if session.lockVisitID == visit { presentedGreetingVisit = visit }
                }
                .id(visit)
            } else {
                OathPasscodeEntry(title: strings.text(.unlockPasscodeTitle), filledCount: filledPINCount,
                    isEnabled: !session.busy && scenePhase == .active && isVisible,
                    isDeleteEnabled: !digits.isEmpty, biometrics: biometrics,
                    errorMessage: hasPasscodeError ? session.notice.map { strings.text($0) } : nil,
                    isPresented: isVisible,
                    titleIdentifier: "wallet.unlock.title", pinsIdentifier: "wallet.unlock.dots", onKey: handleKey)
            }
        }
        .accessibilityIdentifier("wallet.unlock")
        .oathDiagnosticsScreen(active: isVisible)
        .alert(strings.text(.unlockWallet), isPresented: Binding(
            get: { session.notice != nil && !hasPasscodeError && scenePhase == .active && isVisible },
            set: { if !$0 && !hasPasscodeError { session.notice = nil } }
        )) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) { session.notice = nil }
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) { session.notice = nil }
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            if let notice = session.notice { Text(strings.text(notice)) }
        }
        .oathErrorFeedback(hasPasscodeError ? nil : session.notice)
        .onChange(of: activeVisit, initial: true) { _, visit in
            guard let visit else { return }
            // The OS prompt may make the scene inactive. Its task belongs to
            // the protected visit and survives that transient phase change.
            Task { await session.attemptAutomaticUnlock(visit: visit, hasPasscodeInput: !digits.isEmpty) }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { resetInput() }
        }
        .onChange(of: session.isLocked) { _, locked in
            if locked { resetInput() }
            else if isVisible { OathHaptics.shared.play(.success) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetInput() }
        }
        .onDisappear { resetInput() }
    }

    private func handleKey(_ key: OathNumericKeypad.Key) {
        guard isVisible, scenePhase == .active, session.isLocked, !session.busy else { return }
        switch key {
        case .digit(let digit):
            guard digits.count < 6 else { return }
            if hasPasscodeError { session.notice = nil }
            session.choseUnlockInput()
            digits.append(UInt8(digit))
            if digits.count == 6 {
                var entry = digits
                Task {
                    await session.unlock(entry)
                    _ = entry.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                    showsAcceptedPasscode = !session.isLocked && isVisible && scenePhase == .active
                    clearDigits()
                }
            }
        case .delete:
            if !digits.isEmpty { digits.removeLast() }
        case .biometrics:
            if hasPasscodeError { session.notice = nil }
            session.choseUnlockInput()
            clearDigits()
            Task { await session.unlockWithBiometrics() }
        }
    }

    private func clearDigits() {
        _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        digits.removeAll()
    }

    private func resetInput() {
        showsAcceptedPasscode = false
        if hasPasscodeError { session.notice = nil }
        clearDigits()
    }
}

private struct OathFaceIDGreeting: View {
    let title: String
    let colorHex: String?
    let isVisible: Bool
    let onPresented: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            OathWalletSymbol(colorHex: colorHex, size: 32)
                .frame(width: 56, height: 56)
                .background(Color(uiColor: OathWalletAccent.color(colorHex)).opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("wallet.unlock.greeting")
        }
        .padding(.horizontal, 24)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .onChange(of: isVisible, initial: true) { _, visible in
            guard visible, !appeared else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.5)) {
                appeared = true
            } completion: {
                onPresented()
            }
        }
    }
}
