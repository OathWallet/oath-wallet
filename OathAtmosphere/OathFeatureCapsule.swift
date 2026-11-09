import SwiftUI

/// A single persistent glass surface whose contents cycle through wallet features.
struct OathFeatureCapsule: View {
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var rotation = OathFeatureRotation()
    @ScaledMetric(relativeTo: .subheadline) private var badgeSize: CGFloat = 20

    private var displayedRotation: OathFeatureRotation {
        reduceMotion || voiceOverEnabled ? OathFeatureRotation() : rotation
    }

    private var shouldCycle: Bool {
        scenePhase == .active && !reduceMotion && !voiceOverEnabled
    }

    var body: some View {
        glassCaption
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(.featuresAccessibility))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("onboarding.featureCapsule")
            .allowsHitTesting(false)
            .task(id: shouldCycle) {
                guard shouldCycle else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: rotation.feature.dwell)
                    } catch {
                        // Task.sleep only throws for expected lifecycle cancellation.
                        return
                    }
                    guard !Task.isCancelled else { return }
                    withAnimation(.smooth(duration: 0.52)) {
                        rotation.advance()
                    }
                }
            }
    }

    @ViewBuilder
    private var glassCaption: some View {
        if reduceTransparency {
            // The white artwork label needs an opaque blue surface when
            // transparency is disabled, without overriding the scene's theme.
            caption.background(Color(red: 0.12, green: 0.24, blue: 0.43), in: Capsule())
        } else if #available(iOS 26.0, *) {
            // The caption floats over animated artwork. Keep one untinted,
            // native clear-glass surface as its feature labels transition.
            caption.glassEffect(.clear, in: Capsule())
        } else {
            caption.background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var caption: some View {
        ZStack {
            if let chain = displayedRotation.chain {
                HStack(spacing: 8) {
                    // Keep Receive mounted while only the badge and name transition.
                    Text(strings.text(.receive))
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    ZStack(alignment: .leading) {
                        chainCaption(chain)
                            .id(chain)
                            .transition(.blurReplace)
                    }
                }
                .transition(.blurReplace)
            } else {
                HStack(spacing: 8) {
                    if let symbol = displayedRotation.feature.symbol {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.monochrome)
                            .accessibilityHidden(true)
                    }
                    Text(strings.text(displayedRotation.feature.title))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(displayedRotation.feature)
                .transition(.blurReplace)
            }
        }
        .oathFont(.subheadline, weight: .medium)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(minHeight: 42)
    }

    private func chainCaption(_ chain: OathImportChain) -> some View {
        HStack(spacing: 6) {
            OathNetworkLogo(asset: chain.logoAsset, size: badgeSize)
            Text(verbatim: chain.name)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
