import SwiftUI
import UIKit
import OathDiagnostics

/// Decorative native layers; wallet actions and text stay in SwiftUI. No video,
/// network artwork, per-frame SwiftUI state writes, or Metal startup dependency.
struct OathWelcomeArtwork: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let introduction: CGRect
    let icon: CGRect
    let topSafeAreaInset: CGFloat
    let active: Bool
    let reduceMotion: Bool
    let resumeSettled: Bool
    let onReveal: () -> Void

    func makeUIView(context: Context) -> OathWelcomeArtworkView {
        OathWelcomeArtworkView(settled: resumeSettled || reduceMotion,
                               style: colorScheme == .dark ? .dark : .light)
    }
    func updateUIView(_ view: OathWelcomeArtworkView, context: Context) {
        view.updateAppearance(style: colorScheme == .dark ? .dark : .light)
        view.configure(introduction: introduction, icon: icon, topSafeAreaInset: topSafeAreaInset, active: active,
                       reduceMotion: reduceMotion, onReveal: onReveal)
    }
    static func dismantleUIView(_ view: OathWelcomeArtworkView, coordinator: ()) { view.stop() }
}

final class OathWelcomeArtworkView: UIView {
    private let stream = CALayer()
    private let fade = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let halo = CAGradientLayer()
    private let brandGroup = CALayer()
    private let brandClip = CALayer()
    private let brand = CALayer()
    private let mark = CALayer()
    private var tiles: [CALayer] = []
    private var foldedTiles: [FoldedTile] = []
    private var displayLink: CADisplayLink?
    private let target = DisplayTarget()
    private var lastTimestamp: CFTimeInterval?
    private var elapsed: CFTimeInterval = 0
    private var introduction = CGRect.zero
    private var icon = CGRect.zero
    private var topSafeAreaInset: CGFloat = 0
    private var active = false
    private var reduceMotion = false
    private var revealed = false
    private var onReveal: (() -> Void)?
    private var appliedStyle: UIUserInterfaceStyle?

    init(settled: Bool, style: UIUserInterfaceStyle) {
        super.init(frame: .zero)
        if settled { elapsed = 6 }
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        target.view = self
        for light in [halo, glow] {
            light.type = .radial
            light.startPoint = CGPoint(x: 0.5, y: 0.5)
            light.endPoint = CGPoint(x: 1, y: 1)
        }
        layer.addSublayer(halo)
        layer.addSublayer(glow)
        updateAppearance(style: style)
        layer.addSublayer(stream)
        fade.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.018, 0.65, 1]
        stream.mask = fade

