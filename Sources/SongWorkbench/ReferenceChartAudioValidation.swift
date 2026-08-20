import Foundation

/// Judges an uploaded reference chart against the RECORDING, not against the generated chart.
///
/// `ReferenceChartComparator` answers "do these two charts agree?" — useful, but it cannot say
/// which one is right, and on a song where our detector is weak it reports the reference as wrong
/// precisely where the reference is correct. This asks the only question that settles it: for each
/// chord in the uploaded chart, is there an instrument attack or a harmonic change in the audio
/// where it claims one?
///
/// Both charts are scored the same way, so the summary can say which one the recording supports.
/// That is the mechanism behind "the uploaded file might actually be more accurate than the
/// generated one" — it becomes a measurement rather than a judgement call.
enum ReferenceChartAudioValidation {
    struct ChordFinding: Equatable, Sendable, Identifiable {
        var id: String { "\(time)-\(chord)" }
        let time: TimeInterval
        let chord: String
        let evidence: ChordMarkerEvidence
        /// What the frames say about this chord's THIRD. `nil` when no frame evidence was kept.
        let quality: ChordQualityAudit.Verdict?

        /// Whether the recording contradicts this chord's placement outright.
        var isUnsupported: Bool { evidence == .unsupported }

        /// Whether the frames heard the opposite third — the uploaded chart says major where the
        /// recording says minor, or the reverse.
        var hasWrongQuality: Bool {
            if case .corrected = quality { return true }
            return false
        }

        /// What the audio says this chord should be, when it disagrees.
        var suggestedChord: String? {
            if case .corrected(_, let to) = quality { return to }
            return nil
        }
    }

    /// How well one chart's chord placements are borne out by the audio.
    struct ChartScore: Equatable, Sendable {
        let chordCount: Int
        let supportedCount: Int
        /// Chords whose third the frames positively confirmed.
        let qualityConfirmedCount: Int
        /// Chords whose third the frames contradicted.
        let qualityContradictedCount: Int

        /// Share of this chart's chords the audio supports, 0...1. `nil` when the chart has no
        /// chords to score.
        var supportedShare: Double? {
            guard chordCount > 0 else { return nil }
            return Double(supportedCount) / Double(chordCount)
        }

        /// Share of the chords with a decisive third that the audio agrees with. `nil` when no
        /// chord had decisive frame evidence — most often because none was kept.
        var qualityAgreementShare: Double? {
            let decisive = qualityConfirmedCount + qualityContradictedCount
            guard decisive > 0 else { return nil }
            return Double(qualityConfirmedCount) / Double(decisive)
        }
    }

    enum Verdict: String, Equatable, Sendable {
        /// The audio supports the uploaded chart meaningfully better.
        case referenceBetter
        /// The audio supports the generated chart meaningfully better.
        case generatedBetter
        /// Neither is clearly better supported.
        case comparable
        /// Not enough evidence to say — no onsets or change-points were kept for this song, or
        /// too few reference chords could be timed.
        case inconclusive
    }

    struct Result: Equatable, Sendable {
        let findings: [ChordFinding]
        let reference: ChartScore
        let generated: ChartScore
        let verdict: Verdict
        /// Reference chords that matched no transcribed line and so could not be judged.
        let untimedChordCount: Int

        var unsupportedFindings: [ChordFinding] { findings.filter(\.isUnsupported) }
        /// Uploaded chords whose third the recording contradicts.
        var wrongQualityFindings: [ChordFinding] { findings.filter(\.hasWrongQuality) }
    }

    /// Difference in supported share below which the two charts are called comparable. Well above
    /// the noise a handful of chords creates, so a one-chord edge is never reported as a winner.
    static let decisiveMargin = 0.10
    /// Fewest reference chords that must be timable before a verdict is offered at all.
    static let minimumScorableChords = 8

