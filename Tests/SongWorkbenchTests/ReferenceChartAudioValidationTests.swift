import XCTest

@testable import SongWorkbench

final class ReferenceChartTimingTests: XCTestCase {
    private func word(_ text: String, _ start: TimeInterval, _ range: Range<Int>) -> TimedLyricWord
    {
        TimedLyricWord(text: text, start: start, end: start + 0.4, characterRange: range)
    }

    /// "Monday's been hanging" with word timings 1 s apart.
    private var segment: TimedLyricSegment {
        TimedLyricSegment(
            start: 10, end: 14, text: "Monday's been hanging",
            words: [
                word("Monday's", 10, 0..<8),
                word("been", 11, 9..<13),
                word("hanging", 12, 14..<21),
            ])
    }

    func testChordTakesTheTimeOfTheWordItSitsOver() throws {
        let reference = "[C]Monday's [G]been [Am]hanging\n"
        let timed = try ReferenceChartTiming.timedEvents(
            reference: reference, lyricSegments: [segment])
        XCTAssertEqual(timed.events.map(\.chord), ["C", "G", "Am"])
        XCTAssertEqual(timed.events.map(\.time), [10, 11, 12])
        XCTAssertEqual(timed.matchedLineCount, 1)
        XCTAssertEqual(timed.untimedChordCount, 0)
    }

    func testAlignmentSurvivesTextDifferencesBetweenReferenceAndTranscription() throws {
        // The reference carries the real lyric, ours carries ASR output — here "thousand" came
        // back as "thousend", and the apostrophe differs. Character offsets from one text do not
        // address the other; word INDEX does, so the chords still land on the right words.
        let ours = TimedLyricSegment(
            start: 10, end: 16, text: "Mondays been hanging around like a thousend",
            words: [
                word("Mondays", 10, 0..<7),
                word("been", 11, 8..<12),
                word("hanging", 12, 13..<20),
                word("around", 13, 21..<27),
                word("like", 14, 28..<32),
                word("a", 15, 33..<34),
                word("thousend", 16, 35..<43),
            ])
        let timed = try ReferenceChartTiming.timedEvents(
            reference: "[C]Monday's been [G]hanging around like a [Am]thousand\n",
            lyricSegments: [ours])
        XCTAssertEqual(timed.matchedLineCount, 1)
        XCTAssertEqual(timed.events.map(\.time), [10, 12, 16])
    }

    func testUnmatchedReferenceLinesAreReportedNotGuessed() throws {
        // A chord timed by assumption would then be "validated" at a position nothing put it at.
        let reference = "[C]Some line we never transcribed at all here\n"
        let timed = try ReferenceChartTiming.timedEvents(
            reference: reference, lyricSegments: [segment])
        XCTAssertTrue(timed.events.isEmpty)
        XCTAssertEqual(timed.untimedChordCount, 1)
        XCTAssertEqual(timed.matchedLineCount, 0)
    }

    func testLineWithOnlyLineLevelTimingsPlacesChordsAtTheLineStart() throws {
        let noWords = TimedLyricSegment(
            start: 10, end: 14, text: "Monday's been hanging", words: [])
        let timed = try ReferenceChartTiming.timedEvents(
            reference: "[C]Monday's [G]been\n", lyricSegments: [noWords])
        XCTAssertEqual(timed.events.map(\.time), [10, 10])
    }

    func testEventsComeBackInTimeOrder() throws {
        let second = TimedLyricSegment(
            start: 20, end: 24, text: "Work keeps piling",
            words: [word("Work", 20, 0..<4), word("keeps", 21, 5..<10)])
        let timed = try ReferenceChartTiming.timedEvents(
            reference: "[C]Monday's been hanging\n[F]Work [G]keeps piling\n",
            lyricSegments: [segment, second])
        XCTAssertEqual(timed.events.map(\.time), timed.events.map(\.time).sorted())
    }

    func testEmptyInputsAreHandled() throws {
        XCTAssertTrue(
            try ReferenceChartTiming.timedEvents(reference: "", lyricSegments: [segment])
                .events.isEmpty)
        let noSegments = try ReferenceChartTiming.timedEvents(
            reference: "[C]Monday's been hanging\n", lyricSegments: [])
        XCTAssertTrue(noSegments.events.isEmpty)
        XCTAssertEqual(noSegments.untimedChordCount, 1)
    }

    func testWordRangesSplitOnWhitespace() {
        XCTAssertEqual(
            ReferenceChartTiming.wordRanges(in: "one two  three"),
            [0..<3, 4..<7, 9..<14])
    }
}

final class ReferenceChartAudioValidationTests: XCTestCase {
    private func event(_ time: TimeInterval, _ chord: String) -> EditableChordEvent {
        EditableChordEvent(time: time, chord: chord, confidence: 0.8)
    }

    /// Chords every 2 s, with an attack under each.
    private func supported(_ count: Int) -> ([EditableChordEvent], [TimeInterval]) {
        let events = (0..<count).map { event(Double($0) * 2, "C") }
        return (events, events.map(\.time))
    }

