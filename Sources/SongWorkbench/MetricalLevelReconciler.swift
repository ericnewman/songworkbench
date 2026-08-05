import Foundation

/// An exact small-integer tempo ratio (candidate BPM ÷ current BPM). Kept exact rather than as a
/// `Double` so a verdict can be logged, compared and persisted without rounding noise.
struct MetricalRatio: Equatable, Hashable, Sendable, CustomStringConvertible {
    let numerator: Int
    let denominator: Int

    init(_ numerator: Int, _ denominator: Int) {
        let g = max(MetricalRatio.gcd(abs(numerator), abs(denominator)), 1)
        self.numerator = numerator / g
        self.denominator = denominator / g
    }

    static let identity = MetricalRatio(1, 1)

    var value: Double { Double(numerator) / Double(denominator) }
    var isIdentity: Bool { numerator == denominator }
    /// How far this ratio moves the tempo, in octaves. Used only to break exact scoring ties
    /// toward the least disruptive candidate.
    var disruption: Double { abs(log2(value)) }
    var description: String { isIdentity ? "x1" : "x\(numerator)/\(denominator)" }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

/// A song-level "beats per line" — how many beats separate one sung line's onset from the next,
/// pooled across the song. Period only: this type deliberately carries NO downbeat phase.
///
/// Phase was measured unrecoverable on 2026-08-01 (slot boundaries landing near a real inter-word
/// gap maxed out at 53% against a 70% gate; on the cleanest song only 10 of 33 line starts sat
/// within 0.35 s of a slot, median deviation ≈ one full beat). Period recovery, by contrast,
/// reproduced 8.01 and 8.00 beats on the two clean songs. Everything here is on the live side of
/// that result — do not reintroduce a phase term.
struct BeatsPerLineFit: Equatable, Sendable {
    /// Beats between consecutive line onsets, always dyadic (4, 8 or 16).
    let beatsPerLine: Int
    /// Median relative error of the line inter-onset intervals against multiples of
    /// `beatsPerLine`. Lower is better; ≈0.09–0.11 on songs whose grouping is clean, ≥0.23 where
    /// the segmentation is broken.
    let fitError: Double
    /// How many line intervals the fit actually scored (intervals spanning a section break are
    /// excluded, so this is below the line count).
    let sampleCount: Int
    /// Fraction of scored intervals spanning exactly one period rather than two. Low occupancy
    /// means the period is likely half the real phrase length — see `bestDyadicFit`.
    let occupancy: Double
}

/// Reconciles the metrical LEVEL of an estimated tempo — the 3:2 and 5:4 family of errors where
/// the beat tracker locks onto a pulse that is a simple ratio away from the one a player counts.
///
/// ## Why this is needed
///
/// `BeatTracker.analyze` keeps a single `bestLag` from one autocorrelation sweep, weighted by a
/// log-normal prior centred on 105 BPM, and never compares that lag against its own ×3/2 or ×5/4
/// relatives. When the prior pulls the winner onto a neighbouring metrical level, every downstream
/// consumer inherits it: bars, the measure grid, chord windows and the rendered chart all cascade.
///
/// ## The signal
///
/// Sung lines in a song with steady phrase structure are spaced by a whole number of BARS, so under
/// the CORRECT tactus the line inter-onset intervals land on a dyadic beat count (4, 8, 16) and
/// under a wrong one they smear onto 5, 6 or 3. Scoring candidate ratios by that dyadic fit is
/// **non-circular**: it reads measured line onsets and measured beat spacing only.
///
/// This matters because the obvious alternative is not. Chord-vs-beat agreement CANNOT be used as
/// evidence for a beat grid: `ChordTimelineDecoder` builds its evidence windows as
/// `[beatTimes[i], beatTimes[i+1])`, so every chord event begins on a beat by construction, and any
/// metric scoring a candidate grid by chord alignment is biased toward the grid that produced the
/// chords.
///
/// ## Measured basis (2026-08-05, six live songs)
///
/// Agrees with the fully independent chord-loop-period verdict on 5 of 6 songs, including both of
/// its confident retunes (101.3 → 152.0 exactly; 112.3 → 84.3 tying 168.5, which were precisely its
/// two candidates). The lone disagreement is the song with 48% outlier lines and a 0.20-beat
/// minimum line duration, whose line onsets cannot carry a tempo verdict at all — and the
/// acceptance gate below correctly makes it decline rather than retune.
///
/// ## Scope
///
/// 2:1 is deliberately NOT a candidate. A loop-period test provably cannot discriminate an octave
/// (a 4-bar loop is 8 bars at half tempo), so offering it would produce confident nonsense.
enum MetricalLevelReconciler {
    /// Candidate ratios of `candidate BPM ÷ current BPM`. Identity first so it is the reference.
    /// No 2:1 or 1:2 — see the type doc.
    static let candidateRatios: [MetricalRatio] = [
        .identity,
        MetricalRatio(3, 2), MetricalRatio(2, 3),
        MetricalRatio(4, 3), MetricalRatio(3, 4),
        MetricalRatio(5, 4), MetricalRatio(4, 5),
    ]

