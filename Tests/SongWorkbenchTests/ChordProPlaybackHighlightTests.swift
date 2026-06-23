import XCTest

@testable import SongWorkbench

final class ChordProPlaybackHighlightTests: XCTestCase {
    func testHighlightsActiveWordAndChordFromPlaybackTime() {
        let context = ChordProPlaybackHighlightContext(
            currentTime: 2.2,
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
            ],
            chordEvents: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 2, chord: "G/B", confidence: 0.9),
                EditableChordEvent(time: 4, chord: "F", confidence: 0.9),
            ],
            confidenceThreshold: 0.5,
            style: .chord
        )

        XCTAssertEqual(
            context.highlight(forLyricOrdinal: 0),
            ChordProLinePlaybackHighlight(wordRange: 5..<8, chordLabels: ["G/B"])
        )
        XCTAssertNil(context.highlight(forLyricOrdinal: 1))
    }

    func testBassNoteHighlightUsesSlashBassAndHonorsConfidenceThreshold() {
        let context = ChordProPlaybackHighlightContext(
            currentTime: 2.2,
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
            ],
            chordEvents: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 2, chord: "G/B", confidence: 0.4),
                EditableChordEvent(time: 2.1, chord: "F/A", confidence: 0.9),
            ],
            confidenceThreshold: 0.5,
            style: .bassNote
        )

        XCTAssertEqual(
            context.highlight(forLyricOrdinal: 0),
            ChordProLinePlaybackHighlight(wordRange: 5..<8, chordLabels: ["A"])
        )
    }

    func testDoesNotHighlightOutsideTimedLyricSegments() {
        let context = ChordProPlaybackHighlightContext(
            currentTime: 8,
            lyricSegments: [
                TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")
            ],
            chordEvents: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9)
            ],
            confidenceThreshold: 0.5,
            style: .chord
        )

        XCTAssertNil(context.highlight(forLyricOrdinal: 0))
    }
}
