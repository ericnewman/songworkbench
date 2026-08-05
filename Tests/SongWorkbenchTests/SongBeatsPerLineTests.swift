import XCTest

@testable import SongWorkbench

final class SongBeatsPerLineTests: XCTestCase {
    private func uniformBeats(bpm: Double, duration: TimeInterval) -> [TimeInterval] {
        Array(stride(from: 0.0, through: duration, by: 60.0 / bpm))
    }

    /// Line onsets every `beatsPerLine` beats, with deterministic jitter.
    private func onsets(
        bpm: Double, beatsPerLine: Int, count: Int, jitter: TimeInterval = 0.05
    ) -> [TimeInterval] {
        let step = (60.0 / bpm) * Double(beatsPerLine)
        return (0..<count).map { index in
            let phase = Double((index * 7) % 5) / 4.0
            return 1.0 + Double(index) * step + (index % 2 == 0 ? 1 : -1) * phase * jitter
        }
    }

    // MARK: estimate

    func testEstimatesAnEightBeatPhrase() {
        let bpm = 120.0
        let fit = try! XCTUnwrap(
            SongBeatsPerLine.estimate(
                beatTimes: uniformBeats(bpm: bpm, duration: 130),
                bpm: bpm,
                lineOnsets: onsets(bpm: bpm, beatsPerLine: 8, count: 24)))
        XCTAssertEqual(fit.beatsPerLine, 8)
        XCTAssertLessThan(fit.fitError, 0.1)
    }

    func testEstimatesAFourBeatPhrase() {
        let bpm = 96.0
        let fit = try! XCTUnwrap(
            SongBeatsPerLine.estimate(
                beatTimes: uniformBeats(bpm: bpm, duration: 90),
                bpm: bpm,
                lineOnsets: onsets(bpm: bpm, beatsPerLine: 4, count: 28)))
        XCTAssertEqual(fit.beatsPerLine, 4)
    }

    func testEstimateReturnsNilWithoutEnoughLines() {
        XCTAssertNil(
            SongBeatsPerLine.estimate(
                beatTimes: uniformBeats(bpm: 120, duration: 30),
                bpm: 120,
                lineOnsets: [1, 5, 9]))
    }

    func testEstimateReturnsNilForZeroTempo() {
        XCTAssertNil(
            SongBeatsPerLine.estimate(beatTimes: [], bpm: 0, lineOnsets: []))
    }

    // MARK: measure

    func testCleanLinesAreAllOnGrid() {
        let bpm = 120.0
        let beat = 60.0 / bpm
        let measurements = SongBeatsPerLine.measure(
            lineOnsets: onsets(bpm: bpm, beatsPerLine: 8, count: 20),
            beatsPerLine: 8,
            beatLength: beat)
        XCTAssertEqual(measurements.count, 19)
        XCTAssertTrue(measurements.allSatisfy { $0.verdict == .onGrid })
        XCTAssertEqual(SongBeatsPerLine.outlierRate(measurements), 0, accuracy: 1e-9)
    }

    func testShortAndLongLinesAreFlagged() {
        let beat = 0.5
        // 8-beat phrases, with one line split in half and one pair run together.
        let onsets: [TimeInterval] = [
            0,  // 8 beats
            4.0,  // 2 beats  -> SHORT
            5.0,  // 8 beats
            9.0,  // 16 beats -> two phrases, still on grid
            17.0,  // 12 beats -> LONG
            23.0,
            27.0,
        ]
        let m = SongBeatsPerLine.measure(
            lineOnsets: onsets, beatsPerLine: 8, beatLength: beat)
        XCTAssertEqual(m[0].verdict, .onGrid)
        XCTAssertEqual(m[1].verdict, .short)
        XCTAssertEqual(m[2].verdict, .onGrid)
        XCTAssertEqual(m[3].verdict, .onGrid, "a deliberate two-phrase line is not an outlier")
        XCTAssertEqual(m[4].verdict, .long)
        XCTAssertGreaterThan(SongBeatsPerLine.outlierRate(m), 0)
    }

    func testASectionBreakIsNotCountedAsAnOutlier() {
        let beat = 0.5
        // A 40-beat gap between sections must not be reported as a "long line".
        let onsets: [TimeInterval] = [0, 4.0, 8.0, 28.0, 32.0, 36.0]
        let m = SongBeatsPerLine.measure(lineOnsets: onsets, beatsPerLine: 8, beatLength: beat)
        XCTAssertEqual(m[2].verdict, .sectionBreak)
        // Only the four real phrase intervals are scored, and they are all clean.
        XCTAssertEqual(SongBeatsPerLine.outlierRate(m), 0, accuracy: 1e-9)
    }

    func testMeasurementReportsPeriodsSpanned() {
        let m = SongBeatsPerLine.measure(
            lineOnsets: [0, 4.0], beatsPerLine: 8, beatLength: 0.5)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].intervalInBeats, 8, accuracy: 1e-9)
        XCTAssertEqual(m[0].periodsSpanned, 1, accuracy: 1e-9)
        XCTAssertEqual(m[0].lineIndex, 0)
    }

    func testDegenerateInputsYieldNoMeasurements() {
        XCTAssertTrue(
            SongBeatsPerLine.measure(lineOnsets: [1], beatsPerLine: 8, beatLength: 0.5).isEmpty)
        XCTAssertTrue(
            SongBeatsPerLine.measure(lineOnsets: [0, 4], beatsPerLine: 0, beatLength: 0.5).isEmpty)
        XCTAssertTrue(
            SongBeatsPerLine.measure(lineOnsets: [0, 4], beatsPerLine: 8, beatLength: 0).isEmpty)
    }

    func testOutlierRateIsZeroWithNothingToScore() {
        XCTAssertEqual(SongBeatsPerLine.outlierRate([]), 0, accuracy: 1e-9)
    }
}
