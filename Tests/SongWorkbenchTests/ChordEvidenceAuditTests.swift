import XCTest

@testable import SongWorkbench

final class ChordEvidenceAuditTests: XCTestCase {
    // MARK: - Helpers

    private func event(_ time: TimeInterval, _ chord: String) -> EditableChordEvent {
        EditableChordEvent(time: time, chord: chord, confidence: 0.8)
    }

    private func event(_ time: TimeInterval, _ root: PitchClass) -> EditableChordEvent {
        event(time, Chord(root: root, quality: .major).displayName)
    }

    /// Frame-level observations at `hop` spacing: `[(start, end, rootPitchClass)]`, all major.
    private func frames(
        _ spans: [(TimeInterval, TimeInterval, PitchClass)],
        hop: TimeInterval = 0.05
    ) -> [ChordObservation] {
        var result: [ChordObservation] = []
        for (start, end, root) in spans {
            var t = start
            while t < end {
                result.append(
                    ChordObservation(
                        timestamp: t,
                        chord: Chord(root: root, quality: .major),
                        confidence: 0.9
                    ))
                t += hop
            }
        }
        return result
    }

    // MARK: - Classification

    func testAttackAndHarmonicChangeIsTheStrongestEvidence() {
        let audit = ChordEvidenceAudit.audit(
            events: [event(2, .g), event(4, .f)],
            frameObservations: frames([(0, 2, .c), (2, 4, .g), (4, 6, .f)]),
            attackOnsets: [2, 4]
        )
        XCTAssertEqual(audit.verdicts.map(\.evidence), [.attackAndHarmonic, .attackAndHarmonic])
        XCTAssertEqual(audit.unsupportedCount, 0)
        XCTAssertTrue(audit.evidenceTrusted)
        XCTAssertNil(ChordEvidenceAudit.warning(for: audit))
    }

    func testSongOpeningEventHasNoHarmonicEvidenceBecauseNothingPrecedesIt() {
        // Not a defect: "harmonic change" is a claim about a difference, and the first chord of
        // the song has nothing before it to differ from. Its attack still supports it.
        let audit = ChordEvidenceAudit.audit(
            events: [event(0, .c)],
            frameObservations: frames([(0, 4, .c)]),
            attackOnsets: [0]
        )
        XCTAssertEqual(audit.verdicts[0].evidence, .attack)
    }

    func testHarmonicChangeWithNoAttackStillCountsAsEvidence() {
        // A pad or keyboard swelling into the new chord: pitch content moves and holds, but there
        // is no transient to snap to.
        let audit = ChordEvidenceAudit.audit(
            events: [event(0, .c), event(2, .g)],
            frameObservations: frames([(0, 2, .c), (2, 4, .g)]),
            attackOnsets: [0]
        )
        XCTAssertEqual(audit.verdicts[1].evidence, .harmonic)
    }

    func testAttackWithNoHarmonicChangeIsNotTreatedAsUnsupported() {
        // A re-strum inside the ringing chord. Evidence is weaker, but the event survives.
        let audit = ChordEvidenceAudit.audit(
            events: [event(0, .c), event(2, .c)],
            frameObservations: frames([(0, 4, .c)]),
            attackOnsets: [0, 2]
        )
        XCTAssertEqual(audit.verdicts[1].evidence, .attack)
        XCTAssertEqual(audit.unsupportedCount, 0)
    }

    func testEventWithNeitherAttackNorHarmonicChangeIsUnsupported() {
        let audit = ChordEvidenceAudit.audit(
            events: [event(0, .c), event(2, .g)],
            frameObservations: frames([(0, 4, .c)]),
            attackOnsets: [0]
        )
        XCTAssertEqual(audit.verdicts[1].evidence, .unsupported)
    }

    func testUnstableLabelFlickerIsNotAHarmonicChange() {
        // A bend or passing tone: the label moves for one frame, then the old chord resumes.
        // Chroma novelty without stability must not authorize a marker.
        let flicker = frames([(0, 2, .c), (2, 2.05, .g), (2.05, 4, .c)])
        let audit = ChordEvidenceAudit.audit(
            events: [event(0, .c), event(2, .g)],
            frameObservations: flicker,
            attackOnsets: [0]
        )
        XCTAssertEqual(audit.verdicts[1].evidence, .unsupported)
    }

    // MARK: - Chroma change-points

