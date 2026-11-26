import Foundation
import QuartzCore

/// Unit coordinates keep both pools in proportion as the refresh band stretches.
@MainActor final class WalletRefreshAurora {
    private enum Pool {
        case cool, warm

        var radius: CGSize {
            switch self {
            case .cool: CGSize(width: 0.72, height: 1.33)
            case .warm: CGSize(width: 0.63, height: 1.02)
            }
        }

        func center(phase: CGFloat) -> CGPoint {
            let angle = phase * 2 * .pi
            switch self {
            case .cool:
                return CGPoint(x: 0.18 + 0.25 * sin(angle), y: 0.61 + 0.39 * cos(angle))
            case .warm:
                return CGPoint(x: 0.76 + 0.21 * cos(angle + 0.65), y: 0.35 + 0.38 * sin(angle + 0.35))
            }
        }

        func end(from center: CGPoint) -> CGPoint {
            CGPoint(x: center.x + radius.width, y: center.y + radius.height)
        }
    }

    private let base: CAGradientLayer
    private let pools: [(Pool, CAGradientLayer)]
    private var lastPhase: CGFloat?
    private var drifting = false

    init(base: CAGradientLayer, cool: CAGradientLayer, warm: CAGradientLayer) {
        self.base = base
        pools = [(.cool, cool), (.warm, warm)]
        base.startPoint = CGPoint(x: 0, y: 0.9)
        base.endPoint = CGPoint(x: 1, y: 0)
        for (_, layer) in pools {
            layer.type = .radial
            layer.locations = [0, 0.36, 0.72, 1]
        }
    }

    /// Returns the spinner ink for the same contrast range as the gradient.
    func setColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGColor {
        let rgb = SIMD3<Double>(Double(red), Double(green), Double(blue)).clamped(lowerBound: .zero, upperBound: .one)
        let darkInk = Self.luminance(rgb) > 0.185
        let high = rgb.max(), low = rgb.min(), delta = high - low
        let lightness = (high + low) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        let hue: Double
        if delta == 0 { hue = 0 }
        else if high == rgb.x { hue = (rgb.y - rgb.z) / delta }
        else if high == rgb.y { hue = (rgb.z - rgb.x) / delta + 2 }
        else { hue = (rgb.x - rgb.y) / delta + 4 }

        func tone(hueOffset: Double, lightnessOffset: Double, saturationBoost: Double = 0) -> SIMD3<Double> {
            let h = (hue / 6 + hueOffset / 360 + 1).truncatingRemainder(dividingBy: 1)
            let l = min(0.87, max(0.12, lightness + lightnessOffset))
            let s = saturation < 0.08 ? saturation : min(1, saturation + saturationBoost)
            func channel(_ offset: Double) -> Double {
                let k = (offset + h * 12).truncatingRemainder(dividingBy: 12)
                return l - s * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1))
            }
            var color = SIMD3(channel(0), channel(8), channel(4))
            for _ in 0..<24 {
                let luminance = Self.luminance(color)
                if darkInk ? luminance >= 0.225 : luminance <= 0.18 { break }
                color = darkInk ? color + (SIMD3.one - color) * 0.055 : color * 0.955
            }
            return color
        }

        func paint(_ color: SIMD3<Double>, alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: alpha)
        }

        let cool = tone(hueOffset: -43, lightnessOffset: -0.025, saturationBoost: 0.17)
        let warm = tone(hueOffset: 38, lightnessOffset: 0.015, saturationBoost: 0.09)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.colors = [paint(tone(hueOffset: 3, lightnessOffset: -0.10)),
                       paint(tone(hueOffset: 0, lightnessOffset: 0)),
                       paint(tone(hueOffset: 9, lightnessOffset: -0.18))]
        for (pool, layer) in pools {
            let color = pool == .cool ? cool : warm
            layer.colors = [1, 0.89, 0.35, 0].map { paint(color, alpha: $0) }
        }
        CATransaction.commit()
        return CGColor(gray: darkInk ? 0 : 1, alpha: 1)
    }

    private static func luminance(_ rgb: SIMD3<Double>) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.x) + 0.7152 * linear(rgb.y) + 0.0722 * linear(rgb.z)
    }

    func update(pullFraction: CGFloat, holding: Bool, motionAllowed: Bool) {
        let shouldDrift = holding && motionAllowed
        if shouldDrift && drifting { return }
        let pullPhase = 0.04 + 0.15 * min(1.22, max(0, pullFraction))
        let phase = motionAllowed ? (shouldDrift ? lastPhase ?? pullPhase : pullPhase) : 0.46
        guard shouldDrift != drifting || phase != lastPhase else { return }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (pool, layer) in pools {
            let center = pool.center(phase: phase)
            layer.startPoint = center
            layer.endPoint = pool.end(from: center)
            if shouldDrift {
                let centers = (0...32).map { pool.center(phase: phase + CGFloat($0) / 32) }
                let start = layer.convertTime(now, from: nil)
                func animate(_ property: String, through points: [CGPoint]) {
                    let animation = CAKeyframeAnimation(keyPath: property)
                    animation.values = points
                    animation.calculationMode = .linear
                    animation.duration = 2 / 0.74
                    animation.beginTime = start
                    animation.repeatCount = .infinity
                    layer.add(animation, forKey: property)
                }
                animate("startPoint", through: centers)
                animate("endPoint", through: centers.map(pool.end(from:)))
            } else if drifting {
                layer.removeAnimation(forKey: "startPoint")
                layer.removeAnimation(forKey: "endPoint")
            }
        }
        CATransaction.commit()
        lastPhase = phase
        drifting = shouldDrift
    }
}
