import XCTest

@testable import SongWorkbench

/// Invariants of the chart's single row ruler. These are the properties whose absence produced
/// the visible drift: beats must be EQUIDISTANT in pixels on every row regardless of how the
/// measured beat times wobble, and the drag inverse must round-trip through the same mapping.
final class ChordRowRulerTests: XCTestCase {
    /// A deliberately wobbly measured grid (push/drag drummer): 0.4–0.8 s between beats.
    private let wobblyBeats: [TimeInterval] = [
        10.0, 10.6, 11.0, 11.8, 12.3, 12.7, 13.5, 14.0, 14.4, 15.2,
    ]

    private func ruler(grid: MeasureGrid?) -> ChordRowRuler {
        ChordRowRuler(
            grid: grid,
            originTime: 10.6,
            gutterPx: 120,
            pixelsPerBeat: 60,
            pixelsPerSecond: 100
        )
    }

    func testBeatXsAreExactlyEquidistantOnAWobblyMeasuredGrid() {
        let grid = MeasureGrid(beatTimes: wobblyBeats, bpm: 100)
        let xs = ruler(grid: grid).beatXs(from: 10.0, to: 15.2)
        XCTAssertEqual(xs.count, wobblyBeats.count)
        let spacings = zip(xs.dropFirst(), xs).map(-)
        for spacing in spacings {
            XCTAssertEqual(spacing, 60, accuracy: 0.0001, "beats must be one pixelsPerBeat apart")
        }
    }

    func testBeatXsStayEquidistantBeyondTheMeasuredRange() {
        // A row whose window extends past the last measured beat: extrapolated beats must keep
        // the SAME pixel spacing (previously beats were synthesized uniform-in-time and mapped
        // back through the measured grid, which broke spacing exactly here).
        let grid = MeasureGrid(beatTimes: wobblyBeats, bpm: 100)
        let xs = ruler(grid: grid).beatXs(from: 14.0, to: 18.0)
        XCTAssertGreaterThan(xs.count, 2)
        let spacings = zip(xs.dropFirst(), xs).map(-)
        for spacing in spacings {
            XCTAssertEqual(spacing, 60, accuracy: 0.0001)
        }
    }

    func testOriginRendersAtTheGutterColumn() {
        let grid = MeasureGrid(beatTimes: wobblyBeats, bpm: 100)
        XCTAssertEqual(ruler(grid: grid).x(atTime: 10.6), 120, accuracy: 0.0001)
        XCTAssertEqual(ruler(grid: nil).x(atTime: 10.6), 120, accuracy: 0.0001)
    }

    func testTimeAtXInvertsXAtTimeOnAndOffTheGrid() {
        let grid = MeasureGrid(beatTimes: wobblyBeats, bpm: 100)
        for time in stride(from: 10.2, through: 15.0, by: 0.35) {
            let metric = ruler(grid: grid)
            XCTAssertEqual(metric.time(atX: metric.x(atTime: time)), time, accuracy: 0.0001)
            let uniform = ruler(grid: nil)
            XCTAssertEqual(uniform.time(atX: uniform.x(atTime: time)), time, accuracy: 0.0001)
        }
    }

    func testDragInverseFollowsLocalBeatLengthNotFixedPixelsPerSecond() {
        // Between 11.8 and 12.3 the measured beat lasts 0.5 s over 60 px, so dragging a chord
        // +30 px must move it +0.25 s — not 30/pixelsPerSecond = 0.3 s.
        let grid = MeasureGrid(beatTimes: wobblyBeats, bpm: 100)
        let metric = ruler(grid: grid)
        let dragged = metric.time(atX: metric.x(atTime: 11.8) + 30)
        XCTAssertEqual(dragged, 12.05, accuracy: 0.0001)
    }

    func testFallbackAxisBeatsAreEquidistantToo() {
        // pixelsPerBeat 60 / pixelsPerSecond 100 → 0.6 s beats on the uniform axis.
        let xs = ruler(grid: nil).beatXs(from: 10.6, to: 13.0)
        XCTAssertEqual(xs.count, 5)
        let spacings = zip(xs.dropFirst(), xs).map(-)
        for spacing in spacings {
            XCTAssertEqual(spacing, 60, accuracy: 0.0001)
        }
    }

    func testDegenerateGridCannotSpin() {
        let grid = MeasureGrid(beatTimes: [0, 0.001], bpm: 60000)
        let xs = ruler(grid: grid).beatXs(from: 0, to: 10_000)
        XCTAssertLessThanOrEqual(xs.count, 512)
    }
}
