import SwiftUI

/// Native, background-free balance ribbon. Only data and user interactions animate;
/// there is no perpetual timer, shimmer or decorative fabricated price history.
public struct BalanceChartView: View {
    public let series: BalanceChartSeries
    public let concealed: Bool
    public let interactive: Bool
    public let accessibilityLabel: String
    public let accessibilityValue: String
    public let hapticsEnabled: @MainActor () -> Bool
    public let onSelection: (BalanceChartSelection?) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedIndex: Int?
    @State private var scrubbingSeries: BalanceChartSeries?
    #if os(iOS)
    @StateObject private var haptics = BalanceChartHaptics()
    #endif

    public init(series: BalanceChartSeries, concealed: Bool = false, interactive: Bool = true,
                accessibilityLabel: String, accessibilityValue: String,
                hapticsEnabled: @escaping @MainActor () -> Bool = { true },
                onSelection: @escaping (BalanceChartSelection?) -> Void) {
        self.series = series; self.concealed = concealed; self.interactive = interactive
        self.accessibilityLabel = accessibilityLabel; self.accessibilityValue = accessibilityValue
        self.hapticsEnabled = hapticsEnabled; self.onSelection = onSelection
    }

    public var body: some View {
        GeometryReader { geometry in
            let count = min(120, max(2, Int(geometry.size.width / 6)))
            let ticks = displaySeries.ticks(count: count)
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.index) { tick in
                    let selected = selectedIndex == tick.index && !concealed
                    let distance = abs((selectedIndex ?? -100) - tick.index)
                    let proximity = concealed ? 0 : max(0, 1 - Double(distance) / 5)
                    let top = 20 - tick.displacement * 16
                    let height = 60 + proximity * 6
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(LinearGradient(stops: [
                            .init(color: tint(tick).opacity(selected ? 1 : 0.44 + proximity * 0.30), location: 0),
                            .init(color: tint(tick).opacity(selected ? 0.7 : 0.20), location: 0.4),
                            .init(color: tint(tick).opacity(0), location: 1)
                        ], startPoint: .top, endPoint: .bottom))
                        .frame(width: selected ? 2.5 : 1.75, height: height)
                        .shadow(color: tint(tick).opacity(selected ? 0.35 : 0), radius: 4)
                        .position(x: 2 + Double(tick.index) / Double(count - 1) * max(0, geometry.size.width - 4),
                                  y: top + height / 2 - proximity * 3)
                        .animation(reduceMotion || concealed ? nil : .smooth(duration: 0.35), value: tick.displacement)
                }
                #if os(iOS)
                BalanceChartTouchSurface(enabled: interactive && !concealed,
                    onMove: { fraction in
                        select(Int((fraction * Double(count - 1)).rounded()), ticks: ticks)
                    }, onEnd: endSelection)
                #else
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard interactive, !concealed, abs(value.translation.width) > abs(value.translation.height) else { return }
                        select(Int((min(1, max(0, value.location.x / max(1, geometry.size.width))) * Double(count - 1)).rounded()), ticks: ticks)
                    }.onEnded { _ in endSelection() })
                #endif
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                guard interactive, !concealed else { return }
                let current = selectedIndex ?? count - 1
                switch direction {
                case .increment: select(min(count - 1, current + 1), ticks: ticks)
                case .decrement: select(max(0, current - 1), ticks: ticks)
                @unknown default: break
                }
            }
            .accessibilityAction(.escape) { endSelection() }
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(height: 100)
        .onAppear {
            #if os(iOS)
            if interactive && hapticsEnabled() && !concealed { haptics.prepare() }
            #endif
        }
        .onChange(of: concealed) { _, _ in endSelection() }
        .onChange(of: interactive) { _, active in if !active { endSelection() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { endSelection() } }
        .onDisappear { endSelection() }
    }

    private var displaySeries: BalanceChartSeries {
        concealed ? BalanceChartSeries(points: [], interval: series.interval) : (scrubbingSeries ?? series)
    }
    private func tint(_ tick: BalanceChartTick) -> Color {
        if selectedIndex == tick.index && !concealed { return .primary }
        guard !concealed else { return .secondary }
        switch tick.direction {
        case 1: return colorScheme == .dark ? Color(red: 0.61, green: 0.96, blue: 0.75) : Color(red: 0.05, green: 0.52, blue: 0.36)
        case -1: return colorScheme == .dark ? Color(red: 1, green: 0.67, blue: 0.69) : Color(red: 0.84, green: 0.17, blue: 0.25)
        default: return .secondary
        }
    }
    private func select(_ index: Int, ticks: [BalanceChartTick]) {
        guard ticks.indices.contains(index), selectedIndex != index else { return }
        if scrubbingSeries == nil { scrubbingSeries = series }
        selectedIndex = index
        onSelection(displaySeries.selection(at: Double(index) / Double(ticks.count - 1)))
        #if os(iOS)
        haptics.tick(ticks[index], enabled: hapticsEnabled())
        #endif
    }
    private func endSelection() {
        selectedIndex = nil; scrubbingSeries = nil; onSelection(nil)
        #if os(iOS)
        haptics.end()
        #endif
    }
}
