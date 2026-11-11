import SwiftUI

/// Home and Asset Detail measure the balance and actions at their natural height.
struct OathWalletSummaryLayout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 44, content: content)
            .padding(.top, 36)
            .padding(.bottom, 40)
    }
}

/// A native stack with a background confined to its own body. In a List this
/// is one reusable cell; it must never paint a canvas over subsequent cells.
/// Home and asset details share the same compact section inset.
struct OathHeaderScrollContent<Header: View, Content: View>: View {
    let viewportHeight: CGFloat
    var fillsViewport = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: OathHomeBodySurface.clearance) {
            VStack(spacing: 0, content: header)
                .fixedSize(horizontal: false, vertical: true)
                .anchorPreference(key: OathHeaderBounds.self, value: .bounds) { $0 }
            VStack(spacing: 0, content: content)
                .padding(.top, OathHomeBodySurface.contentInset)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: fillsViewport ? .infinity : nil, alignment: .top)
                .background { OathHomeBodySurface() }
        }
        // Accept the native cell's height throughout both growth and shrinkage.
        // With either bound omitted, List can center the old/new intrinsic
        // content during chart expansion, moving even the unchanged header.
        .frame(minHeight: fillsViewport ? max(0, viewportHeight) : 0, maxHeight: .infinity, alignment: .top)
    }
}

private struct OathHeaderBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The header reports only when artwork enters or leaves the bar's background.
private struct OathArtworkAtScrollEdge: PreferenceKey {
    // Unrelated children contribute the identity value, never overwrite a
    // measured list surface. Welcome has no scrolling surface and stays dark.
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value && nextValue() }
}

#if canImport(UIKit)
struct OathArtworkBarAppearance: ViewModifier {
    var stylesNavigationBar = false
    var hasArtworkHeader = true
    @State private var artworkAtTop = true
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let overArtwork = hasArtworkHeader && artworkAtTop
        let screen = content
            .onPreferenceChange(OathArtworkAtScrollEdge.self) { artworkAtTop = $0 }
        let scheme: ColorScheme = overArtwork ? .dark : colorScheme
        if #available(iOS 27, *) {
            if stylesNavigationBar {
                screen.toolbarColorScheme(scheme, for: .navigationBar, .statusBar)
            } else {
                screen.toolbarColorScheme(artworkAtTop ? .dark : nil, for: .statusBar)
            }
        } else if stylesNavigationBar {
            screen.toolbarColorScheme(scheme, for: .navigationBar)
        } else {
            content
        }
    }
}
#endif

/// Dark mode carries the animated colors through one continuous frosted panel.
/// Keep the material behind the entire list, rather than giving reusable rows
/// separate blur layers with visible seams. Light mode keeps its opaque canvas.
struct OathHeaderScrollBackground<Artwork: View>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let artwork: (Bool) -> Artwork

    init(@ViewBuilder artwork: @escaping (Bool) -> Artwork) { self.artwork = artwork }
    init(@ViewBuilder artwork: @escaping () -> Artwork) { self.artwork = { _ in artwork() } }

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(OathHeaderBounds.self) { bounds in
            GeometryReader { viewport in
                let edge = bounds.map { viewport[$0].maxY + OathHomeBodySurface.clearance }
                GeometryReader { geometry in
                    let inset = viewport.frame(in: .global).minY - geometry.frame(in: .global).minY
                    let top = edge.map { $0 + inset } ?? 0
                    let bottom = top + (bounds == nil ? 0 : OathHomeBodySurface.cornerRadius)
                    let frosted = colorScheme == .dark && !reduceTransparency
                    Color(uiColor: OathSurfaceColors.groupedCanvas)
                        .overlay {
                            artwork(geometry.size.height > 0 && (frosted || bottom > 0))
                                .mask(alignment: .top) {
                                    Rectangle().frame(height: frosted ? geometry.size.height : max(0, min(geometry.size.height, bottom)))
                                }
                        }
                        .overlay(alignment: .bottom) {
                            if frosted {
                                Rectangle()
                                    .fill(.regularMaterial)
                                    .overlay(Color.black.opacity(0.18))
                                    .overlay {
                                        LinearGradient(colors: [.white.opacity(0.04), .clear, .black.opacity(0.12)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                    }
                                    .mask(alignment: .bottom) {
                                        Rectangle().frame(height: max(0, min(geometry.size.height, geometry.size.height - top)))
                                    }
                            }
                        }
                }
                .ignoresSafeArea()
                .preference(key: OathArtworkAtScrollEdge.self, value: (edge ?? 0) > 0)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The panel and following cells form one uninterrupted surface.
/// Its native background proposal is exactly the body size, including the
/// empty-state minimum height. Later asset rows own their own backgrounds.
/// Layout/scroll passes are ordinary presentation, not diagnostic failures.
private struct OathHomeBodySurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // Keep the canvas below the native glass actions' backdrop.
    nonisolated static let clearance: CGFloat = 8
    // Align section content with the standard list margin.
    // No additional inset is needed for the section edge.
    nonisolated static let contentInset: CGFloat = 20
    nonisolated static let cornerRadius: CGFloat = 0

    private let surface = Color(uiColor: OathSurfaceColors.groupedCanvas)

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius, style: .continuous)
            .fill(colorScheme == .dark && !reduceTransparency ? .clear : surface)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
