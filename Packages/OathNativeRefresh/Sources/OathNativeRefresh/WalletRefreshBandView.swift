import UIKit

private final class WalletGradientSurface: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}

/// The gradient pools and spinner animate on the render server during the hold.
@MainActor final class WalletRefreshBandView: UIView {
    private let band: WalletGradientSurface
    private let aurora: WalletRefreshAurora
    private let spinner = UIView()
    private var spokes: [CAShapeLayer] = []
    private let trail: [Float] = [0.88, 0.59, 0.39, 0.27, 0.20, 0.16, 0.14, 0.12]
    private var walletColor: UIColor?
    private var travel: CGFloat = 0
    private var pullFraction: CGFloat = 0
    private var holding = false
    private var spinning = false
    var isSettling = false {
        didSet {
            if !isSettling && spinner.alpha == 0 { updateSpinning(false) }
        }
    }

    override init(frame: CGRect) {
        let base = WalletGradientSurface(), cool = WalletGradientSurface(), warm = WalletGradientSurface()
        band = base
        aurora = WalletRefreshAurora(base: base.gradient, cool: cool.gradient, warm: warm.gradient)
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        band.accessibilityIdentifier = "refresh.walletBand"
        band.clipsToBounds = true
        addSubview(band)
        for pool in [cool, warm] {
            pool.isOpaque = false
            pool.frame = band.bounds
            pool.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            band.addSubview(pool)
        }
        let diameter = WalletRefreshMotion.spinnerDiameter
        spinner.bounds.size = CGSize(width: diameter, height: diameter)
        spinner.layer.name = "refresh.spokes"
        band.addSubview(spinner)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: diameter / 2, y: 2))
        path.addLine(to: CGPoint(x: diameter / 2, y: 9))
        for index in 0..<WalletRefreshMotion.spokeCount {
            let spoke = CAShapeLayer()
            spoke.frame = spinner.bounds
            spoke.path = path.cgPath
            spoke.fillColor = nil
            spoke.lineWidth = 4
            spoke.lineCap = .round
            spoke.strokeColor = UIColor.white.cgColor
            spoke.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(index) * .pi / 4))
            spoke.opacity = trail[(trail.count - index) % trail.count]
            spinner.layer.addSublayer(spoke)
            spokes.append(spoke)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (view: Self, _) in
            view.applyWalletColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func setColor(_ color: UIColor) {
        guard walletColor != color else { return }
        walletColor = color
        applyWalletColor()
    }

    private func applyWalletColor() {
        guard let color = walletColor else { return }
        let resolved = color.resolvedColor(with: traitCollection)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            UIColor.systemBlue.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        let ink = aurora.setColor(red: red, green: green, blue: blue)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for spoke in spokes { spoke.strokeColor = ink }
        CATransaction.commit()
    }

    var safeTop: CGFloat {
        // A sheet starts below the status bar. A full-screen stack starts at
        // the screen edge and reveals color behind the system status items.
        window.map {
            max(0, convert(CGPoint(x: 0, y: $0.bounds.minY + $0.safeAreaInsets.top), from: $0).y)
        } ?? safeAreaInsets.top
    }

    var displayedTravel: CGFloat {
        let height = (band.layer.presentation() ?? band.layer).bounds.height
        return WalletRefreshMotion.travel(forBandHeight: height, safeTop: safeTop)
    }

    func setTravel(_ value: CGFloat, followingPull: Bool) {
        travel = value
        if followingPull {
            holding = false
            pullFraction = value / WalletRefreshMotion.hold
            updateAurora()
        }
        updateGeometry()
    }

    func setHolding(_ active: Bool) {
        holding = active
        if !active { pullFraction = 0 }
        updateAurora()
    }

    private func updateAurora() {
        aurora.update(pullFraction: pullFraction, holding: holding,
                      motionAllowed: window != nil && !UIAccessibility.isReduceMotionEnabled)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometry()
    }

    private func updateGeometry() {
        let layout = WalletRefreshMotion.Layout(travel: travel, safeTop: safeTop)
        band.frame = CGRect(x: 0, y: 0, width: bounds.width, height: layout.height)
        spinner.center = CGPoint(x: bounds.midX, y: layout.spinnerY)
        spinner.alpha = layout.opacity
        // The model alpha reaches zero at the start of a UIKit fade. Keep the
        // spokes stepping until the visible indicator has finished returning.
        let visible = layout.opacity > 0 || (isSettling && spinning)
        updateSpinning(visible && window != nil && !UIAccessibility.isReduceMotionEnabled)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { updateSpinning(false) }
        updateAurora()
        setNeedsLayout()
    }

    @objc private func motionPreferenceChanged() {
        updateAurora()
        setNeedsLayout()
    }

    private func updateSpinning(_ enabled: Bool) {
        guard spinning != enabled else { return }
        spinning = enabled
        let count = spokes.count
        let times = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        let start = spinner.layer.convertTime(CACurrentMediaTime(), from: nil)
        for (index, spoke) in spokes.enumerated() {
            if enabled {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.values = (0...count).map { NSNumber(value: trail[($0 + count - index) % count]) }
                animation.keyTimes = times
                animation.calculationMode = .discrete
                animation.duration = WalletRefreshMotion.stepDuration * Double(count)
                animation.beginTime = start
                animation.repeatCount = .infinity
                spoke.add(animation, forKey: "refresh.step")
            } else {
                spoke.removeAnimation(forKey: "refresh.step")
            }
        }
    }
}