    func testUploadedChartWinsWhenTheAudioBacksItBetter() {
        // Ten reference chords all on attacks; ten generated chords, only two on attacks.
        let (referenceEvents, onsets) = supported(10)
        let generatedEvents = (0..<10).map { event(Double($0) * 2 + 0.9, "C") }
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: referenceEvents,
            untimedChordCount: 0,
            generatedEvents: generatedEvents,
            frameObservations: [],
            attackOnsets: onsets,
            changePoints: []
        )
        XCTAssertEqual(result.verdict, .referenceBetter)
        XCTAssertEqual(result.reference.supportedCount, 10)
        XCTAssertLessThan(result.generated.supportedCount, 10)
        XCTAssertEqual(
            ReferenceChartAudioValidation.summary(for: result)?
                .contains("uploaded chart matches the recording better"), true)
    }

    func testGeneratedChartWinsWhenItIsTheBetterSupportedOne() {
        let (generatedEvents, onsets) = supported(10)
        let referenceEvents = (0..<10).map { event(Double($0) * 2 + 0.9, "C") }
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: referenceEvents,
            untimedChordCount: 0,
            generatedEvents: generatedEvents,
            frameObservations: [],
            attackOnsets: onsets,
            changePoints: []
        )
        XCTAssertEqual(result.verdict, .generatedBetter)
    }

    func testEquallySupportedChartsAreComparable() {
        let (events, onsets) = supported(10)
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: events,
            untimedChordCount: 0,
            generatedEvents: events,
            frameObservations: [],
            attackOnsets: onsets,
            changePoints: []
        )
        XCTAssertEqual(result.verdict, .comparable)
    }

    func testUnsupportedReferenceChordsAreFlaggedIndividually() {
        let referenceEvents = [event(0, "C"), event(2, "G"), event(50, "Bb")]
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: referenceEvents,
            untimedChordCount: 0,
            generatedEvents: referenceEvents,
            frameObservations: [],
            attackOnsets: [0, 2],
            changePoints: []
        )
        XCTAssertEqual(result.unsupportedFindings.map(\.chord), ["Bb"])
    }

    func testNoAudioEvidenceIsInconclusiveNotAVerdict() {
        // Absence of evidence must never be read as evidence the uploaded chart is wrong.
        let (events, _) = supported(10)
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: events,
            untimedChordCount: 0,
            generatedEvents: events,
            frameObservations: [],
            attackOnsets: [],
            changePoints: nil
        )
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(
            ReferenceChartAudioValidation.summary(for: result)?.contains("re-analyse"), true)
    }

    func testTooFewTimedChordsIsInconclusive() {
        let (events, onsets) = supported(3)
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: events,
            untimedChordCount: 40,
            generatedEvents: events,
            frameObservations: [],
            attackOnsets: onsets,
            changePoints: []
        )
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(result.untimedChordCount, 40)
    }

    func testAOneChordEdgeIsNotReportedAsAWinner() {
        let (referenceEvents, onsets) = supported(20)
        var generatedEvents = referenceEvents
        generatedEvents[0].time = 99
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: referenceEvents,
            untimedChordCount: 0,
            generatedEvents: generatedEvents,
            frameObservations: [],
            attackOnsets: onsets,
            changePoints: []
        )
        XCTAssertEqual(result.verdict, .comparable, "a 5% edge is inside the noise margin")
    }

    // MARK: - Chord quality

    /// Frames hearing `root` with `quality` across a span, at the 50 ms test hop.
    private func frames(
        _ spans: [(TimeInterval, TimeInterval, PitchClass, ChordQuality)]
    ) -> [ChordObservation] {
        var result: [ChordObservation] = []
        for (start, end, root, quality) in spans {
            var t = start
            while t < end {
                result.append(
                    ChordObservation(
                        timestamp: t, chord: Chord(root: root, quality: quality), confidence: 0.9))
                t += 0.05
            }
        }
        return result
    }

    func testUploadedChordNamingTheWrongThirdIsFlaggedWithASuggestion() {
        // The uploaded chart says D; every frame in its span heard a minor third.
        let referenceEvents = [event(0, "D")]
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: referenceEvents,
            untimedChordCount: 0,
            generatedEvents: referenceEvents,
            frameObservations: frames([(0, 2, .d, .minor)]),
            attackOnsets: [0],
            changePoints: []
        )
        XCTAssertEqual(result.wrongQualityFindings.map(\.chord), ["D"])
        XCTAssertEqual(result.wrongQualityFindings.first?.suggestedChord, "Dm")
    }

    func testQualityAgreementIsReportedForBothCharts() {
        // Uploaded says Dm (right), generated says D (wrong) — same placement for both, so only
        // the third separates them.
        let observations = frames([(0, 2, .d, .minor)])
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: [event(0, "Dm")],
            untimedChordCount: 0,
            generatedEvents: [event(0, "D")],
            frameObservations: observations,
            attackOnsets: [0],
            changePoints: []
        )
        XCTAssertEqual(result.reference.qualityAgreementShare, 1.0)
        XCTAssertEqual(result.generated.qualityAgreementShare, 0.0)
        XCTAssertTrue(result.wrongQualityFindings.isEmpty, "the UPLOADED third is correct here")
    }

    func testQualityIsSilentWithoutFrameEvidence() {
        // No frames kept: absence must not be reported as a quality disagreement.
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: [event(0, "D")],
            untimedChordCount: 0,
            generatedEvents: [event(0, "D")],
            frameObservations: [],
            attackOnsets: [0],
            changePoints: []
        )
        XCTAssertNil(result.reference.qualityAgreementShare)
        XCTAssertTrue(result.wrongQualityFindings.isEmpty)
    }

    func testPlacementAndQualityAreReportedSeparately() {
        // Right place, wrong third — must NOT count as unsupported placement.
        let result = ReferenceChartAudioValidation.validate(
            referenceEvents: [event(0, "D")],
            untimedChordCount: 0,
            generatedEvents: [event(0, "D")],
            frameObservations: frames([(0, 2, .d, .minor)]),
            attackOnsets: [0],
            changePoints: []
        )
        XCTAssertTrue(result.unsupportedFindings.isEmpty)
        XCTAssertEqual(result.wrongQualityFindings.count, 1)
    }
}
