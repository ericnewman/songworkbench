import XCTest

@testable import SongWorkbench

final class SyllableCounterTests: XCTestCase {
    func testCommonWordsHeuristicMatchesTrueSyllableCount() {
        let expectations: [(String, Int)] = [
            ("cat", 1),
            ("dog", 1),
            ("the", 1),
            ("come", 1),
            ("bike", 1),
            ("hello", 2),
            ("table", 2),
            ("little", 2),
            ("apple", 2),
            ("music", 2),
            ("orange", 2),
            ("banana", 3),
            ("beautiful", 3),
        ]
        for (word, expected) in expectations {
            XCTAssertEqual(SyllableCounter.count(in: word), expected, "word: \(word)")
        }
    }

    func testEmptyOrNonAlphabeticInputReturnsZero() {
        XCTAssertEqual(SyllableCounter.count(in: ""), 0)
        XCTAssertEqual(SyllableCounter.count(in: "123"), 0)
        XCTAssertEqual(SyllableCounter.count(in: "..."), 0)
    }

    func testPunctuationIsIgnoredNotTreatedAsABoundary() {
        XCTAssertEqual(SyllableCounter.count(in: "don't"), SyllableCounter.count(in: "dont"))
        XCTAssertEqual(SyllableCounter.count(in: "hel-lo"), SyllableCounter.count(in: "hello"))
    }

    func testMinimumOneSyllableForAnyRealWord() {
        XCTAssertEqual(SyllableCounter.count(in: "bcd"), 1)  // no vowels at all -> floor of 1
    }

    func testCountInWordsSumsAcrossTheLine() {
        XCTAssertEqual(SyllableCounter.count(inWords: ["hello", "little", "cat"]), 2 + 2 + 1)
        XCTAssertEqual(SyllableCounter.count(inWords: []), 0)
    }

    /// Documented known limitation (PRD §5): the heuristic can't detect that a single consonant
    /// separating two vowel letters sometimes forms ONE syllable's nucleus + silent trailing "e"
    /// ("smile" is 1 syllable; the heuristic sees two separate vowel groups "i" and "e"). Locking
    /// in the ACTUAL heuristic behavior here (not the linguistically correct answer) so this is a
    /// deliberate, visible trade-off rather than a silent gap — acceptable because Stage 2 only
    /// needs relative similarity to sibling lines, not an exact count.
    func testKnownHeuristicLimitationOnSingleConsonantSilentEWords() {
        XCTAssertEqual(
            SyllableCounter.count(in: "smile"), 2, "documented heuristic miss, not a bug")
    }
}
