import XCTest

@testable import SongWorkbench

final class ChordProHighlightDeriverTests: XCTestCase {
    private func deriver(
        lyricSegments: [TimedLyricSegment],
        chordEvents: [EditableChordEvent] = [],
        confidenceThreshold: Float = 0.5
    ) -> ChordProHighlightDeriver {
        ChordProHighlightDeriver(
            lyricSegments: lyricSegments,
            chordEvents: chordEvents,
            confidenceThreshold: confidenceThreshold
        )
    }

    func testLyricOrdinalSelectsSegmentContainingTime() {
        let sut = deriver(
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 4, text: "First line"),
                TimedLyricSegment(start: 4, end: 8, text: "Second line"),
            ]
        )

        XCTAssertEqual(sut.lyricOrdinal(at: 1), 0)
        XCTAssertEqual(sut.lyricOrdinal(at: 5), 1)
    }

    func testUpcomingLyricOrdinalFindsNextLineDuringGap() {
        let sut = deriver(
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 4, text: "First line"),
                TimedLyricSegment(start: 12, end: 16, text: "Second line"),
            ]
        )

        // In the gap between the two lines, the upcoming line is the second one.
        XCTAssertEqual(sut.upcomingLyricOrdinal(at: 7), 1)
        // Before the first line begins, the upcoming line is the first one.
        XCTAssertEqual(sut.upcomingLyricOrdinal(at: -1), 0)
        // After the last line there is no upcoming line.
        XCTAssertNil(sut.upcomingLyricOrdinal(at: 20))
    }

    func testLyricOrdinalIsNilOutsideAnySegment() {
        let sut = deriver(
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 4, text: "First line")
            ]
        )

        XCTAssertNil(sut.lyricOrdinal(at: 6))
    }

    func testLyricOrdinalBoundaryIsStartInclusiveEndExclusive() {
        let sut = deriver(
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 4, text: "First line"),
                TimedLyricSegment(start: 4, end: 8, text: "Second line"),
            ]
        )

        // start is inclusive
        XCTAssertEqual(sut.lyricOrdinal(at: 0), 0)
        // end is exclusive: time == 4 belongs to the second segment, not the first
        XCTAssertEqual(sut.lyricOrdinal(at: 4), 1)
    }

    func testWordRangeInterpolatesAcrossMultipleWords() {
        let segment = TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
        let sut = deriver(lyricSegments: [segment])

        // 4 words split over [0, 6): "Walk" 0..<4, "the" 5..<8, "low" 9..<12, "line" 13..<17
        XCTAssertEqual(sut.wordRange(inLyricOrdinal: 0, at: 0.5), 0..<4)
        XCTAssertEqual(sut.wordRange(inLyricOrdinal: 0, at: 2.2), 5..<8)
        XCTAssertEqual(sut.wordRange(inLyricOrdinal: 0, at: 4.0), 9..<12)
        XCTAssertEqual(sut.wordRange(inLyricOrdinal: 0, at: 5.9), 13..<17)

        // The segment-based overload agrees with the ordinal-based one.
        XCTAssertEqual(sut.wordRange(in: segment, at: 2.2), 5..<8)
    }

    func testWordRangeUsesRealWordTimesWhenPresent() {
        // "Walk the low line" with real onsets at 0, 1.5, 3, 4.5.
        let segment = TimedLyricSegment(
            start: 0,
            end: 6,
            text: "Walk the low line",
            words: [
                TimedLyricWord(text: "Walk", start: 0, end: 1.0, characterRange: 0..<4),
                TimedLyricWord(text: "the", start: 1.5, end: 2.0, characterRange: 5..<8),
                TimedLyricWord(text: "low", start: 3.0, end: 3.5, characterRange: 9..<12),
                TimedLyricWord(text: "line", start: 4.5, end: 5.0, characterRange: 13..<17),
            ]
        )
        let sut = deriver(lyricSegments: [segment])

        // Before the first word's start: nothing is active yet.
        XCTAssertNil(sut.wordRange(in: segment, at: -0.1))
        // Inside a word's [start, end): that word.
        XCTAssertEqual(sut.wordRange(in: segment, at: 0.2), 0..<4)
        XCTAssertEqual(sut.wordRange(in: segment, at: 1.7), 5..<8)
        // In the gap after a word ends but before the next starts: most recent word holds.
        XCTAssertEqual(sut.wordRange(in: segment, at: 2.5), 5..<8)
        XCTAssertEqual(sut.wordRange(in: segment, at: 3.2), 9..<12)
        // After the last word ends, it stays highlighted until the segment ends.
        XCTAssertEqual(sut.wordRange(in: segment, at: 5.9), 13..<17)

        // The ordinal-based overload agrees.
        XCTAssertEqual(sut.wordRange(inLyricOrdinal: 0, at: 1.7), 5..<8)
    }

    func testWordRangeFallsBackToInterpolationWhenNoWordTimes() {
        // No words: identical behavior to the legacy interpolation.
        let segment = TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
        let sut = deriver(lyricSegments: [segment])

        XCTAssertEqual(sut.wordRange(in: segment, at: 0.5), 0..<4)
        XCTAssertEqual(sut.wordRange(in: segment, at: 2.2), 5..<8)
        XCTAssertEqual(sut.wordRange(in: segment, at: 4.0), 9..<12)
        XCTAssertEqual(sut.wordRange(in: segment, at: 5.9), 13..<17)
    }

    func testActiveChordLabelsFilterByConfidenceThreshold() {
        let sut = deriver(
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
            ],
            chordEvents: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                // Below threshold: excluded even though it is the latest in time.
                EditableChordEvent(time: 2, chord: "G", confidence: 0.4),
            ],
            confidenceThreshold: 0.5
        )

        XCTAssertEqual(
            sut.activeChordLabels(at: 2.2, forLyricOrdinal: 0, style: .chord),
            ["C"]
        )
    }

    func testActiveChordLabelsOnlyConsidersChordsAtOrBeforeCurrentTime() {
        let sut = deriver(
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
            ],
            chordEvents: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 4, chord: "F", confidence: 0.9),
            ],
            confidenceThreshold: 0.5
        )

        // At 2.2 only the chord at time 0 has occurred; the time-4 chord is in the future.
        XCTAssertEqual(
            sut.activeChordLabels(at: 2.2, forLyricOrdinal: 0, style: .chord),
            ["C"]
        )
    }

    func testActiveChordLabelsBassNoteStyleUsesBassNoteLabels() {
        let sut = deriver(
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
            ],
            chordEvents: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 2, chord: "G/B", confidence: 0.9),
            ],
            confidenceThreshold: 0.5
        )

        // chord style returns the raw chord symbol...
        XCTAssertEqual(
            sut.activeChordLabels(at: 2.2, forLyricOrdinal: 0, style: .chord),
            ["G/B"]
        )
        // ...while bassNote style resolves the slash-bass note label.
        XCTAssertEqual(
            sut.activeChordLabels(at: 2.2, forLyricOrdinal: 0, style: .bassNote),
            [BassNote(chordSymbol: "G/B").map(\.label) ?? ""]
        )
        XCTAssertEqual(
            sut.activeChordLabels(at: 2.2, forLyricOrdinal: 0, style: .bassNote),
            ["B"]
        )
    }
}
