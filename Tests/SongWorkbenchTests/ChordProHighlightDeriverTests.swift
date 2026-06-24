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
