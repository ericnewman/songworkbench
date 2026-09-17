import XCTest

@testable import SongWorkbench

/// Tests for the backlog #15 Phase 2 consolidation's persistence-across-re-analysis mechanism:
/// `TimedLyricSegment.reconciled`/`EditableChordEvent.reconciled` carry a user's Review-chart
/// edits (line correction, chord drag, accept) forward onto whichever freshly re-analyzed
/// segment/event now occupies the same time, mirroring the existing, working
/// `LyricBlendRowBuilder.reconciled` pattern.
final class SongAnalysisDocumentReconciliationTests: XCTestCase {

    // MARK: - TimedLyricSegment

    func testSegmentReconciliationCarriesOverrideTextForwardByWindowOverlap() {
        let old = [
            TimedLyricSegment(start: 0, end: 2, text: "hello werld", overrideText: "hello world"),
            TimedLyricSegment(start: 5, end: 7, text: "second line"),
        ]
        // A fresh analysis slightly shifts the first line's boundaries but it still overlaps.
        let fresh = [
            TimedLyricSegment(start: 0.1, end: 2.2, text: "hallo werld"),
            TimedLyricSegment(start: 5, end: 7, text: "second line"),
        ]

        let reconciled = TimedLyricSegment.reconciled(newSegments: fresh, against: old)

        XCTAssertEqual(reconciled[0].overrideText, "hello world")
        XCTAssertEqual(reconciled[0].text, "hallo werld", "raw ASR text always comes from fresh")
        XCTAssertNil(reconciled[1].overrideText)
    }

    func testSegmentReconciliationCarriesAcceptedFlagForward() {
        var acceptedOld = TimedLyricSegment(start: 10, end: 12, text: "line")
        acceptedOld.accepted = true
        let fresh = [TimedLyricSegment(start: 10, end: 12, text: "line")]

        let reconciled = TimedLyricSegment.reconciled(newSegments: fresh, against: [acceptedOld])

        XCTAssertTrue(reconciled[0].accepted)
    }

    func testSegmentReconciliationFallsBackToNearestStartWithNoOverlap() {
        let old = [
            TimedLyricSegment(start: 0, end: 2, text: "a", overrideText: "A")
        ]
        // Fresh segment doesn't overlap [0,2] at all (a boundary shifted completely past it).
        let fresh = [TimedLyricSegment(start: 2.5, end: 4, text: "a shifted")]

        let reconciled = TimedLyricSegment.reconciled(newSegments: fresh, against: old)

        XCTAssertEqual(reconciled[0].overrideText, "A")
    }

    func testSegmentReconciliationIsNoOpWithNoOldSegments() {
        let fresh = [TimedLyricSegment(start: 0, end: 1, text: "hello")]
        let reconciled = TimedLyricSegment.reconciled(newSegments: fresh, against: [])
        XCTAssertEqual(reconciled, fresh)
    }

    func testEffectiveTextPrefersNonEmptyOverride() {
        let withOverride = TimedLyricSegment(start: 0, end: 1, text: "raw", overrideText: "fixed")
        XCTAssertEqual(withOverride.effectiveText, "fixed")

        let blankOverride = TimedLyricSegment(start: 0, end: 1, text: "raw", overrideText: "   ")
        XCTAssertEqual(blankOverride.effectiveText, "raw")

        let noOverride = TimedLyricSegment(start: 0, end: 1, text: "raw")
        XCTAssertEqual(noOverride.effectiveText, "raw")
    }

    // MARK: - EditableChordEvent

    func testChordReconciliationCarriesManualTimeForwardByNearestDetectedTime() {
        var draggedOld = EditableChordEvent(time: 10.0, chord: "C")
        draggedOld.manualTime = 10.4
        let fresh = [EditableChordEvent(time: 10.05, chord: "C")]

        let reconciled = EditableChordEvent.reconciled(newEvents: fresh, against: [draggedOld])

        XCTAssertEqual(reconciled[0].manualTime, 10.4)
        XCTAssertEqual(
            reconciled[0].time, 10.05, "raw detected time always comes from the fresh event")
    }

    func testChordReconciliationCarriesAcceptedFlagForward() {
        var acceptedOld = EditableChordEvent(time: 20.0, chord: "G")
        acceptedOld.accepted = true
        let fresh = [EditableChordEvent(time: 20.02, chord: "G")]

        let reconciled = EditableChordEvent.reconciled(newEvents: fresh, against: [acceptedOld])

        XCTAssertTrue(reconciled[0].accepted)
    }

