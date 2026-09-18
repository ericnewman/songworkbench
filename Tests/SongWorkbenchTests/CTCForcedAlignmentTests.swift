import XCTest

@testable import SongWorkbench

final class CTCForcedAlignmentTests: XCTestCase {

    /// Builds a posteriorgram where `frames` names the class that dominates each frame, so the
    /// correct alignment is known by construction.
    private func posteriorgram(_ frames: [Int], classes: Int) -> [[Float]] {
        frames.map { winner in
            (0..<classes).map { $0 == winner ? Float(-0.01) : Float(-10) }
        }
    }

    func testAlignsTokensToTheFramesThatSoundThem() throws {
        // blank=0. Frames: b A A b B B B b C
        let logProbs = posteriorgram([0, 1, 1, 0, 2, 2, 2, 0, 3], classes: 4)
        let spans = try CTCForcedAlignment.align(logProbs: logProbs, tokens: [1, 2, 3], blank: 0)

        XCTAssertEqual(spans.map(\.token), [1, 2, 3])
        XCTAssertEqual(spans[0].startFrame, 1)
        XCTAssertEqual(spans[0].endFrame, 2)
        XCTAssertEqual(spans[1].startFrame, 4)
        XCTAssertEqual(spans[1].endFrame, 6)
        XCTAssertEqual(spans[2].startFrame, 8)
    }

    /// The reason the skip transition is guarded. Two identical adjacent tokens must consume two
    /// separate runs with a blank between them; an unguarded skip collapses them into one and
    /// every later word inherits the shift.
    func testRepeatedTokenDoesNotCollapse() throws {
        // b A A b A A b  — "A A", not one long "A"
        let logProbs = posteriorgram([0, 1, 1, 0, 1, 1, 0], classes: 3)
        let spans = try CTCForcedAlignment.align(logProbs: logProbs, tokens: [1, 1], blank: 0)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].startFrame, 1)
        XCTAssertLessThan(spans[0].endFrame, spans[1].startFrame, "the two runs must not merge")
        XCTAssertGreaterThanOrEqual(spans[1].startFrame, 4)
    }

    /// Silence at the head is exactly the case that broke the chart: the opening words must NOT be
    /// placed at 0 when nothing is sounding there.
    func testLeadingSilenceIsNotAssignedToTheFirstToken() throws {
        // eight blank frames, then A, then B
        let logProbs = posteriorgram([0, 0, 0, 0, 0, 0, 0, 0, 1, 2], classes: 3)
        let spans = try CTCForcedAlignment.align(logProbs: logProbs, tokens: [1, 2], blank: 0)

        XCTAssertEqual(
            spans[0].startFrame, 8,
            "first token belongs where it sounds, not at frame 0")
        XCTAssertEqual(spans[1].startFrame, 9)
    }

    func testMonotonicNonOverlappingSpans() throws {
        let logProbs = posteriorgram([0, 1, 0, 2, 2, 0, 3, 0, 4, 4, 0, 5], classes: 6)
        let spans = try CTCForcedAlignment.align(
            logProbs: logProbs, tokens: [1, 2, 3, 4, 5], blank: 0)

        for (earlier, later) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(
                earlier.endFrame, later.startFrame,
                "token \(earlier.index) overlaps token \(later.index)")
        }
    }

    func testRejectsAudioTooShortForTheTokens() {
        let logProbs = posteriorgram([0, 1], classes: 4)
        XCTAssertThrowsError(
            try CTCForcedAlignment.align(logProbs: logProbs, tokens: [1, 2, 3, 1], blank: 0)
        ) { error in
            XCTAssertEqual(
                error as? CTCForcedAlignment.Failure,
                .audioTooShort(frames: 2, minimumRequired: 4))
        }
    }

    func testEmptyInputIsRejected() {
        XCTAssertThrowsError(try CTCForcedAlignment.align(logProbs: [], tokens: [1], blank: 0))
        XCTAssertThrowsError(
            try CTCForcedAlignment.align(
                logProbs: posteriorgram([0, 1], classes: 2), tokens: [], blank: 0))
    }
}