    func testChangePointsDecideHarmonicEvidenceWhenAvailable() {
        // Frames say the label never changes; the chroma says it did. The change-point wins.
        let audit = ChordEvidenceAudit.audit(
            events: [event(2, .g)],
            frameObservations: frames([(0, 4, .c)]),
            attackOnsets: [],
            changePoints: [2.05]
        )
        XCTAssertEqual(audit.verdicts[0].evidence, .harmonic)
        XCTAssertEqual(audit.verdicts[0].harmonicSource, .changePoint)
        XCTAssertEqual(audit.verdicts[0].nearestChangePointDelta ?? 0, 0.05, accuracy: 1e-9)
    }

    func testChangePointTooFarAwayDoesNotSupportTheMarker() {
        let audit = ChordEvidenceAudit.audit(
            events: [event(2, .g)],
            frameObservations: frames([(0, 4, .c)]),
            attackOnsets: [],
            changePoints: [3.5]
        )
        XCTAssertEqual(audit.verdicts[0].evidence, .unsupported)
    }

    func testEmptyChangePointArrayStillAcceptsAStableFrameLabelChange() {
        // The cosine-distance detector found no spike, but the classifier's winner moved and
        // held. That is the slow G–D–C walk a 12-string drone never spikes: labels are the
        // harmonic evidence the distance curve missed.
        let audit = ChordEvidenceAudit.audit(
            events: [event(2, .g)],
            frameObservations: frames([(0, 2, .c), (2, 4, .g)]),
            attackOnsets: [],
            changePoints: []
        )
        XCTAssertEqual(audit.verdicts[0].evidence, .harmonic)
        XCTAssertEqual(audit.verdicts[0].harmonicSource, .frameLabels)
    }

    func testNilChangePointsFallBackToFrameLabels() {
        let audit = ChordEvidenceAudit.audit(
            events: [event(2, .g)],
            frameObservations: frames([(0, 2, .c), (2, 4, .g)]),
            attackOnsets: [],
            changePoints: nil
        )
        XCTAssertEqual(audit.verdicts[0].evidence, .harmonic)
        XCTAssertEqual(audit.verdicts[0].harmonicSource, .frameLabels)
        XCTAssertNil(audit.verdicts[0].nearestChangePointDelta)
    }

    func testChangePointsCatchAChangeTheLabelProxyMisses() {
        // C -> Am shares C and E. The classifier's winner can stay on C across the move, so the
        // label proxy sees no change at all — while the chroma cosine distance registers one.
        // This is the failure the upgrade exists to fix.
        let unchangedLabels = frames([(0, 4, .c)])
        let proxy = ChordEvidenceAudit.audit(
            events: [event(2, "Am")],
            frameObservations: unchangedLabels,
            attackOnsets: [],
            changePoints: nil
        )
        XCTAssertEqual(proxy.verdicts[0].evidence, .unsupported, "the proxy misses it")

        let measured = ChordEvidenceAudit.audit(
            events: [event(2, "Am")],
            frameObservations: unchangedLabels,
            attackOnsets: [],
            changePoints: [2.0]
        )
        XCTAssertEqual(measured.verdicts[0].evidence, .harmonic, "the change-point catches it")
        XCTAssertEqual(measured.verdicts[0].harmonicSource, .changePoint)
    }

    func testStableFrameChangeAuthorizesAMarkerChangePointsMissed() {
        // Verse G–D with dense picking attacks and a change-point nowhere nearby. Labels
        // hold; that is enough harmonic evidence even though the distance detector slept.
        let audit = ChordEvidenceAudit.audit(
            events: [event(0, .g), event(2, .d)],
            frameObservations: frames([(0, 2, .g), (2, 4, .d)]),
            attackOnsets: [0, 0.5, 1.0, 1.5, 2.0, 2.5],
            changePoints: [10.0]
        )
        XCTAssertEqual(audit.verdicts[1].evidence, .attackAndHarmonic)
        XCTAssertEqual(audit.verdicts[1].harmonicSource, .frameLabels)
    }

    func testFilteringDropsShortAttackOnlyFlickerButKeepsABeatLengthChange() {
        // Jangly picking licenses every sliver. Sub-beat Bm/E/F#m inside a G bar must go;
        // a beat of G with only attack evidence (stability window didn't catch it) stays.
        let events = [
            event(0, .g),
            event(0.15, "Bm"),
            event(0.30, .e),
            event(0.55, .d),
        ]
        let result = ChordEvidenceAudit.filtered(
            events: events,
            frameObservations: frames([(0, 0.55, .g), (0.55, 3, .d)]),
            attackOnsets: [0, 0.15, 0.30, 0.55],
            changePoints: [],
            sourceDuration: 3,
            minimumAttackOnlyDuration: 0.5
        )
        XCTAssertEqual(result.events.map(\.chord), ["G", "D"])
    }

