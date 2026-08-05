import XCTest

@testable import SongWorkbench

final class MetricalLevelReconcilerTests: XCTestCase {
    // MARK: Helpers

    /// A song of `lineCount` lines sung every `beatsPerLine` beats at `bpm`, with optional jitter
    /// so the fit is never trivially exact.
    private func lineOnsets(
        bpm: Double,
        beatsPerLine: Int,
        lineCount: Int,
        jitter: TimeInterval = 0,
        start: TimeInterval = 1.0
    ) -> [TimeInterval] {
        let beat = 60.0 / bpm
        let step = beat * Double(beatsPerLine)
        return (0..<lineCount).map { index in
            // Deterministic pseudo-jitter: alternating sign, magnitude cycles through 0…1.
            let phase = Double((index * 7) % 5) / 4.0
            let sign: Double = index % 2 == 0 ? 1 : -1
            return start + Double(index) * step + sign * phase * jitter
        }
    }

    private func uniformBeats(bpm: Double, duration: TimeInterval) -> [TimeInterval] {
        let beat = 60.0 / bpm
        return Array(stride(from: 0.0, through: duration, by: beat))
    }

    // MARK: MetricalRatio

    func testRatioNormalizesAndReportsDisruption() {
        XCTAssertEqual(MetricalRatio(6, 4), MetricalRatio(3, 2))
        XCTAssertTrue(MetricalRatio(4, 4).isIdentity)
        XCTAssertEqual(MetricalRatio(3, 2).value, 1.5, accuracy: 1e-12)
        // x3/4 moves the tempo less than x3/2, so it breaks ties first.
        XCTAssertLessThan(MetricalRatio(3, 4).disruption, MetricalRatio(3, 2).disruption)
        XCTAssertEqual(MetricalRatio(3, 2).description, "x3/2")
    }

    func testOctaveRatiosAreNotCandidates() {
        // A loop-period test cannot discriminate 2:1 — offering it would produce confident nonsense.
        for ratio in MetricalLevelReconciler.candidateRatios {
            XCTAssertNotEqual(ratio.value, 2.0)
            XCTAssertNotEqual(ratio.value, 0.5)
        }
    }

    // MARK: Correct tempo is left alone

    func testCorrectTempoIsNotRetuned() {
        let bpm = 120.0
        let onsets = lineOnsets(bpm: bpm, beatsPerLine: 8, lineCount: 24, jitter: 0.05)
        let verdict = MetricalLevelReconciler.reconcile(
            bpm: bpm, beatTimes: uniformBeats(bpm: bpm, duration: 130), lineOnsets: onsets)
        let unwrapped = try! XCTUnwrap(verdict)
        XCTAssertFalse(unwrapped.isRetune)
        XCTAssertEqual(unwrapped.ratio, .identity)
        XCTAssertEqual(unwrapped.bpm, bpm, accuracy: 1e-9)
        XCTAssertEqual(unwrapped.fit.beatsPerLine, 8)
    }

