import CoreGraphics

@main struct CheckRefreshRingGeometry {
    static func main() {
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        let circle = RefreshRingGeometry.circle
        let check = RefreshRingGeometry.check
        precondition(elements(circle) == elements(check), "Morph paths must have matching elements")
        precondition(elements(check) == [.moveToPoint, .addCurveToPoint, .addCurveToPoint, .addCurveToPoint, .addCurveToPoint])
        for path in [circle, check] {
            precondition(CGRect(x: 0, y: 0, width: 28, height: 28).contains(path.boundingBoxOfPath))
        }
        precondition(check.currentPoint == CGPoint(x: 24, y: 7), "Check ends at its upper-right tip")
        precondition(circle.currentPoint == CGPoint(x: 14, y: 2), "Circle returns to twelve o'clock")
        print("Passed native ring/check path compatibility and bounds checks.")
    }
}
