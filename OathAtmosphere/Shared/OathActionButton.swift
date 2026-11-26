import SwiftUI

enum OathActionAppearance { case primary, secondary, destructiveSecondary, wallet, text }

/// Generic toolbar confirmations are native checkmarks. Step navigation, wallet
/// imports and financial submissions keep explicit labels so their actions stay clear.
enum OathToolbarActionKind { case confirmation, navigation, walletImport, transaction }

/// Full-width shared action, matching Welcome. Place in oathBottomActions,
/// not a bottom toolbar: screen actions need the extra-large button treatment.
/// Keep the same activation guards as consent/signing toolbar actions.
struct OathBottomAction: View {
    let title: String
    let identifier: String
    var role: ButtonRole? = nil
    var appearance: OathActionAppearance = .primary
    var isEnabled = true
    var isWorking = false
    var isInteractionBlocked = false
    var tint: Color = OathOnboardingColors.blue
    let action: () -> Void
    @Environment(\.isEnabled) private var parentIsEnabled
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OathActionButton(title: title, appearance: appearance, role: role, accent: tint,
                         isWorking: isWorking, isInteractionBlocked: isInteractionBlocked) {
            guard parentIsEnabled, isEnabled, !isWorking, !isInteractionBlocked,
                  scenePhase != .background else { return }
            action()
        }
        .disabled(!isEnabled || isWorking)
        .accessibilityIdentifier(identifier)
    }
}

/// Neutral dismissal, independent of the presenting screen's accent color.
/// The native toolbar owns the glass treatment and the hit target.
struct OathCloseButton: View {
    @Environment(\.oathLocalizer) private var strings
    var systemImage = "xmark"
    var feedback: OathHapticEvent? = .dismiss
    let action: @MainActor () -> Void

    var body: some View {
        OathButton(feedback: feedback, action: action) {
            Label(strings.text(.close), systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .oathNeutralControl()
        .accessibilityLabel(strings.text(.close))
    }
}

/// Keep progress inside the native toolbar's neutral glass. The navigation bar
/// owns its background and sizing; only the ready action uses prominent blue.
struct OathToolbarAction: ToolbarContent {
    var title: OathStringKey = .continueAction
    var icon: String? = nil
    var kind: OathToolbarActionKind = .confirmation
    var progressLabel: OathStringKey = .sendPreparing
    let isEnabled: Bool
    let isWorking: Bool
    let identifier: String
    let action: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            item.sharedBackgroundVisibility(isWorking ? .visible : .automatic)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if isWorking {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                    .tint(.secondary)
                    .accessibilityLabel(strings.text(progressLabel))
                    .accessibilityIdentifier(identifier)
            } else {
                readyButton
            }
        }
    }

    private var readyButton: some View {
        OathToolbarButton(title: title, icon: icon, isEnabled: isEnabled && !isWorking,
                          showsCheckmark: kind == .confirmation, action: action)
            .accessibilityIdentifier(identifier)
    }
}

/// One button implementation for toolbar actions, including inherited disabled
/// state. Preserve the native confirmation role even while disabled; validation
/// must not switch a checkmark back to a text button or change its identity.
private struct OathToolbarButton: View {
    let title: OathStringKey
    var icon: String? = nil
    var isEnabled = true
    var showsCheckmark = false
    var role: ButtonRole? = nil
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var parentIsEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.oathLocalizer) private var strings

    private var canActivate: Bool { isEnabled && parentIsEnabled && scenePhase != .background }

    var body: some View {
        Group {
            if showsCheckmark && role != .destructive {
                if #available(iOS 26.0, *) {
                    OathButton(role: .confirm) {
                        guard canActivate else { return }
                        action()
                    }
                        .labelStyle(.iconOnly)
                } else {
                    regularButton
                }
            } else {
                regularButton
            }
        }
        .oathToolbarActionStyle(role: role)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.text(title))
    }

    private var regularButton: some View {
        OathButton(role: role) {
            guard canActivate else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                if showsCheckmark && role != .destructive {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                } else {
                    if let icon { Image(systemName: icon).accessibilityHidden(true) }
                    Text(strings.text(title))
                        .oathFont(.body, weight: .medium)
                }
            }
        }
    }
}

