import XCTest

@testable import SongWorkbench

final class ChordProTranspositionTests: XCTestCase {
    func testPositiveTranspositionUsesSharpsForNaturalChords() throws {
        let document = try ChordProDocument(parsing: "[C]One [G7/B]two [F#m]three")

        XCTAssertEqual(
            document.transposed(by: 1).export(),
            "[C#]One [G#7/C]two [Gm]three"
        )
    }

    func testNegativeTranspositionUsesFlatsForNaturalChordsAndSlashBass() throws {
        let document = try ChordProDocument(parsing: "[C/E]One [A7]two")

        XCTAssertEqual(document.transposed(by: -1).export(), "[B/Eb]One [Ab7]two")
    }

    func testExistingAccidentalSelectsConsistentEnharmonicSpelling() throws {
        let flats = try ChordProDocument(parsing: "[Bb/D]flat")
        let sharps = try ChordProDocument(parsing: "[F#/A]sharp")

        XCTAssertEqual(flats.transposed(by: 1).export(), "[B/Eb]flat")
        XCTAssertEqual(sharps.transposed(by: 1).export(), "[G/A#]sharp")
    }

    func testZeroAndOctaveTranspositionRoundTripExactly() throws {
        let source = "{title: Exact}\n[ C6/9 ]Words [Bbmaj7/D] and [c#m/g#] here"
        let document = try ChordProDocument(parsing: source)

        XCTAssertEqual(document.transposed(by: 0).export(), source)
        XCTAssertEqual(document.transposed(by: 12).export(), source)
        XCTAssertEqual(document.transposed(by: -24).export(), source)
    }

    func testKeyDirectiveTransposesWhileLyricsRemainUnchanged() throws {
        let source = "{key: C}\n{tempo: 100}\n[C]A lyric with C and /G text"
        let document = try ChordProDocument(parsing: source)

        XCTAssertEqual(
            document.transposed(by: 2).export(),
            "{key: D}\n{tempo: 100}\n[D]A lyric with C and /G text"
        )
    }

    func testMinorKeySuffixAndWhitespaceArePreserved() throws {
        let document = try ChordProDocument(parsing: "{ k : Bb minor }\n[Bb]Text")

        XCTAssertEqual(
            document.transposed(by: 2).export(),
            "{ k : C minor }\n[C]Text"
        )
    }
}
