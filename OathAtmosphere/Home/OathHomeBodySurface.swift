import SwiftUI

/// Home and Asset Detail measure the balance and actions at their natural height.
struct OathWalletSummaryLayout<Content: View>: View {
    var topInset: CGFloat = 36
    var bottomInset: CGFloat = 40
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 44, content: content)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
    }
}

/// A native stack with a background confined to its own body. In a List this
/// is one reusable cell; it must never paint a canvas over subsequent cells.
/// Home and asset details share the same compact section inset.
struct OathHeaderScrollContent<Header: View, Content: View>: View {
    let viewportHeight: CGFloat
    var fillsViewport = false
    var headerSpacing: CGFloat = 8
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: headerSpacing) {
            VStack(spacing: 0, content: header)
                .fixedSize(horizontal: false, vertical: true)
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

/// The panel and following cells form one uninterrupted surface.
/// Its native background proposal is exactly the body size, including the
/// empty-state minimum height. Later asset rows own their own backgrounds.
/// Layout/scroll passes are ordinary presentation, not diagnostic failures.
private struct OathHomeBodySurface: View {
    // Align section content with the standard list margin.
    // No additional inset is needed for the section edge.
    nonisolated static let contentInset: CGFloat = 20
    nonisolated static let cornerRadius: CGFloat = 0

    private let surface = Color(uiColor: OathSurfaceColors.groupedCanvas)

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius, style: .continuous)
            .fill(surface)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
