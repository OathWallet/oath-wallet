import SwiftUI

/// Oath's animated welcome screen. The integrating wallet supplies its actions.
public struct OathOnboardingScreen: View {
    private let onCreateWallet: () -> Void
    private let onImportWallet: () -> Void
    private let onMoreOptions: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @ScaledMetric(relativeTo: .title2) private var titleSize = 28
    @State private var visible = false
    @State private var revealed = false
    @State private var actionHeight: CGFloat = 270
    @State private var introductionHeight: CGFloat = 90
    @State private var iconFrame = CGRect.zero

    public init(
        onCreateWallet: @escaping () -> Void,
        onImportWallet: @escaping () -> Void,
        onMoreOptions: @escaping () -> Void
    ) {
        self.onCreateWallet = onCreateWallet
        self.onImportWallet = onImportWallet
        self.onMoreOptions = onMoreOptions
    }

    public var body: some View {
        GeometryReader { geometry in
            let availableSize = OathLayoutGeometry.finiteSize(geometry.size)
            let safeArea = geometry.safeAreaInsets
            let layout = OathOnboardingLayout(
                size: availableSize,
                actionHeight: actionHeight,
                introductionHeight: introductionHeight,
                divisions: reservedFrames(in: geometry, division: true),
                occlusions: reservedFrames(in: geometry, division: false),
                rightToLeft: layoutDirection == .rightToLeft
            )
            let dx = layoutDirection == .rightToLeft ? safeArea.trailing : safeArea.leading
            let icon = iconFrame.offsetBy(dx: dx, dy: safeArea.top)

            ZStack(alignment: .topLeading) {
                Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea()
                OathWelcomeArtwork(
                    introduction: layout.introduction.offsetBy(dx: dx, dy: safeArea.top),
                    icon: icon, topSafeAreaInset: safeArea.top,
                    active: visible && scenePhase == .active,
                    reduceMotion: reducedMotion, resumeSettled: revealed,
                    onReveal: {
                        withAnimation(reducedMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82)) {
                            revealed = true
                        }
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                if OathLayoutGeometry.isUsable(layout.introduction) {
                    introductionPane(layout)
                        .frame(width: layout.introduction.width, height: layout.introduction.height)
                        .position(x: layout.introduction.midX, y: layout.introduction.midY)
                }

                if OathLayoutGeometry.isUsable(layout.actions) {
                    actionsPane(layout)
                        .frame(width: layout.actions.width, height: layout.actions.height)
                        .position(x: layout.actions.midX, y: layout.actions.midY)
                }
            }
            .frame(width: availableSize.width, height: availableSize.height)
            .coordinateSpace(name: "oathOnboarding")
            #if DEBUG
            .onChange(of: layout, initial: true) { _, current in
                if ProcessInfo.processInfo.arguments.contains("-oath-layout-diagnostics") {
                    NSLog("%@", "Oath layout: size=\(geometry.size) safe=\(safeArea) arrangement=\(current.arrangement) introduction=\(current.introduction) actions=\(current.actions)")
                }
            }
            #endif
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .oathDiagnosticsScreen()
    }

    private func reservedFrames(in geometry: GeometryProxy, division: Bool) -> [CGRect] {
        // SwiftUI 8.0.85.27 is the module shipped in the iOS 27.1 SDK.
        // Xcode 27.0 uses the same Swift compiler but lacks reservedRegions,
        // so runtime availability alone cannot protect this reference.
        #if canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            return geometry.reservedRegions(
                kind: division ? .division : .occlusion,
                layoutDirectionBehavior: .fixed
            ).filter(\.isActive).map(\.frame)
        }
        #endif
        return []
    }

