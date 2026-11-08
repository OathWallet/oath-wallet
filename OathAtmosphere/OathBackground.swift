import SwiftUI
import MetalKit

/// Oath's upper silk artwork and white glass logo, with calm space below.
/// Inherits the scene's chosen appearance; the surface contains no text or controls.
public struct OathBackground: View {
    private let colorway: OathColorway
    private var customColor: UInt32?
    private var placement: OathArtworkPlacement?
    private var animates = true
    private var isRefreshing = false
    @State private var isVisible = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    public init(colorway: OathColorway = .cobalt) { self.colorway = colorway }

    init(placement: OathArtworkPlacement, animates: Bool = true, customColor: UInt32? = nil,
         isRefreshing: Bool = false) {
        self.colorway = .cobalt
        self.placement = placement
        self.animates = animates
        self.customColor = customColor
        self.isRefreshing = isRefreshing
    }

    public var body: some View {
        let colors = customColor.map(OathSilkColors.custom) ?? colorway.colors
        let playbackRate = isRefreshing ? 3.0 : 1.0
        let transitionsEnabled = !effectiveReduceMotion && scenePhase == .active && isVisible && animates
        OathAnimatedMetalSurface(colors: colors, playbackRate: playbackRate, surface: OathMetalSurface(
            dark: colorScheme == .dark,
            reduceMotion: effectiveReduceMotion,
            active: isVisible && animates && scenePhase == .active,
            foreground: isVisible && scenePhase != .background,
            colorway: colorway,
            customColor: customColor,
            colors: colors,
            playbackRate: playbackRate,
            placement: placement
        ))
        // Animate the actual shader palette, not the wallet ID or the canvas.
        // SwiftUI retargets from the displayed colors on a rapid second switch.
        // Equal palettes (including default blue/custom blue) do not animate.
        .animation(effectiveReduceMotion || scenePhase != .active || !isVisible
                   ? nil : .easeInOut(duration: 0.5), value: colors)
        // Interpolate speed with SwiftUI, while the existing renderer integrates
        // time continuously. Changing the speed never seeks or restarts the silk.
        .animation(transitionsEnabled ? .easeInOut(duration: 0.35) : nil, value: playbackRate)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        // Artwork remains decorative; the DEBUG-only UIKit identifier lets the
        // startup regression observe readiness; screenshots verify presentation.
    }

    private var effectiveReduceMotion: Bool {
        #if DEBUG
        reduceMotion || ProcessInfo.processInfo.arguments.contains("-oath-artwork-reduce-motion")
        #else
        reduceMotion
        #endif
    }
}

/// SwiftUI owns interpolation; the existing Metal surface and playback clock
/// retain their identity. This introduces no snapshots or second renderer.
private struct OathAnimatedMetalSurface: View, Animatable {
    nonisolated var colors: OathSilkColors
    nonisolated var playbackRate: Double
    let surface: OathMetalSurface

    nonisolated var animatableData: AnimatablePair<OathSilkColors, Double> {
        get { .init(colors, playbackRate) }
        set { colors = newValue.first; playbackRate = newValue.second }
    }

    var body: some View {
        var presentation = surface
        presentation.colors = colors
        presentation.playbackRate = playbackRate
        return presentation
    }
}

private struct OathMetalSurface: UIViewRepresentable {
    let dark: Bool
    let reduceMotion: Bool
    let active: Bool
    let foreground: Bool
    let colorway: OathColorway
    let customColor: UInt32?
    var colors: OathSilkColors
    var playbackRate: Double
    let placement: OathArtworkPlacement?

    func makeCoordinator() -> OathRenderer { OathRenderer() }

    func makeUIView(context: Context) -> OathArtworkView {
        let view = OathArtworkView()
        context.coordinator.configure(view, dark: dark)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: OathArtworkView, context: Context) {
        context.coordinator.update(view, dark: dark, reduceMotion: reduceMotion, active: active,
                                   foreground: foreground, colorway: colorway, customColor: customColor,
                                   colors: colors, placement: placement, playbackRate: playbackRate)
    }

    static func dismantleUIView(_ view: OathArtworkView, coordinator: OathRenderer) {
        coordinator.stop()
    }
}
