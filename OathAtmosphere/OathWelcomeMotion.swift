import Foundation
import CoreGraphics

/// Entrance timing measured from all 675 frames of the supplied 59.82 fps clip.
/// The settled flow is deliberately slower so the logos remain easy to look at.
/// Geometry is independent of display refresh rate and testable without UIKit.
enum OathWelcomeMotion {
    static let revealTime = 1.85
    static let streamStart = 2.55
    static let rows = 28
    static let columns = 3
    static let rowSpacing = 1.12
    // Keep the opening rush, then ease into a calm, continuous paper flow.
    static let rowsPerSecond = 0.4
    static let bendRadius = 0.75
    static let stripsPerTile = 16
    static let openingScale = 0.30
    private static let focalWidth = 2.4
    private static let rearDepth = focalWidth * (1 / openingScale - 1)
    private static let maximumUpperRise = rearDepth - bendRadius - 0.5
    // Include every tile intersecting either curl, even in a tall/narrow pane.
    // Texture layers are pooled once, not created while the paper is moving.
    static let foldedTileCapacity = columns * (
        Int(ceil((maximumUpperRise / Double(Bend.extent) + 1) / rowSpacing)) +
        Int(ceil((bendRadius / Double(Bend.extent) + 1) / rowSpacing)) + 2
    )

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    static func smooth(_ value: Double) -> Double {
        let p = clamp(value)
        return p * p * (3 - 2 * p)
    }

    static func glowOpacity(time: Double) -> Float {
        // Frames 149–186: the light rises once, then remains steady.
        let time = time.isFinite ? time : 0
        return Float(sin(clamp((time - 2.48) / 0.62) * .pi / 2))
    }

    struct Stage {
        let frame: CGRect
        let lightCenter: CGPoint
        init(introduction: CGRect, icon: CGRect, topSafeAreaInset: CGFloat) {
            let inset = topSafeAreaInset.isFinite ? max(0, topSafeAreaInset) : 0
            let top = max(0, max(inset - 12, introduction.minY - 12))
            let end = min(introduction.maxY, icon.maxY + 50)
            frame = CGRect(x: introduction.minX, y: top, width: introduction.width,
                           height: max(1, end - top))
            lightCenter = CGPoint(x: frame.midX, y: top - 15)
        }
    }

    struct Tile {
        let perspective: CGFloat
        let width: CGFloat
        let travel: CGFloat
        let vertical: CGFloat
        let x: CGFloat

        func point(x: CGFloat, y: CGFloat) -> CGPoint {
            let divisor = 1 - perspective * y
            return CGPoint(x: (self.x + width * x) / divisor, y: (travel + vertical * y) / divisor)
        }
    }

    /// Unit-length, eased 90-degree turn. Integrating the tangent gives real
    /// arc-length spacing; zero angular velocity at both ends makes the paper
    /// join its neighbouring planes without a kink or sudden curvature change.
    private enum Bend {
        static let count = 256
        static let points: [CGPoint] = {
            var points = [CGPoint.zero]
            let step = 1 / CGFloat(count)
            for index in 0..<count {
                let a = tangent(CGFloat(index) * step)
                let b = tangent((CGFloat(index) + 0.5) * step)
                let c = tangent(CGFloat(index + 1) * step)
                let last = points[points.count - 1]
                points.append(CGPoint(x: last.x + step * (a.x + 4 * b.x + c.x) / 6,
                                      y: last.y + step * (a.y + 4 * b.y + c.y) / 6))
            }
            return points
        }()
        static var extent: CGFloat { points[count].x }
        static func tangent(_ t: CGFloat) -> CGPoint {
            let angle = CGFloat(smooth(Double(t))) * .pi / 2
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        static func point(_ fraction: CGFloat) -> CGPoint {
            let t = CGFloat(clamp(Double(fraction))) * CGFloat(count)
            let index = min(count - 1, Int(t))
            let p = t - CGFloat(index)
            let step = 1 / CGFloat(count)
            let a = points[index], b = points[index + 1]
            let da = tangent(CGFloat(index) * step), db = tangent(CGFloat(index + 1) * step)
            let h0 = 2 * p * p * p - 3 * p * p + 1
            let h1 = p * p * p - 2 * p * p + p
            let h2 = -2 * p * p * p + 3 * p * p
            let h3 = p * p * p - p * p
            return CGPoint(x: h0 * a.x + h1 * step * da.x + h2 * b.x + h3 * step * db.x,
                           y: h0 * a.y + h1 * step * da.y + h2 * b.y + h3 * step * db.y)
        }
    }

