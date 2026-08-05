import XCTest

@testable import SongWorkbench

/// PAGE-LEVEL geometry invariants, checked through the REAL pipeline:
/// `ChordProDraftBuilder.buildResult` → parsed `ChordProPreviewDocument` →
/// `ChordProPreviewIndexing` → `ChordProPreviewLineWindowResolver` (with the timeline's
/// authoritative row windows, exactly as the Review chart resolves them) → `ChordRowRuler`.
///
/// Exists because a day of layout bugs (2026-08-05) lived in the SEAMS between components
/// while every per-component test stayed green: the preview silently re-derived instrumental
/// row windows from chord onsets instead of the builder's bar-aligned windows, the waveform
/// strip followed collision-nudged word labels, and the gutter was gated on a lyric-derived
/// score. A unit test per component cannot catch "this row renders wider than that one" —
/// only asserting the page's invariants across ALL rows of a built song can.
final class ChartGeometryInvariantTests: XCTestCase {
    private let pixelsPerSecond: CGFloat = 200

    /// 120 BPM 4/4 (2 s bars): a 24 s / 12-bar intro full of chords, two verse lines, a 14.5-bar
    /// mid-song break, a final line, then an outro — every section shape today's bugs hid in.
    private func makeInput() -> ChordProDraftInput {
        let beats = stride(from: 0.5, through: 80.0, by: 0.5).map { $0 }
        func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ range: Range<Int>)
            -> TimedLyricWord
        {
            TimedLyricWord(text: text, start: start, end: end, characterRange: range)
        }
        let lyrics = [
            TimedLyricSegment(
                start: 24.0, end: 27.0, text: "First line here",
                words: [
                    word("First", 24.0, 24.8, 0..<5), word("line", 25.0, 25.8, 6..<10),
                    word("here", 26.0, 27.0, 11..<15),
                ]),
            TimedLyricSegment(
                start: 27.5, end: 30.5, text: "Second line goes",
                words: [
                    word("Second", 27.5, 28.3, 0..<6), word("line", 28.5, 29.3, 7..<11),
                    word("goes", 29.5, 30.5, 12..<16),
                ]),
            TimedLyricSegment(
                start: 45.0, end: 48.0, text: "Third line lands",
                words: [
                    word("Third", 45.0, 45.8, 0..<5), word("line", 46.0, 46.8, 6..<10),
                    word("lands", 47.0, 48.0, 11..<15),
                ]),
        ]
        let chords = stride(from: 1.0, through: 78.0, by: 4.0).map {
            EditableChordEvent(time: $0, chord: Int($0) % 8 < 4 ? "C" : "G", confidence: 0.9)
        }
        return ChordProDraftInput(
            title: "Geometry", tempo: 120, lyrics: lyrics, chords: chords,
            beatTimes: beats, sourceDuration: 80)
    }

    /// Every chord-only row's window, resolved exactly the way the Review chart resolves it:
    /// through the resolver WITH the timeline's row window for that display line.
    private func resolvedInstrumentalWindows(
        result: ChordProDraftResult
    ) throws -> [(number: Int, start: TimeInterval, end: TimeInterval)] {
        let document = try ChordProPreviewDocument(parsing: result.source)
        let items = ChordProPreviewIndexing.indexedBlocks(for: document)
        let windowsByLine = Dictionary(
            uniqueKeysWithValues: result.timeline.rows.compactMap { row in
                row.end > row.start ? (row.number, row.start...row.end) : nil
            })
        let lyricWindows = result.timeline.rows.filter(\.isLyric).map { $0.start...$0.end }
        var resolved: [(Int, TimeInterval, TimeInterval)] = []
        for (index, item) in items.enumerated()
        where ChordProPreviewIndexing.isChordOnlyRow(items, index) {
            guard let number = item.displayLineNumber else {
                XCTFail("chord-only row without a display line number at block \(index)")
                continue
            }
            guard
                let window = ChordProPreviewLineWindowResolver.chordOnlyLineWindow(
                    items: items,
                    index: index,
                    lyricLineWindows: lyricWindows,
                    timelineWindow: windowsByLine[number],
                    songDuration: 80,
                    envelopeDurations: [80],
                    beatTimes: makeInput().beatTimes,
                    beatLengthSeconds: 0.5,
                    chordOnsetTimes: makeInput().chords.map(\.time).sorted()
                )
            else {
                XCTFail("no window resolved for chord-only row \(number)")
                continue
            }
            resolved.append((number, window.start, window.end))
        }
        return resolved
    }

    func testInstrumentalRowsOfARunRenderAtEqualWidths() throws {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let windows = try resolvedInstrumentalWindows(result: result)
        XCTAssertFalse(windows.isEmpty)
        // Group into runs of consecutive display line numbers (one run per section).
        var runs: [[(number: Int, start: TimeInterval, end: TimeInterval)]] = []
        for window in windows {
            if let last = runs.last?.last, window.number == last.number + 1 {
                runs[runs.count - 1].append(window)
            } else {
                runs.append([window])
            }
        }
        for run in runs where run.count > 2 {
            // Interior rows (all but first and last, which absorb entry/remainder) must span
            // IDENTICAL durations — the "musically equal but vastly different on screen" bug.
            let interior = run.dropFirst().dropLast()
            guard let reference = interior.first else { continue }
            for row in interior {
                XCTAssertEqual(
                    row.end - row.start, reference.end - reference.start, accuracy: 0.001,
                    "row \(row.number) duration differs from row \(reference.number) in its run")
            }
            // And every interior duration is a whole number of 2 s bars.
            let bars = (reference.end - reference.start) / 2.0
            XCTAssertEqual(
                bars, bars.rounded(), accuracy: 0.001,
                "interior rows must span whole bars, got \(bars) bars")
        }
    }

    func testRowWindowsTileEachSectionContiguously() throws {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let windows = try resolvedInstrumentalWindows(result: result)
        for (early, late) in zip(windows, windows.dropFirst())
        where late.number == early.number + 1 {
            XCTAssertEqual(
                early.end, late.start, accuracy: 0.001,
                "row \(early.number) must end exactly where row \(late.number) begins")
        }
    }

    func testAllRowsShareDotColumnsOnTheRuler() throws {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let windows = try resolvedInstrumentalWindows(result: result)
        let input = makeInput()
        let grid = MeasureGrid(beatTimes: input.beatTimes, bpm: 120)
        let pixelsPerBeat = 0.5 * pixelsPerSecond
        let gutterPx = 2 * pixelsPerBeat
        var columnSets: [Set<Int>] = []
        for window in windows {
            // Anchor exactly as the chart does: the row's downbeat pinned at the gutter column.
            let downbeat = grid.nearestDownbeatTime(toTime: window.start)
            let ruler = ChordRowRuler(
                grid: grid, originTime: downbeat, gutterPx: gutterPx,
                pixelsPerBeat: pixelsPerBeat, pixelsPerSecond: pixelsPerSecond)
            let xs = ruler.beatXs(from: window.start, to: window.end)
            XCTAssertGreaterThan(xs.count, 1, "row \(window.number) must show beats")
            // Dot x mod pixelsPerBeat must be the shared gutter phase on EVERY row, so dots
            // form vertical columns down the page.
            columnSets.append(
                Set(xs.map { Int(($0.truncatingRemainder(dividingBy: pixelsPerBeat)).rounded()) })
            )
        }
        let distinctPhases = Set(columnSets.flatMap { $0 })
        XCTAssertEqual(
            distinctPhases.count, 1,
            "beat dots must sit in shared columns; found phases \(distinctPhases)")
    }
}