    func testChangePointDetectorFeedsTheAuditEndToEnd() {
        // Real detector output, not a hand-written array: a step from a C-major chroma to an
        // A-minor one must produce a change-point the audit then accepts.
        var chroma: [ChromaVector] = []
        var t = 0.0
        while t < 4 {
            let pitches: [PitchClass] = t < 2 ? [.c, .e, .g] : [.a, .c, .e]
            var values = [Float](repeating: 0.001, count: PitchClass.allCases.count)
            for pitch in pitches { values[pitch.rawValue] = 1 }
            chroma.append(ChromaVector(timestamp: t, values: values))
            t += 0.05
        }
        let points = ChromaChangePointDetector.changePoints(frames: chroma)
        XCTAssertFalse(points.isEmpty, "the detector must fire on a clean chroma step")

        let audit = ChordEvidenceAudit.audit(
            events: [event(2, "Am")],
            frameObservations: frames([(0, 4, .c)]),
            attackOnsets: [],
            changePoints: points
        )
        XCTAssertEqual(audit.verdicts[0].evidence, .harmonic)
    }

    // MARK: - Filtering

    func testFilteringDropsUnsupportedEventsButNeverTheFirst() {
        // The event at 6.0 has no attack near it and no harmonic change (the frames stay on A
        // from 4.0 onward), so it is the decoder reporting held harmony — exactly what must not
        // reach the chart.
        let events = [event(0, .c), event(2, .g), event(4, "Am"), event(6, .f)]
        let result = ChordEvidenceAudit.filtered(
            events: events,
            frameObservations: frames([(0, 2, .c), (2, 4, .g), (4, 8, .a)]),
            attackOnsets: [0, 2, 4]
        )
        XCTAssertEqual(result.events.map(\.chord), ["C", "G", "Am"])
        XCTAssertEqual(result.audit.unsupportedCount, 1)
        XCTAssertNotNil(ChordEvidenceAudit.warning(for: result.audit))
    }

    func testFirstEventSurvivesEvenWhenUnsupported() {
        // A chart needs a chord to open on, and the song's opening attack routinely precedes the
        // first decoded window. The rest of the song is supported, so the audit is trusted and
        // does filter — the opening event is spared by rule, not by the trust guard.
        let result = ChordEvidenceAudit.filtered(
            events: [event(1, .c), event(3, .g), event(5, .f), event(7, .a)],
            frameObservations: frames([(0, 3, .c), (3, 5, .g), (5, 7, .f), (7, 9, .a)]),
            attackOnsets: [3, 5, 7]
        )
        XCTAssertEqual(result.events.map(\.chord), ["C", "G", "F", "A"])
        XCTAssertEqual(result.audit.verdicts[0].evidence, .unsupported)
        XCTAssertTrue(result.audit.evidenceTrusted)
    }

    func testMostlyUnsupportedEvidenceFiltersNothingAndWarnsInstead() {
        // The self-guard: when the stem is the suspect (bleed, or a fingerpicked part with no
        // discrete attacks), deleting most of the chart is the worse failure.
        let events = [event(0, .c), event(2, .g), event(4, "Am"), event(6, .f)]
        let result = ChordEvidenceAudit.filtered(
            events: events,
            frameObservations: frames([(0, 8, .c)]),
            attackOnsets: []
        )
        XCTAssertEqual(result.events.count, events.count, "nothing may be dropped")
        XCTAssertFalse(result.audit.evidenceTrusted)
        XCTAssertEqual(
            ChordEvidenceAudit.warning(for: result.audit)?.contains("none were filtered"), true)
    }

    func testEmptyInputsAreHandled() {
        let empty = ChordEvidenceAudit.audit(
            events: [], frameObservations: [], attackOnsets: [])
        XCTAssertTrue(empty.verdicts.isEmpty)
        XCTAssertNil(ChordEvidenceAudit.warning(for: empty))

        let noEvidence = ChordEvidenceAudit.filtered(
            events: [event(0, .c)], frameObservations: [], attackOnsets: [])
        XCTAssertEqual(noEvidence.events.count, 1)
        XCTAssertFalse(noEvidence.audit.evidenceTrusted)
    }

    func testNearestAttackDeltaIsSignedFromTheEvent() {
        let audit = ChordEvidenceAudit.audit(
            events: [event(2.0, .c)],
            frameObservations: frames([(0, 4, .c)]),
            attackOnsets: [2.2]
        )
        XCTAssertEqual(audit.verdicts[0].nearestAttackDelta ?? 0, 0.2, accuracy: 1e-9)
    }
}
