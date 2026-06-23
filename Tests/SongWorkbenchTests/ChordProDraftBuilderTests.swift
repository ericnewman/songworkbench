import XCTest

@testable import SongWorkbench

final class ChordProDraftBuilderTests: XCTestCase {
    func testBuildAlignsIncludedChordChangesToLyrics() {
        let input = ChordProDraftInput(
            title: "Test Song",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 4, text: "Hello wide world")
            ],
            chords: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.95),
                EditableChordEvent(time: 2, chord: "G", confidence: 0.60),
            ]
        )

        let document = ChordProDraftBuilder().build(input)

        XCTAssertEqual(
            document,
            """
            {title: Test Song}
            {tempo: 120}
            {comment: Generated analysis draft - review required}

            [C]Hello [G]wide world
            """ + "\n"
        )
    }

    func testBuildProducesChordGridWhenLyricsAreUnavailable() {
        let input = ChordProDraftInput(
            title: "Instrumental",
            tempo: nil,
            lyrics: [],
            chords: [
                EditableChordEvent(time: 0, chord: "Dm", confidence: 0.9),
                EditableChordEvent(time: 4, chord: "Bb", confidence: 0.8),
            ]
        )

        XCTAssertEqual(
            ChordProDraftBuilder().build(input),
            """
            {title: Instrumental}
            {comment: Generated analysis draft - review required}

            {start_of_grid}
            | Dm | Bb |
            {end_of_grid}
            """ + "\n"
        )
    }

    func testBuildExcludesDetectedChordsBelowThresholdButKeepsManualChords() {
        let input = ChordProDraftInput(
            title: "Threshold",
            tempo: nil,
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "One two three")],
            chords: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.79),
                EditableChordEvent(time: 1, chord: "G", confidence: 0.80),
                EditableChordEvent(time: 2, chord: "Am", confidence: nil),
            ],
            confidenceThreshold: 0.80
        )

        let document = ChordProDraftBuilder().build(input)

        XCTAssertFalse(document.contains("[C]"))
        XCTAssertTrue(document.contains("[G]"))
        XCTAssertTrue(document.contains("[Am]"))
        XCTAssertFalse(document.contains("low-confidence"))
    }

    func testBuildIsStableAcrossDifferentPersistenceIdentifiers() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = ChordProDraftInput(
            title: "Stable",
            tempo: 90,
            lyrics: [TimedLyricSegment(id: firstID, start: 0, end: 4, text: "Same words")],
            chords: [
                EditableChordEvent(id: firstID, time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(id: secondID, time: 0, chord: "G", confidence: 0.8),
            ]
        )
        let second = ChordProDraftInput(
            title: "Stable",
            tempo: 90,
            lyrics: [TimedLyricSegment(id: secondID, start: 0, end: 4, text: "Same words")],
            chords: [
                EditableChordEvent(id: secondID, time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(id: firstID, time: 0, chord: "G", confidence: 0.8),
            ]
        )

        XCTAssertEqual(ChordProDraftBuilder().build(first), ChordProDraftBuilder().build(second))
    }
}
