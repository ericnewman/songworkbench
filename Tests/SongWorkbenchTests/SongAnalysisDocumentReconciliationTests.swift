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
}
