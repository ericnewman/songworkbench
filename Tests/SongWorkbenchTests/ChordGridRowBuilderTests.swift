import XCTest

@testable import SongWorkbench

final class ChordGridRowBuilderTests: XCTestCase {
    private func event(_ time: TimeInterval, _ chord: String, confidence: Float? = 0.8)
        -> EditableChordEvent
    {
        EditableChordEvent(time: time, chord: chord, confidence: confidence)
    }

    private func line(_ start: TimeInterval, _ end: TimeInterval, _ text: String)
        -> TimedLyricSegment
    {
        TimedLyricSegment(start: start, end: end, text: text, words: [])
    }

    // MARK: - Row grouping

    func testChordsGroupUnderTheLyricLineTheySoundIn() {
        let rows = ChordGridRowBuilder.rows(
            events: [event(1, "C"), event(3, "G"), event(6, "Am")],
            lyricSegments: [line(0, 4, "first line"), line(5, 9, "second line")]
        )
        XCTAssertEqual(rows.map(\.lyric), ["first line", "second line"])
        XCTAssertEqual(rows[0].eventIDs.count, 2)
        XCTAssertEqual(rows[1].eventIDs.count, 1)
    }

    func testLyricLineWithNoChordsStillGetsARow() {
        // The chart shows that line bare; dropping the row would misalign the grid against it.
        let rows = ChordGridRowBuilder.rows(
            events: [event(1, "C")],
            lyricSegments: [line(0, 4, "has a chord"), line(5, 9, "has none")]
        )
        XCTAssertEqual(rows.map(\.lyric), ["has a chord", "has none"])
        XCTAssertTrue(rows[1].eventIDs.isEmpty)
    }

    func testChordsBeforeTheFirstLineBecomeAnIntroRow() {
        let rows = ChordGridRowBuilder.rows(
            events: [event(0.5, "C"), event(6, "G")],
            lyricSegments: [line(5, 9, "the only line")]
        )
        XCTAssertEqual(rows.map(\.instrumentalLabel), ["Intro", nil])
        XCTAssertEqual(rows[0].eventIDs.count, 1)
        XCTAssertTrue(rows[0].isInstrumental)
    }

    func testChordsAfterTheLastLineBecomeAnOutroRow() {
        let rows = ChordGridRowBuilder.rows(
            events: [event(1, "C"), event(12, "G")],
            lyricSegments: [line(0, 4, "the only line")],
            sourceDuration: 20
        )
        XCTAssertEqual(rows.map(\.instrumentalLabel), [nil, "Outro"])
        XCTAssertEqual(rows[1].end, 20)
    }

    func testChordsInAGapBetweenLinesBecomeAnInstrumentalRow() {
        let rows = ChordGridRowBuilder.rows(
            events: [event(1, "C"), event(6, "F"), event(11, "G")],
            lyricSegments: [line(0, 4, "before the break"), line(10, 14, "after the break")]
        )
        XCTAssertEqual(
            rows.map { $0.lyric ?? $0.instrumentalLabel! },
            ["before the break", "Instrumental", "after the break"])
        XCTAssertEqual(rows[1].eventIDs.count, 1)
    }

    func testEveryEventLandsInExactlyOneRow() {
        let events = [
            event(0.5, "C"), event(1, "F"), event(6, "G"), event(11, "Am"), event(30, "C"),
        ]
        let rows = ChordGridRowBuilder.rows(
            events: events,
            lyricSegments: [line(0.8, 4, "one"), line(10, 14, "two")],
            sourceDuration: 40
        )
        let placed = rows.flatMap(\.eventIDs)
        XCTAssertEqual(Set(placed).count, events.count, "no event may be dropped")
        XCTAssertEqual(placed.count, events.count, "no event may appear twice")
    }

    func testNoLyricsYieldsOneInstrumentalRow() {
        let rows = ChordGridRowBuilder.rows(
            events: [event(1, "C"), event(3, "G")],
            lyricSegments: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isInstrumental)
        XCTAssertEqual(rows[0].eventIDs.count, 2)
    }

    func testEmptyInputYieldsNoRows() {
        XCTAssertTrue(ChordGridRowBuilder.rows(events: [], lyricSegments: []).isEmpty)
    }

