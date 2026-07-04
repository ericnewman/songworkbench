import XCTest

@testable import SongWorkbench

final class ChordRowStringBuilderTests: XCTestCase {
    func testNoChordsProducesEmptyString() {
        XCTAssertEqual(ChordRowStringBuilder.build(chords: []), "")
    }

    func testSingleChordIsPlacedAtItsColumn() {
        let row = ChordRowStringBuilder.build(chords: [
            ChordProPreviewChord(name: "G", column: 4)
        ])
        XCTAssertEqual(row, "    G")
    }

    func testMultipleChordsAreEachPlacedAtTheirOwnColumn() {
        let row = ChordRowStringBuilder.build(chords: [
            ChordProPreviewChord(name: "C", column: 0),
            ChordProPreviewChord(name: "G", column: 6),
        ])
        XCTAssertEqual(row, "C     G")
    }

    func testChordsOutOfOrderAreSortedByColumn() {
        let row = ChordRowStringBuilder.build(chords: [
            ChordProPreviewChord(name: "G", column: 6),
            ChordProPreviewChord(name: "C", column: 0),
        ])
        XCTAssertEqual(row, "C     G")
    }

    func testOverlappingChordIsPushedPastThePreviousOneInsteadOfClobberingIt() {
        // "Cmaj7" (5 chars) starting at column 0 runs through column 4; a second chord recorded
        // at column 2 would land inside it and can't be rendered there in a monospaced string.
        let row = ChordRowStringBuilder.build(chords: [
            ChordProPreviewChord(name: "Cmaj7", column: 0),
            ChordProPreviewChord(name: "G", column: 2),
        ])
        XCTAssertEqual(row, "Cmaj7 G")
    }
}
