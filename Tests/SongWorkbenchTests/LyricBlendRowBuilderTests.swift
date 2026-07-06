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

    func testCrossModeDuplicateBeyondClusterWindowMergesIntoOneRow() {
        // Flip Flops regression: Whisper de-padded "Grass between my toes…" to 20.26s while
        // Parakeet heard it at 24.90s — 4.6s apart, far beyond the 1.5s cluster window — so the
        // SAME sung line rendered as two duplicated preview lines (the ball tracked only one).
        // Disjoint mode sets + identical normalized text ⇒ one row with both candidates.
        let balanced = [segment("Grass between my toes, warm and dry", start: 24.9, end: 26.3)]
        let accuracy = [segment("Grass between my toes warm and dry", start: 20.26, end: 23.08)]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: [], balancedDraft: balanced, accuracy: accuracy)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            Set(rows[0].candidates.map(\.mode)), [.accuracy, .balancedDraft])
        XCTAssertEqual(rows[0].start, 20.26, accuracy: 0.000_001)
    }

    func testTwoModeClusterStillMatchesItsSingleModeDuplicate() {
        // The exact field shape that escaped the first fix: BOTH balanced and fast heard
        // "Grass…" at 20.26s (one cluster holding the line TWICE, once per mode), while
        // accuracy's stray copy sits alone at 24.90s past the Smoke row. Comparing a flat
        // concatenation of the cluster's text read as the line doubled and never matched;
        // per-mode text sets must match and merge.
        let fast = [
            segment("Grass between my toes, warm and dry", start: 20.26, end: 23.08),
            segment("Smoke curls up in the big blue sky", start: 23.35, end: 26.30),
        ]
        let balanced = [
            segment("Grass between my toes, warm and dry", start: 20.30, end: 23.10),
            segment("Smoke curls up in the big blue sky", start: 23.40, end: 26.30),
        ]
        let accuracy = [segment("Grass between my toes, warm and dry", start: 24.9, end: 26.3)]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: fast, balancedDraft: balanced, accuracy: accuracy)

        XCTAssertEqual(rows.count, 2, "Grass (all 3 modes) + Smoke (balanced/fast)")
        XCTAssertEqual(
            Set(rows[0].candidates.map(\.mode)), [.accuracy, .balancedDraft, .fastDraft])
        XCTAssertEqual(rows[0].start, 20.26, accuracy: 0.000_001)
        XCTAssertEqual(Set(rows[1].candidates.map(\.mode)), [.balancedDraft, .fastDraft])
    }

    func testNonAdjacentCrossModeDuplicateMergesAcrossAnInterveningRow() {
        // Flip Flops line-2 regression: accuracy's reference-aligned "Grass between my toes"
        // landed at 24.90s — AFTER the real "Smoke curls" line at 23.35 — so the duplicate
        // rows were not adjacent and the old neighbours-only merge missed them (the misplaced
        // copy's words then zippered into the Smoke line downstream).
        let balanced = [
            segment("Grass between my toes, warm and dry", start: 20.26, end: 23.08),
            segment("Smoke curls up in the big blue sky", start: 23.35, end: 26.30),
        ]
        let accuracy = [segment("Grass between my toes, warm and dry", start: 24.9, end: 26.3)]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: [], balancedDraft: balanced, accuracy: accuracy)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].start, 20.26, accuracy: 0.000_001)
        XCTAssertEqual(
            Set(rows[0].candidates.map(\.mode)), [.accuracy, .balancedDraft],
            "the misplaced accuracy copy must fold into the real Grass row")
        XCTAssertEqual(rows[1].candidates.map(\.mode), [.balancedDraft])
    }

    func testRepeatedHookFromTheSameModeStaysTwoRows() {
        // A genuinely repeated hook line: the SAME mode hears both copies, so the clusters
        // share a mode and must never merge — the song really repeats the line.
        let accuracy = [
            segment("flip flops and barbecue", start: 145.9, end: 150.2),
            segment("flip flops and barbecue", start: 150.4, end: 153.2),
        ]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: [], balancedDraft: [], accuracy: accuracy)

        XCTAssertEqual(rows.count, 2)
    }

    func testCrossModeLinesWithDifferentTextDoNotMerge() {
        // Disjoint modes but genuinely different lines just beyond the cluster window.
        let balanced = [segment("a completely different line", start: 3.0, end: 4.0)]
        let accuracy = [segment("hello world", start: 0.0, end: 1.0)]

        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: [], balancedDraft: balanced, accuracy: accuracy)

        XCTAssertEqual(rows.count, 2)
    }

    func testRunOnDuplicateDemotedToTheSplitCandidate() {
        // Field case ("line 9 is actually 2 lines"): accuracy ran the Smoke line together
        // with the Laughter line inside one row, while balanced/fast correctly held just
        // "Laughter floats…" — the default accuracy-first pick rendered a double line and
        // swallowed the chord at "Laughter". The run-on (= neighbour text + other
        // candidate's text) must demote to the split candidate.
        let balanced = [
            segment("Smoke curls up in the big blue sky", start: 23.35, end: 26.30),
            segment("Laughter floats like a lazy breeze", start: 27.08, end: 29.74),
        ]
        let accuracy = [
            segment(
                "Smoke curls up in the big blue sky Laughter floats like a lazy breeze",
                start: 27.08, end: 29.74)
        ]
        let rows = LyricBlendRowBuilder.runOnDuplicatesDemoted(
            LyricBlendRowBuilder.buildRows(
                fastDraft: [], balancedDraft: balanced, accuracy: accuracy))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].selectedMode, .balancedDraft)
        let lyrics = LyricBlendRowBuilder.effectiveLyrics(from: rows)
        XCTAssertEqual(
            lyrics.map(\.text),
            [
                "Smoke curls up in the big blue sky",
                "Laughter floats like a lazy breeze",
            ])
    }

    func testRunOnDemotionToleratesEngineWordingDifferences() {
        // Settle Down field case: accuracy heard ONE 11s segment "She makes me want to
        // settle down, trading my rowdy friends for a one-horse town."; balanced/fast split
        // it but with different wording ("wanna" vs "want to", "one horse" vs "one-horse"),
        // and balanced's second half is contaminated with the next line's words. Exact
        // concatenation can never match — token similarity must.
        let accuracy = [
            segment(
                "She makes me want to settle down, trading my rowdy friends for a "
                    + "one-horse town.",
                start: 54.40, end: 65.78)
        ]
        let balanced = [
            segment("she makes me wanna settle down", start: 54.45, end: 58.10),
            segment(
                "trading my rowdy friends for one horse town build a little",
                start: 59.85, end: 66.0),
        ]
        let fast = [
            segment("She makes me wanna settle down,", start: 54.45, end: 58.12),
            segment("trading my rowdy friends for One horse town,", start: 59.85, end: 65.8),
        ]

        let rows = LyricBlendRowBuilder.runOnDuplicatesDemoted(
            LyricBlendRowBuilder.buildRows(
                fastDraft: fast, balancedDraft: balanced, accuracy: accuracy))

        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[0].selectedMode, "the run-on default must be demoted")
        XCTAssertNotEqual(rows[0].selectedMode, .accuracy)
        let lyrics = LyricBlendRowBuilder.effectiveLyrics(from: rows)
        XCTAssertEqual(lyrics.count, 2, "the joined phrase must render as two lines")
        XCTAssertFalse(
            (lyrics.first?.text ?? "").lowercased().contains("trading"),
            "first line must end at the phrase boundary")
    }

    func testRunOnDemotionLeavesUserPicksAndGenuineLongLinesAlone() {
        // A long line that is NOT a neighbour+candidate concatenation stays on the default.
        let balanced = [segment("a completely different reading", start: 10, end: 12)]
        let accuracy = [segment("some genuinely long single line here", start: 10, end: 12)]
        let rows = LyricBlendRowBuilder.runOnDuplicatesDemoted(
            LyricBlendRowBuilder.buildRows(
                fastDraft: [], balancedDraft: balanced, accuracy: accuracy))
        XCTAssertNil(rows[0].selectedMode)

        // An explicit user pick is never overwritten, even for a true run-on.
        var pickedRows = LyricBlendRowBuilder.buildRows(
            fastDraft: [],
            balancedDraft: [
                segment("first line", start: 0, end: 1),
                segment("second line", start: 3, end: 4),
            ],
            accuracy: [segment("first line second line", start: 3, end: 4)])
        for index in pickedRows.indices { pickedRows[index].selectedMode = .accuracy }
        let kept = LyricBlendRowBuilder.runOnDuplicatesDemoted(pickedRows)
        XCTAssertTrue(kept.allSatisfy { $0.selectedMode == .accuracy })
    }

    // MARK: - Vocal-onset corroboration

    private func timedWords(
        _ starts: [TimeInterval], duration: TimeInterval = 0.3
    ) -> [TimedLyricWord] {
        starts.enumerated().map { index, start in
            TimedLyricWord(
                text: "w\(index)", start: start, end: start + duration, characterRange: 0..<2)
        }
    }

    func testOnsetCorroborationScoresFractionOfWordsOnBursts() {
        let words = timedWords([1.0, 2.0, 3.0, 4.0])
        // Onsets corroborate words 1 and 3 (within 0.18s); 2 and 4 float in silence.
        let score = LyricBlendRowBuilder.onsetCorroboration(
            words: words, vocalOnsets: [1.05, 2.9])
        XCTAssertEqual(score, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            LyricBlendRowBuilder.onsetCorroboration(words: [], vocalOnsets: [1]), 0)
        XCTAssertEqual(
            LyricBlendRowBuilder.onsetCorroboration(words: words, vocalOnsets: []), 0)
    }

    func testOnsetPreferredModeFlipsToTheCorroboratedCandidate() {
        // Accuracy (the default pick) timed its words 4s early — off every burst; balanced
        // sits on the bursts. The stem must win the row for balanced.
        let row = LyricBlendRow(
            start: 20, end: 27,
            candidates: [
                LyricBlendCandidate(
                    mode: .accuracy, text: "grass between my toes",
                    words: timedWords([20.3, 20.8, 21.2, 21.6])),
                LyricBlendCandidate(
                    mode: .balancedDraft, text: "grass between my toes",
                    words: timedWords([24.9, 25.4, 25.8, 26.1])),
            ])
        let onsets: [TimeInterval] = [24.92, 25.41, 25.82, 26.08]

        XCTAssertEqual(
            LyricBlendRowBuilder.onsetPreferredMode(for: row, vocalOnsets: onsets),
            .balancedDraft)

        let corroborated = LyricBlendRowBuilder.onsetCorroborated([row], vocalOnsets: onsets)
        XCTAssertEqual(corroborated[0].selectedMode, .balancedDraft)
    }

    func testOnsetPreferredModeNeverOverridesAUserPick() {
        var row = LyricBlendRow(
            start: 0, end: 2,
            candidates: [
                LyricBlendCandidate(mode: .accuracy, text: "a", words: timedWords([0.0])),
                LyricBlendCandidate(mode: .fastDraft, text: "a", words: timedWords([1.0])),
            ])
        row.selectedMode = .accuracy
        XCTAssertNil(
            LyricBlendRowBuilder.onsetPreferredMode(for: row, vocalOnsets: [1.0]))
        let corroborated = LyricBlendRowBuilder.onsetCorroborated([row], vocalOnsets: [1.0])
        XCTAssertEqual(corroborated[0].selectedMode, .accuracy)
    }

    func testOnsetPreferredModeKeepsDefaultWithinMargin() {
        // Both candidates half-corroborated: no clear winner, default (accuracy) stands.
        let row = LyricBlendRow(
            start: 0, end: 4,
            candidates: [
                LyricBlendCandidate(
                    mode: .accuracy, text: "a b", words: timedWords([1.0, 2.0])),
                LyricBlendCandidate(
                    mode: .balancedDraft, text: "a b", words: timedWords([1.0, 3.0])),
            ])
        XCTAssertNil(
            LyricBlendRowBuilder.onsetPreferredMode(for: row, vocalOnsets: [1.0]))
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