    func testRowIdentitiesAreUnique() {
        let rows = ChordGridRowBuilder.rows(
            events: [event(0.5, "C"), event(1, "F"), event(6, "G"), event(11, "Am")],
            lyricSegments: [line(0.8, 4, "one"), line(10, 14, "two")]
        )
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    // MARK: - Confidence bands

    func testConfidenceBands() {
        XCTAssertEqual(ChordConfidenceBand.band(for: 0.2), .low)
        XCTAssertEqual(ChordConfidenceBand.band(for: 0.49), .low)
        XCTAssertEqual(ChordConfidenceBand.band(for: 0.5), .medium)
        XCTAssertEqual(ChordConfidenceBand.band(for: 0.74), .medium)
        XCTAssertEqual(ChordConfidenceBand.band(for: 0.75), .high)
        XCTAssertEqual(ChordConfidenceBand.band(for: 1.0), .high)
    }

    func testManualChordIsItsOwnBandNotLowConfidence() {
        // A hand-typed chord has no measurement behind it; colouring it red would claim the
        // detector is unsure about a chord the detector never saw.
        XCTAssertEqual(ChordConfidenceBand.band(for: nil), .manual)
    }

    // MARK: - Playback position

    func testSoundingChordIsTheLatestEventAtOrBeforeThePlayhead() {
        let events = [event(0, "C"), event(4, "G"), event(8, "Am")]
        XCTAssertEqual(
            ChordGridRowBuilder.soundingEventID(events: events, at: 5), events[1].id,
            "a chord rings until the next is struck")
        XCTAssertEqual(
            ChordGridRowBuilder.soundingEventID(events: events, at: 4), events[1].id,
            "lit exactly at the attack")
        XCTAssertEqual(
            ChordGridRowBuilder.soundingEventID(events: events, at: 99), events[2].id,
            "the last chord holds through the outro")
    }

    func testNothingSoundsBeforeTheFirstChord() {
        XCTAssertNil(
            ChordGridRowBuilder.soundingEventID(events: [event(4, "C")], at: 1))
        XCTAssertNil(ChordGridRowBuilder.soundingEventID(events: [], at: 1))
    }

    func testSingingWordRangeTracksThePlayhead() {
        let segment = TimedLyricSegment(
            start: 0, end: 3, text: "one two three",
            words: [
                TimedLyricWord(text: "one", start: 0, end: 1, characterRange: 0..<3),
                TimedLyricWord(text: "two", start: 1, end: 2, characterRange: 4..<7),
                TimedLyricWord(text: "three", start: 2, end: 3, characterRange: 8..<13),
            ])
        XCTAssertEqual(ChordGridRowBuilder.singingWordRange(in: segment, at: 0.5), 0..<3)
        XCTAssertEqual(ChordGridRowBuilder.singingWordRange(in: segment, at: 1.5), 4..<7)
        XCTAssertEqual(ChordGridRowBuilder.singingWordRange(in: segment, at: 2.5), 8..<13)
    }

    func testEmphasisHoldsOnTheLastWordThroughATrailingGap() {
        // Otherwise the bold blinks off on a held note or between lines.
        let segment = TimedLyricSegment(
            start: 0, end: 3, text: "one two",
            words: [
                TimedLyricWord(text: "one", start: 0, end: 1, characterRange: 0..<3),
                TimedLyricWord(text: "two", start: 1, end: 2, characterRange: 4..<7),
            ])
        XCTAssertEqual(ChordGridRowBuilder.singingWordRange(in: segment, at: 10), 4..<7)
    }

    func testNoWordTimingsMeansNoEmphasis() {
        // Some transcription paths produce line-level timings only; guessing a range from
        // character counts would bold the wrong word.
        let segment = TimedLyricSegment(start: 0, end: 3, text: "one two", words: [])
        XCTAssertNil(ChordGridRowBuilder.singingWordRange(in: segment, at: 1))
    }

    func testNoEmphasisBeforeTheLineStarts() {
        let segment = TimedLyricSegment(
            start: 5, end: 8, text: "one",
            words: [TimedLyricWord(text: "one", start: 5, end: 6, characterRange: 0..<3)])
        XCTAssertNil(ChordGridRowBuilder.singingWordRange(in: segment, at: 1))
    }

    // MARK: - Instrumental line breaking

    /// 120 BPM: 0.5 s beats, 2 s bars.
    private var beats: [TimeInterval] { stride(from: 0.0, through: 60.0, by: 0.5).map { $0 } }

    func testLongIntroBreaksAcrossSeveralLines() {
        // Thirteen chords over ~19 s with no lyric to break them — the crowded-intro case.
        let intro = (0..<13).map { event(Double($0) * 1.5, "C") }
        let sung = [line(20, 24, "first sung line"), line(25, 29, "second sung line")]
        let rows = ChordGridRowBuilder.rows(
            events: intro + [event(21, "G")],
            lyricSegments: sung,
            beatTimes: beats
        )
        let introRows = rows.filter { $0.instrumentalLabel == "Intro" }
        XCTAssertGreaterThan(introRows.count, 1, "a 19 s intro must not render as one line")
        XCTAssertEqual(
            introRows.flatMap(\.eventIDs).count, intro.count, "no chord may be lost in the split")
    }

    func testTargetComesFromTheSongsOwnSungLineLength() {
        // Median sung line here is 4 s, so that is the instrumental line length too.
        let target = ChordGridRowBuilder.instrumentalLineTarget(
            lyricSegments: [line(0, 4, "a"), line(10, 14, "b"), line(20, 26, "c")],
            beatTimes: beats)
        XCTAssertEqual(target, 4, accuracy: 0.001)
    }

    func testTargetFallsBackToFourBarsWithNoLyrics() {
        // 0.5 s beats, 4/4 → a bar is 2 s, four bars is 8 s.
        let target = ChordGridRowBuilder.instrumentalLineTarget(
            lyricSegments: [], beatTimes: beats)
        XCTAssertEqual(target, 8, accuracy: 0.001)
    }

    func testTargetFallsBackToAConstantWithNeither() {
        XCTAssertEqual(
            ChordGridRowBuilder.instrumentalLineTarget(lyricSegments: [], beatTimes: []), 8)
    }

    func testSplitBreaksBeforeTheChordThatOverrunsTheTarget() {
        let events = [event(0, "C"), event(1, "F"), event(2, "G"), event(9, "Am")]
        let row = ChordGridRowBuilder.Row(
            id: "intro", lyric: nil, segment: nil, instrumentalLabel: "Intro",
            start: 0, end: 12, eventIDs: events.map(\.id))
        let split = ChordGridRowBuilder.splitInstrumental(row, events: events, target: 4)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].eventIDs.count, 3, "C/F/G fit inside the 4 s target")
        XCTAssertEqual(split[1].eventIDs.count, 1, "Am at 9 s starts a new line")
    }

    func testDenseRunBreaksOnChordCountEvenWhenItIsShort() {
        let events = (0..<12).map { event(Double($0) * 0.1, "C") }
        let row = ChordGridRowBuilder.Row(
            id: "intro", lyric: nil, segment: nil, instrumentalLabel: "Intro",
            start: 0, end: 2, eventIDs: events.map(\.id))
        let split = ChordGridRowBuilder.splitInstrumental(row, events: events, target: 60)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].eventIDs.count, ChordGridRowBuilder.maximumInstrumentalChords)
    }

    func testEveryLineKeepsAtLeastOneChordEvenWithAnAbsurdTarget() {
        // A target shorter than the gap between chords must degrade to one chord per line, not
        // loop or emit empty lines.
        let events = [event(0, "C"), event(5, "F"), event(10, "G")]
        let row = ChordGridRowBuilder.Row(
            id: "intro", lyric: nil, segment: nil, instrumentalLabel: "Intro",
            start: 0, end: 15, eventIDs: events.map(\.id))
        let split = ChordGridRowBuilder.splitInstrumental(row, events: events, target: 0.01)
        XCTAssertEqual(split.count, 3)
        XCTAssertTrue(split.allSatisfy { !$0.eventIDs.isEmpty })
    }

    func testSplitRowsKeepUniqueIdentities() {
        let events = (0..<9).map { event(Double($0), "C") }
        let row = ChordGridRowBuilder.Row(
            id: "intro", lyric: nil, segment: nil, instrumentalLabel: "Intro",
            start: 0, end: 9, eventIDs: events.map(\.id))
        let split = ChordGridRowBuilder.splitInstrumental(row, events: events, target: 3)
        XCTAssertEqual(Set(split.map(\.id)).count, split.count)
        XCTAssertTrue(split.allSatisfy { $0.instrumentalLabel == "Intro" })
    }

    func testShortInstrumentalIsLeftAlone() {
        let events = [event(0, "C"), event(1, "F")]
        let row = ChordGridRowBuilder.Row(
            id: "intro", lyric: nil, segment: nil, instrumentalLabel: "Intro",
            start: 0, end: 2, eventIDs: events.map(\.id))
        XCTAssertEqual(
            ChordGridRowBuilder.splitInstrumental(row, events: events, target: 8).count, 1)
    }

    func testSungRowsAreNeverSplit() {
        let row = ChordGridRowBuilder.Row(
            id: "lyric-1", lyric: "a sung line", segment: nil, instrumentalLabel: nil,
            start: 0, end: 30, eventIDs: [UUID(), UUID(), UUID()])
        XCTAssertEqual(ChordGridRowBuilder.splitInstrumental(row, events: [], target: 1).count, 1)
    }
}