    /// Score both charts against the same evidence.
    ///
    /// `attackOnsets` and `changePoints` come from the harmony stage (persisted on the document).
    /// A `nil` `changePoints` means the evidence predates that field — it is passed straight
    /// through to `ChordEvidenceAudit`, which falls back accordingly rather than treating absent
    /// evidence as absence of harmony.
    static func validate(
        referenceEvents: [EditableChordEvent],
        untimedChordCount: Int,
        generatedEvents: [EditableChordEvent],
        frameObservations: [ChordObservation],
        attackOnsets: [TimeInterval],
        changePoints: [TimeInterval]?
    ) -> Result {
        let referenceAudit = ChordEvidenceAudit.audit(
            events: referenceEvents,
            frameObservations: frameObservations,
            attackOnsets: attackOnsets,
            changePoints: changePoints
        )
        let generatedAudit = ChordEvidenceAudit.audit(
            events: generatedEvents,
            frameObservations: frameObservations,
            attackOnsets: attackOnsets,
            changePoints: changePoints
        )
        // Quality is a separate question from placement: a chord can land exactly on the attack
        // and still name the wrong third. Both charts are asked both questions.
        let referenceQuality = ChordQualityAudit.audit(
            events: referenceEvents, frameObservations: frameObservations)
        let generatedQuality = ChordQualityAudit.audit(
            events: generatedEvents, frameObservations: frameObservations)

        let qualityByIndex = Dictionary(
            referenceQuality.findings.map { ($0.index, $0.verdict) },
            uniquingKeysWith: { first, _ in first })
        let findings = referenceAudit.verdicts.map {
            ChordFinding(
                time: $0.time,
                chord: $0.chord,
                evidence: $0.evidence,
                quality: qualityByIndex[$0.index]
            )
        }
        let reference = score(referenceAudit, quality: referenceQuality)
        let generated = score(generatedAudit, quality: generatedQuality)

        return Result(
            findings: findings,
            reference: reference,
            generated: generated,
            verdict: verdict(
                reference: reference,
                generated: generated,
                evidenceUsable: !attackOnsets.isEmpty || (changePoints?.isEmpty == false)
            ),
            untimedChordCount: untimedChordCount
        )
    }

    private static func score(
        _ audit: ChordEvidenceAudit.Result, quality: ChordQualityAudit.Result
    ) -> ChartScore {
        ChartScore(
            chordCount: audit.verdicts.count,
            supportedCount: audit.verdicts.filter { $0.evidence != .unsupported }.count,
            qualityConfirmedCount: quality.findings.filter { $0.verdict == .confirmed }.count,
            qualityContradictedCount: quality.correctedCount
        )
    }

    private static func verdict(
        reference: ChartScore,
        generated: ChartScore,
        evidenceUsable: Bool
    ) -> Verdict {
        guard evidenceUsable,
            reference.chordCount >= minimumScorableChords,
            generated.chordCount >= minimumScorableChords,
            let referenceShare = reference.supportedShare,
            let generatedShare = generated.supportedShare
        else { return .inconclusive }
        let delta = referenceShare - generatedShare
        if delta > decisiveMargin { return .referenceBetter }
        if delta < -decisiveMargin { return .generatedBetter }
        return .comparable
    }

    /// A sentence for the comparison report, or `nil` when there is nothing to say.
    static func summary(for result: Result) -> String? {
        guard result.verdict != .inconclusive else {
            return "Not enough audio evidence kept for this song to judge the uploaded chart — "
                + "re-analyse it to record onsets and harmonic change-points."
        }
        let referencePercent = Int(((result.reference.supportedShare ?? 0) * 100).rounded())
        let generatedPercent = Int(((result.generated.supportedShare ?? 0) * 100).rounded())
        let base =
            "The audio supports \(referencePercent)% of the uploaded chart's chords and "
            + "\(generatedPercent)% of the generated chart's."
        var sentences = [base]
        // Quality is reported alongside placement rather than folded into it: "the chord is in
        // the right place but named wrong" and "there is no chord here at all" are different
        // problems with different fixes.
        if let referenceQuality = result.reference.qualityAgreementShare,
            let generatedQuality = result.generated.qualityAgreementShare
        {
            sentences.append(
                "On chord quality, the audio agrees with "
                    + "\(Int((referenceQuality * 100).rounded()))% of the uploaded chart's thirds "
                    + "and \(Int((generatedQuality * 100).rounded()))% of the generated chart's.")
        }
        switch result.verdict {
        case .referenceBetter:
            sentences.append("The uploaded chart matches the recording better.")
        case .generatedBetter:
            sentences.append("The generated chart matches the recording better.")
        case .comparable:
            sentences.append("Neither is clearly better supported.")
        case .inconclusive:
            break
        }
        return sentences.joined(separator: " ")
    }
}