/// Screen and sheet confirmations always use the system checkmark in app blue.
/// The localized action is retained for VoiceOver, never as a visible Done/Apply
/// label. Destructive actions retain their explicit label and red treatment.
struct OathDoneButton: View {
    var label: OathStringKey = .done
    var role: ButtonRole? = nil
    let action: @MainActor () -> Void

    var body: some View {
        OathToolbarButton(title: label, showsCheckmark: true, role: role, action: action)
    }
}

/// Shared welcome-screen actions. The style owns the surface and content insets;
/// labels remain free to grow for localization and accessibility text sizes.
struct OathActionButton: View {
    static let successAccent = Color(red: 0.07, green: 0.45, blue: 0.28)

    let title: String
    var icon: String? = nil
    var appearance: OathActionAppearance = .primary
    var role: ButtonRole? = nil
    var accent: Color? = nil
    var foreground: Color? = nil
    var isWorking = false
    var isInteractionBlocked = false
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    private var actionAccent: Color? { role == .destructive ? .red : accent }
    private var actionForeground: Color? {
        if appearance == .destructiveSecondary || appearance == .wallet { return foreground ?? .white }
        return role == .destructive && appearance != .primary ? .red : foreground
    }

    var body: some View {
        OathButton(role: role, feedback: nil) {
            guard scenePhase != .background, !isInteractionBlocked else { return }
            OathHaptics.shared.perform(role == .destructive ? .warning : .tap, action: action)
        } label: {
            OathActionLabel(title: title, icon: icon, isWorking: isWorking,
                            progressColor: actionForeground ?? (appearance == .primary ? .white : .primary))
        }
        .oathActionStyle(appearance, accent: actionAccent, foreground: actionForeground)
        .oathInteractionBlocked(isInteractionBlocked)
    }
}

