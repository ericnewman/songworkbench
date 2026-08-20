import XCTest

@testable import SongWorkbench

final class ChordQualityAuditTests: XCTestCase {
    private func event(_ time: TimeInterval, _ chord: String) -> EditableChordEvent {
        EditableChordEvent(time: time, chord: chord, confidence: 0.8)
    }

    /// Frame observations at `hop` spacing: `[(start, end, root, quality)]`.
    private func frames(
        _ spans: [(TimeInterval, TimeInterval, PitchClass, ChordQuality)],
        hop: TimeInterval = 0.05
    ) -> [ChordObservation] {
        var result: [ChordObservation] = []
        for (start, end, root, quality) in spans {
            var t = start
            while t < end {
                result.append(
                    ChordObservation(
                        timestamp: t,
                        chord: Chord(root: root, quality: quality),
                        confidence: 0.9
                    ))
                t += hop
            }
        }
        return result
    }

    // MARK: - The Dm -> D failure

    func testMinorHeardInTheFramesRevertsAKeyPriorMajor() {
        // The documented recurring failure: the decoder emitted D because D is diatonic, while
        // every frame in the span classified a minor third straight from the chroma.
        let result = ChordQualityAudit.corrected(
            events: [event(0, "D")],
            frameObservations: frames([(0, 2, .d, .minor)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["Dm"])
        XCTAssertEqual(result.audit.correctedCount, 1)
        XCTAssertEqual(
            result.audit.findings[0].verdict, .corrected(from: "D", to: "Dm"))
    }

    func testMajorHeardInTheFramesRevertsAnOverEagerMinor() {
        let result = ChordQualityAudit.corrected(
            events: [event(0, "Am")],
            frameObservations: frames([(0, 2, .a, .major)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["A"])
    }

    func testAgreementIsConfirmedAndChangesNothing() {
        let result = ChordQualityAudit.corrected(
            events: [event(0, "Dm")],
            frameObservations: frames([(0, 2, .d, .minor)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["Dm"])
        XCTAssertEqual(result.audit.findings[0].verdict, .confirmed)
        XCTAssertEqual(result.audit.confirmedEventIndices, [0])
        XCTAssertNil(ChordQualityAudit.warning(for: result.audit))
    }

    func testSeventhKeepsItsSeventhWhenTheThirdIsCorrected() {
        let result = ChordQualityAudit.corrected(
            events: [event(0, "D7")],
            frameObservations: frames([(0, 2, .d, .minor7)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["Dm7"])
    }

    func testDominantSeventhCountsAsMajorEvidenceAboutTheThird() {
        // A dominant seventh has a major third, so frames hearing D7 confirm D rather than
        // contradicting it.
        let result = ChordQualityAudit.corrected(
            events: [event(0, "D")],
            frameObservations: frames([(0, 2, .d, .dominant7)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["D"])
        XCTAssertEqual(result.audit.findings[0].verdict, .confirmed)
    }

    // MARK: - Absent third

    func testSplitFramesReadAsAnAbsentThirdAndChangeNothing() {
        // A power chord or a voicing that omits the third: the classifier flips between major and
        // minor across the span. The honest answer is "uncertain", not whichever edged the count.
        let result = ChordQualityAudit.corrected(
            events: [event(0, "D")],
            frameObservations: frames([(0, 1, .d, .major), (1, 2, .d, .minor)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["D"])
        XCTAssertEqual(result.audit.findings[0].verdict, .ambiguousThird)
        XCTAssertEqual(result.audit.correctedCount, 0)
        XCTAssertTrue(
            ChordQualityAudit.warning(for: result.audit)?.contains("power chords") ?? false)
    }

    func testFramesForADifferentRootAreNotEvidenceAboutThisChord() {
        let result = ChordQualityAudit.corrected(
            events: [event(0, "D")],
            frameObservations: frames([(0, 2, .g, .minor)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["D"])
        XCTAssertEqual(result.audit.findings[0].verdict, .noEvidence)
    }

    func testOnlyFramesInsideTheEventSpanCount() {
        // The second event's minor frames must not drag the first event's quality with them.
        let result = ChordQualityAudit.corrected(
            events: [event(0, "D"), event(2, "D")],
            frameObservations: frames([(0, 2, .d, .major), (2, 4, .d, .minor)]),
            sourceDuration: 4
        )
        XCTAssertEqual(result.events.map(\.chord), ["D", "Dm"])
    }

    func testUnparseableLabelsAreLeftAlone() {
        let result = ChordQualityAudit.corrected(
            events: [event(0, "N.C."), event(1, "Dsus4")],
            frameObservations: frames([(0, 2, .d, .minor)]),
            sourceDuration: 2
        )
        XCTAssertEqual(result.events.map(\.chord), ["N.C.", "Dsus4"])
    }

    func testEmptyInputsAreHandled() {
        XCTAssertTrue(ChordQualityAudit.audit(events: [], frameObservations: []).findings.isEmpty)
        let noFrames = ChordQualityAudit.corrected(
            events: [event(0, "D")], frameObservations: [])
        XCTAssertEqual(noFrames.events.map(\.chord), ["D"])
    }

    // MARK: - Round-tripping every name the pipeline can produce

    func testParseInvertsEveryDisplayName() {
        for root in PitchClass.allCases {
            for quality in ChordQuality.allCases {
                let chord = Chord(root: root, quality: quality)
                let parsed = ChordQualityAudit.parse(chord.displayName)
                XCTAssertEqual(parsed?.root, root, chord.displayName)
                XCTAssertEqual(parsed?.quality, quality, chord.displayName)
            }
        }
    }

    // MARK: - Phantom and noise frames

    func testSilentFramesDoNotRewriteAChordsQuality() {
        // `ChordClassifier.bestMatch` initialises to C MAJOR and only replaces on a strictly
        // better score, so a silent frame returns C at confidence 0. Counting those rewrote a
        // held `Cm` to `C` over any quiet passage — the exact Dm->D failure this audit prevents.
        let phantom = (0..<40).map {
            ChordObservation(
                timestamp: Double($0) * 0.05,
                chord: Chord(root: .c, quality: .major),
                confidence: 0)
        }
        let result = ChordQualityAudit.corrected(
            events: [event(0, "Cm")], frameObservations: phantom, sourceDuration: 2)
        XCTAssertEqual(result.events.map(\.chord), ["Cm"])
        XCTAssertEqual(result.audit.correctedCount, 0)
    }

    func testFlatChromaNoiseIsBelowTheUsableBar() {
        // A flat chroma scores 0.4867 against a major triad and 0.5632 against maj7, so any bar
        // at or below ~0.49 admits pure noise as evidence about the third.
        XCTAssertGreaterThan(ChordQualityAudit.minimumUsableFrameConfidence, 0.4867)
    }

    func testTooFewUsableFramesLeavesTheQualityAlone() {
        // One frame must not flip a chord AND then mark it confirmed, which would lock the flip
        // against the repeated-section vote.
        let sparse = [
            ChordObservation(
                timestamp: 0, chord: Chord(root: .d, quality: .minor), confidence: 0.9)
        ]
        let result = ChordQualityAudit.corrected(
            events: [event(0, "D")], frameObservations: sparse, sourceDuration: 2)
        XCTAssertEqual(result.events.map(\.chord), ["D"])
        XCTAssertTrue(result.audit.confirmedEventIndices.isEmpty)
    }
}
