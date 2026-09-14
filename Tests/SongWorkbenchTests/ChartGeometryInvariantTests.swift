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

    /// THE invariant the per-row gutter has to keep, asserted on rows that genuinely DISAGREE
    /// about their gutter — 0, 1 and 2 beats in the same page.
    ///
    /// A continuous per-row gutter was tried and reverted (`6c025e4`/`816857f`) precisely because
    /// it broke this: sizing each row to its own fractional pickup put every downbeat at an
    /// arbitrary sub-beat x, and the beat dots stopped forming columns down the page. Quantising
    /// to whole beats is what makes per-row safe, so the guard has to be a MIXED-gutter page; a
    /// uniform-gutter test passes either way and would not have caught the revert.
    func testMixedPerRowGuttersStillShareDotColumns() throws {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let windows = try resolvedInstrumentalWindows(result: result)
        let input = makeInput()
        let grid = MeasureGrid(beatTimes: input.beatTimes, bpm: 120)
        let beatLength = 0.5
        let pixelsPerBeat = CGFloat(beatLength) * pixelsPerSecond
        // Pickups chosen to land on every gutter size the rule can produce.
        let pickupBeats = [0.0, 0.02, 0.6, 1.4, 2.9]
        var gutterBeatsSeen: Set<Int> = []
        var phases: Set<Int> = []

        for (index, window) in windows.enumerated() {
            let downbeat = grid.nearestDownbeatTime(toTime: window.start)
            let pickup = pickupBeats[index % pickupBeats.count]
            let gutterBeats = ChartPickupGutter.beats(
                downbeat: downbeat, earliestContent: downbeat - pickup * beatLength,
                beatLengthSeconds: beatLength)
            gutterBeatsSeen.insert(gutterBeats)
            let ruler = ChordRowRuler(
                grid: grid, originTime: downbeat,
                gutterPx: CGFloat(gutterBeats) * pixelsPerBeat,
                pixelsPerBeat: pixelsPerBeat, pixelsPerSecond: pixelsPerSecond)
            let xs = ruler.beatXs(from: window.start, to: window.end)
            XCTAssertGreaterThan(xs.count, 1, "row \(window.number) must show beats")
            for x in xs {
                // Every beat dot sits an exact whole number of beats from the row's left edge.
                let columns = x / pixelsPerBeat
                XCTAssertEqual(
                    columns, columns.rounded(), accuracy: 0.001,
                    "row \(window.number) dot at \(x) px is not on a beat column")
                phases.insert(
                    Int((x.truncatingRemainder(dividingBy: pixelsPerBeat)).rounded())
                        % Int(pixelsPerBeat.rounded()))
            }
        }
        XCTAssertGreaterThan(
            gutterBeatsSeen.count, 1,
            "this guard is only meaningful when rows disagree about their gutter")
        XCTAssertEqual(
            phases, [0],
            "beat dots must share one column phase across rows; found \(phases)")
    }

    /// The bug this change exists to fix, at the pixel: a row whose first sound lands ON its
    /// downbeat reserves nothing, so that sound renders at the row's left edge.
    ///
    /// Doc Holiday's opening chord is stored at beat index 0.00 and rendered two beats in, because
    /// the gutter was a flat two beats on every row whether or not anything preceded the downbeat.
    func testARowWithNoPickupRendersItsFirstSoundAtTheLeftEdge() throws {
        let input = makeInput()
        let grid = MeasureGrid(beatTimes: input.beatTimes, bpm: 120)
        let beatLength = 0.5
        let pixelsPerBeat = CGFloat(beatLength) * pixelsPerSecond
        let downbeat = grid.nearestDownbeatTime(toTime: 24.0)

        let gutterBeats = ChartPickupGutter.beats(
            downbeat: downbeat, earliestContent: downbeat, beatLengthSeconds: beatLength)
        XCTAssertEqual(gutterBeats, 0, "content on the downbeat must reserve no gutter")

        let ruler = ChordRowRuler(
            grid: grid, originTime: downbeat, gutterPx: CGFloat(gutterBeats) * pixelsPerBeat,
            pixelsPerBeat: pixelsPerBeat, pixelsPerSecond: pixelsPerSecond)
        XCTAssertEqual(
            ruler.x(atTime: downbeat), 0, accuracy: 0.0001,
            "a row with no pickup must open flush left, not two beats in")

        // And a row that DOES have a pickup still renders it left of the downbeat, unclipped.
        let pickupTime = downbeat - 1.4 * beatLength
        let pickupGutter = ChartPickupGutter.beats(
            downbeat: downbeat, earliestContent: pickupTime, beatLengthSeconds: beatLength)
        XCTAssertEqual(pickupGutter, 2)
        let pickupRuler = ChordRowRuler(
            grid: grid, originTime: downbeat, gutterPx: CGFloat(pickupGutter) * pixelsPerBeat,
            pixelsPerBeat: pixelsPerBeat, pixelsPerSecond: pixelsPerSecond)
        XCTAssertGreaterThan(
            pickupRuler.x(atTime: pickupTime), 0,
            "a real pickup must not be clamped onto the left edge")
        XCTAssertLessThan(
            pickupRuler.x(atTime: pickupTime), pickupRuler.x(atTime: downbeat),
            "a pickup must render LEFT of the downbeat it resolves onto")
    }

    /// The WINDOW FIT, end to end through the real ruler: at 1× zoom a row exactly one phrase
    /// period long ends inside the viewport, on every viewport width. Asserted here rather than
    /// only on the fit arithmetic because the promise is about pixels the `ChordRowRuler`
    /// produces — the seam is where the last round of layout bugs lived.
    func testAPhraseLongRowFitsTheViewportAtOneZoom() throws {
        let input = makeInput()
        let grid = MeasureGrid(beatTimes: input.beatTimes, bpm: 120)
        let beatLength = 0.5
        let inset = ChordProPreviewLineLayout.chartHorizontalInset
        let leading = ChordProPreviewLineLayout.rowLeadingWidth
        let gutterBeats = ChordProPreviewLineLayout.gutterBeats

        for viewportWidth: CGFloat in [800, 1200, 1600, 2400] {
            for beatsPerLine in [4, 8, 12, 16] {
                let scale = ChordProChartScale(
                    fontSize: ChordProChartScale.minimumFontSize,
                    fitFactor: ChordProChartScale.fitFactor(
                        availableWidth: viewportWidth,
                        horizontalInset: inset,
                        rowLeadingWidth: leading,
                        beatsPerLine: beatsPerLine,
                        gutterBeats: gutterBeats,
                        beatLengthSeconds: beatLength,
                        basePixelsPerSecond: ChordProPreviewLineLayout.pixelsPerSecond))
                let scaledPixelsPerSecond = scale.scaled(
                    ChordProPreviewLineLayout.pixelsPerSecond)
                let pixelsPerBeat = CGFloat(beatLength) * scaledPixelsPerSecond
                let downbeat = grid.nearestDownbeatTime(toTime: 24.0)
                let ruler = ChordRowRuler(
                    grid: grid, originTime: downbeat, gutterPx: gutterBeats * pixelsPerBeat,
                    pixelsPerBeat: pixelsPerBeat, pixelsPerSecond: scaledPixelsPerSecond)

                // The row's right edge on screen: content end, plus the line-number column to its
                // left and the chart's own padding.
                let phraseEnd = downbeat + beatLength * Double(beatsPerLine)
                let rightEdge = ruler.x(atTime: phraseEnd) + scale.scaled(leading) + inset

                // Exactly the viewport: it fits AND fills — not a fit that shrinks to be safe.
                XCTAssertEqual(
                    rightEdge, viewportWidth, accuracy: 0.5,
                    "P=\(beatsPerLine) does not fill a \(viewportWidth) px viewport at 1× zoom")
                // Beats stay exactly equidistant on the fitted axis.
                let xs = ruler.beatXs(from: downbeat, to: phraseEnd)
                let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }
                for gap in gaps {
                    XCTAssertEqual(gap, pixelsPerBeat, accuracy: 0.0001)
                }
            }
        }
    }

    func testShortLyricRowsStillReserveThePhraseFrameWidth() throws {
        let beatLength = 0.5
        let beatsPerLine = 8
        let scale = ChordProChartScale(
            fontSize: ChordProChartScale.minimumFontSize,
            fitFactor: ChordProChartScale.fitFactor(
                availableWidth: 1200,
                horizontalInset: ChordProPreviewLineLayout.chartHorizontalInset,
                rowLeadingWidth: ChordProPreviewLineLayout.rowLeadingWidth,
                beatsPerLine: beatsPerLine,
                gutterBeats: ChordProPreviewLineLayout.gutterBeats,
                beatLengthSeconds: beatLength,
                basePixelsPerSecond: ChordProPreviewLineLayout.pixelsPerSecond))
        let pixelsPerBeat =
            CGFloat(beatLength) * scale.scaled(ChordProPreviewLineLayout.pixelsPerSecond)
        let shortLyricWidth = pixelsPerBeat * 1.25
        let referenceEndX = ChordProPreviewLineLayout.referenceFrameEndX(
            gutterPx: pixelsPerBeat,
            reservedGutterPx: ChordProPreviewLineLayout.gutterBeats * pixelsPerBeat,
            phraseWidth: CGFloat(beatsPerLine) * pixelsPerBeat)

        XCTAssertGreaterThan(
            referenceEndX, shortLyricWidth,
            "fixture must model the visible failure: a lyric island shorter than its phrase frame")
        XCTAssertEqual(
            referenceEndX, pixelsPerBeat * 10, accuracy: 0.001,
            "the fit-reserved two-beat pickup column plus the 8-beat phrase must be reserved")
        XCTAssertEqual(
            ChordProPreviewLineLayout.rhythmicFrameWidth(
                wordExtent: shortLyricWidth,
                chordExtent: shortLyricWidth,
                bassExtent: 0,
                rowContentEndX: referenceEndX),
            referenceEndX,
            accuracy: 0.001,
            "a short lyric row must reserve the full phrase frame instead of laying out as a tiny island"
        )
    }

    // MARK: - Fixed-period rows (tasks/spec-fixed-period-rows.md)

    /// 120 BPM 4/4 (beat 0 at 0.5 s, downbeats every 2 s from 0.5 s) with verse lines on a steady
    /// 8-beat phrase, one line running 14 beats, and one line opening a beat before its downbeat —
    /// the shapes that make today's rows differ in length.
    private func makeFixedPeriodInput() -> ChordProDraftInput {
        let beats = stride(from: 0.5, through: 80.0, by: 0.5).map { $0 }
        func line(_ text: String, _ onsets: [TimeInterval], end: TimeInterval) -> TimedLyricSegment
        {
            var cursor = 0
            let tokens = text.split(separator: " ").map(String.init)
            let words = zip(tokens, onsets).enumerated().map { index, pair -> TimedLyricWord in
                let (token, onset) = pair
                let range = cursor..<(cursor + token.count)
                cursor += token.count + 1
                let next = index + 1 < onsets.count ? onsets[index + 1] : end
                return TimedLyricWord(text: token, start: onset, end: next, characterRange: range)
            }
            return TimedLyricSegment(start: onsets[0], end: end, text: text, words: words)
        }
        let lyrics = [
            line("First line here", [24.5, 25.5, 26.5], end: 27.5),
            line("Second line goes", [28.5, 29.5, 30.5], end: 31.5),
            line("Third line lands", [32.5, 33.5, 34.5], end: 35.5),
            line(
                "A much longer line that keeps on going",
                [36.5, 37.5, 38.5, 39.5, 40.5, 41.5, 42.5, 43.0], end: 43.5),
            line("And then we sing", [44.0, 44.5, 45.5, 46.5], end: 47.5),
            line("Last line home", [48.5, 49.5, 50.5], end: 51.5),
        ]
        // A chord on every downbeat, plus two changes played BETWEEN sung lines (27.9 s, 43.7 s):
        // today those fold into a neighbouring line; on fixed rows they belong to the row whose
        // window holds them.
        let downbeatChords = stride(from: 0.5, through: 78.5, by: 2.0).enumerated().map {
            index, time in
            EditableChordEvent(
                time: time, chord: ["C", "G", "Am", "F"][index % 4], confidence: 0.9)
        }
        let chords =
            (downbeatChords + [
                EditableChordEvent(time: 27.9, chord: "Em", confidence: 0.9),
                EditableChordEvent(time: 43.7, chord: "D", confidence: 0.9),
            ]).sorted { $0.time < $1.time }
        var input = ChordProDraftInput(
            title: "Fixed period", tempo: 120, lyrics: lyrics, chords: chords,
            beatTimes: beats, sourceDuration: 80)
        input.barGrid = SongBarGrid(
            beatsPerBar: 4, barPhase: 0, confidence: 0.5, phaseSource: .drumAccents)
        return input
    }

    private func fixedPeriodRows(_ input: ChordProDraftInput) -> [SongTimeline.Row] {
        ChordProDraftBuilder().buildResult(input).timeline.rows
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
    }

    func testFixedPeriodRowsTileTheSongAndSpanOneWholeBarPeriod() throws {
        let input = makeFixedPeriodInput()
        let rows = fixedPeriodRows(input)
        XCTAssertGreaterThanOrEqual(rows.count, 3)
        XCTAssertEqual(
            rows.first?.start ?? -1, 0, accuracy: 1e-6, "rows must start at the song's start")
        XCTAssertEqual(rows.last?.end ?? -1, 80, accuracy: 1e-6, "rows must end at the song's end")
        for (earlier, later) in zip(rows, rows.dropFirst()) {
            XCTAssertEqual(
                earlier.end, later.start, accuracy: 1e-6,
                "rows \(earlier.number) and \(later.number) must tile with no gap or overlap")
        }
        let grid = MeasureGrid(beatTimes: input.beatTimes, bpm: 120, beatsPerBar: 4, barPhase: 0)
        let interior = Array(rows.dropFirst().dropLast())
        let spans = interior.map {
            grid.beatIndex(atTime: $0.end) - grid.beatIndex(atTime: $0.start)
        }
        let period = try XCTUnwrap(spans.first)
        XCTAssertGreaterThan(period, 0)
        XCTAssertEqual(
            period.truncatingRemainder(dividingBy: 4), 0, accuracy: 0.01,
            "the row period (\(period) beats) must be whole bars")
        for (row, span) in zip(interior, spans) {
            XCTAssertEqual(
                span, period, accuracy: 0.01,
                "row \(row.number) spans \(span) beats; every interior row must span \(period)")
        }
    }

    func testInteriorFixedPeriodRowsStartOnDownbeats() {
        let input = makeFixedPeriodInput()
        let grid = MeasureGrid(beatTimes: input.beatTimes, bpm: 120, beatsPerBar: 4, barPhase: 0)
        for row in fixedPeriodRows(input).dropFirst().dropLast() {
            let index = grid.beatIndex(atTime: row.start)
            XCTAssertEqual(
                index, index.rounded(), accuracy: 0.01,
                "row \(row.number) starts \(index) beats in, between beats")
            XCTAssertTrue(
                grid.isDownbeat(beatIndex: Int(index.rounded())),
                "row \(row.number) starts on beat index \(index), not a downbeat")
        }
    }

    func testEveryChordSitsInTheRowWhoseWindowHoldsItsOnset() {
        let input = makeFixedPeriodInput()
        let rows = fixedPeriodRows(input)
        for chord in input.chords {
            guard let owner = rows.first(where: { $0.start <= chord.time && chord.time < $0.end })
            else {
                XCTFail("no row window holds the chord at \(chord.time) s")
                continue
            }
            XCTAssertTrue(
                owner.chordTimes.contains { abs($0 - chord.time) < 1e-6 },
                "the chord at \(chord.time) s must sit in row \(owner.number) "
                    + "(\(owner.start)–\(owner.end) s), whose window holds it")
        }
    }

    func testEveryFixedPeriodRowRendersTheSameFrameWidth() {
        let beatLength = 0.5
        let periodBeats = 8
        let pixelsPerBeat = CGFloat(beatLength) * ChordProPreviewLineLayout.pixelsPerSecond
        let reservedGutter = ChordProPreviewLineLayout.gutterBeats * pixelsPerBeat
        let lyricFrame = ChordProPreviewLineLayout.referenceFrameEndX(
            gutterPx: 0, reservedGutterPx: reservedGutter,
            phraseWidth: CGFloat(periodBeats) * pixelsPerBeat)

        let fixedPeriod = (
            reservedGutterPx: reservedGutter, periodPx: CGFloat(periodBeats) * pixelsPerBeat
        )

        // A last word whose label hangs three beats past the period must not widen its row.
        XCTAssertEqual(
            ChordProPreviewLineLayout.rhythmicFrameWidth(
                wordExtent: lyricFrame + 3 * pixelsPerBeat, chordExtent: lyricFrame,
                bassExtent: 0, rowContentEndX: lyricFrame, fixedPeriod: fixedPeriod),
            lyricFrame, accuracy: 0.001,
            "an overhanging label widened a fixed-period lyric row")
        // A chord-only row of exactly one period draws as wide as a sung row of one period.
        XCTAssertEqual(
            ChordProPreviewLineLayout.instrumentalWidth(
                rhythmicSpacing: true, lineDuration: Double(periodBeats) * beatLength,
                chordColumnExtent: 12, characterWidth: 9,
                pixelsPerSecond: ChordProPreviewLineLayout.pixelsPerSecond,
                fixedPeriod: fixedPeriod),
            lyricFrame, accuracy: 0.001,
            "a one-period chord-only row renders at a different width from a one-period lyric row")
    }

    func testHoldLinesRunToTheWordEndButStopAtTheNextLabelAndTheFrame() {
        // Three labels 20 px wide. Word 0 is held to x 200; word 1 ends right after its label;
        // word 2 is held past the frame edge.
        let spans = ChordProPreviewLineLayout.holdLineSpans(
            labelEnds: [20, 320, 520], wordEndXs: [200, 330, 900], labelStarts: [0, 300, 500],
            frameEnd: 700, gap: 4, minimumLength: 50)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].x, 24, accuracy: 0.001)
        XCTAssertEqual(spans[0].width, 176, accuracy: 0.001, "a held word runs to its end")
        XCTAssertEqual(spans[1].x, 524, accuracy: 0.001)
        XCTAssertEqual(spans[1].width, 176, accuracy: 0.001, "and never past the frame edge")
        // A long hold overlapping the next label stops a gap short of it.
        let clipped = ChordProPreviewLineLayout.holdLineSpans(
            labelEnds: [20], wordEndXs: [400], labelStarts: [0, 150], frameEnd: nil, gap: 4,
            minimumLength: 50)
        XCTAssertEqual(clipped.first?.width ?? -1, 122, accuracy: 0.001)
    }

    /// Playback on fixed-period rows: at every playhead time, the sung row the highlight (and so
    /// the auto-scroll) follows is the timeline row the ball follows — at a row's downbeat before its
    /// first word, and while a pickup is sung just ahead of the next row's downbeat. The second
    /// input shifts every line half a beat late so first words land after their downbeats.
    func testTheHighlightFollowsTheTimelineRowOnFixedPeriodRows() {
        let base = makeFixedPeriodInput()
        func shifted(_ seconds: TimeInterval) -> ChordProDraftInput {
            let lyrics = base.lyrics.map { line -> TimedLyricSegment in
                var moved = line
                moved.start += seconds
                moved.end += seconds
                moved.words = line.words.map { word in
                    var w = word
                    w.start += seconds
                    w.end += seconds
                    return w
                }
                return moved
            }
            var input = ChordProDraftInput(
                title: base.title, tempo: base.tempo, lyrics: lyrics, chords: base.chords,
                beatTimes: base.beatTimes, sourceDuration: base.sourceDuration)
            input.barGrid = base.barGrid
            return input
        }
        for (label, input) in [("fixture", base), ("half a beat late", shifted(0.25))] {
            let result = ChordProDraftBuilder().buildResult(input)
            let deriver = ChordProHighlightDeriver(
                lyricSegments: result.chartLines.map(\.segment), chordEvents: input.chords,
                confidenceThreshold: input.confidenceThreshold)
            var disagreements: [String] = []
            for step in 0..<800 {
                let time = Double(step) * 0.1
                guard let row = result.timeline.row(at: time), case .lyric(let ordinal) = row.kind
                else { continue }
                let highlighted = deriver.lyricOrdinal(at: time)
                if highlighted != ordinal {
                    disagreements.append(
                        String(
                            format: "t=%.1f row %d (ordinal %d) highlight %@", time, row.number,
                            ordinal, highlighted.map(String.init) ?? "nil"))
                }
            }
            XCTAssertEqual(
                disagreements.count, 0,
                "\(label): the highlight must follow the timeline row: \(disagreements.prefix(4))")
        }
    }
}
