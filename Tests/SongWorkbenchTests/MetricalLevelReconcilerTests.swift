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

    // MARK: AnalysisTimingPostPasses — the trio in the pipeline, provenance-guarded

    private func documentNeedingRetune() -> SongAnalysisDocument {
        let trueBPM = 152.0
        let reportedBPM = trueBPM * 2 / 3
        var document = SongAnalysisDocument()
        document.estimatedBPM = reportedBPM
        document.beatTimes = uniformBeats(bpm: reportedBPM, duration: 120)
        document.lyrics = lineOnsets(
            bpm: trueBPM, beatsPerLine: 4, lineCount: 30, jitter: 0.05
        ).map { TimedLyricSegment(start: $0, end: $0 + 1.2, text: "la la la") }
        return document
    }

    func testPostPassesRetuneStoreRawAndStamp() {
        var document = documentNeedingRetune()
        let rawBPM = document.estimatedBPM
        let rawBeats = document.beatTimes
        AnalysisTimingPostPasses.apply(to: &document)
        XCTAssertEqual(document.estimatedBPM!, 152.0, accuracy: 0.5)
        XCTAssertEqual(document.preReconciliationTiming?.estimatedBPM, rawBPM)
        XCTAssertEqual(document.preReconciliationTiming?.beatTimes, rawBeats)
        XCTAssertTrue(AnalysisTimingPostPasses.isCurrent(document))
        XCTAssertNotNil(document.barGrid, "every stamped document carries its one bar grid")
    }

    /// The structural guarantee that replaced "never persist the reconciled values": re-running
    /// the passes on their own persisted output restores the raw answer first, so the tempo
    /// cannot walk (the 101.3 -> 152.0 -> 81.1 loop).
    func testPostPassesNeverCompoundAcrossRepeatedRuns() {
        var document = documentNeedingRetune()
        AnalysisTimingPostPasses.apply(to: &document)
        let firstBPM = document.estimatedBPM
        let firstBeats = document.beatTimes
        for _ in 0..<3 {
            // Simulate a version bump forcing a re-run on the persisted (already-retuned) doc.
            document.timingPostPassTag = nil
            AnalysisTimingPostPasses.apply(to: &document)
        }
        XCTAssertEqual(document.estimatedBPM!, firstBPM!, accuracy: 1e-6)
        XCTAssertEqual(document.beatTimes.count, firstBeats.count)
    }

    func testPostPassesLeaveACorrectTempoAloneAndStoreNoRaw() {
        let bpm = 96.0
        var document = SongAnalysisDocument()
        document.estimatedBPM = bpm
        document.beatTimes = uniformBeats(bpm: bpm, duration: 160)
        document.lyrics = lineOnsets(bpm: bpm, beatsPerLine: 8, lineCount: 26, jitter: 0.05)
            .map { TimedLyricSegment(start: $0, end: $0 + 1.2, text: "la la la") }
        AnalysisTimingPostPasses.apply(to: &document)
        XCTAssertEqual(document.estimatedBPM, bpm)
        XCTAssertNil(document.preReconciliationTiming)
        XCTAssertTrue(AnalysisTimingPostPasses.isCurrent(document))
    }

    func testPostPassesRetuneTheBarGridWithTheBeats() {
        var document = documentNeedingRetune()
        document.barGrid = SongBarGrid(
            beatsPerBar: 4, barPhase: 2, confidence: 0.4, phaseSource: .drumAccents)
        AnalysisTimingPostPasses.apply(to: &document)
        // x3/2 retune: 4 beats/bar -> 6, phase 2 -> 3 (see SongBarGrid.retuned).
        XCTAssertEqual(document.barGrid?.beatsPerBar, 6)
        XCTAssertEqual(document.barGrid?.barPhase, 3)
        XCTAssertEqual(document.preReconciliationTiming?.barGrid?.beatsPerBar, 4)
        XCTAssertEqual(document.preReconciliationTiming?.barGrid?.barPhase, 2)
    }

    /// Field case, Back to New Orleans (2026-09-14): the tracker's 139.7 BPM grid carried only the
    /// default anchored 4/4. The x3/4 retune to 104.8 BPM rescaled that guess into 3/4, so rows
    /// of 8 beats rounded up to 9 and every row gained a beat of false silence. An anchored grid
    /// has no measured bar length to preserve: it must be re-estimated on the retuned beats.
    func testPostPassesReestimateAnAnchoredBarGridInsteadOfRescalingIt() {
        var document = documentNeedingRetune()
        document.barGrid = SongBarGrid(
            beatsPerBar: 4, barPhase: 0, confidence: 0.05, phaseSource: .anchoredToFirstBeat)
        AnalysisTimingPostPasses.apply(to: &document)
        XCTAssertEqual(document.estimatedBPM!, 152.0, accuracy: 0.5, "the fixture must retune")
        XCTAssertEqual(document.barGrid?.beatsPerBar, 4, "a guessed 4/4 must not rescale to 6")
        XCTAssertEqual(document.barGrid?.phaseSource, .anchoredToFirstBeat)
        XCTAssertEqual(document.preReconciliationTiming?.barGrid?.beatsPerBar, 4)
    }

    /// Field case, Don't Forget Me (2026-09-15 corpus, catalog 144 BPM): the stored lines were
    /// already recut on the retuned grid, and `regroup` keeps stored line starts, so every re-run
    /// fed the previous recut to the next verdict — 127.6 -> 143.6 -> 71.8. Restoring the raw
    /// beats alone does not close the loop (tasks/lessons.md, 2026-08-05): the reconciler must
    /// also read the lines as they stood BEFORE the recut. After the first pass nothing may move,
    /// and user annotations must ride along.
    func testPostPassesReadTheLinesAsTheyStoodBeforeTheirOwnRecut() throws {
        var document = try JSONDecoder().decode(
            SongAnalysisDocument.self, from: Data(Self.recutOnRetunedGridFixture.utf8))
        document.lyrics[3].accepted = true
        document.lyrics[7].overrideText = "corrected"
        document.timingPostPassTag = nil
        AnalysisTimingPostPasses.apply(to: &document)
        let first = document
        XCTAssertTrue(first.lyrics.contains { $0.accepted })
        XCTAssertTrue(first.lyrics.contains { $0.overrideText == "corrected" })
        for pass in 2...4 {
            document.timingPostPassTag = nil
            AnalysisTimingPostPasses.apply(to: &document)
            XCTAssertEqual(
                document.estimatedBPM, first.estimatedBPM, "pass \(pass) moved the tempo")
            XCTAssertEqual(document.beatTimes, first.beatTimes, "pass \(pass) moved the beats")
            XCTAssertEqual(
                document.lyrics.map(\.start), first.lyrics.map(\.start),
                "pass \(pass) moved the lines")
            XCTAssertEqual(document.lyrics.map(\.accepted), first.lyrics.map(\.accepted))
            XCTAssertEqual(document.lyrics.map(\.overrideText), first.lyrics.map(\.overrideText))
        }
    }

    /// The raw line starts are only trusted while the stored lines still start where the passes
    /// published them. A Lyric Blend pick that merges two lines is new raw input: re-running
    /// must honour the merge, exactly as for a document that never stored raw starts.
    func testPostPassesTreatLyricsRewrittenSinceAsRaw() throws {
        var document = try JSONDecoder().decode(
            SongAnalysisDocument.self, from: Data(Self.recutOnRetunedGridFixture.utf8))
        AnalysisTimingPostPasses.apply(to: &document)
        // Merge the first line pair whose second line starts lowercase, so no grouping rule
        // re-splits it on its own — only a stale raw start could.
        let index = try XCTUnwrap(
            document.lyrics.indices.dropLast().first {
                document.lyrics[$0 + 1].words.first?.text.hasPrefix("la") == true
            })
        let merged = document.lyrics[index + 1]
        document.lyrics[index].words += merged.words
        document.lyrics[index].end = merged.end
        document.lyrics[index].text += " " + merged.text
        document.lyrics.remove(at: index + 1)
        document.timingPostPassTag = nil
        var control = document
        control.preRecutLineOnsets = nil

        AnalysisTimingPostPasses.apply(to: &document)
        AnalysisTimingPostPasses.apply(to: &control)
        XCTAssertEqual(document.estimatedBPM, control.estimatedBPM)
        XCTAssertEqual(document.lyrics.map(\.start), control.lyrics.map(\.start))
        XCTAssertEqual(document.preRecutLineOnsets, control.preRecutLineOnsets)
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

    // MARK: Tie-breaking prefers the slower tempo

    func testAnOctaveTieDeclinesAndReportsBothCandidates() {
        // Lines 8 beats apart at the true tempo are ALSO 4 beats apart at half of it, so x3/2 and
        // x3/4 score identically by construction. Field case (2026-09-15 corpus): Jessie was a
        // dead man and Something to believe v2 took x3/4 on the slower tie-break (97.5 -> 73.1)
        // when the catalog says x3/2 (144); Moving on and both Another day takes took it when the
        // tracker was already right. A tie has not decided anything, so it must decline.
        let trueBPM = 168.5
        let reportedBPM = trueBPM * 2 / 3
        let onsets = lineOnsets(bpm: trueBPM, beatsPerLine: 8, lineCount: 22, jitter: 0.03)
        let verdict = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: reportedBPM,
                beatTimes: uniformBeats(bpm: reportedBPM, duration: 140),
                lineOnsets: onsets))
        XCTAssertFalse(verdict.isRetune)
        XCTAssertEqual(verdict.bpm, reportedBPM)
        XCTAssertTrue(
            verdict.ambiguousWith.contains(MetricalRatio(3, 2))
                || verdict.ambiguousWith.contains(MetricalRatio(3, 4)),
            "the declined tie must be reported, got \(verdict.ambiguousWith)")
    }

    func testSlowerWinsAThreeHalvesVersusThreeQuartersTie() {
        // The tie-break still fixes which tied winner a declined verdict reports.
        XCTAssertLessThan(MetricalRatio(3, 4).value, MetricalRatio(3, 2).value)
    }

    // MARK: Both halves must reject the incumbent

    func testARetuneCarriedByOneHalfOfTheSongDeclines() {
        // Field case, Good friends and a beer or two (2026-09-15 corpus, catalog 108): x3/2 won
        // 105.5 -> 158.2 on the whole song while one half of its lines still fit x1. Here 24
        // lines sit on a clean x3/2 grid and the last 10 on the incumbent's own 8-beat phrases.
        let reportedBPM = 100.0
        let fastBPM = reportedBPM * 3 / 2
        let fast = lineOnsets(bpm: fastBPM, beatsPerLine: 4, lineCount: 24, jitter: 0.04)
        let slow = lineOnsets(
            bpm: reportedBPM, beatsPerLine: 8, lineCount: 10, jitter: 0.04,
            start: fast.last! + 60.0 / reportedBPM * 8)
        let onsets = fast + slow
        let beats = uniformBeats(bpm: reportedBPM, duration: slow.last! + 5)

        // Precondition: on the whole song x3/2 clears both fit gates.
        let intervals = zip(onsets, onsets.dropFirst()).map { $1 - $0 }
        let atFast = try! XCTUnwrap(
            MetricalLevelReconciler.bestDyadicFit(intervals: intervals.map { $0 / (60 / fastBPM) }))
        let atIncumbent = try! XCTUnwrap(
            MetricalLevelReconciler.bestDyadicFit(
                intervals: intervals.map { $0 / (60 / reportedBPM) }))
        XCTAssertLessThanOrEqual(atFast.fitError, 0.15)
        XCTAssertLessThanOrEqual(atFast.fitError, atIncumbent.fitError * 0.6)

        let verdict = try! XCTUnwrap(
            MetricalLevelReconciler.reconcile(
                bpm: reportedBPM, beatTimes: beats, lineOnsets: onsets))
        XCTAssertFalse(verdict.isRetune, "the second half fits the incumbent")
        XCTAssertTrue(
            MetricalLevelReconciler.reconcile(
                bpm: reportedBPM, beatTimes: beats, lineOnsets: Array(fast.prefix(17)))?.isRetune
                ?? false,
            "the first half alone would retune")
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

    // MARK: BouncingBall horizontal easing (amber chord ball)

    func testLinearEasingTravelsAtConstantVelocityBetweenTaps() {
        // Chord taps 4s apart: the ball must be exactly on pace at every instant.
        let ball = BouncingBall(
            beatTimes: [0, 4], beatX: [0, 400], horizontalEasing: .linear)
        for fraction in [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95] {
            let position = try! XCTUnwrap(ball.position(at: 4 * fraction))
            XCTAssertEqual(position.x, CGFloat(400 * fraction), accuracy: 0.001)
        }
    }

    func testSmoothstepCreepsAtTheEndsWhichIsWhyChordsUseLinear() {
        let eased = BouncingBall(beatTimes: [0, 4], beatX: [0, 400])
        let linear = BouncingBall(beatTimes: [0, 4], beatX: [0, 400], horizontalEasing: .linear)
        // Over the first 5% of a 4-second gap, smoothstep covers 2.9 px against linear's 20 —
        // under a sixth of the pace. That near-stillness is what reads as "stopped, waiting".
        let easedStart = try! XCTUnwrap(eased.position(at: 0.2))
        let linearStart = try! XCTUnwrap(linear.position(at: 0.2))
        XCTAssertEqual(easedStart.x, 2.9, accuracy: 0.1)
        XCTAssertEqual(linearStart.x, 20, accuracy: 0.001)
        XCTAssertLessThan(easedStart.x, linearStart.x / 6)
        // Symmetrically at the far end: 5% of the gap still to run, but only 2.9 px of travel
        // left — the ball looks like it arrived early and sat there.
        let easedEnd = try! XCTUnwrap(eased.position(at: 3.8))
        XCTAssertEqual(easedEnd.x, 397.1, accuracy: 0.1)
        XCTAssertGreaterThan(easedEnd.x, 400 - (400 - linearStart.x) / 6)
    }

    func testBothEasingsLandExactlyOnTheOnset() {
        // The fix is about the JOURNEY, not the arrival: both must be exact at the tap.
        for easing in [BouncingBall.HorizontalEasing.smoothstep, .linear] {
            let ball = BouncingBall(
                beatTimes: [0, 4], beatX: [0, 400], horizontalEasing: easing)
            let arrival = try! XCTUnwrap(ball.position(at: 4))
            XCTAssertEqual(arrival.x, 400, accuracy: 0.001)
            XCTAssertEqual(arrival.lift, 0, accuracy: 0.001, "the ball taps down on the onset")
        }
    }

    func testWordBallKeepsSmoothstepByDefault() {
        let ball = BouncingBall(beatTimes: [0, 4], beatX: [0, 400])
        let position = try! XCTUnwrap(ball.position(at: 2))
        // smoothstep(0.5) == 0.5, so midpoint agrees; the difference is only off-centre.
        XCTAssertEqual(position.x, 200, accuracy: 0.001)
        let quarter = try! XCTUnwrap(ball.position(at: 1))
        XCTAssertNotEqual(quarter.x, 100, accuracy: 1.0)
    }

    func testMedianBeatLengthFallsBackToNominalForShortGrids() {
        let length = try! XCTUnwrap(
            MetricalLevelReconciler.medianBeatLength(beatTimes: [0, 0.5], bpm: 120))
        XCTAssertEqual(length, 0.5, accuracy: 1e-9)
    }
}

