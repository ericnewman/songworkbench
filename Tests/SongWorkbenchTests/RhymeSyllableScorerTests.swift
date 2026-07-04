import XCTest

@testable import SongWorkbench

final class RhymeSyllableScorerTests: XCTestCase {
    private func detector() -> RhymeDetector {
        RhymeDetector(
            table: RhymeDetector.parseTable(
                """
                cat\tAE T
                hat\tAE T
                mat\tAE T
                dog\tAO G
                orange\tAO R AH N JH
                """))
    }

    private func candidate(
        _ wordIndex: Int, ending: String, syllables: Int, distance: TimeInterval
    ) -> RhymeSyllableScorer.Candidate {
        RhymeSyllableScorer.Candidate(
            wordIndex: wordIndex, endingWord: ending, syllableCount: syllables,
            distanceFromComputedBoundary: distance)
    }

    func testReturnsNilForEmptyCandidates() {
        XCTAssertNil(
            RhymeSyllableScorer.selectBoundary(
                among: [], siblingEndings: [], siblingSyllableCounts: [], rhymeDetector: detector())
        )
    }

    func testSingleCandidateIsReturnedRegardlessOfSiblingData() {
        let only = candidate(3, ending: "dog", syllables: 1, distance: 0.4)
        let result = RhymeSyllableScorer.selectBoundary(
            among: [only], siblingEndings: ["cat"], siblingSyllableCounts: [1],
            rhymeDetector: detector())
        XCTAssertEqual(result, only)
    }

    func testNoSiblingDataKeepsNearestCandidate() {
        let nearest = candidate(3, ending: "dog", syllables: 1, distance: 0.05)
        let farther = candidate(5, ending: "cat", syllables: 1, distance: 0.9)
        let result = RhymeSyllableScorer.selectBoundary(
            among: [nearest, farther], siblingEndings: [], siblingSyllableCounts: [],
            rhymeDetector: detector())
        XCTAssertEqual(result, nearest)
    }

    func testNudgesToACandidateThatRhymesAndMatchesSyllableCountBetter() {
        // Nearest candidate ends on "dog" (no rhyme with siblings, wrong syllable count relative to
        // a 2-syllable sibling median); a slightly farther but still-nearby candidate ends on "cat"
        // (rhymes with the "hat"/"mat" siblings, matches the syllable median) — should win.
        let nearest = candidate(3, ending: "dog", syllables: 1, distance: 0.05)
        let better = candidate(4, ending: "cat", syllables: 2, distance: 0.3)
        let result = RhymeSyllableScorer.selectBoundary(
            among: [nearest, better], siblingEndings: ["hat", "mat"],
            siblingSyllableCounts: [2, 2], rhymeDetector: detector())
        XCTAssertEqual(result, better)
    }

    func testMarginalDifferenceDoesNotNudgeAwayFromNearest() {
        // Both candidates score identically well (both rhyme, both match syllable count) — the
        // improvement over "nearest" is zero, which must not clear `minimumImprovement`.
        let nearest = candidate(3, ending: "cat", syllables: 2, distance: 0.05)
        let tied = candidate(4, ending: "hat", syllables: 2, distance: 0.3)
        let result = RhymeSyllableScorer.selectBoundary(
            among: [nearest, tied], siblingEndings: ["mat"], siblingSyllableCounts: [2],
            rhymeDetector: detector())
        XCTAssertEqual(result, nearest)
    }

    func testAllCandidatesLackingAnySignalKeepsNearest() {
        // Neither candidate's ending word is in the table, and there is no syllable sibling data —
        // no usable signal at all, so the nearest-in-time candidate must be kept untouched.
        let nearest = candidate(3, ending: "xyzzy", syllables: 1, distance: 0.05)
        let other = candidate(4, ending: "zzyzx", syllables: 1, distance: 0.3)
        let result = RhymeSyllableScorer.selectBoundary(
            among: [nearest, other], siblingEndings: ["qwerty"], siblingSyllableCounts: [],
            rhymeDetector: detector())
        XCTAssertEqual(result, nearest)
    }

    func testNeverReturnsACandidateNotInTheProvidedList() {
        let nearest = candidate(3, ending: "dog", syllables: 1, distance: 0.05)
        let better = candidate(4, ending: "cat", syllables: 2, distance: 0.3)
        let result = RhymeSyllableScorer.selectBoundary(
            among: [nearest, better], siblingEndings: ["hat"], siblingSyllableCounts: [2],
            rhymeDetector: detector())
        XCTAssertTrue(result == nearest || result == better)
    }
}
