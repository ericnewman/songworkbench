import XCTest

@testable import SongWorkbench

/// Fixtures here run at 120 BPM with lines every 4 s, which `SongBeatsPerLine` reads as an
/// 8-beat phrase — so one PERIOD is 4 s and one word step is 0.45 s.
final class PhrasePeriodLineRecutterTests: XCTestCase {
    private let bpm = 120.0
    private let period = 4.0
    private let step = 0.45
    private let wordLength = 0.25

    private func beats(duration: TimeInterval) -> [TimeInterval] {
        Array(stride(from: 0.0, through: duration, by: 60.0 / bpm))
    }

    /// A line of `count` words from `start`, one every `step`, optionally with a WIDE silence
    /// after word index `gapAfter` (everything after it shifts later by `gap`).
    private func line(
        start: TimeInterval, count: Int, gapAfter: Int? = nil, gap: TimeInterval = 0.6,
        prefix: String = "w"
    ) -> TimedLyricSegment {
        var words: [TimedLyricWord] = []
        var cursor = start
        for index in 0..<count {
            words.append(
                TimedLyricWord(
                    text: "\(prefix)\(index)", start: cursor, end: cursor + wordLength,
                    characterRange: 0..<1))
            cursor += step + (index == gapAfter ? gap : 0)
        }
        return segment(words)
    }

    private func segment(_ words: [TimedLyricWord]) -> TimedLyricSegment {
        var text = ""
        var rebuilt: [TimedLyricWord] = []
        for word in words {
            if !text.isEmpty { text += " " }
            let lower = text.count
            text += word.text
            rebuilt.append(
                TimedLyricWord(
                    text: word.text, start: word.start, end: word.end,
                    characterRange: lower..<text.count))
        }
        return TimedLyricSegment(
            start: words[0].start, end: words[words.count - 1].end, text: text, words: rebuilt)
    }

    /// Ten evenly spaced 4-word lines — the "clean song" baseline every fixture perturbs.
    private func evenLines(count: Int = 10) -> [TimedLyricSegment] {
        (0..<count).map { line(start: Double($0) * period, count: 4, prefix: "a\($0)_") }
    }

    /// The clean song with its line at 16 s replaced by one long line covering 16–24 s, carrying a
    /// real 0.6 s silence exactly one period in.
    private func songWithOneDoubleLengthLine(gapAfter: Int? = 7) -> [TimedLyricSegment] {
        var lines = evenLines()
        lines[4] = line(start: 16.0, count: 16, gapAfter: gapAfter, prefix: "b")
        lines.remove(at: 5)
        return lines
    }

    // MARK: - Bail-outs

    func testNoTempoIsANoOp() {
        let lines = evenLines()
        XCTAssertEqual(
            PhrasePeriodLineRecutter.recut(lines, beatTimes: beats(duration: 60), tempo: nil),
            lines)
    }

    func testTooFewLinesToEstablishAPeriodIsANoOp() {
        let lines = [line(start: 0, count: 4), line(start: 4, count: 4)]
        XCTAssertEqual(
            PhrasePeriodLineRecutter.recut(lines, beatTimes: beats(duration: 40), tempo: bpm),
            lines)
    }

    func testEmptyInputIsANoOp() {
        XCTAssertEqual(
            PhrasePeriodLineRecutter.recut([], beatTimes: beats(duration: 40), tempo: bpm), [])
    }

    // MARK: - Split

    func testSplitsATwoPeriodLineAtTheRealGap() {
        let lines = songWithOneDoubleLengthLine()
        let result = PhrasePeriodLineRecutter.recut(
            lines, beatTimes: beats(duration: 60), tempo: bpm)
        XCTAssertEqual(result.count, lines.count + 1, "the double-length line should be cut once")
        let pieces = result.filter { $0.text.hasPrefix("b") }
        XCTAssertEqual(pieces.count, 2)
        // The cut lands on the MEASURED onset of the word after the silence (20.2 s), not on the
        // computed one-period target (20.0 s) — the target only chooses which gap to snap to.
        XCTAssertEqual(pieces[1].start, 20.2, accuracy: 1e-9)
        XCTAssertEqual(pieces[0].words.count, 8)
        XCTAssertEqual(pieces[1].words.count, 8)
    }

    /// The same over-long line sung legato: no gap anywhere near the boundary. Nothing may be cut
    /// — a boundary lands on a real measured gap or it does not exist.
    func testDoesNotCutWhenNoRealGapSitsNearTheBoundary() {
        let lines = songWithOneDoubleLengthLine(gapAfter: nil)
        XCTAssertEqual(
            PhrasePeriodLineRecutter.recut(lines, beatTimes: beats(duration: 60), tempo: bpm),
            lines)
    }

    /// A gap that is wide in absolute terms but nowhere near `onset + k · P` is not a boundary.
    func testDoesNotCutAtAGapFarFromTheBoundary() {
        let lines = songWithOneDoubleLengthLine(gapAfter: 2)
        XCTAssertEqual(
            PhrasePeriodLineRecutter.recut(lines, beatTimes: beats(duration: 60), tempo: bpm),
            lines)
    }

    // MARK: - Merge

    /// A line the ASR split in half — two rows half a period apart — is folded back into one,
    /// because the combined row lands on the period and neither piece does.
    func testMergesATooShortLineIntoItsNeighbour() {
        var lines = evenLines()
        lines[8] = line(start: 32.0, count: 4, prefix: "x")
        lines.insert(line(start: 34.0, count: 3, prefix: "y"), at: 9)

        let result = PhrasePeriodLineRecutter.recut(
            lines, beatTimes: beats(duration: 60), tempo: bpm)
        XCTAssertEqual(result.count, lines.count - 1)
        let merged = try! XCTUnwrap(result.first { $0.text.contains("x0") })
        XCTAssertTrue(merged.text.contains("y0"), "the two fragments should be one row")
        XCTAssertEqual(merged.start, 32.0, accuracy: 1e-9)
        XCTAssertEqual(merged.words.count, 7)
    }