extension MetricalLevelReconcilerTests {
    /// Don't Forget Me as stored by the 2026-09-15 corpus run (stem-whisper85): published at
    /// 127.6 BPM, raw tracker answer 95.7 BPM, lines already recut on the retuned grid. Words are
    /// anonymized to la/La (case and trailing punctuation kept, since grouping reads both) and
    /// times are rounded to 0.1 ms; the replay walk reproduces on this copy.
    fileprivate static let recutOnRetunedGridFixture = #"""
        {"estimatedBPM":127.60416666666666,"barGrid":{"barPhase":0,"beatsPerBar":5,"confidence":0,"phaseSource":"anchoredToFirstBeat"},"timingPostPassTag":"timing-3",
        "preReconciliationTiming":{"estimatedBPM":95.703125,"barGrid":{"barPhase":3,"beatsPerBar":4,"confidence":0.08381154297209627,"phaseSource":"drumAccents"},"beatTimes":[
        1.1238,1.7507,2.3776,3.0046,3.6315,4.2585,4.8854,5.5123,6.1393,6.7662,7.3931,8.0201,
        8.647,9.274,9.9009,10.5278,11.1548,11.7817,12.4087,13.0356,13.6625,14.2895,14.9164,15.5434,
        16.1703,16.7972,17.4242,18.0511,18.678,19.305,19.9319,20.5589,21.1858,21.8127,22.4397,23.0666,
        23.6936,24.3205,24.9474,25.5744,26.2013,26.8282,27.4552,28.0821,28.7091,29.336,29.9629,30.5899,
        31.2168,31.8438,32.4707,33.0976,33.7246,34.3515,34.9785,35.6054,36.2323,36.8593,37.4862,38.1131,
        38.7401,39.367,39.994,40.6209,41.2478,41.8748,42.5017,43.1287,43.7556,44.3825,45.0095,45.6364,
        46.2634,46.8903,47.5172,48.1442,48.7711,49.398,50.025,50.6519,51.2789,51.9058,52.5327,53.1597,
        53.7866,54.4136,55.0405,55.6674,56.2944,56.9213,57.5482,58.1752,58.8021,59.4291,60.056,60.6829,
        61.3099,61.9368,62.5638,63.1907,63.8176,64.4446,65.0715,65.6985,66.3254,66.9523,67.5793,68.2062,
        68.8331,69.4601,70.087,70.714,71.3409,71.9678,72.5948,73.2217,73.8487,74.4756,75.1025,75.7295,
        76.3564,76.9834,77.6103,78.2372,78.8642,79.4911,80.118,80.745,81.3719,81.9989,82.6258,83.2527,
        83.8797,84.5066,85.1336,85.7605,86.3874,87.0144,87.6413,88.2682,88.8952,89.5221,90.1491,90.776,
        91.4029,92.0299,92.6568,93.2838,93.9107,94.5376,95.1646,95.7915,96.4185,97.0454,97.6723,98.2993,
        98.9262,99.5531,100.1801,100.807,101.434,102.0609,102.6878,103.3148,103.9417,104.5687,105.1956,105.8225,
        106.4495,107.0764,107.7034,108.3303,108.9572,109.5842,110.2111,110.838,111.465,112.0919,112.7189,113.3458,
        113.9727,114.5997,115.2266,115.8536,116.4805,117.1074,117.7344,118.3613,118.9882,119.6152,120.2421,120.8691,
        121.496,122.1229,122.7499,123.3768,124.0038,124.6307,125.2576,125.8846,126.5115,127.1385,127.7654,128.3923,
        129.0193,129.6462,130.2731,130.9001,131.527,132.154,132.7809,133.4078,134.0348,134.6617,135.2887,135.9156,
        136.5425,137.1695,137.7964,138.4234,139.0503,139.6772,140.3042,140.9311,141.558,142.185,142.8119,143.4389,
        144.0658,144.6927,145.3197,145.9466,146.5736,147.2005,147.8274,148.4544,149.0813,149.7082,150.3352,150.9621,
        151.5891,152.216,152.8429,153.4699,154.0968,154.7238,155.3507,155.9776,156.6046,157.2315,157.8585,158.4854,
        159.1123,159.7393,160.3662,160.9931,161.6201,162.247,162.874,163.5009,164.1278,164.7548,165.3817,166.0087,
        166.6356,167.2625,167.8895,168.5164,169.1434,169.7703,170.3972,171.0242,171.6511,172.278,172.905,173.5319,
        174.1589,174.7858,175.4127,176.0397,176.6666,177.2936,177.9205,178.5474,179.1744,179.8013,180.4282,181.0552,
        181.6821,182.3091,182.936,183.5629,184.1899,184.8168,185.4438,186.0707,186.6976,187.3246,187.9515,188.5785,
        189.2054,189.8323,190.4593,191.0862,191.7131,192.3401,192.967,193.594,194.2209,194.8478,195.4748,196.1017,
        196.7287,197.3556,197.9825,198.6095,199.2364,199.8634,200.4903,201.1172,201.7442,202.3711,202.998,203.625,
        204.2519,204.8789,205.5058,206.1327,206.7597,207.3866,208.0136,208.6405,209.2674,209.8944,210.5213,211.1482,
        211.7752,212.4021,213.0291,213.656,214.2829,214.9099,215.5368,216.1638,216.7907,217.4176,218.0446,218.6715,
        219.2985,219.9254,220.5523,221.1793,221.8062,222.4331,223.0601,223.687,224.314,224.9409,225.5678,226.1948,
        226.8217,227.4487,228.0756,228.7025,229.3295,229.9564,230.5834,231.2103,231.8372,232.4642,233.0911,233.718,
        234.345,234.9719,235.5989,236.2258,236.8527,237.4797,238.1066,238.7336,239.3605,239.9874,240.6144,241.2413,
        241.8682,242.4952,243.1221,243.7491,244.376,245.0029,245.6299,246.2568,246.8838,247.5107,248.1376,248.7646,
        249.3915,250.0185,250.6454,251.2723,251.8993,252.5262,253.1531,253.7801,254.407,255.034,255.6609,256.2878,
        256.9148,257.5417,258.1687,258.7956,259.4225,260.0495,260.6764,261.3034,261.9303,262.5572,263.1842,263.8111,
        264.438,265.065,265.6919,266.3189,266.9458,267.5727,268.1997,268.8266,269.4536,270.0805,270.7074,271.3344,
        271.9613,272.5882,273.2152,273.8421,274.4691
        ]},"lyrics":[
        {"start":25.5,"end":30.7445,"text":"La la la la la la la","words":[{"text":"La","start":25.5,"end":26.3075,"characterRange":[0,2]},{"text":"la","start":26.3075,"end":26.911,"characterRange":[3,5]},{"text":"la","start":26.911,"end":28.2455,"characterRange":[6,8]},{"text":"la","start":28.2455,"end":28.7215,"characterRange":[9,11]},{"text":"la","start":28.7215,"end":29.053,"characterRange":[12,14]},{"text":"la","start":29.053,"end":29.886,"characterRange":[15,17]},{"text":"la","start":30.03,"end":30.7445,"characterRange":[18,20]}]},
        {"start":30.67,"end":37.349,"text":"La la la la la la la","words":[{"text":"La","start":30.67,"end":31.722,"characterRange":[0,2]},{"text":"la","start":31.722,"end":32.453,"characterRange":[3,5]},{"text":"la","start":33.03,"end":33.6685,"characterRange":[6,8]},{"text":"la","start":33.6685,"end":34.748,"characterRange":[9,11]},{"text":"la","start":34.748,"end":35.326,"characterRange":[12,14]},{"text":"la","start":35.5725,"end":36.0995,"characterRange":[15,17]},{"text":"la","start":35.98,"end":37.349,"characterRange":[18,20]}]},
        {"start":37.349,"end":40.545,"text":"La la la","words":[{"text":"La","start":37.349,"end":38.403,"characterRange":[0,2]},{"text":"la","start":38.42,"end":39.2105,"characterRange":[3,5]},{"text":"la","start":39.69,"end":40.545,"characterRange":[6,8]}]},
        {"start":40.66,"end":44.03,"text":"la la la","words":[{"text":"la","start":40.66,"end":42.27,"characterRange":[0,2]},{"text":"la","start":42.27,"end":42.9165,"characterRange":[3,5]},{"text":"la","start":42.9505,"end":44.03,"characterRange":[6,8]}]},
        {"start":44.01,"end":50.95,"text":"La la la la la la","words":[{"text":"La","start":44.01,"end":44.761,"characterRange":[0,2]},{"text":"la","start":44.761,"end":46.223,"characterRange":[3,5]},{"text":"la","start":46.38,"end":47.192,"characterRange":[6,8]},{"text":"la","start":47.192,"end":48.3905,"characterRange":[9,11]},{"text":"la","start":48.3905,"end":49.385,"characterRange":[12,14]},{"text":"la","start":49.385,"end":50.95,"characterRange":[15,17]}]},
        {"start":51,"end":54.622,"text":"La la la la","words":[{"text":"La","start":51,"end":51.6205,"characterRange":[0,2]},{"text":"la","start":51.646,"end":52.717,"characterRange":[3,5]},{"text":"la","start":52.61,"end":53.7965,"characterRange":[6,8]},{"text":"la","start":53.8985,"end":54.622,"characterRange":[9,11]}]},
        {"start":54.672,"end":63.954,"text":"La la la la","words":[{"text":"La","start":54.672,"end":56.729,"characterRange":[0,2]},{"text":"la","start":56.9585,"end":59.0325,"characterRange":[3,5]},{"text":"la","start":59.21,"end":61.37,"characterRange":[6,8]},{"text":"la","start":61.37,"end":63.954,"characterRange":[9,11]}]},
        {"start":63.9,"end":67.593,"text":"La la la la la la","words":[{"text":"La","start":63.9,"end":64.634,"characterRange":[0,2]},{"text":"la","start":64.7,"end":65.433,"characterRange":[3,5]},{"text":"la","start":65.3,"end":65.705,"characterRange":[6,8]},{"text":"la","start":65.8,"end":66.2575,"characterRange":[9,11]},{"text":"la","start":66.13,"end":67.0735,"characterRange":[12,14]},{"text":"la","start":66.95,"end":67.593,"characterRange":[15,17]}]},
        {"start":67.643,"end":75.395,"text":"La la la la la la la","words":[{"text":"La","start":67.643,"end":69.462,"characterRange":[0,2]},{"text":"la","start":69.9295,"end":71.655,"characterRange":[3,5]},{"text":"la","start":71.53,"end":72.0375,"characterRange":[6,8]},{"text":"la","start":72.386,"end":73.066,"characterRange":[9,11]},{"text":"la","start":72.96,"end":74.222,"characterRange":[12,14]},{"text":"la","start":74.13,"end":74.528,"characterRange":[15,17]},{"text":"la","start":74.5535,"end":75.395,"characterRange":[18,20]}]},
        {"start":75.395,"end":80.767,"text":"La la la la la la","words":[{"text":"La","start":75.395,"end":76.381,"characterRange":[0,2]},{"text":"la","start":76.4065,"end":77.554,"characterRange":[3,5]},{"text":"la","start":77.51,"end":77.962,"characterRange":[6,8]},{"text":"la","start":78.16,"end":78.7525,"characterRange":[9,11]},{"text":"la","start":78.7525,"end":79.781,"characterRange":[12,14]},{"text":"la","start":79.781,"end":80.767,"characterRange":[15,17]}]},
        {"start":80.767,"end":90.44,"text":"La la la la la la la la la","words":[{"text":"La","start":80.767,"end":82.994,"characterRange":[0,2]},{"text":"la","start":83.0535,"end":83.6315,"characterRange":[3,5]},{"text":"la","start":83.657,"end":84.762,"characterRange":[6,8]},{"text":"la","start":84.762,"end":85.629,"characterRange":[9,11]},{"text":"la","start":85.782,"end":86.819,"characterRange":[12,14]},{"text":"la","start":86.904,"end":87.7965,"characterRange":[15,17]},{"text":"la","start":87.87,"end":89.2415,"characterRange":[18,20]},{"text":"la","start":89.3,"end":89.658,"characterRange":[21,23]},{"text":"la","start":89.72,"end":90.44,"characterRange":[24,26]}]},
        {"start":90.39,"end":94,"text":"La la la","words":[{"text":"La","start":90.39,"end":91.8425,"characterRange":[0,2]},{"text":"la","start":92.87,"end":93.534,"characterRange":[3,5]},{"text":"la","start":93.534,"end":94,"characterRange":[6,8]}]},
        {"start":94.05,"end":101.847,"text":"La la la la la","words":[{"text":"La","start":94.05,"end":95.4805,"characterRange":[0,2]},{"text":"la","start":95.489,"end":96.5175,"characterRange":[3,5]},{"text":"la","start":96.815,"end":98.4725,"characterRange":[6,8]},{"text":"la","start":98.4725,"end":101.014,"characterRange":[9,11]},{"text":"la","start":100.88,"end":101.847,"characterRange":[12,14]}]},
        {"start":101.95,"end":103.802,"text":"la la","words":[{"text":"la","start":101.95,"end":102.6545,"characterRange":[0,2]},{"text":"la","start":102.68,"end":103.802,"characterRange":[3,5]}]},
        {"start":103.802,"end":110.73,"text":"La la la la la la","words":[{"text":"La","start":103.802,"end":104.686,"characterRange":[0,2]},{"text":"la","start":104.686,"end":105.57,"characterRange":[3,5]},{"text":"la","start":105.99,"end":107.338,"characterRange":[6,8]},{"text":"la","start":107.3,"end":108.188,"characterRange":[9,11]},{"text":"la","start":108.188,"end":109.769,"characterRange":[12,14]},{"text":"la","start":109.769,"end":110.73,"characterRange":[15,17]}]},
        {"start":110.78,"end":117.283,"text":"La la la la la la la","words":[{"text":"La","start":110.78,"end":111.5795,"characterRange":[0,2]},{"text":"la","start":111.605,"end":112.3105,"characterRange":[3,5]},{"text":"la","start":112.3445,"end":113.4835,"characterRange":[6,8]},{"text":"la","start":113.5685,"end":114.6565,"characterRange":[9,11]},{"text":"la","start":114.69,"end":115.87,"characterRange":[12,14]},{"text":"la","start":115.87,"end":116.5605,"characterRange":[15,17]},{"text":"la","start":116.586,"end":117.283,"characterRange":[18,20]}]},
        {"start":117.283,"end":123.42,"text":"La la la la la","words":[{"text":"La","start":117.283,"end":118.0225,"characterRange":[0,2]},{"text":"la","start":118.0225,"end":118.762,"characterRange":[3,5]},{"text":"la","start":118.762,"end":119.9945,"characterRange":[6,8]},{"text":"la","start":119.9945,"end":121.635,"characterRange":[9,11]},{"text":"la","start":121.635,"end":123.42,"characterRange":[12,14]}]},
        {"start":123.42,"end":127.98,"text":"La la la la La la la la","words":[{"text":"La","start":123.42,"end":124.185,"characterRange":[0,2]},{"text":"la","start":124.185,"end":125.477,"characterRange":[3,5]},{"text":"la","start":125.715,"end":126.786,"characterRange":[6,8]},{"text":"la","start":126.77,"end":127.0835,"characterRange":[9,11]},{"text":"La","start":127.092,"end":127.2195,"characterRange":[12,14]},{"text":"la","start":127.2365,"end":127.4745,"characterRange":[15,17]},{"text":"la","start":127.4745,"end":127.7125,"characterRange":[18,20]},{"text":"la","start":127.738,"end":127.98,"characterRange":[21,23]}]},
        {"start":128.03,"end":137.003,"text":"La la la la","words":[{"text":"La","start":128.03,"end":129.948,"characterRange":[0,2]},{"text":"la","start":130.2285,"end":132.3025,"characterRange":[3,5]},{"text":"la","start":132.3025,"end":134.4785,"characterRange":[6,8]},{"text":"la","start":134.53,"end":137.003,"characterRange":[9,11]}]},
        {"start":137.02,"end":140.43,"text":"La la la la la la","words":[{"text":"La","start":137.02,"end":137.768,"characterRange":[0,2]},{"text":"la","start":137.76,"end":138.6775,"characterRange":[3,5]},{"text":"la","start":138.62,"end":138.992,"characterRange":[6,8]},{"text":"la","start":138.992,"end":139.4,"characterRange":[9,11]},{"text":"la","start":139.4,"end":140.0035,"characterRange":[12,14]},{"text":"la","start":140.02,"end":140.43,"characterRange":[15,17]}]},
        {"start":140.48,"end":143.8455,"text":"La la la","words":[{"text":"La","start":140.48,"end":141.7375,"characterRange":[0,2]},{"text":"la","start":142.7065,"end":143.3185,"characterRange":[3,5]},{"text":"la","start":143.3185,"end":143.8455,"characterRange":[6,8]}]},
        {"start":143.98,"end":148.6225,"text":"la la la la","words":[{"text":"la","start":143.98,"end":144.7975,"characterRange":[0,2]},{"text":"la","start":144.7975,"end":146.744,"characterRange":[3,5]},{"text":"la","start":146.67,"end":147.271,"characterRange":[6,8]},{"text":"la","start":147.271,"end":148.6225,"characterRange":[9,11]}]},
        {"start":148.58,"end":149.753,"text":"La la la la la la la","words":[{"text":"La","start":148.58,"end":148.801,"characterRange":[0,2]},{"text":"la","start":148.801,"end":149.0135,"characterRange":[3,5]},{"text":"la","start":149.0135,"end":149.0815,"characterRange":[6,8]},{"text":"la","start":149.0815,"end":149.226,"characterRange":[9,11]},{"text":"la","start":149.226,"end":149.4725,"characterRange":[12,14]},{"text":"la","start":149.4725,"end":149.5405,"characterRange":[15,17]},{"text":"la","start":149.5405,"end":149.753,"characterRange":[18,20]}]},
        {"start":150.603,"end":154.343,"text":"La la la la la la","words":[{"text":"La","start":150.603,"end":151.2915,"characterRange":[0,2]},{"text":"la","start":151.2915,"end":152.1245,"characterRange":[3,5]},{"text":"la","start":152.01,"end":152.3965,"characterRange":[6,8]},{"text":"la","start":152.49,"end":152.949,"characterRange":[9,11]},{"text":"la","start":153.06,"end":153.782,"characterRange":[12,14]},{"text":"la","start":153.782,"end":154.343,"characterRange":[15,17]}]},
        {"start":154.36,"end":157.182,"text":"La la la la la la la la la","words":[{"text":"La","start":154.36,"end":154.887,"characterRange":[0,2]},{"text":"la","start":154.79,"end":155.0315,"characterRange":[3,5]},{"text":"la","start":155.0315,"end":155.329,"characterRange":[6,8]},{"text":"la","start":155.329,"end":155.55,"characterRange":[9,11]},{"text":"la","start":155.55,"end":155.771,"characterRange":[12,14]},{"text":"la","start":155.771,"end":156.0685,"characterRange":[15,17]},{"text":"la","start":156.0685,"end":156.5785,"characterRange":[18,20]},{"text":"la","start":156.621,"end":156.7315,"characterRange":[21,23]},{"text":"la","start":156.7485,"end":157.182,"characterRange":[24,26]}]},
        {"start":157.182,"end":164.713,"text":"La la la la la la la la la","words":[{"text":"La","start":157.182,"end":157.488,"characterRange":[0,2]},{"text":"la","start":157.42,"end":157.573,"characterRange":[3,5]},{"text":"la","start":157.56,"end":157.7345,"characterRange":[6,8]},{"text":"la","start":157.7515,"end":157.879,"characterRange":[9,11]},{"text":"la","start":157.85,"end":158.0235,"characterRange":[12,14]},{"text":"la","start":158.16,"end":159.698,"characterRange":[15,17]},{"text":"la","start":159.8765,"end":162.18,"characterRange":[18,20]},{"text":"la","start":162.18,"end":163.03,"characterRange":[21,23]},{"text":"la","start":163.098,"end":164.713,"characterRange":[24,26]}]},
        {"start":164.713,"end":166.4045,"text":"La la la la la la la La la la la la la","words":[{"text":"La","start":164.713,"end":164.9,"characterRange":[0,2]},{"text":"la","start":164.9255,"end":165.1465,"characterRange":[3,5]},{"text":"la","start":165.1465,"end":165.223,"characterRange":[6,8]},{"text":"la","start":165.223,"end":165.376,"characterRange":[9,11]},{"text":"la","start":165.376,"end":165.6225,"characterRange":[12,14]},{"text":"la","start":165.648,"end":165.699,"characterRange":[15,17]},{"text":"la","start":165.73,"end":165.954,"characterRange":[18,20]},{"text":"La","start":165.954,"end":166.039,"characterRange":[21,23]},{"text":"la","start":166.039,"end":166.141,"characterRange":[24,26]},{"text":"la","start":166.1665,"end":166.1835,"characterRange":[27,29]},{"text":"la","start":166.1835,"end":166.2515,"characterRange":[30,32]},{"text":"la","start":166.2515,"end":166.3535,"characterRange":[33,35]},{"text":"la","start":166.39,"end":166.4045,"characterRange":[36,38]}]},
        {"start":166.39,"end":168.098,"text":"La la la la la la la la","words":[{"text":"La","start":166.39,"end":166.855,"characterRange":[0,2]},{"text":"la","start":166.4045,"end":166.532,"characterRange":[3,5]},{"text":"la","start":166.855,"end":167.229,"characterRange":[6,8]},{"text":"la","start":167.2545,"end":167.3735,"characterRange":[9,11]},{"text":"la","start":167.399,"end":167.484,"characterRange":[12,14]},{"text":"la","start":167.484,"end":167.6625,"characterRange":[15,17]},{"text":"la","start":167.6625,"end":167.7135,"characterRange":[18,20]},{"text":"la","start":167.7135,"end":168.098,"characterRange":[21,23]}]},
        {"start":185.13,"end":188.292,"text":"La la la la la la","words":[{"text":"La","start":185.13,"end":185.606,"characterRange":[0,2]},{"text":"la","start":185.6315,"end":185.9545,"characterRange":[3,5]},{"text":"la","start":186.04,"end":186.4475,"characterRange":[6,8]},{"text":"la","start":186.51,"end":187.442,"characterRange":[9,11]},{"text":"la","start":187.442,"end":187.7735,"characterRange":[12,14]},{"text":"la","start":187.93,"end":188.292,"characterRange":[15,17]}]},
        {"start":188.292,"end":191.9238,"text":"La la la la la la","words":[{"text":"La","start":188.292,"end":188.8955,"characterRange":[0,2]},{"text":"la","start":188.8955,"end":189.788,"characterRange":[3,5]},{"text":"la","start":189.7965,"end":190.553,"characterRange":[6,8]},{"text":"la","start":190.48,"end":190.8505,"characterRange":[9,11]},{"text":"la","start":191.08,"end":191.301,"characterRange":[12,14]},{"text":"la","start":191.29,"end":191.9238,"characterRange":[15,17]}]},
        {"start":192.083,"end":195.466,"text":"La la la la","words":[{"text":"La","start":192.083,"end":193.069,"characterRange":[0,2]},{"text":"la","start":193.05,"end":194.259,"characterRange":[3,5]},{"text":"la","start":194.33,"end":195.06,"characterRange":[6,8]},{"text":"la","start":195.06,"end":195.466,"characterRange":[9,11]}]},
        {"start":195.466,"end":198.798,"text":"La la la la","words":[{"text":"La","start":195.466,"end":196.4435,"characterRange":[0,2]},{"text":"la","start":196.4435,"end":197.421,"characterRange":[3,5]},{"text":"la","start":197.29,"end":198.271,"characterRange":[6,8]},{"text":"la","start":198.271,"end":198.798,"characterRange":[9,11]}]},
        {"start":198.798,"end":203.78,"text":"La la la la la la la","words":[{"text":"La","start":198.798,"end":199.682,"characterRange":[0,2]},{"text":"la","start":199.66,"end":199.903,"characterRange":[3,5]},{"text":"la","start":199.98,"end":200.804,"characterRange":[6,8]},{"text":"la","start":201.03,"end":201.5095,"characterRange":[9,11]},{"text":"la","start":201.603,"end":202.334,"characterRange":[12,14]},{"text":"la","start":202.334,"end":203.099,"characterRange":[15,17]},{"text":"la","start":203.08,"end":203.78,"characterRange":[18,20]}]},
        {"start":203.83,"end":206.38,"text":"La la","words":[{"text":"La","start":203.83,"end":205.105,"characterRange":[0,2]},{"text":"la","start":205.139,"end":206.38,"characterRange":[3,5]}]},
        {"start":206.7285,"end":209.729,"text":"la La la la la la","words":[{"text":"la","start":206.7285,"end":207.0175,"characterRange":[0,2]},{"text":"La","start":207.026,"end":207.3065,"characterRange":[3,5]},{"text":"la","start":207.3065,"end":207.4255,"characterRange":[6,8]},{"text":"la","start":207.451,"end":208.148,"characterRange":[9,11]},{"text":"la","start":208.148,"end":208.4285,"characterRange":[12,14]},{"text":"la","start":208.4285,"end":209.729,"characterRange":[15,17]}]},
        {"start":209.729,"end":214.3728,"text":"La la la la","words":[{"text":"La","start":209.729,"end":210.46,"characterRange":[0,2]},{"text":"la","start":210.46,"end":211.6925,"characterRange":[3,5]},{"text":"la","start":212.024,"end":212.925,"characterRange":[6,8]},{"text":"la","start":212.94,"end":214.3728,"characterRange":[9,11]}]},
        {"start":217.583,"end":220.966,"text":"La la la la La la la la","words":[{"text":"La","start":217.583,"end":217.8635,"characterRange":[0,2]},{"text":"la","start":217.8635,"end":218.331,"characterRange":[3,5]},{"text":"la","start":218.331,"end":218.79,"characterRange":[6,8]},{"text":"la","start":218.89,"end":219.198,"characterRange":[9,11]},{"text":"La","start":219.19,"end":219.504,"characterRange":[12,14]},{"text":"la","start":219.37,"end":220.0225,"characterRange":[15,17]},{"text":"la","start":220.12,"end":220.541,"characterRange":[18,20]},{"text":"la","start":220.541,"end":220.966,"characterRange":[21,23]}]},
        {"start":220.966,"end":222.666,"text":"La la la la","words":[{"text":"La","start":220.966,"end":221.34,"characterRange":[0,2]},{"text":"la","start":221.34,"end":221.8075,"characterRange":[3,5]},{"text":"la","start":221.8075,"end":222.173,"characterRange":[6,8]},{"text":"la","start":222.19,"end":222.666,"characterRange":[9,11]}]},
        {"start":222.666,"end":227.206,"text":"La la la la la la","words":[{"text":"La","start":222.666,"end":223.5075,"characterRange":[0,2]},{"text":"la","start":223.55,"end":224.519,"characterRange":[3,5]},{"text":"la","start":224.63,"end":224.859,"characterRange":[6,8]},{"text":"la","start":224.95,"end":225.539,"characterRange":[9,11]},{"text":"la","start":225.58,"end":226.542,"characterRange":[12,14]},{"text":"la","start":226.54,"end":227.206,"characterRange":[15,17]}]},
        {"start":227.256,"end":229.9165,"text":"La la la","words":[{"text":"La","start":227.256,"end":228.276,"characterRange":[0,2]},{"text":"la","start":228.24,"end":229.5,"characterRange":[3,5]},{"text":"la","start":229.5255,"end":229.9165,"characterRange":[6,8]}]},
        {"start":230.1545,"end":233.648,"text":"la la la la","words":[{"text":"la","start":230.1545,"end":230.741,"characterRange":[0,2]},{"text":"la","start":230.74,"end":232.1775,"characterRange":[3,5]},{"text":"la","start":232.1775,"end":232.5855,"characterRange":[6,8]},{"text":"la","start":232.54,"end":233.648,"characterRange":[9,11]}]},
        {"start":233.63,"end":235.297,"text":"La la la la la la la La la la la la la la","words":[{"text":"La","start":233.63,"end":233.7755,"characterRange":[0,2]},{"text":"la","start":233.7755,"end":233.937,"characterRange":[3,5]},{"text":"la","start":233.937,"end":233.9795,"characterRange":[6,8]},{"text":"la","start":233.9965,"end":234.09,"characterRange":[9,11]},{"text":"la","start":234.09,"end":234.2685,"characterRange":[12,14]},{"text":"la","start":234.25,"end":234.328,"characterRange":[15,17]},{"text":"la","start":234.328,"end":234.4895,"characterRange":[18,20]},{"text":"La","start":234.498,"end":234.6255,"characterRange":[21,23]},{"text":"la","start":234.6255,"end":234.7785,"characterRange":[24,26]},{"text":"la","start":234.7785,"end":234.8295,"characterRange":[27,29]},{"text":"la","start":234.8295,"end":234.9315,"characterRange":[30,32]},{"text":"la","start":234.9315,"end":235.11,"characterRange":[33,35]},{"text":"la","start":235.11,"end":235.161,"characterRange":[36,38]},{"text":"la","start":235.161,"end":235.297,"characterRange":[39,41]}]},
        {"start":235.297,"end":239.088,"text":"La la la la la la la La la la la la la","words":[{"text":"La","start":235.297,"end":235.552,"characterRange":[0,2]},{"text":"la","start":235.569,"end":235.8835,"characterRange":[3,5]},{"text":"la","start":235.8835,"end":235.9855,"characterRange":[6,8]},{"text":"la","start":235.9855,"end":236.198,"characterRange":[9,11]},{"text":"la","start":236.198,"end":236.572,"characterRange":[12,14]},{"text":"la","start":236.572,"end":236.6485,"characterRange":[15,17]},{"text":"la","start":236.674,"end":236.997,"characterRange":[18,20]},{"text":"La","start":236.997,"end":237.3795,"characterRange":[21,23]},{"text":"la","start":237.34,"end":237.8385,"characterRange":[24,26]},{"text":"la","start":237.78,"end":237.983,"characterRange":[27,29]},{"text":"la","start":238.02,"end":238.289,"characterRange":[30,32]},{"text":"la","start":238.2975,"end":238.7565,"characterRange":[33,35]},{"text":"la","start":238.7565,"end":239.088,"characterRange":[36,38]}]},
        {"start":239.06,"end":240.703,"text":"La la la la la la","words":[{"text":"La","start":239.06,"end":239.3855,"characterRange":[0,2]},{"text":"la","start":239.3855,"end":239.7425,"characterRange":[3,5]},{"text":"la","start":239.7425,"end":239.853,"characterRange":[6,8]},{"text":"la","start":239.85,"end":240.074,"characterRange":[9,11]},{"text":"la","start":240.04,"end":240.4395,"characterRange":[12,14]},{"text":"la","start":240.465,"end":240.703,"characterRange":[15,17]}]},
        {"start":248.0363,"end":254.9563,"text":"la la la","words":[{"text":"la","start":248.0363,"end":249.4663,"characterRange":[0,2]},{"text":"la","start":249.32,"end":249.9563,"characterRange":[3,5]},{"text":"la","start":249.9563,"end":254.9563,"characterRange":[6,8]}]}
        ]}
        """#
}
