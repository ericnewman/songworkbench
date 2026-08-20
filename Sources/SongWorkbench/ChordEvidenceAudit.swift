import Foundation

/// What kind of audio evidence supports a chord marker's PLACEMENT (not its identity).
///
/// The distinction is the whole point: a chord detector reports the *active harmony* at every
/// point in the song, but a chart marker is a claim that a chordal instrument **attacked** there.
/// A window can win the Viterbi decode — and so emit an event — with nothing struck under it at
/// all, which is how a chart grows markers the player never hears. This classifies each surviving
/// event by the evidence that actually exists for it.
enum ChordMarkerEvidence: String, Codable, Equatable, Sendable {
    /// An amplitude transient in an allowed instrument stem AND a stable pitch-content change.
    /// The strongest support a marker can have.
    case attackAndHarmonic
    /// A transient with no accompanying harmonic change — a re-strum or pick noise inside the
    /// chord that was already ringing, not a change.
    case attack
    /// A stable pitch-content change with no transient — a swelling pad, a fingerpicked voicing
    /// change, a keyboard held through a chord change. Real, but quiet.
    case harmonic
    /// Neither. Nothing in the audio says a chord landed here.
    case unsupported
}

/// Maps every chord event to the audio evidence that authorizes it, and drops the ones nothing
/// supports — the "final one-to-one audit" run inside the pipeline rather than left to the reader
/// of the finished chart.
///
/// Evidence comes from two sources already computed by the harmony stage, so this adds no audio
/// pass:
/// - **attacks**: `InstrumentOnsetDetector` onsets on the guitar/other/accompaniment stem. These
///   are the same onsets `ChordOnsetAligner` snaps to, so a snapped event sits exactly on one.
/// - **harmonic change**: `SongAudioAnalysis.harmonicChangePoints` — chroma cosine-distance
///   change-points from `ChromaChangePointDetector`, measured on the pitch content itself rather
///   than inferred from label flips.
///
/// When change-points are unavailable (an analysis cached before they were computed) the audit
/// falls back to the frame-level `ChordObservation` labels: a label that changes and then *holds*
/// stands in for a change-point, a label that flickers for a frame or two is treated as a passing
/// tone. The fallback is measurably coarser — a label flip needs the classifier's winner to change,
/// so a real move between two chords that share two notes can pass with no flip at all — which is
/// why it exists only for old cache entries, and why `Verdict.harmonicSource` records which one
/// decided each marker.
enum ChordEvidenceAudit {
    /// Which evidence decided the harmonic half of a verdict.
    enum HarmonicSource: String, Equatable, Sendable {
        /// A chroma change-point from `ChromaChangePointDetector`. The real measurement.
        case changePoint
        /// Frame-label change with a stability check — the fallback for analyses cached before
        /// change-points were computed.
        case frameLabels
    }

    struct Verdict: Equatable, Sendable {
        let index: Int
        let time: TimeInterval
        let chord: String
        let evidence: ChordMarkerEvidence
        /// Signed seconds from the event to the nearest attack onset, or `nil` when no onset
        /// exists at all. Positive means the attack is LATER than the marker.
        let nearestAttackDelta: TimeInterval?
        /// Which evidence answered "did the harmony change here?" for this marker.
        let harmonicSource: HarmonicSource
        /// Signed seconds from the event to the nearest chroma change-point, or `nil` when
        /// change-points were unavailable. Positive means the change is LATER than the marker.
        let nearestChangePointDelta: TimeInterval?
    }

    struct Result: Equatable, Sendable {
        let verdicts: [Verdict]
        /// Fraction of events with `.unsupported` evidence.
        let unsupportedFraction: Double
        /// Whether the evidence itself is trustworthy enough to act on. `false` when so many
        /// events lack support that the *stem* is the likely problem (bleed, a lost quiet guitar,
        /// a fingerpicked part with no discrete attacks) rather than the events. Nothing is
        /// dropped in that case — deleting most of a section's chords is a worse failure than
        /// leaving a few unsupported ones in.
        let evidenceTrusted: Bool

