import XCTest

@testable import SongWorkbench

final class LyricBlendRowBuilderTests: XCTestCase {
    private func segment(_ text: String, start: TimeInterval, end: TimeInterval)
        -> TimedLyricSegment
    {
        TimedLyricSegment(
            start: start, end: end, text: text,
            words: [
                TimedLyricWord(text: text, start: start, end: end, characterRange: 0..<text.count)
            ]
        )
    }

    func testEmptyInputsProduceNoRows() {
        let rows = LyricBlendRowBuilder.buildRows(fastDraft: [], balancedDraft: [], accuracy: [])
        XCTAssertEqual(rows, [])
    }

    func testSingleModeProducesOneCandidatePerRow() {
        let lines = [
            segment("hello world", start: 0, end: 1),
            segment("second line", start: 3, end: 4),
        ]
        let rows = LyricBlendRowBuilder.buildRows(fastDraft: [], balancedDraft: [], accuracy: lines)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].candidates.map(\.text), ["hello world"])
        XCTAssertEqual(rows[0].candidates.map(\.mode), [.accuracy])
        XCTAssertEqual(rows[1].candidates.map(\.text), ["second line"])
    }

    func testLinesFromDifferentModesWithinClusterWindowShareOneRow() {
        // All 3 modes describe the same sung moment with slightly different onsets/wording.
        let fast = [segment("hello werld", start: 0.1, end: 1.0)]
        let balanced = [segment("hello world", start: 0.2, end: 1.1)]
        let accuracy = [segment("hello, world", start: 0.0, end: 1.0)]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: fast, balancedDraft: balanced, accuracy: accuracy)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].candidates.count, 3)
        XCTAssertEqual(
            Set(rows[0].candidates.map(\.mode)), [.fastDraft, .balancedDraft, .accuracy])
        // Fixed mode order regardless of input order: accuracy, balanced, fast.
        XCTAssertEqual(
            rows[0].candidates.map(\.mode), [.accuracy, .balancedDraft, .fastDraft])
    }

    func testLinesBeyondClusterWindowFormSeparateRows() {
        let accuracy = [
            segment("first line", start: 0, end: 1),
            segment("far apart line", start: 10, end: 11),
        ]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: [], balancedDraft: [], accuracy: accuracy, clusterWindow: 1.5)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].start, 0, accuracy: 0.000_001)
        XCTAssertEqual(rows[1].start, 10, accuracy: 0.000_001)
    }

    func testMultipleSegmentsFromTheSameModeInOneRowAreJoinedIntoOneCandidate() {
        // A mode that split what another mode kept as one line — both fast-draft segments land
        // in the same cluster window as the single accuracy line.
        let fast = [
            segment("hello", start: 0.0, end: 0.4),
            segment("world", start: 0.5, end: 1.0),
        ]
        let accuracy = [segment("hello world", start: 0.1, end: 1.0)]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: fast, balancedDraft: [], accuracy: accuracy)

        XCTAssertEqual(rows.count, 1)
        let fastCandidate = rows[0].candidates.first { $0.mode == .fastDraft }
        XCTAssertEqual(fastCandidate?.text, "hello world")
        XCTAssertEqual(fastCandidate?.words.count, 2)
    }

    func testEffectiveCandidatePrefersSelectedModeThenAccuracyThenBalancedThenFast() {
        let row = LyricBlendRow(
            start: 0, end: 1,
            candidates: [
                LyricBlendCandidate(mode: .fastDraft, text: "fast"),
                LyricBlendCandidate(mode: .balancedDraft, text: "balanced"),
            ],
            selectedMode: nil)

        // No accuracy candidate present -> falls through to balanced (next in preference order).
        XCTAssertEqual(row.effectiveCandidate()?.text, "balanced")

        var selected = row
        selected.selectedMode = .fastDraft
        XCTAssertEqual(selected.effectiveCandidate()?.text, "fast")

        // A selectedMode with no matching candidate (e.g. that mode's pass failed) falls back to
        // the default preference order rather than returning nil.
        var stale = row
        stale.selectedMode = .accuracy
        XCTAssertEqual(stale.effectiveCandidate()?.text, "balanced")
    }

    func testEffectiveLyricsReflectsSelectionsAndDefaultsForUnselectedRows() {
        let rows = [
            LyricBlendRow(
                start: 0, end: 1,
                candidates: [
                    LyricBlendCandidate(mode: .accuracy, text: "accurate line"),
                    LyricBlendCandidate(mode: .fastDraft, text: "fast line"),
                ],
                selectedMode: .fastDraft),
            LyricBlendRow(
                start: 2, end: 3,
                candidates: [
                    LyricBlendCandidate(mode: .accuracy, text: "second accurate line"),
                    LyricBlendCandidate(mode: .fastDraft, text: "second fast line"),
                ],
                selectedMode: nil),
        ]

        let lyrics = LyricBlendRowBuilder.effectiveLyrics(from: rows)

        XCTAssertEqual(lyrics.map(\.text), ["fast line", "second accurate line"])
        XCTAssertEqual(lyrics.map(\.start), [0, 2])
    }
}