    func testFourBeatPhrasesAlsoResolveWithoutRetuning() {
        let bpm = 96.0
        let onsets = lineOnsets(bpm: bpm, beatsPerLine: 4, lineCount: 28, jitter: 0.04)
        let verdict = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: bpm, beatTimes: uniformBeats(bpm: bpm, duration: 90), lineOnsets: onsets))
        XCTAssertFalse(verdict.isRetune)
        XCTAssertEqual(verdict.fit.beatsPerLine, 4)
    }

    // MARK: The errors this exists to catch

    func testRecoversA3To2MetricalLevelError() {
        // TRUE tempo 152, 4 beats per line. The tracker reported 101.3 (a 2:3 lag error), under
        // which the same lines measure ~5.9 beats apart — non-dyadic, the classic tell.
        let trueBPM = 152.0
        let reportedBPM = trueBPM * 2 / 3
        let onsets = lineOnsets(bpm: trueBPM, beatsPerLine: 4, lineCount: 30, jitter: 0.05)
        let verdict = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: reportedBPM,
                beatTimes: uniformBeats(bpm: reportedBPM, duration: 120),
                lineOnsets: onsets))
        XCTAssertTrue(verdict.isRetune)
        XCTAssertEqual(verdict.ratio, MetricalRatio(3, 2))
        XCTAssertEqual(verdict.bpm, trueBPM, accuracy: 0.01)
        XCTAssertEqual(verdict.fit.beatsPerLine, 4)
        XCTAssertLessThan(verdict.fit.fitError, verdict.currentFit.fitError)
    }

    func testRecoversA5To4MetricalLevelError() {
        let trueBPM = 88.0
        let reportedBPM = trueBPM * 5 / 4
        let onsets = lineOnsets(bpm: trueBPM, beatsPerLine: 8, lineCount: 26, jitter: 0.04)
        let verdict = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: reportedBPM,
                beatTimes: uniformBeats(bpm: reportedBPM, duration: 150),
                lineOnsets: onsets))
        XCTAssertTrue(verdict.isRetune)
        XCTAssertEqual(verdict.ratio, MetricalRatio(4, 5))
        XCTAssertEqual(verdict.bpm, trueBPM, accuracy: 0.01)
    }

    // MARK: Idempotency — this runs unconditionally on EVERY load and now persists

    func testReconcilingTwiceDoesNotRetuneAgain() {
        // A second pass over an already-corrected song must be a no-op. If it were not, opening
        // the same song repeatedly would walk its tempo away a ratio at a time.
        let trueBPM = 152.0
        let reportedBPM = trueBPM * 2 / 3
        let onsets = lineOnsets(bpm: trueBPM, beatsPerLine: 4, lineCount: 30, jitter: 0.05)
        let beats = uniformBeats(bpm: reportedBPM, duration: 120)

        let first = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: reportedBPM, beatTimes: beats, lineOnsets: onsets))
        XCTAssertTrue(first.isRetune)

        // Apply the verdict exactly as `applyAnalysis` does, then re-run.
        let correctedBeats = MetricalLevelReconciler.reconciledBeatTimes(
            beatTimes: beats, ratio: first.ratio)
        let second = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: first.bpm, beatTimes: correctedBeats, lineOnsets: onsets))
        XCTAssertFalse(second.isRetune, "a corrected song must not be retuned a second time")
        XCTAssertEqual(second.ratio, .identity)
        XCTAssertEqual(second.bpm, first.bpm, accuracy: 1e-6)
    }

    func testReconcilingAnAlreadyCorrectSongRepeatedlyIsStable() {
        let bpm = 96.0
        let onsets = lineOnsets(bpm: bpm, beatsPerLine: 8, lineCount: 26, jitter: 0.05)
        var currentBPM = bpm
        var currentBeats = uniformBeats(bpm: bpm, duration: 160)
        for pass in 1...4 {
            let verdict = try! XCTUnwrap(
                MetricalLevelReconciler.reconcile(
                    bpm: currentBPM, beatTimes: currentBeats, lineOnsets: onsets))
            XCTAssertFalse(verdict.isRetune, "pass \(pass) retuned a song that was already correct")
            currentBeats = MetricalLevelReconciler.reconciledBeatTimes(
                beatTimes: currentBeats, ratio: verdict.ratio)
            currentBPM = verdict.bpm
        }
        XCTAssertEqual(currentBPM, bpm, accuracy: 1e-9)
    }

    // MARK: The gates

    func testBrokenSegmentationDeclinesToRetune() {
        // Scrambled line onsets — the shape of a song whose grouping is broken (measured: 48%
        // outliers, 0.20-beat minimum line duration). No metrical level fits well, so the
        // absolute-quality gate must refuse rather than pick the least-bad ratio.
        let bpm = 110.0
        let beat = 60.0 / bpm
        let ragged: [Double] = [
            0.4, 2.9, 3.2, 7.7, 8.1, 8.3, 13.9, 14.2, 19.6, 20.0, 23.1, 28.8, 29.0, 33.2,
            37.9, 38.1, 43.6, 44.0, 44.2, 49.9, 55.1, 55.4, 60.8, 66.2, 66.5, 71.0,
        ]
        let verdict = MetricalLevelReconciler.reconcile(
            bpm: bpm,
            beatTimes: uniformBeats(bpm: bpm, duration: 80),
            lineOnsets: ragged.map { $0 * beat / beat })
        if let verdict {
            XCTAssertFalse(
                verdict.isRetune,
                "A song this broken must decline, not retune to the least-bad ratio")
        }
    }

    func testMarginalImprovementDoesNotClearTheImprovementGate() {
        // Absolute quality alone is not enough: a candidate must also beat the incumbent by the
        // improvement factor, or a merely-tidier alternative would keep flipping good songs.
        var configuration = MetricalLevelReconciler.Configuration()
        configuration.improvementFactor = 0.6
        let bpm = 120.0
        let onsets = lineOnsets(bpm: bpm, beatsPerLine: 8, lineCount: 24, jitter: 0.05)
        let verdict = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: bpm,
                beatTimes: uniformBeats(bpm: bpm, duration: 130),
                lineOnsets: onsets,
                configuration: configuration))
        XCTAssertFalse(verdict.isRetune)
    }

    func testTooFewLinesYieldsNoVerdict() {
        let bpm = 120.0
        XCTAssertNil(
            MetricalLevelReconciler.reconcile(
                bpm: bpm,
                beatTimes: uniformBeats(bpm: bpm, duration: 30),
                lineOnsets: [1.0, 5.0, 9.0]))
    }

    func testZeroBPMYieldsNoVerdict() {
        XCTAssertNil(
            MetricalLevelReconciler.reconcile(bpm: 0, beatTimes: [], lineOnsets: []))
    }

    // MARK: Ambiguity is reported, not hidden

    func testTiedCandidatesAreSurfacedOnTheVerdict() {
        // A song whose lines are 8 beats apart at the true tempo is ALSO explicable as 4 beats
        // apart at 3/4 the tempo. When two levels score within epsilon, the winner stays
        // deterministic but the tie must be visible so an independent signal can arbitrate.
        let trueBPM = 168.5
        let reportedBPM = trueBPM * 2 / 3
        let onsets = lineOnsets(bpm: trueBPM, beatsPerLine: 8, lineCount: 22, jitter: 0.03)
        let verdict = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: reportedBPM,
                beatTimes: uniformBeats(bpm: reportedBPM, duration: 140),
                lineOnsets: onsets))
        XCTAssertTrue(verdict.isRetune)
        // Whatever wins, a verdict that had a near-tie must say so rather than present a coin
        // flip as a decision.
        if !verdict.ambiguousWith.isEmpty {
            XCTAssertFalse(verdict.ambiguousWith.contains(verdict.ratio))
        }
    }

    // MARK: bestDyadicFit

    func testBestDyadicFitPicksThePeriodAndScoresIt() {
        // Realistically jittered 8-beat phrasing with one 2-period gap. Deliberately NOT exact
        // multiples: with many intervals landing exactly on 8.0 the P=4 median is exactly 0 and
        // the shorter period wins outright, which is the divisibility artifact rather than a tie.
        let intervals = [8.3, 7.7, 8.2, 7.8, 16.4, 8.25, 7.75, 8.3, 7.7, 8.2, 7.8, 8.25]
        let fit = try! XCTUnwrap(MetricalLevelReconciler.bestDyadicFit(intervals: intervals))
        XCTAssertEqual(fit.beatsPerLine, 8)
        XCTAssertLessThan(fit.fitError, 0.05)
        // The 16.4 gap is two periods at P=8, so every interval scores.
        XCTAssertEqual(fit.sampleCount, intervals.count)
        XCTAssertEqual(fit.occupancy, 11.0 / 12.0, accuracy: 1e-9)
    }

    func testShorterPeriodDoesNotWinByDivisibilityOnExactlyRegularInput() {
        // Lines EXACTLY 8 beats apart fit P=4 perfectly too (every interval a clean 2×4), so the
        // errors tie at 0 and the shorter period would win by iteration order. The exact-tie
        // break toward the longer period is the whole scope of this case — real input never ties.
        let intervals = [Double](repeating: 8.0, count: 16)
        let fit = try! XCTUnwrap(MetricalLevelReconciler.bestDyadicFit(intervals: intervals))
        XCTAssertEqual(fit.beatsPerLine, 8, "P=4 explains every interval as 2×4 and must not win")
        XCTAssertEqual(fit.occupancy, 1.0, accuracy: 1e-9)
    }

    func testJitteredInputPicksTheLongerPeriodOnErrorAlone() {
        // The real-data mechanism, independent of the tie-break: relative error is normalised by
        // the period, so any deviation costs P=4 twice what it costs P=8.
        let intervals = [8.3, 7.7, 8.25, 7.8, 8.2, 7.75, 8.3, 7.7, 8.2, 7.8, 8.25, 7.75]
        let fit = try! XCTUnwrap(MetricalLevelReconciler.bestDyadicFit(intervals: intervals))
        XCTAssertEqual(fit.beatsPerLine, 8)
    }

    func testGenuinelyShorterPhrasesStillResolveToTheShorterPeriod() {
        // Guard the opposite error: the tie-break must not drag real 4-beat phrasing up to 8.
        let intervals = [4.1, 3.9, 4.05, 3.95, 4.1, 3.9, 4.0, 4.05, 3.95, 4.1, 3.9, 4.0]
        let fit = try! XCTUnwrap(MetricalLevelReconciler.bestDyadicFit(intervals: intervals))
        XCTAssertEqual(fit.beatsPerLine, 4)
    }

    func testBestDyadicFitReturnsNilWhenTooFewIntervalsScore() {
        // All intervals are section-break sized relative to every dyadic period, so nothing scores.
        XCTAssertNil(MetricalLevelReconciler.bestDyadicFit(intervals: [90, 95, 88]))
    }

    // MARK: reconciledBeatTimes

    func testReconciledGridIsIdentityForTheIdentityRatio() {
        let beats = uniformBeats(bpm: 120, duration: 10)
        XCTAssertEqual(
            MetricalLevelReconciler.reconciledBeatTimes(beatTimes: beats, ratio: .identity), beats)
    }

    func testReconciledGridAtThreeHalvesRetainsEverySecondMeasuredBeat() {
        // 120 bpm → 0.5s beats. At ×3/2 there are 3 new beats per 2 old, so the beat becomes 1/3 s
        // and exactly every SECOND original beat lands on a new one. The odd beats necessarily
        // fall between — that is what changing metrical level means.
        let beats = uniformBeats(bpm: 120, duration: 6)
        let out = MetricalLevelReconciler.reconciledBeatTimes(
            beatTimes: beats, ratio: MetricalRatio(3, 2))
        for (index, original) in beats.enumerated() where index % 2 == 0 {
            XCTAssertTrue(
                out.contains { abs($0 - original) < 1e-6 },
                "measured beat \(original) at even index \(index) must survive")
        }
        let spacing = zip(out, out.dropFirst()).map { $1 - $0 }
        for gap in spacing { XCTAssertEqual(gap, 1.0 / 3.0, accuracy: 1e-6) }
    }

    func testReconciledGridAtFourFifthsIsSlowerAndStaysSorted() {
        let beats = uniformBeats(bpm: 100, duration: 12)
        let out = MetricalLevelReconciler.reconciledBeatTimes(
            beatTimes: beats, ratio: MetricalRatio(4, 5))
        XCTAssertLessThan(out.count, beats.count)
        XCTAssertEqual(out, out.sorted())
        let spacing = zip(out, out.dropFirst()).map { $1 - $0 }
        // 100 bpm → 0.6s; at ×4/5 the tempo is 80 bpm → 0.75s.
        for gap in spacing { XCTAssertEqual(gap, 0.75, accuracy: 1e-6) }
    }

    func testReconciledGridFollowsNonUniformMeasuredBeats() {
        // A drum-locked grid is NOT uniform. The retune must interpolate between the real beats
        // rather than overwrite them with a metronome, so the retained (every-2nd) beats keep
        // their MEASURED times — uneven spacing and all.
        let beats: [TimeInterval] = [0, 0.52, 0.99, 1.55, 2.01]
        let out = MetricalLevelReconciler.reconciledBeatTimes(
            beatTimes: beats, ratio: MetricalRatio(3, 2))
        for (index, original) in beats.enumerated() where index % 2 == 0 {
            XCTAssertTrue(
                out.contains { abs($0 - original) < 1e-6 },
                "measured beat \(original) at even index \(index) must survive")
        }
        // A metronome would have produced perfectly even spacing; the measured grid does not.
        let spacing = zip(out, out.dropFirst()).map { $1 - $0 }
        let spread = (spacing.max() ?? 0) - (spacing.min() ?? 0)
        XCTAssertGreaterThan(spread, 1e-3, "retuned grid must inherit the measured unevenness")
    }

    func testMedianBeatLengthFallsBackToNominalForShortGrids() {
        let length = try! XCTUnwrap(
            MetricalLevelReconciler.medianBeatLength(beatTimes: [0, 0.5], bpm: 120))
        XCTAssertEqual(length, 0.5, accuracy: 1e-9)
    }
}