        var unsupportedCount: Int { verdicts.filter { $0.evidence == .unsupported }.count }
    }

    /// Above this share of unsupported events, blame the evidence rather than the events.
    /// ponytail: one flat threshold, whole-song. Per-section thresholds if a fingerpicked bridge
    /// inside an otherwise-strummed song turns out to need them.
    static let untrustedUnsupportedFraction = 0.5

    /// Classify each event. Pure, deterministic, no I/O. Order and count of `verdicts` match
    /// `events`. With no onsets and no observations every event is `.unsupported`, which trips
    /// `evidenceTrusted` to `false` — absent evidence is never read as evidence of absence.
    static func audit(
        events: [EditableChordEvent],
        frameObservations: [ChordObservation],
        attackOnsets: [TimeInterval],
        changePoints: [TimeInterval]? = nil,
        attackTolerance: TimeInterval = 0.35,
        changePointTolerance: TimeInterval = 0.35,
        stabilityWindow: TimeInterval = 0.4,
        minimumStableShare: Double = 0.6
    ) -> Result {
        guard !events.isEmpty else {
            return Result(verdicts: [], unsupportedFraction: 0, evidenceTrusted: false)
        }
        let sortedOnsets = attackOnsets.sorted()
        let sortedFrames = frameObservations.sorted { $0.timestamp < $1.timestamp }
        // An EMPTY change-point array is a real measurement ("this stem's chroma never moves
        // sharply enough"), not a missing one — only `nil` means unavailable. Falling back on an
        // empty array would silently re-enable the coarse path for songs the detector genuinely
        // found nothing in.
        let sortedChangePoints = changePoints?.sorted()
        let harmonicSource: HarmonicSource =
            sortedChangePoints == nil ? .frameLabels : .changePoint

        var verdicts: [Verdict] = []
        verdicts.reserveCapacity(events.count)
        for (index, event) in events.enumerated() {
            let time = event.time
            let delta = nearestDelta(to: time, in: sortedOnsets)
            let hasAttack = delta.map { abs($0) <= attackTolerance } ?? false

            let changeDelta = sortedChangePoints.flatMap { nearestDelta(to: time, in: $0) }
            let hasHarmonic: Bool
            if sortedChangePoints != nil {
                hasHarmonic = changeDelta.map { abs($0) <= changePointTolerance } ?? false
            } else {
                hasHarmonic = harmonicChangeHolds(
                    at: time,
                    frames: sortedFrames,
                    window: stabilityWindow,
                    minimumStableShare: minimumStableShare
                )
            }

            let evidence: ChordMarkerEvidence
            switch (hasAttack, hasHarmonic) {
            case (true, true): evidence = .attackAndHarmonic
            case (true, false): evidence = .attack
            case (false, true): evidence = .harmonic
            case (false, false): evidence = .unsupported
            }
            verdicts.append(
                Verdict(
                    index: index,
                    time: time,
                    chord: event.chord,
                    evidence: evidence,
                    nearestAttackDelta: delta,
                    harmonicSource: harmonicSource,
                    nearestChangePointDelta: changeDelta
                ))
        }

        let unsupported = verdicts.filter { $0.evidence == .unsupported }.count
        let fraction = Double(unsupported) / Double(verdicts.count)
        return Result(
            verdicts: verdicts,
            unsupportedFraction: fraction,
            evidenceTrusted: fraction <= untrustedUnsupportedFraction
        )
    }