    func testChordReconciliationIgnoresMatchesOutsideTolerance() {
        var draggedOld = EditableChordEvent(time: 10.0, chord: "C")
        draggedOld.manualTime = 10.4
        // A fresh event 5 seconds away is a DIFFERENT chord change, not the same one re-detected.
        let fresh = [EditableChordEvent(time: 15.0, chord: "C")]

        let reconciled = EditableChordEvent.reconciled(newEvents: fresh, against: [draggedOld])

        XCTAssertNil(reconciled[0].manualTime)
    }

    func testChordReconciliationIsNoOpWithNoOldEvents() {
        let fresh = [EditableChordEvent(time: 1, chord: "Am")]
        let reconciled = EditableChordEvent.reconciled(newEvents: fresh, against: [])
        XCTAssertEqual(reconciled, fresh)
    }

    func testEffectiveTimePrefersManualOverride() {
        var dragged = EditableChordEvent(time: 5.0, chord: "F")
        dragged.manualTime = 5.75
        XCTAssertEqual(dragged.effectiveTime, 5.75)

        let notDragged = EditableChordEvent(time: 5.0, chord: "F")
        XCTAssertEqual(notDragged.effectiveTime, 5.0)
    }

    // MARK: - EditableChordEvent.matching(rowTime:in:) (Review chart interactivity)

    func testMatchingFindsTheExactRawTimeEvent() {
        let target = EditableChordEvent(time: 12.0, chord: "Dm")
        let events = [EditableChordEvent(time: 3.0, chord: "C"), target]

        let match = EditableChordEvent.matching(rowTime: 12.0, in: events)

        XCTAssertEqual(match?.id, target.id)
    }

    func testMatchingIgnoresManualTimeAndMatchesByRawTime() {
        // A previously-dragged chord's manualTime must NOT be what rowTime is compared against —
        // the row's authoritative time is always the RAW time the builder threaded through.
        var dragged = EditableChordEvent(time: 8.0, chord: "Em")
        dragged.manualTime = 20.0

        let match = EditableChordEvent.matching(rowTime: 8.0, in: [dragged])

        XCTAssertEqual(match?.id, dragged.id)
    }

    func testMatchingReturnsNilBeyondTolerance() {
        let events = [EditableChordEvent(time: 8.0, chord: "Em")]

        XCTAssertNil(EditableChordEvent.matching(rowTime: 8.5, in: events))
        XCTAssertNotNil(EditableChordEvent.matching(rowTime: 8.005, in: events))
    }

    func testMatchingPicksTheNearestWhenMultipleAreWithinTolerance() {
        let near = EditableChordEvent(time: 8.002, chord: "A")
        let far = EditableChordEvent(time: 8.009, chord: "B")

        let match = EditableChordEvent.matching(rowTime: 8.0, in: [far, near], tolerance: 0.01)

        XCTAssertEqual(match?.id, near.id)
    }

    func testMatchingReturnsNilForEmptyEvents() {
        XCTAssertNil(EditableChordEvent.matching(rowTime: 1, in: []))
    }

    // MARK: - Chord placement candidates (A/B rig)

