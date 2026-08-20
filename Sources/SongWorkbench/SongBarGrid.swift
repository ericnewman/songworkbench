import Foundation

/// The song's ONE answer to "which beat is beat 1, and how many beats are in a bar".
///
/// This exists because three components each estimated that independently, from three different
/// signals, and nothing reconciled them:
///
/// - the chord decoder used drum-accent phase and HARD-CODED `beatsPerBar: 4`;
/// - `ChordProDraftBuilder` used chord-onset phase, ungated, with `beatsPerBar` from lyric-line
///   onsets;
/// - the view drew barlines from a drums+bass envelope phase, gated, falling back to 0.
///
/// So a chord could be written into "bar 2, beat 1" of the chart text and drawn two beats away
/// from the barline claiming to be beat 1 — the chord's TIME was right and its reading was wrong.
///
/// `ChordRowRuler` already learned this lesson for the x-axis: its header records that the chart
/// once had four coexisting x-axes in a row and "every spacing bug was one element disagreeing
/// with another about the ruler". This is that same discipline applied to bar phase — estimated
/// once, stored on the document, and read by everyone.
struct SongBarGrid: Codable, Equatable, Sendable {
    /// Which signal decided `barPhase`. Kept so a chart can explain itself, and so a weak estimate
    /// is never mistaken for a measured one.
    enum PhaseSource: String, Codable, Equatable, Sendable {
        /// Drum-stem accent energy cleared the confidence gate. The strongest signal available:
        /// kick and snare land on strong beats regardless of what anything else is doing.
        case drumAccents
        /// No signal cleared the gate, so the grid anchors its first downbeat to the song's first
        /// beat. Not a guess dressed as a measurement — the convention, and on this library the
        /// first chord lands within a fifth of a beat of beat 0 on four songs of five.
        case anchoredToFirstBeat
    }

    var beatsPerBar: Int
    /// Index into the beat grid of the first downbeat.
    var barPhase: Int
    /// Accent-based downbeat confidence, 0...1. Below `minimumPhaseConfidence` the phase is
    /// anchored rather than measured.
    var confidence: Double
    var phaseSource: PhaseSource

    /// Confidence the accent signal must reach before it overrides the anchor. Matches the gate
    /// the decoder and the view already used independently.
    static let minimumPhaseConfidence = 0.08

    /// The grid to use when nothing has been estimated yet.
    static let unknown = SongBarGrid(
        beatsPerBar: 4, barPhase: 0, confidence: 0, phaseSource: .anchoredToFirstBeat)

    /// This grid re-expressed on a beat grid retuned by `ratio` (old beat index i ↔ new index
    /// i × ratio, see `MetricalLevelReconciler.reconciledBeatTimes`). Bar DURATION is what a
    /// retune preserves — the same physical downbeats, counted at a different level — so both
    /// `beatsPerBar` and `barPhase` scale with the grid. When either lands between beats of the
    /// new grid the measured phase is not representable there; the result then anchors to beat 0
    /// honestly (confidence 0) rather than rounding to a nearby beat and calling it measured.
    func retuned(by ratio: MetricalRatio) -> SongBarGrid {
        guard !ratio.isIdentity else { return self }
        let scaledBeats = beatsPerBar * ratio.numerator
        let scaledPhase = barPhase * ratio.numerator
        guard scaledBeats % ratio.denominator == 0, scaledPhase % ratio.denominator == 0,
            scaledBeats / ratio.denominator >= 1
        else {
            return SongBarGrid(
                beatsPerBar: max(
                    1, Int((Double(beatsPerBar) * ratio.value).rounded())),
                barPhase: 0, confidence: 0, phaseSource: .anchoredToFirstBeat)
        }
        return SongBarGrid(
            beatsPerBar: scaledBeats / ratio.denominator,
            barPhase: scaledPhase / ratio.denominator,
            confidence: confidence,
            phaseSource: phaseSource)
    }
}

/// Estimates the one `SongBarGrid` for a song.
///
/// The policy is the best-evidenced of the three it replaces — the view's, which carries a written
/// record of why: strong accent evidence wins when it clears the gate, and otherwise the phase
/// anchors to beat 0 rather than trusting a weak signal. Chord onsets are deliberately NOT used
/// for phase, even though `ChordProDraftBuilder` used to: the view's own analysis measured chord
/// onsets concentrating on a phase only 1.15x-1.37x above chance, which is why it rejected that
/// signal — while the builder used it anyway, ungated.
enum SongBarGridEstimator {
    /// - Parameters:
    ///   - beatStrengths: per-beat accent energy (drums), or empty when no drum stem exists.
    ///   - lyricLineOnsets: sung-line starts, the signal `estimateBeatsPerBar` reads. Beats per bar
    ///     stays 4 unless this shows a clear non-4/4 phrasing.
    static func estimate(
        beatTimes: [TimeInterval],
        beatStrengths: [Double],
        lyricLineOnsets: [TimeInterval]
    ) -> SongBarGrid {
        let beatsPerBar =
            beatTimes.isEmpty
            ? 4
            : DownbeatEstimator.estimateBeatsPerBar(
                beatTimes: beatTimes, onsets: lyricLineOnsets)

        guard !beatStrengths.isEmpty else {
            return SongBarGrid(
                beatsPerBar: beatsPerBar, barPhase: 0, confidence: 0,
                phaseSource: .anchoredToFirstBeat)
        }
        let confidence = DownbeatEstimator.downbeatConfidence(
            beatStrengths: beatStrengths, beatsPerBar: beatsPerBar)
        guard confidence >= SongBarGrid.minimumPhaseConfidence else {
            return SongBarGrid(
                beatsPerBar: beatsPerBar, barPhase: 0, confidence: confidence,
                phaseSource: .anchoredToFirstBeat)
        }
        return SongBarGrid(
            beatsPerBar: beatsPerBar,
            barPhase: DownbeatEstimator.barPhase(
                beatStrengths: beatStrengths, beatsPerBar: beatsPerBar),
            confidence: confidence,
            phaseSource: .drumAccents
        )
    }
}