    /// The events worth writing to a chart, plus the audit that decided it.
    ///
    /// Drops `.unsupported` events when the evidence is trustworthy. The first event always
    /// survives regardless — a chart needs a chord to open on, and the song's opening attack is
    /// routinely before the first decoded window.
    ///
    /// `.attack`-only events are KEPT, not dropped: a transient with no harmonic change is a
    /// re-strum of the ringing chord, but this audit runs after the decoder has already deduped
    /// repeated labels, so what reaches here is a genuine label change whose harmonic evidence is
    /// merely weaker than its transient. Dropping those cost real changes in testing.
    static func filtered(
        events: [EditableChordEvent],
        frameObservations: [ChordObservation],
        attackOnsets: [TimeInterval],
        changePoints: [TimeInterval]? = nil,
        attackTolerance: TimeInterval = 0.35,
        changePointTolerance: TimeInterval = 0.35,
        stabilityWindow: TimeInterval = 0.4,
        minimumStableShare: Double = 0.6
    ) -> (events: [EditableChordEvent], audit: Result) {
        let result = audit(
            events: events,
            frameObservations: frameObservations,
            attackOnsets: attackOnsets,
            changePoints: changePoints,
            attackTolerance: attackTolerance,
            changePointTolerance: changePointTolerance,
            stabilityWindow: stabilityWindow,
            minimumStableShare: minimumStableShare
        )
        guard result.evidenceTrusted else { return (events, result) }
        let kept = events.enumerated().filter { index, _ in
            index == 0 || result.verdicts[index].evidence != .unsupported
        }.map(\.element)
        return (kept, result)
    }

    /// A user-facing sentence when the audit found something worth knowing, `nil` when the chart
    /// is clean. Two findings are worth reporting: evidence too weak to act on (nothing was
    /// filtered, so the chart still carries whatever the decoder produced), and a filter pass that
    /// removed a non-trivial share of the markers.
    static func warning(for result: Result) -> String? {
        guard !result.verdicts.isEmpty else { return nil }
        let percent = Int((result.unsupportedFraction * 100).rounded())
        if !result.evidenceTrusted {
            return """
                \(percent)% of chord markers have no instrument attack or harmonic change under \
                them, so none were filtered — the chord timing is unverified. Likely a stem \
                problem (bleed, or a quiet part with no discrete attacks) rather than \(result
                    .unsupportedCount) genuinely wrong chords.
                """
        }
        guard result.unsupportedCount > 0 else { return nil }
        return
            "Removed \(result.unsupportedCount) chord marker(s) (\(percent)%) with no instrument "
            + "attack or harmonic change in the audio."
    }

    /// Whether the frame-level chord label at `time` differs from the label just before it AND the
    /// new label holds for at least `minimumStableShare` of the following `window`. The stability
    /// requirement is what separates a chord change from a bend, a slide, or a lead line passing
    /// through: both move the chroma, only one of them stays moved.
    private static func harmonicChangeHolds(
        at time: TimeInterval,
        frames: [ChordObservation],
        window: TimeInterval,
        minimumStableShare: Double
    ) -> Bool {
        guard !frames.isEmpty, window > 0 else { return false }
        let after = frames.filter { $0.timestamp >= time && $0.timestamp < time + window }
        let before = frames.filter { $0.timestamp >= time - window && $0.timestamp < time }
        guard !after.isEmpty, !before.isEmpty else { return false }

        guard let (afterLabel, afterCount) = modalLabel(after) else { return false }
        guard let (beforeLabel, _) = modalLabel(before) else { return false }
        guard afterLabel != beforeLabel else { return false }
        return Double(afterCount) / Double(after.count) >= minimumStableShare
    }

    private static func modalLabel(_ observations: [ChordObservation]) -> (String, Int)? {
        let counts = observations.reduce(into: [String: Int]()) { counts, observation in
            counts[observation.chord.displayName, default: 0] += 1
        }
        guard let winner = counts.max(by: { $0.value < $1.value }) else { return nil }
        return (winner.key, winner.value)
    }

    /// Signed distance from `time` to the nearest value (nearest − time), or `nil` when empty.
    private static func nearestDelta(
        to time: TimeInterval, in sortedValues: [TimeInterval]
    ) -> TimeInterval? {
        guard !sortedValues.isEmpty else { return nil }
        var low = 0
        var high = sortedValues.count - 1
        if time <= sortedValues[low] { return sortedValues[low] - time }
        if time >= sortedValues[high] { return sortedValues[high] - time }
        while low <= high {
            let mid = (low + high) / 2
            let value = sortedValues[mid]
            if value == time { return 0 }
            if value < time { low = mid + 1 } else { high = mid - 1 }
        }
        let below = sortedValues[high]
        let above = sortedValues[low]
        return (time - below) <= (above - time) ? below - time : above - time
    }
}