    func testPlacementCandidatesDefaultEmptyAndDecodeFromDocumentWithoutTheKey() throws {
        // A document written before the A/B rig has no `placementCandidates` key at all; it must
        // decode to empty rather than throwing, and report every variant as unavailable.
        let json = Data(
            #"{"id":"7B7A3B9E-0000-4000-8000-000000000000","time":3.5,"chord":"G"}"#.utf8)
        let decoded = try JSONDecoder().decode(EditableChordEvent.self, from: json)

        XCTAssertTrue(decoded.placementCandidates.isEmpty)
        XCTAssertNil(decoded.placementTime(for: .beatQuantized))
        XCTAssertNil(decoded.placementTime(for: .instrumentOnset))
        // With nothing recorded, auditioning a variant must not move or drop the event.
        XCTAssertEqual(decoded.effectiveTime(preferring: .instrumentOnset), 3.5)
    }

    func testPlacementCandidatesRoundTrip() throws {
        var event = EditableChordEvent(time: 3.5, chord: "G")
        event.placementCandidates[ChordPlacementVariant.beatQuantized.rawValue] = 3.5
        event.placementCandidates[ChordPlacementVariant.instrumentOnset.rawValue] = 3.42

        let restored = try JSONDecoder().decode(
            EditableChordEvent.self, from: JSONEncoder().encode(event))

        XCTAssertEqual(restored.placementTime(for: .beatQuantized), 3.5)
        XCTAssertEqual(restored.placementTime(for: .instrumentOnset), 3.42)
    }

    func testAuditioningAVariantUsesItsCandidateTime() {
        var event = EditableChordEvent(time: 3.5, chord: "G")
        event.placementCandidates[ChordPlacementVariant.instrumentOnset.rawValue] = 3.42

        XCTAssertEqual(event.effectiveTime(preferring: nil), 3.5)
        XCTAssertEqual(event.effectiveTime(preferring: .instrumentOnset), 3.42)
        // A variant the stage never recorded falls back rather than dropping the event.
        XCTAssertEqual(event.effectiveTime(preferring: .beatQuantized), 3.5)
    }

    func testManualTimeOutranksAnAuditionedVariant() {
        // A hand-dragged chord is a decision, not a candidate: auditioning must never override it,
        // or an A/B pass would silently discard the user's own corrections.
        var event = EditableChordEvent(time: 3.5, chord: "G", manualTime: 9.0)
        event.placementCandidates[ChordPlacementVariant.instrumentOnset.rawValue] = 3.42

        XCTAssertEqual(event.effectiveTime(preferring: .instrumentOnset), 9.0)
    }

    func testAuditionOutranksARecordedPickButNotAManualDrag() {
        var event = EditableChordEvent(time: 10, chord: "G")
        event.placementCandidates[ChordPlacementVariant.beatQuantized.rawValue] = 10
        event.placementCandidates[ChordPlacementVariant.instrumentOnset.rawValue] = 9.8
        let picks = [ChordPlacementPick(start: 0, end: 20, variant: .instrumentOnset)]

        // No audition: the recorded verdict applies.
        XCTAssertEqual(event.placementTime(auditioning: nil, picks: picks), 9.8)
        // Auditioning shows the variant under test even where a verdict already exists, so the
        // ear and the eye judge the same placement.
        XCTAssertEqual(event.placementTime(auditioning: .beatQuantized, picks: picks), 10)

        var dragged = event
        dragged.manualTime = 1.5
        XCTAssertEqual(dragged.placementTime(auditioning: .beatQuantized, picks: picks), 1.5)
    }

    func testNewestOverlappingPickWins() {
        var event = EditableChordEvent(time: 10, chord: "G")
        event.placementCandidates[ChordPlacementVariant.beatQuantized.rawValue] = 10
        event.placementCandidates[ChordPlacementVariant.instrumentOnset.rawValue] = 9.8
        let picks = [
            ChordPlacementPick(start: 0, end: 20, variant: .instrumentOnset),
            ChordPlacementPick(start: 8, end: 12, variant: .beatQuantized),
        ]

        // Re-judging a span must not require deleting the earlier verdict.
        XCTAssertEqual(event.placementTime(auditioning: nil, picks: picks), 10)
    }

    func testPickCoveringAnEventWithNoSuchCandidateFallsThroughToTheDetectedTime() {
        // A song analysed before the A/B rig has no candidates; a pick must not zero its chords.
        let event = EditableChordEvent(time: 10, chord: "G")
        let picks = [ChordPlacementPick(start: 0, end: 20, variant: .instrumentOnset)]

        XCTAssertEqual(event.placementTime(auditioning: nil, picks: picks), 10)
        XCTAssertEqual(event.placementTime(auditioning: .instrumentOnset, picks: picks), 10)
    }

    func testPickOutsideTheEventsTimeDoesNotApply() {
        var event = EditableChordEvent(time: 30, chord: "G")
        event.placementCandidates[ChordPlacementVariant.instrumentOnset.rawValue] = 29.5
        let picks = [ChordPlacementPick(start: 0, end: 20, variant: .instrumentOnset)]

        XCTAssertEqual(event.placementTime(auditioning: nil, picks: picks), 30)
    }

    func testPlacementPickNormalizesReversedBoundsAndIsHalfOpen() {
        let pick = ChordPlacementPick(start: 12, end: 4, variant: .beatQuantized)

        XCTAssertEqual(pick.start, 4)
        XCTAssertEqual(pick.end, 12)
        XCTAssertTrue(pick.contains(4))
        XCTAssertTrue(pick.contains(11.9))
        // Half-open, so abutting picks can't both claim the boundary instant.
        XCTAssertFalse(pick.contains(12))
        XCTAssertFalse(pick.contains(3.9))
    }

    // MARK: - Hidden chords (Review popup / Chords page, 2026-08-26)

    /// A hide is a judgement about the SONG, not one detection run — like `accepted`, it must
    /// survive re-analysis onto whichever fresh event lands at the same time.
    func testChordReconciliationCarriesHiddenForward() {
        let old = [
            EditableChordEvent(time: 10, chord: "C", confidence: 0.9, hidden: true),
            EditableChordEvent(time: 20, chord: "G", confidence: 0.9),
        ]
        let fresh = [
            EditableChordEvent(time: 10.2, chord: "C", confidence: 0.8),
            EditableChordEvent(time: 20.1, chord: "G", confidence: 0.8),
        ]

        let reconciled = EditableChordEvent.reconciled(newEvents: fresh, against: old)

        XCTAssertTrue(reconciled[0].hidden)
        XCTAssertFalse(reconciled[1].hidden)
    }

    /// Documents written before the flag existed must decode with `hidden == false`.
    func testChordEventDecodesWithoutHiddenKey() throws {
        let legacy = Data(
            """
            {"time": 3.5, "chord": "Am", "confidence": 0.6}
            """.utf8)
        let event = try JSONDecoder().decode(EditableChordEvent.self, from: legacy)
        XCTAssertFalse(event.hidden)
        XCTAssertEqual(event.chord, "Am")
    }

}

// MARK: - Resolved lines (`TimedLyricSegment.resolved`)

extension SongAnalysisDocumentReconciliationTests {
    private func timedLine(
        _ words: [(String, TimeInterval, TimeInterval)], override: String? = nil
    ) -> TimedLyricSegment {
        var text = ""
        var timed: [TimedLyricWord] = []
        for (word, start, end) in words {
            if !text.isEmpty { text += " " }
            let lower = text.count
            text += word
            timed.append(
                TimedLyricWord(
                    text: word, start: start, end: end, characterRange: lower..<text.count,
                    confidence: 0.9))
        }
        return TimedLyricSegment(
            start: words.first?.1 ?? 0, end: words.last?.2 ?? 0, text: text, words: timed,
            overrideText: override)
    }

