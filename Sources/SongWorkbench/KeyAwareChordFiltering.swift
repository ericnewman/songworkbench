import Foundation

/// Scales frame-level chord observation confidences by a harmonic prior derived from the
/// estimated musical key, BEFORE beat-window voting. Diatonic chords keep their evidence,
/// common borrowed chords are mildly discounted, and chromatic (out-of-key) labels are
/// strongly discounted so that transient chroma noise stops winning beat windows.
///
/// This is a prior, not a gate: a chromatic chord with strong, sustained chroma evidence
/// still wins its windows (e.g. a real modulation or secondary dominant passage).
struct KeyPriorChordRescorer: Sendable {
    let key: MusicalKey
    /// Multiplier for chords diatonic to the key.
    var diatonicWeight: Float = 1.0
    /// Multiplier for common borrowed/modal-mixture chords (iv, bVII, bVI, bIII, II in major;
    /// V, IV, I picardy in minor). Tuned offline on the reference song's cached frames.
    var borrowedWeight: Float = 0.75
    /// Multiplier for everything else. Tuned offline: 0.7 left window winners unchanged too
    /// often (non-diatonic rate barely moved); 0.5 lets sustained genuine evidence win while
    /// noise frames lose the vote.
    var chromaticWeight: Float = 0.5

    func rescore(_ observations: [ChordObservation]) -> [ChordObservation] {
        observations.map { observation in
            ChordObservation(
                timestamp: observation.timestamp,
                chord: observation.chord,
                confidence: observation.confidence * weight(for: observation.chord)
            )
        }
    }

    func weight(for chord: Chord) -> Float {
        let interval = (chord.root.rawValue - key.root.rawValue + 12) % 12
        switch membership(interval: interval, quality: chord.quality) {
        case .diatonic: return diatonicWeight
        case .borrowed: return borrowedWeight
        case .chromatic: return chromaticWeight
        }
    }

    private enum Membership {
        case diatonic
        case borrowed
        case chromatic
    }

    private func membership(interval: Int, quality: ChordQuality) -> Membership {
        let isMinorish = quality == .minor || quality == .minor7
        let isMajorish = quality == .major || quality == .major7
        let isDominant = quality == .dominant7
        switch key.quality {
        case .minor, .minor7:
            // Natural-minor diatonic triads: i, iv, v, bIII, bVI, bVII.
            switch interval {
            case 0 where isMinorish, 5 where isMinorish, 7 where isMinorish:
                return .diatonic
            case 3 where isMajorish, 8 where isMajorish, 10 where isMajorish || isDominant:
                return .diatonic
            // Harmonic-minor V/V7, dorian IV, picardy I.
            case 7 where isMajorish || isDominant, 5 where isMajorish, 0 where isMajorish:
                return .borrowed
            default:
                return .chromatic
            }
        case .major, .major7, .dominant7:
            // Major-key diatonic: I, IV, V(7), ii, iii, vi.
            switch interval {
            case 0 where isMajorish, 5 where isMajorish, 7 where isMajorish || isDominant:
                return .diatonic
            case 2 where isMinorish, 4 where isMinorish, 9 where isMinorish:
                return .diatonic
            // Common mixture/secondary: iv, bVII, bVI, bIII, II (V/V). The parallel minor
            // of the tonic is intentionally NOT here: minor-vs-major third is one chroma
            // bin, so "im" is overwhelmingly a misread of the tonic major, not mixture.
            case 5 where isMinorish, 10 where isMajorish || isDominant, 8 where isMajorish:
                return .borrowed
            case 3 where isMajorish, 2 where isMajorish || isDominant:
                return .borrowed
            default:
                return .chromatic
            }
        }
    }
}

/// Removes chord events whose implied duration (time until the next event) is shorter than a
/// minimum fraction of a beat. Per-beat voting emits events on beat boundaries, but the
/// downstream `ChordOnsetAligner` snap and its nondecreasing clamp can compress neighbours to
/// sub-beat spacing; those slivers are transition noise, not playable chord changes.
///
/// A dropped event's span is absorbed by the PREVIOUS chord (the previous event simply
/// sustains longer). Adjacent duplicates left behind by a merge are collapsed.
enum ChordEventDurationFilter {
    /// - Parameters:
    ///   - events: chord events ordered by time.
    ///   - beatTimes: the resolved beat grid; used to measure the local beat length.
    ///   - minimumBeatFraction: events spanning less than this fraction of the local beat are
    ///     merged away. 0.8 keeps genuine one-beat passing chords (which per-beat voting emits
    ///     at full-beat spacing) while removing snap-compressed slivers.
    ///   - sourceDuration: full audio length; gives the final event a measurable span.
    static func merge(
        _ events: [EditableChordEvent],
        beatTimes: [TimeInterval],
        minimumBeatFraction: Double = 0.8,
        sourceDuration: TimeInterval? = nil
    ) -> [EditableChordEvent] {
        guard events.count > 1 else { return events }
        let intervals = beatIntervals(beatTimes)
        guard !intervals.isEmpty else { return collapseDuplicates(events) }

        var result = events
        // Iterate to a fixed point: removing one sliver can expose an adjacent duplicate or
        // another sub-minimum span. Bounded by the event count.
        var iterations = 0
        while iterations < events.count {
            iterations += 1
            var dropIndex: Int?
            var shortestRatio = Double.infinity
            for index in result.indices {
                let start = result[index].time
                let end: TimeInterval
                if index + 1 < result.count {
                    end = result[index + 1].time
                } else if let sourceDuration, sourceDuration > start {
                    end = sourceDuration
                } else {
                    continue
                }
                let beat = localBeatLength(at: start, intervals: intervals)
                guard beat > 0 else { continue }
                let ratio = (end - start) / beat
                if ratio < minimumBeatFraction, ratio < shortestRatio {
                    // Never drop the first event: its span defines where the song's harmony
                    // starts; absorb forward slivers instead.
                    if index == 0 { continue }
                    shortestRatio = ratio
                    dropIndex = index
                }
            }
            guard let dropIndex else { break }
            result.remove(at: dropIndex)
            result = collapseDuplicates(result)
            if result.count <= 1 { break }
        }
        return collapseDuplicates(result)
    }

    private static func collapseDuplicates(_ events: [EditableChordEvent]) -> [EditableChordEvent] {
        var collapsed: [EditableChordEvent] = []
        for event in events {
            if let previous = collapsed.last, previous.chord == event.chord {
                continue
            }
            collapsed.append(event)
        }
        return collapsed
    }

    private static func beatIntervals(_ beatTimes: [TimeInterval]) -> [(
        time: TimeInterval, length: TimeInterval
    )] {
        guard beatTimes.count >= 2 else { return [] }
        var intervals: [(TimeInterval, TimeInterval)] = []
        for index in 0..<(beatTimes.count - 1) {
            let length = beatTimes[index + 1] - beatTimes[index]
            if length > 0 { intervals.append((beatTimes[index], length)) }
        }
        return intervals
    }

    private static func localBeatLength(
        at time: TimeInterval,
        intervals: [(time: TimeInterval, length: TimeInterval)]
    ) -> TimeInterval {
        var best = intervals[0]
        for interval in intervals where abs(interval.time - time) < abs(best.time - time) {
            best = interval
        }
        return best.length
    }
}