    /// Measured lower edge of the leading row, relative to the opening/fade.
    /// PCHIP preserves forward motion while matching the reference frames.
    private static let entrance = MonotoneTrack(
        times: [streamStart, 2.75, 3.0, 3.25, 3.5],
        values: [0, 0.08, 0.22, 0.52, 0.90]
    )

    private struct MonotoneTrack: Sendable {
        let times: [Double]
        let values: [Double]
        let slopes: [Double]
        init(times: [Double], values: [Double]) {
            self.times = times
            self.values = values
            let h = (1..<times.count).map { times[$0] - times[$0 - 1] }
            let d = (1..<times.count).map { (values[$0] - values[$0 - 1]) / h[$0 - 1] }
            var slopes = [max(0, min(3 * d[0], ((2 * h[0] + h[1]) * d[0] - h[0] * d[1]) / (h[0] + h[1])))]
            for i in 1..<(times.count - 1) {
                let w1 = 2 * h[i] + h[i - 1], w2 = h[i] + 2 * h[i - 1]
                slopes.append((w1 + w2) / (w1 / d[i - 1] + w2 / d[i]))
            }
            let n = d.count - 1
            slopes.append(max(0, min(3 * d[n], ((2 * h[n] + h[n - 1]) * d[n] - h[n] * d[n - 1]) / (h[n] + h[n - 1]))))
            self.slopes = slopes
        }
        func sample(_ time: Double) -> (value: Double, speed: Double) {
            let i = min(times.count - 2, max(0, (times.firstIndex { $0 > time } ?? times.count) - 1))
            let h = times[i + 1] - times[i]
            let p = clamp((time - times[i]) / h)
            let p2 = p * p, p3 = p2 * p
            let value = (2 * p3 - 3 * p2 + 1) * values[i] + (p3 - 2 * p2 + p) * h * slopes[i]
                + (-2 * p3 + 3 * p2) * values[i + 1] + (p3 - p2) * h * slopes[i + 1]
            let speed = ((6 * p2 - 6 * p) * values[i] + (3 * p2 - 4 * p + 1) * h * slopes[i]
                + (-6 * p2 + 6 * p) * values[i + 1] + (3 * p2 - 2 * p) * h * slopes[i + 1]) / h
            return (value, speed)
        }
    }

    struct Surface {
        let width: CGFloat
        let height: CGFloat
        let radius: CGFloat
        let upperRise: CGFloat
        let depth: CGFloat
        let focalLength: CGFloat
        let upperLength: CGFloat
        let middleStart: CGFloat
        let frontStart: CGFloat
        var middleLength: CGFloat { radius / Bend.extent }
        var frontY: CGFloat { upperRise + radius }
        var recyclePosition: Double {
            Double((frontStart + height + width - frontY) / width)
        }

        init(size: CGSize) {
            let size = OathLayoutGeometry.finiteSize(size)
            width = max(1, size.width * 0.35)
            height = max(1, size.height)
            radius = width * bendRadius
            depth = width * rearDepth
            upperRise = min(height * 0.34, width * maximumUpperRise)
            focalLength = width * focalWidth
            upperLength = upperRise / Bend.extent
            middleStart = upperLength + depth - upperRise - radius
            frontStart = middleStart + radius / Bend.extent
        }

