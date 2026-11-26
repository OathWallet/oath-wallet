import Foundation

public struct BalanceChartPoint: Equatable, Sendable {
    public let date: Date
    public let value: Decimal
    public init(date: Date, value: Decimal) { self.date = date; self.value = value }
}

/// The cursor's time is distinct from the last actual observation. Unknown
/// history remains nil; dragging never synthesizes a zero or interpolated value.
public struct BalanceChartSelection: Equatable, Sendable {
    public let date: Date
    public let value: Decimal?
    public let observedAt: Date?
}

/// Observed portfolio values, not price candles or invented intermediate values.
/// Values are held until the next observation; time before the first is unknown.
public struct BalanceChartSeries: Equatable, Sendable {
    public let points: [BalanceChartPoint]
    public let interval: DateInterval
    public var opening: Decimal? { points.first?.value }

    public init(points: [BalanceChartPoint], interval: DateInterval) {
        self.interval = interval
        var unique: [Date: BalanceChartPoint] = [:]
        for point in points where point.date.timeIntervalSince1970.isFinite && !point.value.isNaN && point.value >= 0 {
            if point.date <= interval.end { unique[point.date] = point }
        }
        self.points = unique.values.sorted { $0.date < $1.date }
    }

    public func point(at fraction: Double) -> BalanceChartPoint? {
        guard fraction.isFinite else { return nil }
        let date = interval.start.addingTimeInterval(interval.duration * min(1, max(0, fraction)))
        // Last observation at or before the requested time (never a future value).
        var lower = 0, upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date <= date { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 ? points[lower - 1] : nil
    }

    public func selection(at fraction: Double) -> BalanceChartSelection? {
        guard fraction.isFinite else { return nil }
        let fraction = min(1, max(0, fraction))
        let observation = point(at: fraction)
        return BalanceChartSelection(date: interval.start.addingTimeInterval(interval.duration * fraction),
            value: observation?.value, observedAt: observation?.date)
    }

    public func ticks(count: Int) -> [BalanceChartTick] {
        let count = min(160, max(2, count))
        let deltas = points.map { $0.value - (opening ?? $0.value) }
        let maximum = deltas.map { abs($0) }.max() ?? 0
        return (0..<count).map { index in
            let point = point(at: Double(index) / Double(count - 1))
            let delta = point.map { $0.value - (opening ?? $0.value) } ?? 0
            let ratio = maximum > 0 ? NSDecimalNumber(decimal: delta / maximum).doubleValue : 0
            return BalanceChartTick(index: index, point: point,
                displacement: ratio.isFinite ? min(1, max(-1, ratio)) : 0,
                direction: delta == 0 ? 0 : (delta > 0 ? 1 : -1))
        }
    }
}

public struct BalanceChartTick: Equatable, Sendable {
    public let index: Int
    public let point: BalanceChartPoint?
    public let displacement: Double
    public let direction: Int
}

/// One physical detent per new tick, capped at 25 Hz even during fast scrubbing.
/// Pure policy keeps hardware output testable without a phone or simulator.
struct BalanceChartHapticPolicy {
    private var lastIndex: Int?
    private var lastTime: Double = -.infinity
    private var lastDirection: Int?
    mutating func reset() { self = Self() }
    mutating func sample(index: Int, direction: Int, displacement: Double, time: Double) -> (intensity: Float, sharpness: Float)? {
        guard time.isFinite, displacement.isFinite, index != lastIndex, time - lastTime >= 0.04 else { return nil }
        let crossing = lastDirection.map { $0 != direction } ?? false
        lastIndex = index; lastTime = time; lastDirection = direction
        let depth = min(1, abs(displacement))
        return (Float(crossing ? 0.62 : 0.22 + depth * 0.26), Float(crossing ? 0.72 : 0.28 + depth * 0.36))
    }
}
