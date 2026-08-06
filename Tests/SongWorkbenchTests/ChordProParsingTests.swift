import XCTest

@testable import SongWorkbench

final class ChordProParsingTests: XCTestCase {
    func testParserPreservesDirectivesLyricsLineEndingsAndFinalNewline() throws {
        let source = "{title: Test Song}\r\n[C]Hello [G7/B]world\r\n{comment: [not a chord]}\r\n"

        let document = try ChordProDocument(parsing: source)

        XCTAssertEqual(document.export(), source)
        XCTAssertEqual(document.elements.count, 6)
        XCTAssertEqual(document.elements[0], .directive("{title: Test Song}\r\n"))
        XCTAssertEqual(document.elements[2], .text("Hello "))
        XCTAssertEqual(document.elements[4], .text("world\r\n"))
        XCTAssertEqual(document.elements[5], .directive("{comment: [not a chord]}\r\n"))
    }

    func testParserCreatesStructuredRootSuffixAndSlashBass() throws {
        let document = try ChordProDocument(parsing: "Play [  Bbmaj7/D  ] now")

        guard case .chord(let chord) = document.elements[1] else {
            return XCTFail("Expected a structured chord element")
        }
        XCTAssertEqual(chord.root, ChordProNote(letter: "B", accidental: .flat))
        XCTAssertEqual(chord.suffix, "maj7")
        XCTAssertEqual(chord.bass, ChordProNote(letter: "D", accidental: nil))
        XCTAssertEqual(chord.description, "Bbmaj7/D")
        XCTAssertEqual(document.export(), "Play [  Bbmaj7/D  ] now")
    }

    func testNoChordMarkerImportsAsARestInsteadOfRejectingTheFile() throws {
        // Regression: a single [N.C.] used to throw `invalidChord`, which rejected the WHOLE
        // imported chart rather than just that token.
        let source = "[C]Verse [N.C.]break [G]end"
        let document = try ChordProDocument(parsing: source)

        guard case .chord(let rest) = document.elements[2] else {
            return XCTFail("Expected [N.C.] to parse as a chord element")
        }
        XCTAssertTrue(rest.isNoChord)
        XCTAssertNil(rest.root)
        XCTAssertEqual(rest.description, "N.C.")
        XCTAssertEqual(document.export(), source, "export must round-trip byte-exactly")
    }

    func testNoChordSpellingsAreAcceptedAndPreservedVerbatim() throws {
        for spelling in ["N.C.", "N.C", "NC", "nc", "n.c.", "No Chord"] {
            let source = "[C]a [\(spelling)]b"
            let document = try ChordProDocument(parsing: source)
            guard case .chord(let rest) = document.elements[2] else {
                return XCTFail("Expected \(spelling) to parse as a no-chord element")
            }
            XCTAssertTrue(rest.isNoChord, "\(spelling) should be a rest")
            // The author's spelling survives; we do not normalise it on the way out.
            XCTAssertEqual(rest.description, spelling)
            XCTAssertEqual(document.export(), source)
        }
    }

    func testTransposingLeavesNoChordMarkersUntouched() throws {
        let document = try ChordProDocument(parsing: "[C]a [N.C.]b [G7/B]c")

        let transposed = document.transposed(by: 2)

        XCTAssertEqual(transposed.export(), "[D]a [N.C.]b [A7/C#]c")
    }

    func testEscapedBracketsRemainLiteralLyrics() throws {
        let source = #"A \[literal\] bracket and [C] chord"#
        let document = try ChordProDocument(parsing: source)

        XCTAssertEqual(document.export(), source)
        XCTAssertEqual(
            document.elements.filter {
                if case .chord = $0 { return true }
                return false
            }.count, 1)
    }

    func testMalformedBracketsProduceClearLocatedErrors() {
        assertParseError("Text [C", equals: .unmatchedOpeningBracket(characterOffset: 5))
        assertParseError("Text C]", equals: .unmatchedClosingBracket(characterOffset: 6))
        assertParseError("Text []", equals: .emptyChord(characterOffset: 5))
        assertParseError("Text [Verse]", equals: .invalidChord("Verse", characterOffset: 5))
    }

    private func assertParseError(
        _ source: String,
        equals expected: ChordProParseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ChordProDocument(parsing: source), file: file, line: line) {
            error in
            XCTAssertEqual(error as? ChordProParseError, expected, file: file, line: line)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription, file: file, line: line)
        }
    }
}
