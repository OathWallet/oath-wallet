import SwiftUI

enum OathBalanceMaskStyle {
    case amount, secondary, detail, hero, receipt, compact

    var symbolSize: CGFloat {
        switch self {
        case .amount, .compact: 10
        case .secondary: 8.5
        case .detail: 13
        case .hero: 40
        case .receipt: 25
        }
    }
    var lineHeight: CGFloat {
        switch self {
        case .amount: 22
        case .secondary, .compact: 18
        case .detail: 24
        case .hero: 70
        case .receipt: 41
        }
    }
    var textStyle: Font.TextStyle {
        switch self {
        case .secondary, .compact: .subheadline
        case .detail: .title3
        case .hero, .receipt: .largeTitle
        case .amount: .body
        }
    }
    var count: Int { self == .compact ? 3 : 5 }
}

/// Fixed-count symbols never encode the amount, its sign, or its digit count.
/// Every size uses a static neutral-gray mask, including the large balance.
struct OathBalanceMask: View {
    let style: OathBalanceMaskStyle
    @ScaledMetric private var scaledSymbolSize: CGFloat
    @ScaledMetric private var scaledLineHeight: CGFloat

    init(style: OathBalanceMaskStyle = .amount) {
        self.style = style
        _scaledSymbolSize = ScaledMetric(wrappedValue: style.symbolSize, relativeTo: style.textStyle)
        _scaledLineHeight = ScaledMetric(wrappedValue: style.lineHeight, relativeTo: style.textStyle)
    }

    // The shared 58-point hero balance has a fixed type size too.
    private var symbolSize: CGFloat { style == .hero ? style.symbolSize : scaledSymbolSize }
    private var lineHeight: CGFloat { style == .hero ? style.lineHeight : scaledLineHeight }

    var body: some View {
        symbols
            // Sampled from the reference's resting asterisks: sRGB #858585.
            .foregroundStyle(Color(.sRGB, red: 0.522, green: 0.522, blue: 0.522, opacity: 1))
            .frame(height: lineHeight)
            .fixedSize()
            .accessibilityHidden(true)
        // Mask presentation is not a diagnostic event. Persistence failures
        // remain at the session boundary.
    }

    private var symbols: some View {
        HStack(spacing: symbolSize * 0.2) {
            ForEach(0..<style.count, id: \.self) { _ in
                Image(systemName: "asterisk")
                    .resizable()
                    .scaledToFit()
                    .font(.system(size: symbolSize, weight: .bold))
                    .frame(width: symbolSize, height: symbolSize)
            }
        }
    }
}

private struct OathBalanceConcealment: ViewModifier {
    let hidden: Bool
    let style: OathBalanceMaskStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.oathLocalizer) private var strings

    func body(content: Content) -> some View {
        Group {
            if hidden { OathBalanceMask(style: style).transition(.opacity) }
            else { content.transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: hidden)
        .accessibilityRepresentation {
            if hidden { Text(strings.text(.balanceHidden)) }
            else { content }
        }
    }
}

extension View {
    func oathBalanceConcealed(_ hidden: Bool, style: OathBalanceMaskStyle = .amount) -> some View {
        modifier(OathBalanceConcealment(hidden: hidden, style: style))
    }
}
