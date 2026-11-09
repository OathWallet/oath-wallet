import SwiftUI

/// Oath's animated welcome screen. The integrating wallet supplies its actions.
public struct OathOnboardingScreen: View {
    private let onCreateWallet: () -> Void
    private let onImportWallet: () -> Void
    private let onMoreOptions: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @ScaledMetric(relativeTo: .largeTitle) private var compactTitleSize = 32
    @ScaledMetric(relativeTo: .largeTitle) private var expandedTitleSize = 40
    @State private var actionHeight: CGFloat = 200
    @State private var introductionHeight: CGFloat = 175
    @State private var artworkPlacement = OathArtworkPlacement()

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
            let placement = OathArtworkPlacement(
                logo: artworkPlacement.logo,
                logoClip: layout.introduction,
                copy: artworkPlacement.copy,
                actions: artworkPlacement.actions,
                spreadDivider: layout.spreadDivider,
                rendersLogo: false
            ).offsetBy(dx: layoutDirection == .rightToLeft ? safeArea.trailing : safeArea.leading, dy: safeArea.top)

            // Both panes and the renderer keep their identity when the display
            // folds or rotates, preserving the current phrase and motion time.
            ZStack(alignment: .topLeading) {
                OathBackground(placement: placement)
                    .ignoresSafeArea()

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

    private func introductionPane(_ layout: OathOnboardingLayout) -> some View {
        GeometryReader { viewport in
            let viewportHeight = OathLayoutGeometry.finiteSize(viewport.size).height
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    // The welcome artwork is always blue, in either appearance.
                    // Render the supplied white vector directly, without glass shading.
                    Image("OathWelcomeMarkWhite")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: layout.logoSize.width, height: layout.logoSize.height)
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("oathOnboarding")) } action: {
                            guard OathLayoutGeometry.isUsable($0) else { return }
                            artworkPlacement.logo = $0
                        }
                        .padding(.bottom)

                    introduction(expanded: layout.arrangement == .spread && layout.introduction.width >= 360)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("oathOnboarding")) } action: {
                            guard OathLayoutGeometry.isUsable($0) else { return }
                            introductionHeight = $0.height
                            artworkPlacement.copy = $0
                        }
                        .padding(.top)
                }
                .frame(maxWidth: .infinity)
                // Center the entire introduction; larger text can still scroll.
                .frame(minHeight: viewportHeight, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
        }
        .padding()
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
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("oathOnboarding")) } action: {
                    guard OathLayoutGeometry.isUsable($0) else { return }
                    // Include the system padding in the pane's requested height.
                    let systemPadding = max(0, layout.actions.height - viewportHeight)
                    actionHeight = $0.height + systemPadding
                    artworkPlacement.actions = $0
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
        .accessibilityIdentifier("onboarding.actionsPane")
    }

    private func introduction(expanded: Bool) -> some View {
        VStack(spacing: 0) {
            OathFeatureCapsule()

            Text(strings.text(.brandLine))
                .oathFont(.caption2, weight: .bold)
                .tracking(strings.language == .arabic ? 0 : 1.4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top)
                .accessibilityIdentifier("onboarding.brandLine")

            Text(strings.text(.headline))
                .oathFont(.largeTitle, weight: .semibold, size: expanded ? expandedTitleSize : compactTitleSize)
                .tracking(strings.language == .arabic ? 0 : -0.7)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.headline")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: expanded ? 380 : 360)
    }

    private var linkBlue: Color {
        colorScheme == .dark ? OathOnboardingColors.brightBlue : OathOnboardingColors.blue
    }

    private var consentText: AttributedString {
        let localized = strings.text(.consent)
        var text = (try? AttributedString(markdown: localized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(localized)
        text.foregroundColor = colorScheme == .dark
            ? Color(red: 0.62, green: 0.66, blue: 0.74)
            : Color(red: 0.40, green: 0.435, blue: 0.50)
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

            // Keep the filled Light appearance against the white footer; Dark
            // uses the same raised charcoal treatment as other secondary actions.
            OathActionButton(title: strings.text(.importWallet),
                             appearance: colorScheme == .dark ? .secondary : .primary,
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
