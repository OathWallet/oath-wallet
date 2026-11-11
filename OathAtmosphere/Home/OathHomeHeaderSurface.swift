import SwiftUI

extension View {
    @ViewBuilder func oathNativeAppBar(title: String = "", subtitle: String? = nil, hasArtworkHeader: Bool = true,
                                       file: StaticString = #fileID, line: UInt = #line) -> some View {
        // Classic navigation bars need a visible background for their native
        // foreground color scheme to apply over artwork at the scroll edge.
        let background: Visibility = if #available(iOS 26, *) { .automatic } else { .visible }
        let screen = navigationBarTitleDisplayMode(.inline)
            .oathNativeLocalization(navigationBackground: background, navigationMaterial: nil,
                                    systemNavigationAppearance: true, systemBackButton: true,
                                    file: file, line: line)
            .modifier(OathArtworkBarAppearance(stylesNavigationBar: true, hasArtworkHeader: hasArtworkHeader))
        if let subtitle {
            if #available(iOS 26, *) {
                screen.navigationTitle(title).navigationSubtitle(Text(verbatim: subtitle))
            } else {
                screen.navigationTitle(title + " · " + subtitle)
            }
        } else {
            screen.navigationTitle(title)
        }
    }
}

/// A fixed viewport canvas, masked to the header above the Assets surface.
/// Scroll and refresh never resize the renderer.
struct OathHomeHeaderSurface: View {
    let animates: Bool
    var colorHex: String? = nil
    var isRefreshing = false

    var body: some View {
        GeometryReader { geometry in
            OathBackground(placement: .walletBackdrop(size: geometry.size),
                           animates: animates, customColor: colorHex.flatMap { UInt32($0, radix: 16) },
                           isRefreshing: isRefreshing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Both wallet screens use the same artwork and drag blur behind their content.
struct OathWalletHeaderBackground: ViewModifier {
    let animates: Bool
    let colorHex: String?
    let effects: OathHomeScrollEffects

    func body(content: Content) -> some View {
        content
            .modifier(OathHeaderScrollBackground { visible in
                OathHomeHeaderSurface(animates: animates && visible, colorHex: colorHex, isRefreshing: effects.isRefreshing)
                    .modifier(OathHomeDragBlur(effects: effects))
            })
    }
}

struct OathHomeToolbar: ToolbarContent {
    let onScan: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            OathWalletSidebarButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
            OathButton(strings.text(.scan), systemImage: "viewfinder", feedback: .scan, action: onScan)
                .accessibilityIdentifier("home.scanner")
        }
    }
}

/// Read the gesture state only at the decorative surface. Scrolling must not
/// rebuild Home's rows or replace the Metal renderer and its animation clock.
struct OathHomeDragBlur: ViewModifier {
    let effects: OathHomeScrollEffects
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .blur(radius: effects.isDragging ? 16 : 0, opaque: true)
            .animation(reduceMotion ? nil : .smooth, value: effects.isDragging)
    }
}