    private var reducedMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-oath-artwork-reduce-motion") { return true }
        #endif
        return reduceMotion
    }

    private func introductionPane(_ layout: OathOnboardingLayout) -> some View {
        GeometryReader { viewport in
            let height = OathLayoutGeometry.finiteSize(viewport.size).height
            ScrollView(.vertical) {
                VStack(spacing: 20) {
                    // The native compositor owns this icon throughout the opening
                    // transition. Its measured destination stays aligned at any size.
                    Color.clear
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("oathOnboarding")) } action: {
                            guard OathLayoutGeometry.isUsable($0) else { return }
                            iconFrame = $0
                        }
                    introduction
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            if $0.isFinite { introductionHeight = $0 }
                        }
                        .opacity(revealed ? 1 : 0)
                        .blur(radius: revealed ? 0 : 8)
                        .offset(y: revealed ? 0 : 24)
                        .accessibilityHidden(!revealed)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: height, alignment: .bottom)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 24)
        .clipShape(Rectangle())
        .accessibilityIdentifier("onboarding.introductionPane")
    }

    private func actionsPane(_ layout: OathOnboardingLayout) -> some View {
        GeometryReader { viewport in
            let viewportHeight = OathLayoutGeometry.finiteSize(viewport.size).height
            ScrollView(.vertical) {
                VStack(spacing: 16) {
                    walletActions

                    Text(consentText)
                        .oathFont(.caption)
                        .tint(linkBlue)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340)
                        .accessibilityIdentifier("onboarding.consent")
                }
                .frame(maxWidth: OathActionMetrics.maximumWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    guard $0.isFinite, $0 > 0 else { return }
                    // Measure layout, not the reveal transform: the animation
                    // must not feed per-frame positions back into SwiftUI state.
                    let systemPadding = max(0, layout.actions.height - viewportHeight)
                    actionHeight = $0 + systemPadding
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: viewportHeight, alignment: .bottom)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // Glass can expand into system padding without escaping the pane.
            .scrollClipDisabled()
        }
        .padding()
        .clipShape(Rectangle())
        .opacity(revealed ? 1 : 0)
        .blur(radius: revealed ? 0 : 8)
        .offset(y: revealed ? 0 : 30)
        .allowsHitTesting(revealed)
        .accessibilityHidden(!revealed)
        .accessibilityIdentifier("onboarding.actionsPane")
    }

    private var introduction: some View {
        VStack(spacing: 12) {
            Text(verbatim: strings.appDisplayName)
                .oathFont(.title2, weight: .semibold, size: titleSize)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.brandLine")
            Text(strings.text(.headline))
                .oathFont(.body, weight: .medium)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .accessibilityIdentifier("onboarding.headline")
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340)
    }

    private var linkBlue: Color {
        colorScheme == .dark ? OathOnboardingColors.brightBlue : OathOnboardingColors.blue
    }

    private var consentText: AttributedString {
        let localized = strings.text(.consent)
        var text = (try? AttributedString(markdown: localized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(localized)
        text.foregroundColor = Color(uiColor: .secondaryLabel)
        let links = text.runs.filter { $0.link != nil }.map(\.range)
        for range in links {
            text[range].foregroundColor = linkBlue
            if differentiateWithoutColor { text[range].underlineStyle = .single }
        }
        return text
    }

    private var walletActions: some View {
        VStack(spacing: OathActionMetrics.spacing) {
            OathActionButton(title: strings.text(.createWallet)) {
                onCreateWallet()
            }
            .accessibilityIdentifier("onboarding.createWallet")

            // The shared secondary action follows the scene's appearance.
            OathActionButton(title: strings.text(.importWallet),
                             appearance: .secondary,
                             accent: Color(uiColor: OathSurfaceColors.field), foreground: .primary) {
                onImportWallet()
            }
            .accessibilityIdentifier("onboarding.importWallet")

            OathActionButton(title: strings.text(.moreOptions), appearance: .text) {
                onMoreOptions()
            }
            .accessibilityIdentifier("onboarding.moreOptions")
        }
    }
}

enum OathOnboardingColors {
    static let blue = Color(red: 0.12, green: 0.30, blue: 0.90)
    static let brightBlue = Color(red: 0.36, green: 0.56, blue: 1.0)
}
