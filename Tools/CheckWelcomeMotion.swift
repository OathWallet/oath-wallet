import Foundation
import CoreGraphics

@main struct CheckWelcomeMotion {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ reason: String) {
            precondition(value, reason); checks += 1
        }
        let sizes = [CGSize(width: 320, height: 250), CGSize(width: 440, height: 520),
                     CGSize(width: 700, height: 650), CGSize(width: 150, height: 650),
                     .zero, CGSize(width: CGFloat.nan, height: .infinity)]
        for size in sizes {
            let surface = OathWelcomeMotion.Surface(size: size)
            for time in stride(from: 0.0, through: 120.0, by: 0.1) {
                let advance = surface.advance(time: time)
                var folded = 0
                for row in 0..<OathWelcomeMotion.rows {
                    for column in 0..<3 {
                        let position = surface.position(row: row, column: column, advance: advance)
                        let tile = surface.tile(position: position, column: column)
                        let a = tile.point(x: 0, y: 0), b = tile.point(x: 1, y: 1)
                        check(a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite, "No invalid layer geometry")
                        check(b.x > a.x && b.y > a.y, "Perspective must never invert or collapse a tile")
                        if surface.isFolded(position: position) { folded += 1 }
                    }
                }
                check(folded <= OathWelcomeMotion.foldedTileCapacity, "The bounded mesh pool covers both curls, including narrow layouts")
            }
            let departing = surface.tile(position: surface.recyclePosition, column: 1)
            check(departing.point(x: 0, y: 0).y > surface.height, "Recycle only after the entire tile leaves the fade")
            let recycled = surface.tile(position: surface.recyclePosition - Double(OathWelcomeMotion.rows) * OathWelcomeMotion.rowSpacing, column: 1)
            check(recycled.point(x: 0, y: 1).y < 0, "Recycled tiles must remain behind the opening")
            check(abs(surface.projected(path: 0).scale - 0.30) < 0.00001, "The opening is finite, not an infinite vanishing point")
            for (time, fraction) in [(2.55, 0.0), (2.75, 0.08), (3.0, 0.22), (3.25, 0.52), (3.5, 0.90)] {
                let leadingBottom = surface.tile(position: surface.advance(time: time), column: 0).point(x: 0, y: 1).y
                check(abs(leadingBottom / surface.height - fraction) < 0.00001, "The leading row must match the reference timing landmarks")
            }
            for boundary in [CGFloat.zero, surface.upperLength, surface.middleStart, surface.frontStart] {
                let epsilon: CGFloat = 0.0001
                let before = surface.projected(path: boundary - epsilon)
                let at = surface.projected(path: boundary)
                let after = surface.projected(path: boundary + epsilon)
                check(abs(before.y - after.y) < 0.001, "No positional jump at either curl or plane")
                check(abs(before.slope - after.slope) < 0.0001, "Both curls join the planes with continuous tangents")
                check(abs((at.slope - before.slope) / epsilon - (after.slope - at.slope) / epsilon) < 0.01, "Both curls ease their curvature at the joins")
            }
        }
        let surface = OathWelcomeMotion.Surface(size: CGSize(width: 440, height: 520))
        check(surface.isFolded(position: Double(surface.upperLength / surface.width / 2)), "Mesh deformation is present directly below the notch")
        check(surface.isFolded(position: Double((surface.middleStart + surface.frontStart) / surface.width / 2)), "Mesh deformation is also present in the middle")
        for offset in stride(from: 0.6, through: 5.0, by: 0.1) {
            let tile = surface.tile(position: Double(surface.frontStart / surface.width) + offset, column: 1)
            check(abs(tile.width - surface.width) < 0.00001, "Front-facing tiles stop growing")
            check(abs(tile.perspective) < 0.00001, "The front remains vertical")
            check(abs(tile.vertical - surface.width) < 0.00001, "Front-facing logos retain square proportions")
        }
        for position in stride(from: -0.5, through: Double(surface.frontStart / surface.width) + 0.5, by: 0.05) {
            for column in 0..<3 {
                for strip in 0..<(OathWelcomeMotion.stripsPerTile - 1) {
                    let start = CGFloat(strip) / CGFloat(OathWelcomeMotion.stripsPerTile)
                    let end = CGFloat(strip + 1) / CGFloat(OathWelcomeMotion.stripsPerTile)
                    let nextEnd = CGFloat(strip + 2) / CGFloat(OathWelcomeMotion.stripsPerTile)
                    let first = surface.tile(position: position, column: column, from: start, to: end)
                    let next = surface.tile(position: position, column: column, from: end, to: nextEnd)
                    for x in [CGFloat.zero, 0.5, 1] {
                        let a = first.point(x: x, y: 1), b = next.point(x: x, y: 0)
                        check(hypot(a.x - b.x, a.y - b.y) < 0.00001, "Texture strips meet exactly through both curls")
                    }
                }
            }
        }
        let dt = 0.0001
        func speed(_ t: Double) -> Double {
            (surface.advance(time: t + dt) - surface.advance(time: t)) / dt
        }
        for t in stride(from: OathWelcomeMotion.streamStart + 0.01, through: 8.0, by: 0.01) {
            check(speed(t) > 0, "Paper must never stop or reverse during entrance or cruise")
        }
        var previous = speed(3.5)
        for t in stride(from: 3.51, through: 8.0, by: 0.01) {
            let current = speed(t)
            check(current <= previous + 0.000001 && current >= OathWelcomeMotion.rowsPerSecond - 0.000001, "The rush settles continuously into the slow flow")
            previous = current
        }
        for time in [2.75, 3.0, 3.25, 3.5, 4.5] {
            check(abs(speed(time - dt) - speed(time)) < 0.01, "No velocity jump at a timing landmark")
        }
        check(speed(3.5) > speed(5) * 4, "The entrance is visibly faster than the slow flow")
        check(abs(speed(8) - OathWelcomeMotion.rowsPerSecond) < 0.001, "Cruise speed holds the slower settled pace")
        for row in 0..<OathWelcomeMotion.rows {
            let position = surface.position(row: row, column: 0, advance: surface.advance(time: 2.55))
            check(surface.tile(position: position, column: 0).point(x: 0, y: 1).y <= 0, "No rows appear in front before the entrance")
        }
        for time in [Double.nan, -.infinity, .infinity, -1, 1000000] {
            check(surface.position(row: 0, column: 0, advance: surface.advance(time: time)).isFinite, "Invalid and long-running clocks stay safe")
        }
        var lastOpacity: Float = 0
        for frame in 0..<675 {
            let time = Double(frame) / 59.82
            let opacity = OathWelcomeMotion.glowOpacity(time: time)
            check(opacity >= lastOpacity && opacity <= 1, "The notch light fades in once, without pulsing")
            if time < 2.48 { check(opacity == 0, "The light waits for the reference entrance") }
            if time >= 3.1 { check(opacity == 1, "The settled light is constant") }
            lastOpacity = opacity
        }
        for inset: CGFloat in [0, 20, 47, 59, 62] {
            let intro = CGRect(x: 0, y: inset, width: 402, height: 500)
            let stage = OathWelcomeMotion.Stage(introduction: intro, icon: CGRect(x: 161, y: 360, width: 80, height: 80), topSafeAreaInset: inset)
            check(stage.frame.minY == max(0, inset - 12), "Paper opens beneath the system safe area")
            check(stage.lightCenter.x == intro.midX && stage.lightCenter.y == stage.frame.minY - 15, "Light follows the opening without guessing hardware bounds")
        }
        let bounds = CGRect(x: 0, y: 0, width: 440, height: 956)
        let destination = CGRect(x: 180, y: 400, width: 80, height: 80)
        check(OathWelcomeMotion.iconFrame(time: 0, bounds: bounds, destination: destination) == bounds, "Opening fills the screen")
        check(OathWelcomeMotion.iconFrame(time: 1.66, bounds: bounds, destination: destination) == bounds, "Reference hold lasts 1.67 seconds")
        let settled = OathWelcomeMotion.iconFrame(time: 6, bounds: bounds, destination: destination)
        check(abs(settled.width - 80) < 0.001 && abs(settled.midY - destination.midY) < 0.001, "Opening settles at the measured icon")
        for frame in 0...675 {
            let rect = OathWelcomeMotion.iconFrame(time: Double(frame) / 59.82, bounds: bounds, destination: destination)
            check(OathLayoutGeometry.isUsable(rect), "Opening must have usable geometry on every reference frame")
        }
        check(OathWelcomeMotion.iconFrame(time: 2, bounds: .zero, destination: .zero) == .zero, "Zero-sized navigation proposals remain safe")
        print("Welcome motion: \(checks) checks passed")
    }
}
