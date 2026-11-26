import XCTest
@testable import OathBalanceChart

final class BalanceChartTests: XCTestCase {
    private func point(_ time: Double, _ value: Decimal) -> BalanceChartPoint {
        .init(date: Date(timeIntervalSince1970: time), value: value)
    }
    private var interval: DateInterval { .init(start: Date(timeIntervalSince1970: 100), duration: 100) }

    func testGrayZeroAndFlatPortfolio() {
        for value in [Decimal(0), Decimal(250)] {
            let series = BalanceChartSeries(points: [point(100, value), point(200, value)], interval: interval)
            XCTAssertTrue(series.ticks(count: 73).allSatisfy { $0.direction == 0 && $0.displacement == 0 })
        }
    }
    func testPositiveNegativeAndReturnToOpening() {
        let series = BalanceChartSeries(points: [point(100, 100), point(125, 120), point(150, 90), point(175, 100)], interval: interval)
        let ticks = series.ticks(count: 5)
        XCTAssertEqual(ticks.map(\.direction), [0, 1, -1, 0, 0])
        XCTAssertEqual(ticks.map(\.displacement), [0, 1, -0.5, 0, 0])
    }
    func testUnknownTimeDoesNotInventZeroOrInterpolateMoney() {
        let series = BalanceChartSeries(points: [point(125, 10), point(175, 30)], interval: interval)
        XCTAssertNil(series.point(at: 0))
        XCTAssertEqual(series.point(at: 0.5)?.value, 10)
        XCTAssertEqual(series.point(at: 0.75)?.value, 30)
        XCTAssertEqual(series.point(at: 0.5)?.date, Date(timeIntervalSince1970: 125))
    }
    func testCursorTimeMovesWhileObservedValueIsHeld() {
        let series = BalanceChartSeries(points: [point(125, 10), point(175, 30)], interval: interval)
        XCTAssertEqual(series.selection(at: 0.5)?.date, Date(timeIntervalSince1970: 150))
        XCTAssertEqual(series.selection(at: 0.5)?.observedAt, Date(timeIntervalSince1970: 125))
        XCTAssertEqual(series.selection(at: 0.5)?.value, 10)
        XCTAssertNil(series.selection(at: 0)?.value)
        XCTAssertNil(series.selection(at: 0)?.observedAt)
    }
    func testInvalidValuesAndFutureObservationsAreExcluded() {
        let series = BalanceChartSeries(points: [point(100, 10), point(140, .nan), point(150, -1), point(210, 900)], interval: interval)
        XCTAssertEqual(series.points, [point(100, 10)])
        XCTAssertNil(series.point(at: .nan))
        XCTAssertEqual(series.point(at: 2)?.value, 10)
    }
    func testDuplicateTimestampUsesLastCommittedValueAndSorts() {
        let series = BalanceChartSeries(points: [point(200, 50), point(100, 20), point(200, 60)], interval: interval)
        XCTAssertEqual(series.points, [point(100, 20), point(200, 60)])
    }
    func testSubCentChangeKeepsDirectionWithoutFloatingPointCancellation() {
        let value = Decimal(string: "12345678901234567890.123456789")!
        let series = BalanceChartSeries(points: [point(100, value), point(200, value + Decimal(string: "0.000000001")!)], interval: interval)
        XCTAssertEqual(series.ticks(count: 2).last?.direction, 1)
        XCTAssertEqual(series.ticks(count: 2).last?.displacement, 1)
    }
    func testEmptyAndZeroDurationAreFiniteAndBounded() {
        let series = BalanceChartSeries(points: [], interval: .init(start: interval.start, duration: 0))
        XCTAssertEqual(series.ticks(count: Int.max).count, 160)
        XCTAssertEqual(series.ticks(count: 0).count, 2)
        XCTAssertTrue(series.ticks(count: 73).allSatisfy { $0.point == nil && $0.displacement.isFinite })
    }
    func testHapticsRequireNewTickAndAreRateLimited() {
        var policy = BalanceChartHapticPolicy()
        XCTAssertNotNil(policy.sample(index: 0, direction: 0, displacement: 0, time: 1))
        XCTAssertNil(policy.sample(index: 0, direction: 0, displacement: 0, time: 2))
        XCTAssertNil(policy.sample(index: 1, direction: 1, displacement: 1, time: 1.01))
        let crossing = policy.sample(index: 1, direction: 1, displacement: 1, time: 1.05)
        XCTAssertEqual(crossing?.intensity, 0.62)
        XCTAssertEqual(crossing?.sharpness, 0.72)
        policy.reset()
        XCTAssertNotNil(policy.sample(index: 1, direction: 1, displacement: 1, time: 1.06))
    }
    func testHapticParametersRemainWithinHardwareBounds() {
        var policy = BalanceChartHapticPolicy()
        XCTAssertNil(policy.sample(index: 0, direction: 0, displacement: .nan, time: 0))
        XCTAssertNil(policy.sample(index: 0, direction: 0, displacement: 0, time: .infinity))
        let value = policy.sample(index: 0, direction: -1, displacement: -1e10, time: 0)
        XCTAssertNotNil(value)
        XCTAssertTrue((0...1).contains(value!.intensity))
        XCTAssertTrue((0...1).contains(value!.sharpness))
    }
}
