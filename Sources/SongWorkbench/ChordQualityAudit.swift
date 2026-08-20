import Foundation

/// Checks a chord marker's QUALITY — major vs minor — against the pitch content the frame-level
/// classifier actually heard, and reverts the decoder when a key prior overrode it.
///
/// This exists because of one specific, recurring, documented failure: `Dm` corrected to `D`
/// because `D` is diatonic. `KeyPriorChordRescorer` implements exactly that reasoning — in a major
/// key the parallel-minor tonic is deliberately scored `chromaticWeight` (0.5) on the theory that
/// "minor-vs-major third is one chroma bin, so `im` is overwhelmingly a misread." That is true
/// often enough to be useful and wrong often enough to be a bug: it discounts the one chord most
/// likely to be a genuine borrowed chord, and the discount is applied to *every* frame of it, so a
/// sustained, unambiguous minor chord can still lose its windows.
///
/// The audit is the counterweight. `SongAudioAnalysis.chords` are classified by `ChordClassifier`
/// straight from chroma template matching, with **no key prior applied** — the prior enters later,
/// inside `ChordTimelineDecoder`. So the frame labels are independent evidence about the third, and
/// where they decisively disagree with the decoded label they win. That is the doc's rule stated as
/// code: go to the stem and find the third; do not consult the key signature.
///
/// Only major↔minor is arbitrated. Root and extensions are left alone — the root is settled by the
/// bass refiner, and an extension the chroma cannot support is a separate problem.
enum ChordQualityAudit {
    enum Verdict: Equatable, Sendable {
        /// Frame evidence agrees with the decoded quality.
        case confirmed
        /// Frame evidence decisively contradicts it; the label was rewritten.
        case corrected(from: String, to: String)
        /// The frames split between major and minor of this root — the voicing has no clear
        /// third (a power chord, or a voicing that omits it). Left untouched and flagged: the
        /// honest answer is "uncertain", not whichever side edged the count.
        case ambiguousThird
        /// No frame evidence for this event's root in its span. Nothing to arbitrate.
        case noEvidence
    }

    struct Finding: Equatable, Sendable {
        let index: Int
        let time: TimeInterval
        let chord: String
        let verdict: Verdict
    }

    struct Result: Equatable, Sendable {
        let findings: [Finding]

        var correctedCount: Int {
            findings.filter {
                if case .corrected = $0.verdict { return true } else { return false }
            }
            .count
        }
        var ambiguousCount: Int {
            findings.filter { $0.verdict == .ambiguousThird }.count
        }
        /// Events whose quality the frames positively confirmed. These carry direct pitch
        /// evidence, so a later repeated-section vote must not overwrite them.
        var confirmedEventIndices: Set<Int> {
            Set(findings.filter { $0.verdict == .confirmed }.map(\.index))
        }
    }

    /// Confidence-weighted share the winning quality must hold before the audit will act. Below
    /// this the third is treated as absent rather than as a weak vote for one side.
    static let decisiveShare = 0.65

    /// Frames below this confidence are not evidence about anything.
    ///
    /// `ChordClassifier.bestMatch` initialises its answer to C MAJOR and only replaces it on a
    /// strictly-better score, so a silent or degenerate frame — every rest, every fade, every
    /// gap between phrases — comes back as `C` at confidence 0. Counting those was letting a
    /// `Cm` held over a quiet passage be rewritten to `C`: phantom frames, root matches, all
    /// voting "major", share 1.0. That is the exact `Dm`->`D` failure this audit exists to
    /// prevent, arriving through the back door.
    ///
    /// 0.55, not the 0.45 `MusicalKeyEstimator` uses — because 0.45 does not actually exclude
    /// anything. `ChordClassifier.confidence` is a raw cosine similarity against a root-weighted
    /// template, and a FLAT chroma (pure noise, cymbals, separation hash) scores 0.4867 against
    /// every major triad and 0.5632 against maj7. A 0.45 bar therefore admits noise as evidence;
    /// measured, not assumed — see the arithmetic in this constant's tests.
    ///
    /// 0.55 sits above the flat-chroma triad score with a little margin. It is still below any
    /// real chord observation, whose usable range runs to ~0.97 for a clean triad.
    static let minimumUsableFrameConfidence: Float = 0.55

    /// Fewest usable frames in an event's span before its quality may be rewritten.
    ///
    /// Without this, one frame could flip a chord: a short event spans 1-2 frames at the ~93 ms
    /// analysis hop, and a single matching-root frame gives share 1.0. That frame would then also
    /// mark the event `confirmed`, locking the flip against the repeated-section vote — the one
    /// mechanism that could have corrected it.
    static let minimumUsableFrameCount = 3