    /// A short line whose only reachable neighbour sits across a section break is left alone: that
    /// silence is a gap in the song, not a mis-split line.
    func testNeverMergesAcrossASectionBreak() {
        var lines = (0..<6).map { line(start: Double($0) * period, count: 4, prefix: "a\($0)_") }
        // 24 s instrumental, then a short fragment that opens the next section.
        lines.append(line(start: 44.0, count: 2, prefix: "frag"))
        lines.append(line(start: 44.8, count: 4, prefix: "c0_"))
        lines.append(contentsOf: [52.0, 56.0, 60.0].map { line(start: $0, count: 4, prefix: "d") })

        let result = PhrasePeriodLineRecutter.recut(
            lines, beatTimes: beats(duration: 90), tempo: bpm)
        XCTAssertFalse(
            result.contains { $0.text.contains("frag") && $0.text.contains("a5_") },
            "the fragment was welded onto the previous section's last line")
    }

    // MARK: - Gate

    /// The pass hands back its input BYTE-IDENTICAL when it cannot improve the song, rather than
    /// emitting a re-cut that is merely different.
    func testAlreadyCleanSongsAreReturnedUntouched() {
        let lines = evenLines(count: 12)
        let grid = beats(duration: 60)
        XCTAssertEqual(PhrasePeriodLineRecutter.recut(lines, beatTimes: grid, tempo: bpm), lines)
        let report = PhrasePeriodLineRecutter.recutReporting(
            lines, beatTimes: grid, tempo: bpm
        ).report
        XCTAssertEqual(report?.accepted, false)
        XCTAssertEqual(report?.splits, 0)
        XCTAssertEqual(report?.merges, 0)
    }

    func testAnAcceptedRecutNeverRaisesTheOutlierRate() {
        let report = try! XCTUnwrap(
            PhrasePeriodLineRecutter.recutReporting(
                songWithOneDoubleLengthLine(), beatTimes: beats(duration: 60), tempo: bpm
            ).report)
        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.beatsPerLine, 8)
        XCTAssertLessThanOrEqual(report.outlierRateAfter, report.outlierRateBefore)
    }

    // MARK: - Idempotency

    /// Re-running the pass on its OWN output must change nothing. The real guarantee is measured
    /// on live songs in `PhrasePeriodLineRecutterDiagnosticTests` — synthetic uniform onsets hide
    /// exactly this class of defect (tasks/lessons.md) — so this is the cheap regression, not the
    /// proof.
    func testRecutIsIdempotent() {
        var lines = songWithOneDoubleLengthLine()
        lines[7] = line(start: 32.0, count: 4, prefix: "x")
        lines.append(line(start: 34.0, count: 3, prefix: "y"))

        let grid = beats(duration: 60)
        let once = PhrasePeriodLineRecutter.recut(lines, beatTimes: grid, tempo: bpm)
        XCTAssertNotEqual(once, lines, "this fixture must actually exercise the pass")
        let twice = PhrasePeriodLineRecutter.recut(once, beatTimes: grid, tempo: bpm)
        XCTAssertEqual(twice, once)
        XCTAssertEqual(PhrasePeriodLineRecutter.recut(twice, beatTimes: grid, tempo: bpm), once)
    }

    // MARK: - Structure preservation

    func testEveryWordSurvivesInOrder() {
        let lines = songWithOneDoubleLengthLine()
        let result = PhrasePeriodLineRecutter.recut(
            lines, beatTimes: beats(duration: 60), tempo: bpm)
        XCTAssertEqual(
            result.flatMap { $0.words.map(\.text) }, lines.flatMap { $0.words.map(\.text) })
        XCTAssertEqual(
            result.flatMap { $0.words.map(\.start) }, lines.flatMap { $0.words.map(\.start) })
    }

    /// The re-cut drops per-line annotations by construction (it rebuilds segments from words);
    /// `TimedLyricSegment.reconciled` is what carries the user's own edits back across it, and
    /// `AppModel.applyAnalysis` runs it immediately afterwards. This pins that contract.
    func testUserEditsSurviveViaReconciliation() {
        var lines = songWithOneDoubleLengthLine()
        lines[4].overrideText = "the words I actually sang"
        lines[4].accepted = true

        let result = PhrasePeriodLineRecutter.recut(
            lines, beatTimes: beats(duration: 60), tempo: bpm)
        let reconciled = TimedLyricSegment.reconciled(newSegments: result, against: lines)
        let carried = reconciled.filter { $0.overrideText == "the words I actually sang" }
        XCTAssertFalse(carried.isEmpty, "the override was lost across the re-cut")
        XCTAssertTrue(carried.allSatisfy(\.accepted))
    }

    // MARK: - Row-width spread

    func testSpanRatioMeasuresWordSpansNotSegmentBounds() {
        // A line with a long trailing silence in `end` is not a wide ROW.
        var narrow = line(start: 0, count: 4)
        narrow.end = 30
        let wide = line(start: 40, count: 16)
        let narrowSpan = narrow.words[3].end - narrow.words[0].start
        let wideSpan = wide.words[15].end - wide.words[0].start
        XCTAssertEqual(
            PhrasePeriodLineRecutter.spanRatio([narrow, narrow, wide]), wideSpan / narrowSpan,
            accuracy: 0.001)
    }
}
