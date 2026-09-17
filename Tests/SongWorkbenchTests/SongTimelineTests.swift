import XCTest

@testable import SongWorkbench

final class SongTimelineTests: XCTestCase {
    // A synthetic song shaped like the audited Summertime defect: a LONG intro (multiple
    // chord-only rows), two verse lines, a long instrumental break, one more line, then
    // outro chords. 120 BPM → 0.5 s beats, 2 s bars.
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
        // Chords through the intro, verse, break, and outro.
        let chords = stride(from: 1.0, through: 78.0, by: 4.0).map {
            EditableChordEvent(time: $0, chord: Int($0) % 8 < 4 ? "C" : "G", confidence: 0.9)
        }
        return ChordProDraftInput(
            title: "Timeline Test",
            tempo: 120,
            lyrics: lyrics,
            chords: chords,
            confidenceThreshold: 0.5,
            beatTimes: beats,
            sourceDuration: 80,
            untranscribedVocalRegions: [50.0...55.0]
        )
    }

    /// Every numbered musical line of the rendered source (non-blank, non-directive) must have
    /// exactly one timeline row, in order — the alignment invariant the ball relies on.
    func testRowNumbersMatchRenderedMusicalLines() {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let numberedLines = result.source
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("{") }
        XCTAssertEqual(result.timeline.rows.count, numberedLines.count)
        XCTAssertEqual(result.timeline.rows.map(\.number), Array(1...numberedLines.count))
    }

    func testMultiRowIntroHasPerRowWindowsCoveringTheGap() throws {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let introRows = result.timeline.rows.filter {
            $0.kind == .instrumental(role: .intro)
        }
        // 24s intro at 2s bars = 12 bars → split into multiple rows (typical lyric bars ~4).
        XCTAssertGreaterThan(introRows.count, 1, "long intro must produce multiple rows")
        XCTAssertEqual(introRows.first?.start ?? -1, 0, accuracy: 1e-9)
        // The intro runs up to the first sung row, which starts on its row grid window.
        let firstLyric = try XCTUnwrap(result.timeline.rows.first(where: \.isLyric))
        XCTAssertEqual(introRows.last?.end ?? -1, firstLyric.start, accuracy: 1e-9)
        // Contiguous, ascending windows — the ball walks them row by row (audit RC-2).
        for (early, late) in zip(introRows, introRows.dropFirst()) {
            XCTAssertEqual(early.end, late.start, accuracy: 1e-9)
        }
        // row(at:) resolves each intro moment to ITS row, not the last one.
        let timeline = result.timeline
        let first = timeline.row(at: 1.0)
        // Half a second before the intro ends: a pickup sung just ahead of the first lyric row's
        // downbeat now stays in the row where it sounds, so the last intro moment is found from
        // the intro rows themselves rather than a fixed time.
        let last = timeline.row(at: (introRows.last?.end ?? 24) - 0.5)
        XCTAssertEqual(first?.number, introRows.first?.number)
        XCTAssertEqual(last?.number, introRows.last?.number)
        XCTAssertNotEqual(first?.number, last?.number)
    }

    func testLyricRowsCarryOrdinalsAndWindows() {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let lyricRows = result.timeline.rows.filter(\.isLyric)
        XCTAssertFalse(lyricRows.isEmpty)
        // Ordinals count the sung rows in chart order, and each one is `chartLines[ordinal]`.
        XCTAssertEqual(lyricRows.map(\.kind), lyricRows.indices.map { .lyric(ordinal: $0) })
        XCTAssertEqual(lyricRows.count, result.chartLines.count)
        // The playhead on any word a row sings (pickups drawn in its gutter aside) resolves to
        // that row.
        for (row, line) in zip(lyricRows, result.chartLines) {
            for word in line.segment.words where word.start >= row.start {
                XCTAssertEqual(
                    result.timeline.row(at: word.start)?.number, row.number,
                    "word \(word.text) at \(word.start) s must resolve to row \(row.number)")
            }
        }
    }

    func testBreakAndOutroRowsAreTypedAndUntranscribedFlagged() throws {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        let rows = result.timeline.rows
        let interludes = rows.filter { $0.kind == .instrumental(role: .interlude) }
        // The 30.5→45 gap (7+ bars) becomes instrumental rows that tile the space between the
        // sung rows on either side of it.
        let firstInterlude = try XCTUnwrap(interludes.first)
        let lastInterlude = try XCTUnwrap(interludes.last)
        let before = try XCTUnwrap(
            rows.last { $0.isLyric && $0.end <= firstInterlude.start + 1e-9 })
        let after = try XCTUnwrap(rows.first { $0.isLyric && $0.start >= lastInterlude.end - 1e-9 })
        XCTAssertEqual(firstInterlude.start, before.end, accuracy: 1e-9)
        XCTAssertEqual(lastInterlude.end, after.start, accuracy: 1e-9)
        // The untranscribed sung span 50–55 lies in the OUTRO here (after the last line at 48):
        // outro rows overlapping it are flagged; the interlude rows (30.5–45) are not.
        XCTAssertTrue(interludes.allSatisfy { !$0.containsUntranscribedVocals })
        let outros = result.timeline.rows.filter { $0.kind == .instrumental(role: .outro) }
        XCTAssertFalse(outros.isEmpty)
        XCTAssertTrue(
            outros.contains(where: \.containsUntranscribedVocals),
            "outro rows overlapping 50...55 must carry the untranscribed-vocals flag")
    }

    func testRowAtBeforeFirstRowIsNilAndNextRowFinds() {
        let result = ChordProDraftBuilder().buildResult(makeInput())
        XCTAssertNil(result.timeline.row(at: -0.5))
        XCTAssertEqual(result.timeline.nextRow(after: -0.5)?.number, 1)
    }

    /// The convenience `buildResult(_:)` and legacy `build(_:)` must agree byte-for-byte.
    func testBuildAndBuildResultProduceIdenticalSource() {
        let input = makeInput()
        XCTAssertEqual(
            ChordProDraftBuilder().build(input), ChordProDraftBuilder().buildResult(input).source)
    }
}