    /// Audit every event's quality against the frames inside its own span.
    ///
    /// Each event's span runs to the next event (or `sourceDuration`). Only frames whose ROOT
    /// matches the event's root are counted — a frame that heard a different chord entirely says
    /// nothing about this chord's third.
    static func audit(
        events: [EditableChordEvent],
        frameObservations: [ChordObservation],
        sourceDuration: TimeInterval? = nil
    ) -> Result {
        guard !events.isEmpty, !frameObservations.isEmpty else {
            return Result(findings: [])
        }
        let frames = frameObservations.sorted { $0.timestamp < $1.timestamp }

        var findings: [Finding] = []
        findings.reserveCapacity(events.count)
        for (index, event) in events.enumerated() {
            guard let parsed = parse(event.chord), parsed.quality.isTriadicallyArbitrable else {
                findings.append(
                    Finding(
                        index: index, time: event.time, chord: event.chord, verdict: .noEvidence)
                )
                continue
            }
            let end: TimeInterval
            if index + 1 < events.count {
                end = events[index + 1].time
            } else if let sourceDuration, sourceDuration > event.time {
                end = sourceDuration
            } else {
                end = .infinity
            }

            var majorWeight = 0.0
            var minorWeight = 0.0
            var usableFrames = 0
            for frame in frames
            where frame.timestamp >= event.time && frame.timestamp < end
                && frame.chord.root == parsed.root
                && frame.confidence >= minimumUsableFrameConfidence
            {
                usableFrames += 1
                let weight = Double(frame.confidence)
                if frame.chord.quality.isMinorish {
                    minorWeight += weight
                } else if frame.chord.quality.isMajorish {
                    majorWeight += weight
                }
            }

            let total = majorWeight + minorWeight
            guard total > 0, usableFrames >= minimumUsableFrameCount else {
                findings.append(
                    Finding(
                        index: index, time: event.time, chord: event.chord, verdict: .noEvidence)
                )
                continue
            }
            let heardMinor = minorWeight > majorWeight
            let share = max(majorWeight, minorWeight) / total
            guard share >= decisiveShare else {
                findings.append(
                    Finding(
                        index: index, time: event.time, chord: event.chord,
                        verdict: .ambiguousThird))
                continue
            }
            if heardMinor == parsed.quality.isMinorish {
                findings.append(
                    Finding(index: index, time: event.time, chord: event.chord, verdict: .confirmed)
                )
            } else {
                let corrected = rename(event.chord, toMinor: heardMinor)
                findings.append(
                    Finding(
                        index: index, time: event.time, chord: event.chord,
                        verdict: .corrected(from: event.chord, to: corrected)))
            }
        }
        return Result(findings: findings)
    }

    /// Events with contradicted qualities rewritten, plus the audit that decided it. Count, order,
    /// and timing are untouched — this only ever changes a label's major/minor.
    static func corrected(
        events: [EditableChordEvent],
        frameObservations: [ChordObservation],
        sourceDuration: TimeInterval? = nil
    ) -> (events: [EditableChordEvent], audit: Result) {
        let result = audit(
            events: events,
            frameObservations: frameObservations,
            sourceDuration: sourceDuration
        )
        var corrected = events
        for finding in result.findings {
            if case .corrected(_, let to) = finding.verdict {
                corrected[finding.index].chord = to
            }
        }
        return (corrected, result)
    }

    /// A user-facing sentence, or `nil` when nothing needed saying.
    static func warning(for result: Result) -> String? {
        var parts: [String] = []
        if result.correctedCount > 0 {
            parts.append(
                "corrected \(result.correctedCount) chord quality(ies) the key prior had "
                    + "overridden")
        }
        if result.ambiguousCount > 0 {
            parts.append(
                "\(result.ambiguousCount) chord(s) have no clear third in the audio (possible "
                    + "power chords)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + "."
    }

    // MARK: - Chord names

    private static let rootNames = [
        "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B",
    ]

    /// Inverse of `Chord.displayName`. Returns `nil` for anything that name never produces, so a
    /// hand-edited or otherwise unrecognized label is left strictly alone.
    static func parse(_ name: String) -> (root: PitchClass, quality: ChordQuality)? {
        let suffixes: [(String, ChordQuality)] = [
            ("maj7", .major7), ("m7", .minor7), ("7", .dominant7), ("m", .minor), ("", .major),
        ]
        for (suffix, quality) in suffixes {
            guard name.hasSuffix(suffix) else { continue }
            let rootName = String(name.dropLast(suffix.count))
            guard let index = rootNames.firstIndex(of: rootName),
                let root = PitchClass(rawValue: index)
            else { continue }
            return (root, quality)
        }
        return nil
    }

    /// Swap a label's third while preserving its root and seventh: `D` ↔ `Dm`, `D7` ↔ `Dm7`.
    private static func rename(_ name: String, toMinor: Bool) -> String {
        guard let parsed = parse(name) else { return name }
        let quality: ChordQuality
        switch parsed.quality {
        case .major, .minor: quality = toMinor ? .minor : .major
        case .major7, .minor7: quality = toMinor ? .minor7 : .major7
        case .dominant7: quality = toMinor ? .minor7 : .dominant7
        }
        return Chord(root: parsed.root, quality: quality).displayName
    }
}

extension ChordQuality {
    var isMinorish: Bool { self == .minor || self == .minor7 }
    /// Dominant sevenths have a major third, so they count as major evidence about the third.
    var isMajorish: Bool { self == .major || self == .major7 || self == .dominant7 }
    /// Whether major↔minor is a meaningful question for this quality. Every quality in the
    /// vocabulary has a third today; the property exists so a future added quality (sus, 5) is
    /// excluded by default rather than silently arbitrated.
    var isTriadicallyArbitrable: Bool { isMinorish || isMajorish }
}
