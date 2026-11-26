import AppKit
import SwiftUI

// Render the production chart directly on the Mac host, without a simulator.
@main struct CheckBalanceChart {
    @MainActor static func main() throws {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_000), duration: 1_000)
        func series(_ values: [Decimal]) -> BalanceChartSeries {
            BalanceChartSeries(points: values.enumerated().map {
                BalanceChartPoint(date: interval.start.addingTimeInterval(Double($0.offset) * 1_000 / Double(values.count - 1)), value: $0.element)
            }, interval: interval)
        }
        let zero = series([0, 0]), gain = series([100, 105, 102, 112, 108, 120]), loss = series([100, 94, 97, 90, 88, 80])
        func chart(_ series: BalanceChartSeries, hidden: Bool = false) -> some View {
            BalanceChartView(series: series, concealed: hidden, interactive: false,
                accessibilityLabel: "Balance history", accessibilityValue: "", hapticsEnabled: { false }, onSelection: { _ in })
        }
        func rendered(_ series: BalanceChartSeries, dark: Bool, hidden: Bool = false, width: CGFloat = 342, rtl: Bool = false) -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: chart(series, hidden: hidden).frame(width: width)
                .background(dark ? Color(white: 0.08) : .white)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: renderer.cgImage!)
        }
        var checks = 0
        for dark in [false, true] {
            for width: CGFloat in [272, 342, 652] {
                let neutral = rendered(zero, dark: dark, width: width)
                let positive = rendered(gain, dark: dark, width: width)
                let negative = rendered(loss, dark: dark, width: width)
                var gray = 0, green = 0, red = 0
                for y in 0..<neutral.pixelsHigh {
                    for x in 0..<neutral.pixelsWide {
                        let n = neutral.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        if abs(n.redComponent - n.greenComponent) < 0.01 { gray += 1 }
                        let p = positive.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        if p.greenComponent - p.redComponent > 0.03 { green += 1 }
                        let m = negative.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        if m.redComponent - m.greenComponent > 0.03 { red += 1 }
                    }
                }
                precondition(gray == neutral.pixelsHigh * neutral.pixelsWide, "Zero must be gray")
                precondition(green > 400 && red > 400, "Directional colors must remain visible")
                let hiddenGain = rendered(gain, dark: dark, hidden: true, width: width)
                let hiddenLoss = rendered(loss, dark: dark, hidden: true, width: width)
                precondition(hiddenGain.tiffRepresentation == hiddenLoss.tiffRepresentation, "Hidden chart leaked direction or shape")
                precondition(positive.pixelsHigh == 200 && negative.pixelsHigh == 200, "Data changed layout height")
                let rtl = rendered(gain, dark: dark, width: width, rtl: true)
                var maximumDifference: CGFloat = 0
                for y in 0..<rtl.pixelsHigh {
                    for x in 0..<rtl.pixelsWide {
                        let a = rtl.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        let b = positive.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        maximumDifference = max(maximumDifference, abs(a.redComponent - b.redComponent),
                            abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
                    }
                }
                precondition(maximumDifference <= 1.0 / 255 + 0.00001,
                    "Chronology changed in RTL: \(maximumDifference)")
                checks += 5
            }
        }
        func column(dark: Bool) -> some View {
            VStack(spacing: 20) {
                Text("Total Balance").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("$1,240.00").font(.system(size: 54, weight: .semibold)).monospacedDigit()
                Text("+$240.00  (24.00%) Today").font(.subheadline).foregroundStyle(.green)
                chart(gain)
                HStack {
                    Label("Send", systemImage: "paperplane")
                    Spacer()
                    Label("Receive", systemImage: "qrcode")
                }.font(.headline).padding(.horizontal, 28).padding(.vertical, 18)
                Divider()
                Text("Zero / unchanged").font(.caption).foregroundStyle(.secondary)
                chart(zero)
                Text("Negative change").font(.caption).foregroundStyle(.secondary)
                chart(loss)
            }
            .padding(24).frame(width: 390)
            .background(dark ? Color(white: 0.08) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        let renderer = ImageRenderer(content: HStack(spacing: 0) { column(dark: false); column(dark: true) })
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
        let output = CommandLine.arguments.dropFirst().first ?? "/tmp/oath-balance-chart-preview.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        print("Passed \(checks) host rendering checks; preview: \(output)")
    }
}