    /// Dyadic beats-per-line candidates. A phrase is 1, 2 or 4 bars of 4.
    static let dyadicPeriods = [4, 8, 16]

    struct Configuration: Equatable, Sendable {
        /// A retune must fit this well in absolute terms.
        var maximumFitError: Double = 0.15
        /// …and must beat the incumbent by this factor. Both gates must pass: absolute quality
        /// alone would retune songs whose lines are simply too broken to judge.
        var improvementFactor: Double = 0.6
        /// Runner-up within this much of the winner counts as a tie, and is reported rather than
        /// silently resolved.
        var ambiguityEpsilon: Double = 0.02
        /// Ignore line intervals outside this range — below is a mis-split, above is a section break.
        var minimumInterval: TimeInterval = 0.2
        var maximumInterval: TimeInterval = 30
        /// A fit must score at least this many intervals, and at least this fraction of them.
        var minimumSamples: Int = 6
        var minimumSampleFraction: Double = 0.5

        init() {}
    }

    struct Verdict: Equatable, Sendable {
        let ratio: MetricalRatio
        /// The reconciled tempo. Equals the input BPM when `ratio` is the identity.
        let bpm: Double
        let fit: BeatsPerLineFit
        /// The incumbent tempo's own fit, for comparison and logging.
        let currentFit: BeatsPerLineFit
        /// True when a different metrical level won and cleared both gates.
        let isRetune: Bool
        /// Another candidate scored within `ambiguityEpsilon`. The winner is still deterministic,
        /// but a caller with an independent signal (the chord-loop period) should arbitrate.
        let ambiguousWith: [MetricalRatio]
    }

    /// Returns the reconciled metrical level, or `nil` when there is not enough evidence to judge.
    ///
    /// - Parameters:
    ///   - bpm: the incumbent tempo.
    ///   - beatTimes: the resolved beat grid; used ONLY for its median spacing, never its phase.
    ///   - lineOnsets: measured lyric line START times. These are real onsets — per-word times
    ///     inside a line are character-proportional interpolation and must not be used here.
    static func reconcile(
        bpm: Double,
        beatTimes: [TimeInterval],
        lineOnsets: [TimeInterval],
        configuration: Configuration = Configuration()
    ) -> Verdict? {
        guard bpm > 0 else { return nil }
        guard let beatLength = medianBeatLength(beatTimes: beatTimes, bpm: bpm) else { return nil }

        let intervals = lineIntervals(lineOnsets, configuration: configuration)
        guard intervals.count >= configuration.minimumSamples else { return nil }

        var scored: [(ratio: MetricalRatio, fit: BeatsPerLineFit)] = []
        for ratio in candidateRatios {
            // A faster candidate tempo means a SHORTER beat.
            let candidateBeatLength = beatLength / ratio.value
            guard candidateBeatLength > 0 else { continue }
            let inBeats = intervals.map { $0 / candidateBeatLength }
            if let fit = bestDyadicFit(intervals: inBeats, configuration: configuration) {
                scored.append((ratio, fit))
            }
        }
        guard let currentFit = scored.first(where: { $0.ratio.isIdentity })?.fit else { return nil }

        // Deterministic ordering: lowest error, then the least disruptive tempo move, then a
        // stable key. Ties are surfaced on the verdict rather than resolved by luck.
        let ranked = scored.sorted {
            if $0.fit.fitError != $1.fit.fitError { return $0.fit.fitError < $1.fit.fitError }
            if $0.ratio.disruption != $1.ratio.disruption {
                return $0.ratio.disruption < $1.ratio.disruption
            }
            return $0.ratio.numerator < $1.ratio.numerator
        }
        guard let winner = ranked.first else { return nil }

        let clearsAbsolute = winner.fit.fitError <= configuration.maximumFitError
        let clearsImprovement =
            winner.fit.fitError <= currentFit.fitError * configuration.improvementFactor
        let isRetune = !winner.ratio.isIdentity && clearsAbsolute && clearsImprovement

        let accepted = isRetune ? winner : (ratio: MetricalRatio.identity, fit: currentFit)
        let acceptedError = accepted.fit.fitError
        let epsilon = configuration.ambiguityEpsilon
        let ambiguous =
            ranked
            .filter { $0.ratio != accepted.ratio }
            .filter { abs($0.fit.fitError - acceptedError) <= epsilon }
            .map(\.ratio)

        return Verdict(
            ratio: accepted.ratio,
            bpm: bpm * accepted.ratio.value,
            fit: accepted.fit,
            currentFit: currentFit,
            isRetune: isRetune,
            ambiguousWith: isRetune ? ambiguous : []
        )
    }