/// The monochrome surface shared by Home and Asset Detail.
private struct OathWalletActionStyle: ButtonStyle {
    let foreground: Color
    let borderShape: ButtonBorderShape
    let controlSize: ControlSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: LinearGradient {
        if colorScheme == .dark {
            LinearGradient(stops: [
                .init(color: Color(white: 0x3F / 255.0), location: 0),
                .init(color: Color(white: 0x32 / 255.0), location: 0.26),
                .init(color: Color(white: 0x2A / 255.0), location: 0.5),
                .init(color: Color(white: 0x25 / 255.0), location: 0.85)
            ], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: [Color(white: 0x2A / 255.0), Color(white: 0x11 / 255.0)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var border: LinearGradient {
        if colorScheme == .dark {
            // The rim lets the charcoal show through between its two highlights.
            let highlight = Color.white.opacity(0.165)
            return LinearGradient(colors: [highlight, .white.opacity(0), highlight],
                                  startPoint: UnitPoint(x: 0.475, y: -0.04),
                                  endPoint: UnitPoint(x: 0.525, y: 0.98))
        }
        return LinearGradient(colors: [Color(white: 0x4E / 255.0), Color(white: 0x39 / 255.0)],
                              startPoint: .top, endPoint: .bottom)
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        configuration.label
            .foregroundStyle(foreground)
            .oathActionDimensions(controlSize)
            .background {
                borderShape.fill(fill)
                    .overlay { borderShape.strokeBorder(border, lineWidth: 2) }
                    .overlay { borderShape.fill(.black.opacity(pressed ? 0.12 : 0)) }
            }
            .contentShape(borderShape)
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pressed)
    }
}

/// UIKit owns event delivery while system UI is present. Do not add another
/// interaction lock during Face ID's foreground-inactive dismissal. Actual
/// authentication/committed work still blocks through `blocked` or .disabled.
private struct OathInteractionBlock: ViewModifier {
    let blocked: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let allowsInteraction = !blocked && scenePhase != .background
        content
            .allowsHitTesting(allowsInteraction)
            .accessibilityRespondsToUserInteraction(allowsInteraction)
    }
}

/// Shared text, icon and progress content without extra per-screen padding.
struct OathActionLabel: View {
    let title: String
    var icon: String? = nil
    var isWorking = false
    var progressColor: Color = .white
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: OathActionMetrics.labelSpacing) {
            if isWorking {
                ProgressView().controlSize(.small)
                    .tint(isEnabled ? progressColor : Color(uiColor: .secondaryLabel))
            }
            else if let icon { Image(systemName: icon).accessibilityHidden(true) }
            Text(title)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    func oathActionDimensions(_ controlSize: ControlSize) -> some View {
        let fullWidth = controlSize == .extraLarge
        return padding(.horizontal, fullWidth ? 24 : 10)
            .padding(.vertical, fullWidth ? 16 : 10)
            .frame(maxWidth: .infinity, minHeight: fullWidth ? 58 : 44)
    }
}

/// Shared opaque surface: a gentle vertical gradient and a tonal inset rim.
/// This is drawing only; Button retains activation, focus and accessibility,
/// while OathButton continues to own haptics and guarded action delivery.
private struct OathFilledButtonStyle: ButtonStyle {
    let surface: Color
    let foreground: Color
    let borderShape: ButtonBorderShape
    let controlSize: ControlSize
    var isNeutral = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var rim: some View {
        if isNeutral || !isEnabled {
            // A thin neutral edge follows the white/charcoal surface. The old
            // two-point white highlight was too bright on dark buttons.
            let color: Color = colorScheme == .dark ? .white : .black
            let opacity = colorScheme == .dark ? 0.10 : 0.08
            borderShape.strokeBorder(color.opacity(isEnabled ? opacity : 0.04), lineWidth: 1)
        } else {
            // Derive the edge from the actual accent, including destructive
            // actions. Keep it saturated instead of washing it out with white.
            borderShape.strokeBorder(surface, lineWidth: 2)
                .brightness(0.08)
                .saturation(1.15)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        configuration.label
            .foregroundStyle(isEnabled ? foreground : Color(uiColor: .secondaryLabel))
            .oathActionDimensions(controlSize)
            .background {
                borderShape.fill(isEnabled ? surface : Color(uiColor: .systemGray5))
                    .overlay {
                        if isEnabled {
                            borderShape.fill(LinearGradient(stops: [
                                .init(color: .white.opacity(0.08), location: 0),
                                .init(color: .clear, location: 0.55),
                                .init(color: .black.opacity(0.04), location: 1)
                            ], startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .overlay {
                        rim
                    }
                    .overlay {
                        borderShape.fill(.black.opacity(pressed ? 0.08 : 0))
                    }
            }
            .contentShape(borderShape)
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pressed)
    }
}

private struct OathActionStyle: ViewModifier {
    let appearance: OathActionAppearance
    let accent: Color?
    let foreground: Color?
    let borderShape: ButtonBorderShape
    let controlSize: ControlSize

    func body(content: Content) -> some View {
        styledButton(content)
            .controlSize(controlSize)
            .buttonBorderShape(borderShape)
            .oathFont(.body, weight: .medium)
    }

    @ViewBuilder private func styledButton(_ content: Content) -> some View {
        switch appearance {
        case .primary:
            content.buttonStyle(OathFilledButtonStyle(
                surface: accent ?? OathOnboardingColors.blue,
                foreground: foreground ?? .white,
                borderShape: borderShape, controlSize: controlSize
            ))
        case .destructiveSecondary:
            content.buttonStyle(OathFilledButtonStyle(
                surface: .red, foreground: foreground ?? .white,
                borderShape: borderShape, controlSize: controlSize
            ))
        case .secondary:
            // Use Oath's white/charcoal palette, independent of wallet accents
            // and the blue default tint supplied by OathBottomAction.
            content.buttonStyle(OathFilledButtonStyle(
                surface: Color(uiColor: OathSurfaceColors.card),
                foreground: foreground ?? .primary,
                borderShape: borderShape, controlSize: controlSize, isNeutral: true
            ))
        case .wallet:
            content.buttonStyle(OathWalletActionStyle(
                foreground: foreground ?? .white, borderShape: borderShape, controlSize: controlSize
            ))
        case .text:
            // Preserve the welcome screen's quiet More Options treatment while
            // retaining native control insets and the same extra-large height.
            content.buttonStyle(.bordered).tint(.clear)
                .foregroundStyle(foreground ?? .secondary)
        }
    }
}

/// Import, contact, filter and send confirmations share the same native glass
/// and semantic colors. Read the effective environment so a disabled parent
/// also changes both the fill and label, not only the button's hit testing.
private struct OathToolbarActionStyle: ViewModifier {
    var role: ButtonRole? = nil
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        nativeButton(content)
            .tint(isEnabled ? (role == .destructive ? .red : OathOnboardingColors.blue) : Color(uiColor: .systemGray3))
            .foregroundStyle(isEnabled ? Color.white : Color(uiColor: .secondaryLabel))
    }

    @ViewBuilder private func nativeButton(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// For transient authentication/input suspension, not form validation.
    /// Raw Button/Toggle actions must also guard against queued activation.
    func oathInteractionBlocked(_ blocked: Bool = false) -> some View {
        modifier(OathInteractionBlock(blocked: blocked))
    }

    /// Confirmations stay blue even in sheets with neutral navigation controls.
    func oathConfirmationControl() -> some View {
        tint(OathOnboardingColors.blue)
    }

    /// Toolbar actions use this before .disabled so native enabled state is
    /// inherited. Keep neutral navigation controls and alert roles separate.
    func oathToolbarActionStyle(role: ButtonRole? = nil) -> some View {
        modifier(OathToolbarActionStyle(role: role))
    }

    /// Explicit label color avoids inheriting a wallet or navigation-link tint.
    /// Use only for neutral controls; confirmation buttons own their blue tint.
    func oathNeutralControl() -> some View {
        foregroundStyle(Color(uiColor: .label))
            .tint(Color(uiColor: .label))
    }

    func oathActionStyle(_ appearance: OathActionAppearance = .primary,
                         accent: Color? = nil, foreground: Color? = nil,
                         borderShape: ButtonBorderShape = .capsule,
                         controlSize: ControlSize = .extraLarge) -> some View {
        modifier(OathActionStyle(appearance: appearance, accent: accent, foreground: foreground,
                                borderShape: borderShape, controlSize: controlSize))
    }

    /// existingInset accounts for a form's padding instead of adding it twice.
    func oathActionArea(existingInset: CGFloat = 0) -> some View {
        OathActionAreaLayout(existingInset: existingInset) { self }
    }

    /// Fixed screen actions belong to the system's bottom safe-area bar, so
    /// scrolling content receives the native edge treatment behind the controls.
    /// Keep form/inline actions in oathActionArea instead.
    func oathBottomActions<Actions: View>(isPresented: Bool = true,
                                          maximumWidth: CGFloat = OathActionMetrics.maximumWidth,
                                          onHeightChange: ((CGFloat) -> Void)? = nil,
                                          @ViewBuilder content: () -> Actions) -> some View {
        modifier(OathBottomActions(isPresented: isPresented, maximumWidth: maximumWidth, onHeightChange: onHeightChange, actions: content()))
    }
}

private struct OathBottomActions<Actions: View>: ViewModifier {
    let isPresented: Bool
    let maximumWidth: CGFloat
    let onHeightChange: ((CGFloat) -> Void)?
    let actions: Actions

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .bottom) { bar }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content.safeAreaInset(edge: .bottom) {
                bar.background(.bar)
            }
        }
    }

    @ViewBuilder private var bar: some View {
        // Apply system padding only to a real bar. Empty states and working
        // screens must not reserve an invisible footer's height.
        if isPresented {
            let paddedActions = actions
                .frame(maxWidth: maximumWidth)
                .padding()
                .frame(maxWidth: .infinity)
            if let onHeightChange {
                paddedActions.onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeightChange)
            } else { paddedActions }
        }
    }
}

/// Sizes before placement, without geometry-to-state writes or a first-frame
/// resize. The system still measures the native button at every Dynamic Type size.
private struct OathActionAreaLayout: Layout {
    var existingInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? OathActionMetrics.maximumWidth + 64
        let innerWidth = OathActionMetrics.contentWidth(in: width, existingInset: existingInset)
        let height = subviews.first?.sizeThatFits(.init(width: innerWidth, height: nil)).height ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = OathActionMetrics.contentWidth(in: bounds.width, existingInset: existingInset)
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                             proposal: .init(width: width, height: bounds.height))
    }
}
