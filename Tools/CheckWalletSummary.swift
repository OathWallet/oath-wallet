import AppKit
import Observation
import SwiftUI

// Map the app's localization and system label color to the Mac host.
enum SummaryStringKey { case balanceHidden }
struct SummaryLocalizer: Sendable {
    func text(_ key: SummaryStringKey) -> String { "Balance hidden" }
}
private struct SummaryLocalizerKey: EnvironmentKey { static let defaultValue = SummaryLocalizer() }
extension EnvironmentValues {
    var oathLocalizer: SummaryLocalizer { self[SummaryLocalizerKey.self] }
}
extension NSColor {
    static var secondaryLabel: NSColor { .secondaryLabelColor }
}
extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

@main struct CheckWalletSummary {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--animations-only") {
            print("Passed \(verifyBalanceUpdates()) balance display checks on the Mac host.")
            return
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func bounds(_ bitmap: NSBitmapImageRep, name: String, matching: (NSColor) -> Bool) -> CGRect {
            var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), matching(color) else { continue }
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            if maxX < minX || maxY < minY {
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/oath-summary-probe-failed.png"))
                preconditionFailure("Missing rendered \(name); saved /tmp/oath-summary-probe-failed.png")
            }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        func walletAction(_ title: String, icon: String) -> some View {
            Button {} label: { OathActionLabel(title: title, icon: icon) }
                .buttonStyle(OathWalletActionStyle(foreground: .white, borderShape: .capsule, controlSize: .extraLarge))
                .font(.system(.body, weight: .medium))
        }
        func render(asset: Bool, width: CGFloat, rtl: Bool, size: DynamicTypeSize,
                    value: String, stacked: Bool, concealed: Bool = false, homeInset: CGFloat = 16) -> NSBitmapImageRep {
            let view = OathWalletSummary(topInset: asset ? 36 : homeInset, bottomInset: asset ? 40 : 0) {
                OathWalletBalance(value: value, concealed: concealed,
                                  title: asset ? (rtl ? "إجمالي الرصيد" : "Total Balance") : nil)
            } detail: {
                if asset {
                    Text("4.99 USDT").font(.title3).foregroundStyle(.red)
                } else {
                    Text("-$0.01 (0.01%) Today").font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 8).foregroundStyle(.red)
                }
            } send: {
                walletAction(rtl ? "إرسال" : "Send", icon: "paperplane")
                    .frame(minWidth: stacked ? 240 : 80, maxWidth: .infinity).overlay(Color.green)
            } receive: {
                walletAction(rtl ? "استلام" : "Receive", icon: "qrcode")
                    .frame(minWidth: stacked ? 240 : 80, maxWidth: .infinity).overlay(Color.green)
            }
            .frame(width: width).background(.black)
            .environment(\.colorScheme, .dark)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.dynamicTypeSize, size)
            .environment(\.scenePhase, .inactive)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: renderer.cgImage!)
        }
        func buttonFill(in scheme: ColorScheme) -> CGFloat {
            let renderer = ImageRenderer(content: walletAction("Send", icon: "paperplane").frame(width: 170)
                .environment(\.colorScheme, scheme))
            renderer.scale = 1
            let image = NSBitmapImageRep(cgImage: renderer.cgImage!)
            check(image.pixelsWide == 170 && image.pixelsHigh == 58, "Wallet actions must use Asset Detail sizing")
            func sample(_ y: Int, x: Int = 30) -> CGFloat {
                // Compare the encoded components, as sampled in the reference image.
                let color = image.colorAt(x: x, y: y)!
                check(abs(color.redComponent - color.blueComponent) < 0.01, "Wallet action fill has a color cast")
                return color.redComponent
            }
            let top = sample(8), bottom = sample(50)
            check(top > bottom && top < 0.30, "Wallet action lost its dark vertical gradient")
            if scheme == .dark {
                check(abs(sample(29) * 255 - 42) < 3 && abs(bottom * 255 - 37) < 3,
                      "Dark wallet actions must settle into the reference charcoal fill")
                check(sample(1, x: 42) > sample(1, x: 127) + 0.015 &&
                      sample(56, x: 127) > sample(56, x: 42) + 0.015,
                      "Dark wallet actions need opposing highlights on the capsule rim")
            }
            return bottom
        }
        let lightFill = buttonFill(in: .light), darkFill = buttonFill(in: .dark)
        check(darkFill > lightFill + 0.04, "Dark mode must use Home's lighter charcoal button surface")
        for width: CGFloat in [320, 430, 700] {
            for rtl in [false, true] {
                for size: DynamicTypeSize in [.large, .accessibility3] {
                    for stacked in [false, true] {
                        let value = rtl ? "د.أ. 123456789.12" : "$123456789.12"
                        let home = render(asset: false, width: width, rtl: rtl, size: size, value: value, stacked: stacked)
                        let asset = render(asset: true, width: width, rtl: rtl, size: size, value: value, stacked: stacked)
                        let hidden = render(asset: false, width: width, rtl: rtl, size: size,
                                            value: value, stacked: stacked, concealed: true)
                        let hiddenShort = render(asset: false, width: width, rtl: rtl, size: size,
                                                 value: "$0", stacked: stacked, concealed: true)
                        check(hidden.pixelsHigh == home.pixelsHigh, "Hiding the balance moves the header actions")
                        check(hidden.representation(using: .png, properties: [:]) == hiddenShort.representation(using: .png, properties: [:]),
                              "Hidden header reveals information about amount length or digits")
                        let removedTopSpace = CGFloat(asset.pixelsHigh - home.pixelsHigh) - 40
                        check(removedTopSpace > 20, "Home unexpectedly reserves space for the asset title")
                        if width == 320 && !stacked {
                            let smallHolding = render(asset: false, width: width, rtl: rtl, size: size, value: "$1.00", stacked: false)
                            check(home.pixelsHigh == smallHolding.pixelsHigh, "Fitting a wider total shifts the actions")
                        }
                        // Semantic primary text on macOS is slightly dimmer than literal white.
                        let primary: (NSColor) -> Bool = { $0.redComponent > 0.7 && $0.greenComponent > 0.7 && $0.blueComponent > 0.7 }
                        let green: (NSColor) -> Bool = { $0.greenComponent > 0.6 && $0.redComponent < 0.4 && $0.blueComponent < 0.55 }
                        let balance = bounds(home, name: "Home balance", matching: primary)
                        let assetBalance = bounds(asset, name: "asset balance", matching: primary)
                        check(balance.offsetBy(dx: 0, dy: removedTopSpace) == assetBalance,
                              "Removing Home's title changes balance size or horizontal alignment")
                        let actions = bounds(home, name: "Home actions", matching: green)
                        let assetActions = bounds(asset, name: "asset actions", matching: green)
                        if size == .large && width == 430 && !stacked && !rtl {
                            let unpadded = render(asset: false, width: width, rtl: rtl, size: size,
                                                  value: value, stacked: false, homeInset: 0)
                            check(bounds(unpadded, name: "Unpadded balance", matching: primary).offsetBy(dx: 0, dy: 16) == balance,
                                  "Home must add exactly 16 points above the balance")
                            check(actions.height == 58, "Side-by-side wallet actions must use the full-size capsule")
                        }
                        check(actions.offsetBy(dx: 0, dy: removedTopSpace) == assetActions,
                              "Removing Home's title changes action sizes or relative spacing")
                        check(balance.minX >= 24 && balance.maxX <= width - 24, "Long balance escapes shared margins")
                        check(balance.maxY < actions.minY && assetBalance.maxY < assetActions.minY, "Large text overlaps actions")
                        check(actions.maxY == CGFloat(home.pixelsHigh), "Home retains extra space below its actions")
                    }
                }
            }
        }
        // Five fixed neutral-gray glyphs for balances; three for the compact
        // change pill. Check actual rendered pixels, not implementation strings.
        for style: OathBalanceMaskStyle in [.amount, .secondary, .detail, .hero, .receipt, .compact] {
            func mask(_ value: String) -> NSBitmapImageRep {
                let renderer = ImageRenderer(content: Text(value).foregroundStyle(.red)
                    .oathBalanceConcealed(true, style: style)
                    .environment(\.scenePhase, .inactive))
                renderer.scale = 3
                return NSBitmapImageRep(cgImage: renderer.cgImage!)
            }
            let short = mask("$0"), long = mask("-$123,456,789.12")
            check(short.representation(using: .png, properties: [:]) == long.representation(using: .png, properties: [:]),
                  "Hidden amount affects the mask")
            var runs = 0, wasOccupied = false, grayPixels = 0
            for x in 0..<short.pixelsWide {
                var occupied = false
                for y in 0..<short.pixelsHigh {
                    // Inspect encoded components directly; converting AppKit's
                    // bitmap color to a second profile changes the gray's gamma.
                    guard let color = short.colorAt(x: x, y: y), color.alphaComponent > 0.95 else { continue }
                    occupied = true
                    if abs(color.redComponent - 0.522) < 0.03,
                       abs(color.greenComponent - color.redComponent) < 0.01,
                       abs(color.blueComponent - color.redComponent) < 0.01 { grayPixels += 1 }
                    else { preconditionFailure("Hidden amount is not the neutral reference gray") }
                }
                if occupied && !wasOccupied { runs += 1 }
                wasOccupied = occupied
            }
            check(runs == (style == .compact ? 3 : 5), "Wrong number of visible mask glyphs")
            check(grayPixels > 30, "Missing or invisible balance mask")
        }
        let preview = VStack(spacing: 20) {
            OathWalletBalance(value: "$354.12", concealed: true, title: "Total Balance")
                .foregroundStyle(.primary).padding(24).background(.white)
            HStack {
                Text("Bitcoin").foregroundStyle(.black)
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("$354.12").oathBalanceConcealed(true)
                    Text("0.00556706 BTC").oathBalanceConcealed(true, style: .secondary)
                }
            }.padding(20)
        }.frame(width: 393).padding(.vertical, 20).background(.white)
            .environment(\.colorScheme, .light)
            .environment(\.scenePhase, .inactive)
        let previewRenderer = ImageRenderer(content: preview)
        previewRenderer.scale = 2
        let previewBitmap = NSBitmapImageRep(cgImage: previewRenderer.cgImage!)
        try! previewBitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: "/tmp/oath-balance-mask-preview.png"))
        checks += verifyBalanceUpdates()
        print("Passed \(checks) shared wallet header and balance display checks on the Mac host.")
    }

    @MainActor static func verifyBalanceUpdates() -> Int {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let state = BalanceProbeState()
        let host = NSHostingView(rootView: BalanceProbe(state: state))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 430, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func frame() -> Data {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])!
        }
        func frames(_ count: Int) -> Set<Data> { Set((0..<count).map { _ in frame() }) }

        let zero = frame()
        check(frames(10) == [zero], "A fresh wallet must display a steady zero")
        state.value = "$405.12"
        let funded = frame()
        check(funded != zero && frames(12) == [funded], "A new fiat balance must appear directly")
        state.value = "$789.34"
        check(frame() != funded, "The updated amount must be visible")
        withAnimation(.linear(duration: 0.45)) { state.value = "$405.12" }
        check(frames(12) == [funded], "An animation in the surrounding screen must not animate a balance change")
        state.quantity = "١٢٫٣٤ 1INCH"
        let withQuantity = frame()
        check(withQuantity != funded && frames(12) == [withQuantity], "A new token quantity must appear directly")
        state.value = "$0.00"
        state.quantity = "0 1INCH"
        check(frames(12) == [zero], "A refreshed balance must return directly to the initial zero")

        state.hidden = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let mask = frame()
        check(mask != zero && frames(36) == [mask], "The concealed balance must remain still")
        state.value = "$405.12"
        state.quantity = "١٢٫٣٤ 1INCH"
        check(frames(6) == [mask], "An update must not expose a concealed balance")
        state.phase = .inactive
        check(frames(6) == [mask], "An inactive scene must retain the privacy mask")
        state.phase = .active
        check(frames(8) == [mask], "Returning to the foreground must retain the privacy mask")
        state.hidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        check(frames(8) == [withQuantity], "Revealing the balance must display the latest values")
        state.hidden = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        check(frames(8) == [mask], "Hiding the balance again must restore the same mask")
        return checks
    }
}

@MainActor @Observable private final class BalanceProbeState {
    var value = "$0.00"
    var quantity = "0 1INCH"
    var hidden = false
    var phase = ScenePhase.active
}

private struct BalanceProbe: View {
    let state: BalanceProbeState
    var body: some View {
        VStack {
            OathWalletBalance(value: state.value, concealed: state.hidden, title: "Total Balance")
            OathBalanceText(value: state.quantity, font: .title3)
                .oathBalanceConcealed(state.hidden, style: .detail)
        }
        .foregroundStyle(.white)
        .frame(width: 430, height: 150).background(.black)
        .contentTransition(.opacity)
        .environment(\.colorScheme, .dark)
        .environment(\.scenePhase, state.phase)
    }
}