        // Use exactly the network artwork shown elsewhere in Oath, including
        // user-supplied Plasma, World Chain and Elysium designs.
        let featured: [OathImportChain] = [.bitcoin, .ethereum, .solana, .plasma, .worldchain, .elysium,
                                         .bnb, .polygon, .arbitrum, .avalanche, .base, .sui]
        let chains = featured + OathImportChain.enabledCases.filter { !featured.contains($0) }
        let images = chains.map { chain -> CGImage? in
            guard let image = OathNetworkLogo.renderedImage(asset: chain.logoAsset, size: 128, scale: 2)?.cgImage else {
                OathDiagnostics.record(ArtworkError.missingChainImage, component: "rendering", operation: "welcome_chain_image", context: ["chain": chain.rawValue])
                return nil
            }
            return image
        }
        for index in 0..<(OathWelcomeMotion.rows * OathWelcomeMotion.columns) {
            let tile = CALayer()
            tile.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
            tile.anchorPoint = .zero
            tile.contents = images[index % images.count]
            tile.contentsGravity = .resizeAspect
            tile.isDoubleSided = false
            stream.addSublayer(tile)
            tiles.append(tile)
        }
        // Both curls share this bounded mesh pool. Straight sections use one
        // layer per tile; all layers reference the same original textures.
        for _ in 0..<OathWelcomeMotion.foldedTileCapacity {
            let tile = FoldedTile()
            stream.addSublayer(tile.group)
            foldedTiles.append(tile)
        }
        brand.backgroundColor = UIColor(red: 0.145, green: 0.47, blue: 1, alpha: 1).cgColor
        brand.cornerCurve = .continuous
        layer.addSublayer(brandGroup)
        brandGroup.addSublayer(brand)
        // Only alpha matters for this mask; it is not a visible surface.
        brandClip.backgroundColor = UIColor.white.cgColor
        if let image = UIImage(named: OathAppIcon.signalBlue.preview)?.cgImage {
            mark.contents = image
        } else {
            OathDiagnostics.record(ArtworkError.missingBrandImage, component: "rendering", operation: "welcome_brand_image")
        }
        mark.contentsGravity = .resizeAspect
        mark.cornerCurve = .continuous
        mark.masksToBounds = true
        brandGroup.addSublayer(mark)
    }
    required init?(coder: NSCoder) { nil }

    func updateAppearance(style: UIUserInterfaceStyle) {
        guard appliedStyle != style else { return }
        appliedStyle = style
        let traits = UITraitCollection(userInterfaceStyle: style)
        let ink = UIColor.label.resolvedColor(with: traits)
        let dark = style == .dark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundColor = OathSurfaceColors.canvas.resolvedColor(with: traits)
        // CGColors are resolved values, so refresh them when SwiftUI's scene
        // appearance changes, including while Reduce Motion stops the clock.
        // Light mode uses quiet neutral depth; dark mode retains the light.
        let transparentInk = ink.withAlphaComponent(0).cgColor
        halo.colors = [ink.withAlphaComponent(dark ? 0.30 : 0.06).cgColor, transparentInk]
        glow.colors = [ink.withAlphaComponent(dark ? 0.58 : 0.10).cgColor, transparentInk]
        CATransaction.commit()
    }

    func configure(introduction: CGRect, icon: CGRect, topSafeAreaInset: CGFloat, active: Bool,
                   reduceMotion: Bool, onReveal: @escaping () -> Void) {
        self.introduction = introduction
        self.icon = icon
        self.topSafeAreaInset = topSafeAreaInset
        self.active = active
        self.reduceMotion = reduceMotion
        self.onReveal = onReveal
        if reduceMotion { elapsed = max(6, elapsed) }
        setNeedsLayout()
        updateClock()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        render()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateClock()
    }

    private func updateClock() {
        guard active, window != nil, !reduceMotion else { stop(); return }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }
    fileprivate func tick(_ link: CADisplayLink) {
        if let previous = lastTimestamp { elapsed += max(0, link.targetTimestamp - previous) }
        lastTimestamp = link.targetTimestamp
        render()
    }

    private func render() {
        guard OathLayoutGeometry.isUsable(bounds), OathLayoutGeometry.isUsable(icon),
              OathLayoutGeometry.isUsable(introduction) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stream.frame = bounds
        // The lower fade ends before the copy: logos never compete with it.
        let stage = OathWelcomeMotion.Stage(introduction: introduction, icon: icon, topSafeAreaInset: topSafeAreaInset)
        fade.frame = stage.frame
        glow.bounds = CGRect(x: 0, y: 0, width: stage.frame.width * 0.48, height: stage.frame.width * 0.22)
        halo.bounds = CGRect(x: 0, y: 0, width: stage.frame.width * 0.90, height: stage.frame.width * 0.55)
        glow.position = stage.lightCenter
        halo.position = stage.lightCenter
        glow.opacity = OathWelcomeMotion.glowOpacity(time: elapsed)
        halo.opacity = glow.opacity
        let surface = OathWelcomeMotion.Surface(size: stage.frame.size)
        let origin = CGPoint(x: stage.frame.midX, y: stage.frame.minY)
        let advance = surface.advance(time: elapsed)
        let entranceOpacity = Float(OathWelcomeMotion.smooth((elapsed - OathWelcomeMotion.streamStart) / 0.12))
        var foldedCount = 0
        for (index, layer) in tiles.enumerated() {
            let column = index % 3
            let position = surface.position(row: index / 3, column: column, advance: advance)
            let tile = surface.tile(position: position, column: column)
            guard entranceOpacity > 0, tile.point(x: 0, y: 0).y < stage.frame.height,
                  tile.point(x: 0, y: 1).y > 0 else {
                layer.isHidden = true
                continue
            }
            if surface.isFolded(position: position), foldedCount < foldedTiles.count {
                layer.isHidden = true
                let folded = foldedTiles[foldedCount]
                foldedCount += 1
                folded.group.isHidden = false
                folded.group.position = origin
                folded.group.opacity = entranceOpacity
                if folded.sourceIndex != index {
                    for strip in folded.strips { strip.contents = layer.contents }
                    folded.sourceIndex = index
                }
                for strip in folded.strips {
                    let range = strip.contentsRect
                    let projection = surface.tile(position: position, column: column,
                                                  from: range.minY, to: range.maxY)
                    strip.transform = transform(for: projection)
                }
            } else {
                layer.isHidden = false
                layer.position = origin
                layer.transform = transform(for: tile)
                layer.opacity = entranceOpacity
            }
        }
        for index in foldedCount..<foldedTiles.count {
            foldedTiles[index].group.isHidden = true
        }
        let frame = OathWelcomeMotion.iconFrame(time: elapsed, bounds: bounds, destination: icon)
        brandGroup.frame = bounds
        brandClip.frame = introduction
        brandGroup.mask = elapsed >= 2.6 ? brandClip : nil
        brand.frame = frame
        brand.cornerRadius = min(icon.width * 0.225, frame.width * 0.225)
        let markWidth = min(icon.width, frame.width)
        mark.frame = CGRect(x: frame.midX - markWidth / 2, y: frame.midY - markWidth / 2,
                            width: markWidth, height: markWidth)
        mark.cornerRadius = markWidth * 0.225
        CATransaction.commit()
        if !revealed, elapsed >= OathWelcomeMotion.revealTime {
            revealed = true
            // layoutSubviews may run inside a SwiftUI update. Publish only once,
            // on the next main-loop turn; never publish animation frames.
            DispatchQueue.main.async { [weak self] in self?.onReveal?() }
        }
    }
    private func transform(for tile: OathWelcomeMotion.Tile) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m11 = tile.width / 100
        transform.m22 = tile.vertical / 100
        transform.m41 = tile.x
        transform.m42 = tile.travel
        transform.m24 = -tile.perspective / 100
        return transform
    }

    @MainActor private final class FoldedTile {
        let group = CALayer()
        let strips: [CALayer]
        var sourceIndex: Int?

        init() {
            group.anchorPoint = .zero
            group.isHidden = true
            strips = (0..<OathWelcomeMotion.stripsPerTile).map { index in
                let strip = CALayer()
                strip.anchorPoint = .zero
                strip.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
                // Subpixel overlap avoids hairline seams between projected
                // strips. Matching source and surface intervals keeps the
                // artwork continuous, including its original rounded corners.
                let start = max(0, CGFloat(index) / CGFloat(OathWelcomeMotion.stripsPerTile) - 0.001)
                let end = min(1, CGFloat(index + 1) / CGFloat(OathWelcomeMotion.stripsPerTile) + 0.001)
                strip.contentsRect = CGRect(x: 0, y: start, width: 1, height: end - start)
                strip.contentsGravity = .resize
                strip.isDoubleSided = false
                return strip
            }
            for strip in strips { group.addSublayer(strip) }
        }
    }
    private enum ArtworkError: Error { case missingChainImage, missingBrandImage }
    @MainActor private final class DisplayTarget: NSObject {
        weak var view: OathWelcomeArtworkView?
        @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
    }
}
