import SwiftUI
import UIKit
import OathNativeRefresh

@main struct WalletBandPlacementApp: App {
    var body: some Scene { WindowGroup { WalletBandPlacement() } }
}

private struct WalletBandPlacement: View {
    @State private var taps = 0
    @State private var toolbarTaps = 0
    @State private var starts = 0
    @State private var completed = 0
    private let pale = ProcessInfo.processInfo.arguments.contains("--pale")

    var body: some View {
        TabView {
            Tab("Wallet", systemImage: "wallet.bifold") {
                NavigationStack {
                    GeometryReader { geometry in
                        NativeRefreshScroll(identifier: "probe.scroll",
                            tint: pale ? UIColor(red: 1, green: 0.85, blue: 0.35, alpha: 1)
                                       : UIColor(red: 0.14, green: 0.30, blue: 0.88, alpha: 1),
                            indicator: .walletBand, timing: .walletBand, refreshIdentity: "fixture",
                            action: {
                                BandSampler.activated = CACurrentMediaTime()
                                starts += 1
                                try await Task.sleep(for: .seconds(6))
                                completed += 1
                            }, onFailure: {}, onScroll: { _ in }) {
                                Button { taps += 1 } label: {
                                    Text("Receive \(taps)")
                                        .frame(maxWidth: .infinity).frame(height: 48)
                                        .background(WalletBandTrace(pale: pale))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("receive")
                                // Exercise resizing the empty section as the
                                // toolbar moves and inserting assets mid-pull.
                                Text("Requests \(starts) · Completed \(completed)")
                                    .accessibilityIdentifier("work")
                                    .frame(minHeight: pale && starts == 0 ? max(0, geometry.size.height - 48) : 0,
                                           alignment: .top)
                                if !pale || starts > 0 {
                                    ForEach(0..<24) { index in Text("Asset \(index)").frame(height: 52) }
                                }
                            }
                    }
                    .safeAreaInset(edge: .bottom) {
                        Text("Search domain").frame(maxWidth: .infinity).frame(height: 42)
                            .background(.bar).accessibilityIdentifier("address")
                    }
                    .navigationTitle("Wallet")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("History \(toolbarTaps)") { toolbarTaps += 1 }.accessibilityIdentifier("history")
                        }
                    }
                }.walletRefreshNavigation()
            }
            Tab("Explore", systemImage: "safari") { Text("Explore") }
        }
        .preferredColorScheme(pale ? .dark : .light)
    }
}

// Sample the synthetic fixture in display coordinates, including the real
// navigation bar. No callbacks or instrumentation are added to the package.
private struct WalletBandTrace: UIViewRepresentable {
    let pale: Bool
    func makeUIView(context: Context) -> BandSampler { BandSampler(pale: pale) }
    func updateUIView(_ view: BandSampler, context: Context) {}
}

@MainActor private final class BandSampler: UIView {
    static var activated: CFTimeInterval = 0
    private let file: URL
    private weak var bar: UINavigationBar?
    private weak var list: UIScrollView?
    private weak var band: UIView?
    private var link: CADisplayLink?
    private var trace = "t,activated,pan,finger,overscroll,bar,bandTop,bandHeight,spinnerY,opacity,row,step,ink,coolX,warmX,edgeError\n"
    private var count = 0

    init(pale: Bool) {
        file = URL.temporaryDirectory.appending(path: pale ? "band-dark.csv" : "band-light.csv")
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil {
            let link = CADisplayLink(target: self, selector: #selector(sample))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private func find(in view: UIView) {
        if let nav = view as? UINavigationBar { bar = nav }
        if view.accessibilityIdentifier == "probe.scroll", let scroll = view as? UIScrollView { list = scroll }
        if view.accessibilityIdentifier == "refresh.walletBand" { band = view }
        for child in view.subviews { find(in: child) }
    }

    @objc private func sample() {
        guard let window, count < 2400 else { return }
        if bar == nil || list == nil || band == nil { find(in: window) }
        guard let bar, let list, let band else { return }
        let pan = list.panGestureRecognizer
        func displayedFrame(_ view: UIView) -> CGRect {
            if let layer = view.layer.presentation(), let root = window.layer.presentation() {
                return layer.convert(layer.bounds, to: root)
            }
            return view.convert(view.bounds, to: window)
        }
        let strip = displayedFrame(band)
        let pools = (band.layer.sublayers ?? []).compactMap { $0 as? CAGradientLayer }
            .filter { $0.type == .radial }.map { $0.presentation() ?? $0 }
        let edgeError = pools.map { pool in
            max(abs(pool.frame.minX), abs(pool.frame.minY),
                abs(pool.frame.maxX - strip.width), abs(pool.frame.maxY - strip.height))
        }.max() ?? .infinity
        let spinnerLayer = band.layer.sublayers?.first { $0.name == "refresh.spokes" }
        let spinner = spinnerLayer?.presentation() ?? spinnerLayer
        let firstRow = displayedFrame(self).midY
        let segments = spinnerLayer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        let step = segments.indices.max { (segments[$0].presentation()?.opacity ?? 0) < (segments[$1].presentation()?.opacity ?? 0) } ?? -1
        let ink = segments.first?.strokeColor.flatMap { UIColor(cgColor: $0).cgColor.components?.first } ?? -1
        let values: [Double] = [CACurrentMediaTime(), Self.activated, Double(pan.state.rawValue),
                      pan.translation(in: window).y, -list.contentOffset.y - list.adjustedContentInset.top,
                      displayedFrame(bar).minY, strip.minY, strip.height,
                      (spinner?.position.y ?? 0) + strip.minY, Double(spinner?.opacity ?? 0), firstRow, Double(step), ink,
                      Double(pools.first?.startPoint.x ?? -1), pools.count == 2 ? pools[1].startPoint.x : -1, edgeError]
        trace += values.map { String(format: "%.4f", $0) }.joined(separator: ",") + "\n"
        count += 1
        if count.isMultiple(of: 30) { try? trace.write(to: file, atomically: true, encoding: .utf8) }
    }
}
