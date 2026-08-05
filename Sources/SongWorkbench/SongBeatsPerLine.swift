import Foundation

/// How a single sung line measures against the song's beats-per-line.
enum LineLengthVerdict: String, Equatable, Sendable {
    /// Spans a whole number of phrase periods, within tolerance.
    case onGrid
    /// Materially shorter than a phrase — usually a line that was split where it should not have
    /// been, or an ASR fragment.
    case short
    /// Materially longer than a phrase — usually two lines that were run together.
    case long
    /// Spans a section break; says nothing about the line's own length.
    case sectionBreak
}

/// One line's measurement against the song-level phrase period.
struct LineLengthMeasurement: Equatable, Sendable {
    /// Index into the lyric line array this measures.
    let lineIndex: Int
    /// Interval from this line's onset to the NEXT line's onset, in beats. The last line has no
    /// successor and is not measured.
    let intervalInBeats: Double
    /// The interval as a multiple of the song's beats-per-line (1.0 = exactly one phrase).
    let periodsSpanned: Double
    let verdict: LineLengthVerdict
}

/// The song-level phrase period, and each line's fit against it.
///
/// This is the framework the chart lays lines out in: one phrase period is the reference extent a
/// row is drawn to, and a line that does not fit is a segmentation defect made visible rather than
/// a layout to be stretched around.
///
/// PERIOD ONLY — there is deliberately no downbeat phase here. Phase was measured unrecoverable on
/// 2026-08-01 (slot boundaries near a real inter-word gap maxed at 53% against a 70% gate; on the
/// cleanest song only 10 of 33 line starts sat within 0.35 s of a slot, median deviation ≈ one full
/// beat). Period recovery reproduced 8.01/8.00 beats on the same songs. Every consumer must anchor
/// to a line's OWN measured onset, never to an absolute slot boundary.
enum SongBeatsPerLine {
    struct Configuration: Equatable, Sendable {
        /// How far from a WHOLE number of periods a line may sit and still count as on-grid.
        var tolerance: Double = 0.25
        /// At or beyond this many periods, treat the interval as a section break instead.
        var sectionBreakThreshold: Double = 2.75
        init() {}
    }

    /// Estimates the song's phrase period from measured line onsets and the measured beat grid.
    /// Returns `nil` when there is not enough evidence.
    static func estimate(
        beatTimes: [TimeInterval],
        bpm: Double,
        lineOnsets: [TimeInterval],
        configuration: MetricalLevelReconciler.Configuration = .init()
    ) -> BeatsPerLineFit? {
        guard bpm > 0,
            let beatLength = MetricalLevelReconciler.medianBeatLength(
                beatTimes: beatTimes, bpm: bpm),
            beatLength > 0
        else { return nil }
        let sorted = lineOnsets.sorted()
        let intervals = zip(sorted, sorted.dropFirst())
            .map { ($1 - $0) / beatLength }
            .filter {
                $0 > configuration.minimumInterval / beatLength
                    && $0 < configuration.maximumInterval / beatLength
            }
        guard !intervals.isEmpty else { return nil }
        return MetricalLevelReconciler.bestDyadicFit(
            intervals: intervals, configuration: configuration)
    }

    /// Measures every line against the phrase period.
    ///
    /// Uses the interval to the NEXT line's onset rather than the line's own end time, because
    /// onsets are real measurements whereas a line's end is derived from word timings that are
    /// character-proportional interpolation inside the line.
    static func measure(
        lineOnsets: [TimeInterval],
        beatsPerLine: Int,
        beatLength: TimeInterval,
        configuration: Configuration = Configuration()
    ) -> [LineLengthMeasurement] {
        guard beatsPerLine > 0, beatLength > 0, lineOnsets.count >= 2 else { return [] }
        let period = Double(beatsPerLine)
        var result: [LineLengthMeasurement] = []
        for index in 0..<(lineOnsets.count - 1) {
            let interval = (lineOnsets[index + 1] - lineOnsets[index]) / beatLength
            guard interval > 0 else { continue }
            let periods = interval / period
            // On-grid means near a WHOLE number of periods, not near exactly one: a deliberate
            // two-phrase line is correct, so the whole-multiple test has to come before any
            // short/long thresholding or every long-but-correct line is flagged.
            let nearest = max(1.0, periods.rounded())
            let verdict: LineLengthVerdict
            if periods >= configuration.sectionBreakThreshold {
                verdict = .sectionBreak
            } else if abs(periods - nearest) <= configuration.tolerance {
                verdict = .onGrid
            } else {
                verdict = periods < 1 ? .short : .long
            }
            result.append(
                LineLengthMeasurement(
                    lineIndex: index,
                    intervalInBeats: interval,
                    periodsSpanned: periods,
                    verdict: verdict))
        }
        return result
    }

    /// Fraction of measured lines that do not sit on the phrase grid, ignoring section breaks.
    /// Measured 2026-08-05 on six live songs: 0.15–0.18 where grouping is clean, 0.29 and 0.48 on
    /// the two songs with known segmentation defects.
    static func outlierRate(_ measurements: [LineLengthMeasurement]) -> Double {
        let scored = measurements.filter { $0.verdict != .sectionBreak }
        guard !scored.isEmpty else { return 0 }
        let bad = scored.filter { $0.verdict != .onGrid }.count
        return Double(bad) / Double(scored.count)
    }
}