// MARK: - Persisted layout

extension SongTimelineTests {
    func testRowIDsAreStableAcrossRebuildsAndStructureMatchIgnoresTextEdits() throws {
        let lyrics = [
            TimedLyricSegment(start: 0, end: 2, text: "hello world"),
            TimedLyricSegment(start: 20, end: 22, text: "second line"),
        ]
        let input = ChordProDraftInput(
            title: "t", tempo: 120, lyrics: lyrics,
            chords: [EditableChordEvent(time: 8, chord: "C", confidence: 0.9)])
        let first = ChordProDraftBuilder().buildResult(input)
        let again = ChordProDraftBuilder().buildResult(input)
        XCTAssertEqual(first.timeline.rows.map(\.id), again.timeline.rows.map(\.id))
        XCTAssertEqual(Set(first.timeline.rows.map(\.id)).count, first.timeline.rows.count)

        XCTAssertTrue(first.timeline.matchesRowStructure(of: first.source))
        XCTAssertTrue(
            first.timeline.matchesRowStructure(
                of: first.source.replacingOccurrences(of: "hello world", with: "hullo there")))
        XCTAssertFalse(
            first.timeline.matchesRowStructure(
                of: first.source.replacingOccurrences(of: "second line", with: "")))

        let layout = PersistedChartLayout(result: first, lyrics: lyrics)
        let decoded = try JSONDecoder().decode(
            PersistedChartLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.result(source: first.source).timeline, first.timeline)
        XCTAssertEqual(
            layout.lyricStructureDigest,
            LyricStructureDigest.of(
                lyrics.map {
                    TimedLyricSegment(start: $0.start + 0.3, end: $0.end + 0.3, text: $0.text)
                }),
            "timing changes keep the digest")
        XCTAssertNotEqual(
            layout.lyricStructureDigest,
            LyricStructureDigest.of([
                lyrics[0], TimedLyricSegment(start: 20, end: 22, text: "other line"),
            ]))
    }
}
