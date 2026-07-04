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

    // MARK: - Manual override ("4th candidate")

    func testEffectiveTextPrefersOverrideOverEverySelectedCandidate() {
        var row = LyricBlendRow(
            start: 0, end: 1,
            candidates: [LyricBlendCandidate(mode: .accuracy, text: "misheard line")],
            selectedMode: .accuracy)
        row.overrideText = "the correct line"

        XCTAssertEqual(row.effectiveText(), "the correct line")
        // effectiveCandidate() itself is unaffected — it never considers the override.
        XCTAssertEqual(row.effectiveCandidate()?.text, "misheard line")
    }

    func testEffectiveTextIgnoresWhitespaceOnlyOverride() {
        var row = LyricBlendRow(
            start: 0, end: 1,
            candidates: [LyricBlendCandidate(mode: .accuracy, text: "fallback line")],
            selectedMode: nil)
        row.overrideText = "   "

        XCTAssertEqual(row.effectiveText(), "fallback line")
    }

    func testEffectiveLyricsUsesOverrideTextWithNoWords() {
        var row = LyricBlendRow(
            start: 5, end: 6,
            candidates: [LyricBlendCandidate(mode: .accuracy, text: "wrong")],
            selectedMode: nil)
        row.overrideText = "right"

        let lyrics = LyricBlendRowBuilder.effectiveLyrics(from: [row])

        XCTAssertEqual(lyrics.map(\.text), ["right"])
        XCTAssertEqual(lyrics.first?.words, [])
    }

    func testReconciledCarriesOverrideForwardOntoTheOverlappingNewRow() {
        var oldRow = LyricBlendRow(
            start: 10, end: 11,
            candidates: [LyricBlendCandidate(mode: .accuracy, text: "old asr guess")])
        oldRow.overrideText = "my correction"
        oldRow.selectedMode = .fastDraft

        // A fresh re-analysis rebuilt the row with a new id and a slightly shifted window, but
        // it's clearly still "the same line".
        let newRow = LyricBlendRow(
            start: 10.1, end: 11.05,
            candidates: [LyricBlendCandidate(mode: .accuracy, text: "new asr guess")])

        let reconciled = LyricBlendRowBuilder.reconciled(newRows: [newRow], against: [oldRow])

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].overrideText, "my correction")
        XCTAssertEqual(reconciled[0].selectedMode, .fastDraft)
        // The new row's own id/candidates are otherwise untouched.
        XCTAssertEqual(reconciled[0].id, newRow.id)
        XCTAssertEqual(reconciled[0].candidates.map(\.text), ["new asr guess"])
    }

    func testReconciledFallsBackToNearestStartWhenWindowsDoNotOverlap() {
        var oldRow = LyricBlendRow(
            start: 20.0, end: 20.4,
            candidates: [LyricBlendCandidate(mode: .accuracy, text: "old")])
        oldRow.overrideText = "kept override"

        // No true overlap (old ends at 20.4, new starts at 20.5), but well within tolerance.
        let newRow = LyricBlendRow(
            start: 20.5, end: 21.0,
            candidates: [LyricBlendCandidate(mode: .accuracy, text: "new")])

        let reconciled = LyricBlendRowBuilder.reconciled(newRows: [newRow], against: [oldRow])

        XCTAssertEqual(reconciled[0].overrideText, "kept override")
    }

    func testReconciledLeavesNewRowUntouchedWhenNothingOldIsClose() {
        var oldRow = LyricBlendRow(
            start: 0, end: 1, candidates: [LyricBlendCandidate(mode: .accuracy, text: "old")])
        oldRow.overrideText = "should not leak"

        // Far away in time — a genuinely different line (e.g. a new verse the old analysis
        // didn't have).
        let newRow = LyricBlendRow(
            start: 100, end: 101, candidates: [LyricBlendCandidate(mode: .accuracy, text: "new")])

        let reconciled = LyricBlendRowBuilder.reconciled(newRows: [newRow], against: [oldRow])

        XCTAssertNil(reconciled[0].overrideText)
    }

    func testReconciledWithNoOldRowsReturnsNewRowsUnchanged() {
        let newRow = LyricBlendRow(
            start: 0, end: 1, candidates: [LyricBlendCandidate(mode: .accuracy, text: "new")])

        let reconciled = LyricBlendRowBuilder.reconciled(newRows: [newRow], against: [])

        XCTAssertEqual(reconciled, [newRow])
    }

    func testReconciledDoesNotCarryForwardAnEmptyOldOverride() {
        let oldRow = LyricBlendRow(
            start: 0, end: 1, candidates: [LyricBlendCandidate(mode: .accuracy, text: "old")])
        // overrideText defaults to nil — nothing to carry forward.
        let newRow = LyricBlendRow(
            start: 0.05, end: 1.0, candidates: [LyricBlendCandidate(mode: .accuracy, text: "new")])

        let reconciled = LyricBlendRowBuilder.reconciled(newRows: [newRow], against: [oldRow])

        XCTAssertNil(reconciled[0].overrideText)
    }
}
