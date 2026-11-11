import OathDiagnostics
import SwiftUI
import OathDatabase

/// An in-memory preview until saving atomically commits this wallet's metadata.
/// Navigation and keyboard avoidance use native controls.
struct OathWalletCustomizationScreen: View {
    enum Mode: Equatable { case setup, edit, create(UUID) }

    let session: OathWalletSession
    let walletID: String
    let mode: Mode
    let onSaved: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @State private var preparation = OathWalletCreationPreparation()
    @State private var editedCreationName = false
    @State private var name = ""
    @State private var initialDefaultName: String?
    @State private var colorHex: String?
    @State private var initialized = false
    @State private var focused = false
    @State private var submitting = false
    @State private var failed = false
    @State private var work: Task<Void, Never>?

    private static let swatches: [String?] = [nil, "8B36C9", "288CBC", "126BB5", "12989C", "209750", "DF438D", "EE741B", "BC2835", "656977"]
    private var wallet: WalletRecord? { session.wallets.first { $0.id == walletID } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameIsValid: Bool { trimmedName.isEmpty || WalletRecord.isValidName(trimmedName) }
    private var creating: Bool {
        if case .create = mode { return true }
        return false
    }
    private var readyToEdit: Bool { creating || (initialized && wallet != nil) }
    private var canSave: Bool {
        readyToEdit && session.isUnlocked && (creating || !session.changingWallet) && !submitting && nameIsValid
    }
    private var editableName: Binding<String> {
        Binding(get: { name }, set: { value in
            if creating { editedCreationName = true }
            name = value
        })
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 24)
                    HStack(spacing: 0) {
                        OathTextInput(text: editableName, focused: $focused,
                                      title: strings.text(creating && !initialized ? .mainWalletName : .walletName),
                                      identifier: "walletCustomize.name", prominent: true)
                        if !name.isEmpty {
                            Button {
                                editableName.wrappedValue = ""
                                focused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(.white.opacity(0.78))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(strings.text(.clear))
                            .accessibilityIdentifier("walletCustomize.name.clear")
                        }
                    }
                    .disabled(submitting)
                    .padding(.horizontal, 24)
                    colorChoices
                    saveButton
                        .accessibilityIdentifier("walletCustomize.apply")
                        .oathActionArea()
                    if readyToEdit && !nameIsValid {
                        Text(strings.text(.walletNameHint))
                            .oathFont(.footnote).foregroundStyle(.white)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                    if failed || preparation.failed {
                        Text(strings.text(preparation.failed ? .walletChangeFailed : .walletCustomizeFailed))
                            .oathFont(.footnote).foregroundStyle(.white)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                            .accessibilityIdentifier("walletCustomize.error")
                    }
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height))
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background {
            GeometryReader { geometry in
                OathBackground(placement: .walletBackdrop(size: geometry.size),
                               animates: session.isUnlocked, customColor: colorHex.flatMap { UInt32($0, radix: 16) })
                // The shared shader supplies the same readable material as
                // Home, so this preview matches the saved wallet's appearance.
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .toolbar {
            if preparation.failed {
                ToolbarItem(placement: .topBarLeading) { OathCloseButton { dismiss() } }
            }
        }
        .task(id: session.isUnlocked) {
            if session.isUnlocked { _ = startCreation() }
            else { preparation.cancel() }
        }
        .task(id: wallet?.id) {
            guard !initialized, let wallet else { return }
            let displayName = session.walletName(wallet, strings: strings)
            initialDefaultName = wallet.name.isEmpty ? displayName : nil
            if !creating || !editedCreationName { name = displayName }
            if !creating { colorHex = wallet.colorHex }
            initialized = true
        }
        .oathAutofocus(when: readyToEdit && session.isUnlocked && !submitting) {
            focused = true
        }
        .onDisappear {
            preparation.cancel()
            work?.cancel()
            work = nil
            focused = false
            submitting = false
        }
        .oathLanguage(strings.language)
    }

    private var colorChoices: some View {
        let rtl = strings.language.isRightToLeft
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(0..<Self.swatches.count, id: \.self) { index in
                        let hex = Self.swatches[index]
                        OathButton(feedback: .selection) { colorHex = hex } label: {
                            Circle().fill(color(for: hex))
                                .overlay(Circle().strokeBorder(.white.opacity(colorHex == hex ? 0.9 : 0.25), lineWidth: colorHex == hex ? 2 : 1))
                                .overlay {
                                    if colorHex == hex { Image(systemName: "checkmark").font(.system(size: 20, weight: .medium)).foregroundStyle(.white) }
                                }
                                .frame(width: 44, height: 44)
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel(hex.map { strings.format(.walletColorValue, $0) } ?? strings.text(.walletDefaultColor))
                        .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
                        .accessibilityIdentifier("walletCustomize.color.\(hex ?? "default")")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: readyToEdit ? rtl : nil, initial: true) { _, _ in
                guard readyToEdit, let index = Self.swatches.firstIndex(of: colorHex) else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
        .accessibilityLabel(strings.text(.walletColor))
        .disabled(submitting)
    }

    private func color(for hex: String?) -> Color {
        let rgb = hex.flatMap { UInt32($0, radix: 16) } ?? 0x244DE0
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }

    private var saveButton: some View {
        OathActionButton(title: strings.text(mode == .edit ? .apply : .continueAction),
                         accent: .black, isWorking: submitting) {
            guard canSave else { return }
            failed = false
            focused = false
            submitting = true
            commit()
        }
        .disabled(!canSave)
    }

    private func startCreation() -> Task<Bool, Never>? {
        guard case .create(let request) = mode, session.isUnlocked else { return nil }
        return preparation.start {
            if session.displayedProfile?.id == request, wallet != nil, !session.changingWallet { return }
            _ = try await session.addWallet(requestID: request)
        }
    }

    private func commit() {
        guard submitting, work == nil, session.isUnlocked else { return }
        let savedName = trimmedName, savedColor = colorHex
        let keepDefaultName = savedName == initialDefaultName
        work = Task {
            defer { work = nil; submitting = false }
            do {
                if let pending = startCreation(), !(await pending.value) { return }
                try Task.checkCancellation()
                try await session.customizeWallet(walletID, name: savedName, colorHex: savedColor, keepDefaultName: keepDefaultName, strings: strings)
                guard !Task.isCancelled, session.isUnlocked else { return }
                onSaved()
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled { failed = true } }
        }
    }
}

extension View {
    /// The same native navigation treatment for setup, additional wallets, and
    /// the editor in Settings. App appearance itself remains unchanged.
    func oathWalletCustomizationNavigation() -> some View {
        modifier(OathWalletCustomizationNavigation())
    }
}

private struct OathWalletCustomizationNavigation: ViewModifier {
    @Environment(\.oathLocalizer) private var strings
    func body(content: Content) -> some View {
        content
            .navigationTitle(strings.text(.customizeWallet))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .oathNativeLocalization(navigationTint: .white, onArtwork: true, navigationBackground: .hidden)
    }
}
