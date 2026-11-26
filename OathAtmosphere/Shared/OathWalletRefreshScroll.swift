import SwiftUI
import OathNativeRefresh

enum OathWalletAccent {
    static func color(_ hex: String?) -> UIColor {
        let rgb = hex.flatMap { $0.count == 6 ? UInt32($0, radix: 16) : nil } ?? 0x244DE0
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

struct OathWalletRefreshScroll<Content: View>: View {
    let identifier: String
    let colorHex: String?
    var timing: NativeRefreshTiming = .walletBand
    let isEnabled: Bool
    let refreshIdentity: String?
    let action: @MainActor @Sendable () async throws -> Void
    var onScroll: @MainActor (CGFloat) -> Void = { _ in }
    @ViewBuilder let content: () -> Content
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        NativeRefreshScroll(identifier: identifier, tint: OathWalletAccent.color(colorHex),
            indicator: .walletBand, timing: timing,
            labels: NativeRefreshLabels(pull: strings.text(.pullToRefresh), refreshing: strings.text(.refreshing),
                                        succeeded: strings.text(.refreshSucceeded), failed: strings.text(.refreshFailed)),
            isEnabled: isEnabled, refreshIdentity: refreshIdentity, action: action,
            onFailure: {}, onScroll: onScroll, feedback: { event in
                switch event {
                case .started: OathHaptics.shared.play(.refresh)
                case .succeeded: OathHaptics.shared.play(.success)
                case .failed: OathHaptics.shared.play(.error)
                case .finished, .pullStep: break
                }
            }) { content() }
            .id(strings.language.isRightToLeft)
    }
}