    func testResolvedCorrectionAddressesItsOwnTextAndKeepsSungTimes() {
        let line = timedLine(
            [("I", 10, 10.2), ("got", 10.2, 10.6), ("sum", 10.6, 11), ("troubles", 11, 12)],
            override: "I've got some troubles now")

        let resolved = line.resolved

        XCTAssertEqual(resolved.text, "I've got some troubles now")
        XCTAssertTrue(LyricWordRanges.addressText(resolved.words, resolved.text))
        XCTAssertEqual(resolved.words.map(\.text), ["I've", "got", "some", "troubles", "now"])
        XCTAssertEqual(resolved.words.map(\.start), [10, 10.2, 10.6, 11, 12])
        XCTAssertEqual(
            resolved.words.map(\.timingSource),
            [.substituted, .matched, .substituted, .matched, .interpolated])
        // Only words the transcriber actually heard keep a confidence.
        XCTAssertEqual(
            resolved.words.map { $0.confidence != nil }, [false, true, false, true, false])
        // The stored line is untouched; the correction is still identifiable.
        XCTAssertEqual(line.text, "I got sum troubles")
        XCTAssertEqual(resolved.overrideText, "I've got some troubles now")
    }

    func testResolvedCorrectionSpreadsARewordedRunAcrossTheWordsItReplaces() {
        let line = timedLine(
            [("I", 1, 1.5), ("wanna", 1.5, 2.5), ("go", 2.5, 3)], override: "I want to go")

        let resolved = line.resolved

        XCTAssertTrue(LyricWordRanges.addressText(resolved.words, resolved.text))
        XCTAssertEqual(resolved.words.map(\.text), ["I", "want", "to", "go"])
        XCTAssertEqual(resolved.words[1].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(resolved.words[2].end, 2.5, accuracy: 1e-9)
        XCTAssertEqual(resolved.words[1].timingSource, .interpolated)
        XCTAssertEqual(resolved.words.map(\.start), resolved.words.map(\.start).sorted())
    }

    func testResolvedRederivesStaleRangesWithoutMovingWords() {
        var line = timedLine([("hello", 1, 2), ("world", 2, 3)])
        line.words[1].characterRange = 0..<5  // points at "hello"

        let resolved = line.resolved

        XCTAssertTrue(LyricWordRanges.addressText(resolved.words, resolved.text))
        XCTAssertEqual(resolved.words.map(\.characterRange), [0..<5, 6..<11])
        XCTAssertEqual(resolved.words.map(\.start), [1, 2])
        XCTAssertEqual(resolved.words.map(\.timingSource), [nil, nil])
    }

    func testResolvedLeavesAConsistentLineUnchangedAndClearsWordsOnAnUntimedCorrection() {
        let line = timedLine([("hello", 1, 2), ("world", 2, 3)])
        XCTAssertEqual(line.resolved, line)

        let untimed = TimedLyricSegment(start: 4, end: 6, text: "wrong", overrideText: "right")
        XCTAssertEqual(untimed.resolved.text, "right")
        XCTAssertEqual(untimed.resolved.words, [])
    }
}