        func advance(time: Double) -> Double {
            let time = time.isFinite ? max(0, time) : 0
            guard time > streamStart else { return -0.5 }
            if time < 3.5 {
                return Double(path(projectedY: height * entrance.sample(time).value) / width) - 0.5
            }
            let end = entrance.sample(3.5)
            let endPath = path(projectedY: height * end.value)
            let initialSpeed = Double(height / width / projected(path: endPath).slope) * end.speed
            let p = min(1, time - 3.5)
            // Integral of smoothstep velocity: match the entrance derivative,
            // decelerate without a discontinuity, then cruise from 4.5 seconds.
            let distance = initialSpeed * p + (rowsPerSecond - initialSpeed) * (p * p * p - p * p * p * p / 2)
            return Double(endPath / width) - 0.5 + distance + max(0, time - 4.5) * rowsPerSecond
        }

        func position(row: Int, column: Int, advance: Double) -> Double {
            let stagger = column == 1 ? 0.52 : 0
            let raw = advance - Double(row) * rowSpacing - stagger
            let cycle = Double(rows) * rowSpacing
            guard raw > recyclePosition else { return raw }
            return raw - ceil((raw - recyclePosition) / cycle) * cycle
        }

        func isFolded(position: Double) -> Bool {
            let top = (position - 0.5) * width, bottom = (position + 0.5) * width
            return (bottom > 0 && top < upperLength) || (bottom > middleStart && top < frontStart)
        }

        func projected(path: CGFloat) -> (scale: CGFloat, y: CGFloat, slope: CGFloat) {
            let y: CGFloat, z: CGFloat, dy: CGFloat, dz: CGFloat
            if path < 0 {
                y = path; z = -depth; dy = 1; dz = 0
            } else if path < upperLength {
                let t = path / upperLength
                let p = Bend.point(t), tangent = Bend.tangent(t)
                y = p.x * upperLength; z = -depth + p.y * upperLength
                dy = tangent.x; dz = tangent.y
            } else if path < middleStart {
                y = upperRise; z = -depth + upperRise + path - upperLength
                dy = 0; dz = 1
            } else if path < frontStart {
                let t = (path - middleStart) / middleLength
                let p = Bend.point(t), tangent = Bend.tangent(t)
                y = upperRise + p.y * middleLength; z = -radius + p.x * middleLength
                dy = tangent.y; dz = tangent.x
            } else {
                y = frontY + path - frontStart; z = 0; dy = 1; dz = 0
            }
            let scale = focalLength / (focalLength - z)
            return (scale, y * scale, dy * scale + y * scale * dz / (focalLength - z))
        }

        func path(projectedY: CGFloat) -> CGFloat {
            if projectedY <= 0 { return projectedY / openingScale }
            if projectedY >= frontY { return frontStart + projectedY - frontY }
            var lower: CGFloat = 0, upper = frontStart
            for _ in 0..<36 {
                let middle = (lower + upper) / 2
                if projected(path: middle).y < projectedY { lower = middle } else { upper = middle }
            }
            return (lower + upper) / 2
        }

        func tile(position: Double, column: Int, from: CGFloat = 0, to: CGFloat = 1) -> Tile {
            let position = position.isFinite ? position : 0
            let top = projected(path: (position + from - 0.5) * width)
            let bottom = projected(path: (position + to - 0.5) * width)
            let ratio = top.scale / bottom.scale
            return Tile(perspective: 1 - ratio, width: width * top.scale,
                        travel: top.y, vertical: bottom.y * ratio - top.y,
                        x: width * (CGFloat(column - 1) * 1.08 - 0.5) * top.scale)
        }
    }

    static func iconFrame(time: Double, bounds: CGRect, destination: CGRect) -> CGRect {
        guard OathLayoutGeometry.isUsable(bounds), OathLayoutGeometry.isUsable(destination) else { return .zero }
        let time = time.isFinite ? max(0, time) : 0
        let p = 1 - pow(1 - clamp((time - 1.67) / 0.33), 3)
        let settle = max(0, time - 2)
        let scale = time < 2 ? 1 : 1 - 0.22 * exp(-settle * 9) * sin(settle * 21)
        let width = (bounds.width + (destination.width - bounds.width) * p) * scale
        let height = (bounds.height + (destination.height - bounds.height) * p) * scale
        let x = bounds.midX + (destination.midX - bounds.midX) * p
        let y = bounds.midY + (destination.midY - bounds.midY) * p
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }
}
