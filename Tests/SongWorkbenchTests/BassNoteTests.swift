import XCTest

@testable import SongWorkbench

final class BassNoteTests: XCTestCase {
    func testRootIsUsedWhenNoSlashBass() {
        XCTAssertEqual(BassNote(chordSymbol: "C")?.label, "C")
        XCTAssertEqual(BassNote(chordSymbol: "Cmaj7")?.label, "C")
        XCTAssertEqual(BassNote(chordSymbol: "Am")?.label, "A")
    }

    func testSlashBassTakesPrecedenceOverRoot() {
        XCTAssertEqual(BassNote(chordSymbol: "G/B")?.label, "B")
        XCTAssertEqual(BassNote(chordSymbol: "C/E")?.label, "E")
        XCTAssertEqual(BassNote(chordSymbol: "F#m/A")?.label, "A")
    }

    func testAccidentalsArePreservedOnRootAndBass() {
        XCTAssertEqual(BassNote(chordSymbol: "F#")?.label, "F#")
        XCTAssertEqual(BassNote(chordSymbol: "Bb")?.label, "Bb")
        XCTAssertEqual(BassNote(chordSymbol: "Bbmaj7/D")?.label, "D")
        XCTAssertEqual(BassNote(chordSymbol: "A/Db")?.label, "Db")
    }

    func testFallsBackToRootWhenSlashBassIsUnparseable() {
        // Unreadable bass after the slash → use the root.
        XCTAssertEqual(BassNote(chordSymbol: "C/X")?.label, "C")
    }

    func testReturnsNilWhenNoPitchLetterIsPresent() {
        XCTAssertNil(BassNote(chordSymbol: "N.C."))
        XCTAssertNil(BassNote(chordSymbol: ""))
        XCTAssertNil(BassNote(chordSymbol: "   "))
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        XCTAssertEqual(BassNote(chordSymbol: "  G/B  ")?.label, "B")
    }
}
