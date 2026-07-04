import XCTest

@testable import SongWorkbench

final class RhymeDetectorTests: XCTestCase {
    /// A tiny, hand-built table in the exact bundled TSV format — rhyme keys mirror what
    /// `RhymeDetector`'s production loader would derive from real CMUdict entries (last
    /// primary-stressed vowel through the end, stress digits stripped), but are written literally
    /// here so the test doesn't depend on the real bundled file at all.
    private func detector() -> RhymeDetector {
        RhymeDetector(
            table: RhymeDetector.parseTable(
                """
                # comment lines and blank lines below are ignored by the parser
                cat\tAE T
                hat\tAE T
                dog\tAO G
                frog\tAO G
                love\tAH V
                dove\tAH V
                orange\tAO R AH N JH
                silver\tIH L V ER
                don't\tOW N T
                """))
    }

    // MARK: - parseTable

    func testParseTableSkipsCommentsAndBlankLinesAndHandlesCRLF() {
        let table = RhymeDetector.parseTable("# header\r\n\r\ncat\tAE T\r\nhat\tAE T\r\n")
        XCTAssertEqual(table["cat"], "AE T")
        XCTAssertEqual(table["hat"], "AE T")
        XCTAssertEqual(table.count, 2)
    }

    func testParseTableIgnoresMalformedLines() {
        let table = RhymeDetector.parseTable("cat\tAE T\nno-tab-here\nempty\t\n")
        XCTAssertEqual(table["cat"], "AE T")
        XCTAssertNil(table["no-tab-here"])
        XCTAssertEqual(table["empty"], "")
    }

    // MARK: - normalize

    func testNormalizeLowercasesAndKeepsApostrophesButStripsOtherPunctuation() {
        XCTAssertEqual(RhymeDetector.normalize("Don't!"), "don't")
        XCTAssertEqual(RhymeDetector.normalize("CAT,"), "cat")
        XCTAssertEqual(RhymeDetector.normalize("  Hat  "), "hat")
    }

    // MARK: - rhymes / rhymePart

    func testKnownRhymingPairsMatch() {
        let d = detector()
        XCTAssertTrue(d.rhymes("cat", "hat"))
        XCTAssertTrue(d.rhymes("dog", "frog"))
        XCTAssertTrue(d.rhymes("love", "dove"))
        XCTAssertTrue(d.rhymes("Don't!", "don't"))  // case/punctuation-insensitive
    }

    func testKnownNonRhymingPairsDoNotMatch() {
        let d = detector()
        XCTAssertFalse(d.rhymes("cat", "dog"))
        XCTAssertFalse(d.rhymes("orange", "silver"))
    }

    func testOutOfVocabularyWordNeverAssertsAMatch() {
        let d = detector()
        XCTAssertNil(d.rhymePart(for: "xyzzy"))
        XCTAssertFalse(d.rhymes("xyzzy", "cat"))
        XCTAssertFalse(d.rhymes("cat", "xyzzy"))
    }

    // MARK: - bestRhymeScore

    func testBestRhymeScoreFindsAMatchAmongMultipleOthers() {
        let d = detector()
        XCTAssertEqual(d.bestRhymeScore(for: "cat", against: ["dog", "hat"]), 1.0)
    }

    func testBestRhymeScoreIsZeroWhenKnownButNoOtherMatches() {
        let d = detector()
        XCTAssertEqual(d.bestRhymeScore(for: "cat", against: ["dog"]), 0.0)
    }

    func testBestRhymeScoreIsNilWhenTheWordItselfIsUnknown() {
        let d = detector()
        XCTAssertNil(d.bestRhymeScore(for: "xyzzy", against: ["cat", "dog"]))
    }

    func testBestRhymeScoreIsNilWhenNoOtherIsKnown() {
        let d = detector()
        XCTAssertNil(d.bestRhymeScore(for: "cat", against: ["xyzzy", "zzyzx"]))
        XCTAssertNil(d.bestRhymeScore(for: "cat", against: []))
    }

    // MARK: - shared bundle loader

    func testSharedNeverCrashesEvenIfBundleResourceIsMissingInThisTestTarget() {
        // The test target doesn't necessarily host the app bundle's Resources/ (logic-test bundles
        // have no host app) — `.shared` must degrade to an empty, harmless table rather than crash.
        _ = RhymeDetector.shared.rhymePart(for: "cat")
    }
}