    /// Best dyadic beats-per-line for a set of line intervals already expressed in beats.
    ///
    /// Ranked by median relative error alone, with an exact tie broken toward the LONGER period.
    ///
    /// The tie-break exists because fit error has a divisibility artifact: every interval on an
    /// 8-beat grid is also a clean 2×4, so perfectly regular lines score 0 at both P=4 and P=8 and
    /// the shorter period would win a tie it should lose. On measured input this does not arise:
    /// relative error is normalized by the period, so real jitter costs the shorter period twice as
    /// much and the longer one wins on error alone. (The artifact needs intervals landing EXACTLY
    /// on multiples, which only happens in synthetic input.)
    ///
    /// A weighted occupancy term was tried here and REVERTED: penalizing periods that mostly
    /// explain intervals as 2×P is intuitively right but measurably wrong, because the `multiple
    /// <= 2` cap admits a DIFFERENT set of intervals for each period, so the medians being compared
    /// are not over the same sample. Measured 2026-08-05 against the independent chord-loop
    /// verdicts on six songs: plain relative error agrees 6/6, adding occupancy drops it to 5/6
    /// (it flips the one song whose reconciled tempo the chord-loop pass had pinned exactly), and a
    /// circular-concentration formulation collapses to 2/6 by over-selecting P=16. Do not re-add it.
    static func bestDyadicFit(
        intervals: [Double],
        configuration: Configuration = Configuration()
    ) -> BeatsPerLineFit? {
        var best: BeatsPerLineFit?
        for period in dyadicPeriods {
            let p = Double(period)
            var errors: [Double] = []
            var singlePeriodCount = 0
            for interval in intervals {
                // Allow a line to span one or two periods; anything longer is a section break and
                // says nothing about phrase length.
                let multiple = max(1.0, (interval / p).rounded())
                guard multiple <= 2, interval <= 2.5 * p else { continue }
                if multiple == 1 { singlePeriodCount += 1 }
                errors.append(abs(interval - multiple * p) / p)
            }
            let required = max(
                configuration.minimumSamples,
                Int((configuration.minimumSampleFraction * Double(intervals.count)).rounded(.up)))
            guard errors.count >= required, let error = median(errors) else { continue }
            let candidate = BeatsPerLineFit(
                beatsPerLine: period,
                fitError: error,
                sampleCount: errors.count,
                occupancy: Double(singlePeriodCount) / Double(errors.count))
            guard let incumbent = best else {
                best = candidate
                continue
            }
            let epsilon = 1e-12
            let strictlyBetter = error < incumbent.fitError - epsilon
            let tiedButLonger =
                abs(error - incumbent.fitError) <= epsilon && period > incumbent.beatsPerLine
            if strictlyBetter || tiedButLonger { best = candidate }
        }
        return best
    }

    // MARK: - Helpers

    /// Median spacing of the resolved beats, ignoring implausible jumps. Falls back to the nominal
    /// `60/bpm` when the grid is too short or degenerate.
    static func medianBeatLength(beatTimes: [TimeInterval], bpm: Double) -> TimeInterval? {
        guard bpm > 0 else { return nil }
        let nominal = 60.0 / bpm
        let sorted = beatTimes.sorted()
        guard sorted.count > 8 else { return nominal }
        let diffs = zip(sorted, sorted.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0.1 && $0 < 2.0 }
        guard let m = median(diffs), m > 0 else { return nominal }
        return m
    }

    private static func lineIntervals(
        _ onsets: [TimeInterval],
        configuration: Configuration
    ) -> [TimeInterval] {
        let sorted = onsets.sorted()
        return zip(sorted, sorted.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > configuration.minimumInterval && $0 < configuration.maximumInterval }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
