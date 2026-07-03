import Foundation

/// Decodes the chord timeline from frame-level chord observations with temporal smoothing.
///
/// Replaces independent per-beat-window voting for the offline analysis path. Each beat
/// window's evidence (confidence-summed frame labels, optionally scaled by a key prior)
/// becomes a Viterbi emission; a constant switch penalty rewards staying on the current
/// chord, and an explicit no-chord state absorbs windows with weak evidence (quiet intros,
/// fades) instead of letting garbage labels win them.
///
/// Validated offline against the reference song's cached frames: independent voting produced
/// 117 events (28% non-diatonic, 26 sub-beat, 31% chorus self-agreement); this decoder with
/// the key prior produced ~58 events, ~12% non-diatonic, ~4 sub-beat, 67% chorus agreement
/// before repeated-section consensus.
struct ChordTimelineDecoder: Sendable {
    /// Log-domain cost of switching chords between adjacent beat windows. Higher = smoother.
    /// 2.5 rode the tonic straight through the reference song's real mid-verse changes
    /// (author-confirmed); 2.0 recovers them once bass re-rooting pools the split evidence.
    var switchPenalty: Float = 2.0
    /// Evidence mass assigned to the no-chord state in every window. Windows whose total
    /// label evidence is comparable to this floor decode as "no chord" and emit nothing
    /// (the previous chord sustains).
    var noChordFloor: Float = 0.5
    /// Frames below this confidence are ignored, matching `ChordEventReducer`.
    var minimumConfidence: Float = 0.45

    func events(
        from analysis: SongAudioAnalysis,
        key: MusicalKey?,
        bassNotes: [BassNoteObservation] = []
    ) -> [EditableChordEvent] {
        guard let beatTimes = analysis.beat?.beatTimes, beatTimes.count >= 2 else {
            // No usable beat grid: fall back to the window-voting reducer (2s windows).
            return ChordEventReducer().events(from: analysis)
        }
        let rescorer = key.map { KeyPriorChordRescorer(key: $0) }
        // Bass-informed re-rooting at the FRAME level: shared-note confusions (Ab vs Cm) can
        // fully mask the true label in the chroma, and a masked label can't win any window.
        let rerooted = BassInformedChordRefiner().refineObservations(
            analysis.chords, bassNotes: bassNotes)
        let usable = rerooted.filter { $0.confidence >= minimumConfidence }
        guard !usable.isEmpty else { return [] }

        let windows = Self.windowEvidence(
            observations: usable,
            beatTimes: beatTimes,
            rescorer: rescorer
        )
        let labels = Self.observedLabels(windows)
        guard !labels.isEmpty else { return [] }
        let path = Self.decode(
            windows: windows,
            labels: labels,
            switchPenalty: switchPenalty,
            noChordFloor: noChordFloor
        )

        var events: [EditableChordEvent] = []
        var previous: String?
        for (index, label) in path.enumerated() {
            guard let label, label != previous else { continue }
            events.append(
                EditableChordEvent(
                    time: windows[index].start,
                    chord: label,
                    confidence: windows[index].meanRawConfidence[label] ?? 0.6
                ))
            previous = label
        }
        return Self.mergeSameRootExtensions(events)
    }

    /// Collapses adjacent events that are the same chord under different amounts of colour —
    /// a triad next to its own seventh extension (F# then F#maj7) is one sustained chord whose
    /// upper voices moved, not a chord change. Keeps the earlier onset and the plain triad label.
    static func mergeSameRootExtensions(_ events: [EditableChordEvent]) -> [EditableChordEvent] {
        var merged: [EditableChordEvent] = []
        for event in events {
            if let last = merged.last, let base = sharedTriadLabel(last.chord, event.chord) {
                merged[merged.count - 1].chord = base
                merged[merged.count - 1].confidence = max(
                    last.confidence ?? 0, event.confidence ?? 0)
                continue
            }
            merged.append(event)
        }
        return merged
    }

    /// The common triad label when two labels are the same root and triad quality differing
    /// only by a seventh extension ("F#"/"F#maj7"/"F#7" → "F#", "Ebm"/"Ebm7" → "Ebm"); nil
    /// when they are genuinely different chords.
    private static func sharedTriadLabel(_ a: String, _ b: String) -> String? {
        guard a != b else { return a }
        let baseA = triadBase(a)
        let baseB = triadBase(b)
        guard baseA == baseB else { return nil }
        return baseA
    }

    private static func triadBase(_ label: String) -> String {
        if label.hasSuffix("maj7") { return String(label.dropLast(4)) }
        if label.hasSuffix("m7") { return String(label.dropLast(1)) }
        if label.hasSuffix("7") { return String(label.dropLast(1)) }
        return label
    }

    // MARK: - Evidence

    struct WindowEvidence: Sendable {
        let start: TimeInterval
        /// Confidence-summed (and key-prior-scaled) evidence per chord label.
        let scores: [String: Float]
        /// Mean UNSCALED frame confidence per label, reported on emitted events so the
        /// persisted confidence keeps its original meaning for thresholds and UI.
        let meanRawConfidence: [String: Float]
    }

    static func windowEvidence(
        observations: [ChordObservation],
        beatTimes: [TimeInterval],
        rescorer: KeyPriorChordRescorer?
    ) -> [WindowEvidence] {
        var windows: [WindowEvidence] = []
        windows.reserveCapacity(beatTimes.count - 1)
        var cursor = 0
        let sorted = observations.sorted { $0.timestamp < $1.timestamp }
        for index in 0..<(beatTimes.count - 1) {
            let start = beatTimes[index]
            let end = beatTimes[index + 1]
            var scores: [String: Float] = [:]
            var sums: [String: Float] = [:]
            var counts: [String: Int] = [:]
            while cursor < sorted.count, sorted[cursor].timestamp < end {
                let observation = sorted[cursor]
                cursor += 1
                guard observation.timestamp >= start else { continue }
                let label = observation.chord.displayName
                let weight = rescorer?.weight(for: observation.chord) ?? 1
                scores[label, default: 0] += observation.confidence * weight
                sums[label, default: 0] += observation.confidence
                counts[label, default: 0] += 1
            }
            let means = sums.reduce(into: [String: Float]()) { result, entry in
                result[entry.key] = entry.value / Float(max(counts[entry.key] ?? 1, 1))
            }
            windows.append(WindowEvidence(start: start, scores: scores, meanRawConfidence: means))
        }
        return windows
    }

    static func observedLabels(_ windows: [WindowEvidence]) -> [String] {
        var labels: Set<String> = []
        for window in windows { labels.formUnion(window.scores.keys) }
        return labels.sorted()
    }

    // MARK: - Viterbi

    /// Returns one entry per window: the decoded chord label, or `nil` for no-chord.
    static func decode(
        windows: [WindowEvidence],
        labels: [String],
        switchPenalty: Float,
        noChordFloor: Float
    ) -> [String?] {
        // State 0 is the no-chord state; states 1... map to labels.
        let stateCount = labels.count + 1
        var logProb = [Float](repeating: 0, count: stateCount)
        var backpointers: [[Int]] = []
        backpointers.reserveCapacity(windows.count)

        for window in windows {
            let total = window.scores.values.reduce(0, +)
            var emission = [Float](repeating: 0, count: stateCount)
            if total > 0 {
                emission[0] = log(noChordFloor / (total + noChordFloor))
                for (index, label) in labels.enumerated() {
                    let score = max(window.scores[label] ?? 0, 1e-3)
                    emission[index + 1] = log(score / (total + noChordFloor))
                }
            } else {
                // No frames at all: uninformative, NOT evidence against sustaining the
                // current chord. Give the no-chord state only a mild edge so long silent
                // stretches drift to no-chord without punishing a chord that resumes.
                emission[0] = log(Float(0.6))
                for index in labels.indices { emission[index + 1] = log(Float(0.5)) }
            }

            // Best previous state is either "stay" or the single global best with penalty.
            var bestValue = logProb[0]
            var bestIndex = 0
            for state in 1..<stateCount where logProb[state] > bestValue {
                bestValue = logProb[state]
                bestIndex = state
            }
            var next = [Float](repeating: 0, count: stateCount)
            var back = [Int](repeating: 0, count: stateCount)
            for state in 0..<stateCount {
                let stay = logProb[state]
                let jump = bestValue - switchPenalty
                if stay >= jump || bestIndex == state {
                    next[state] = stay + emission[state]
                    back[state] = state
                } else {
                    next[state] = jump + emission[state]
                    back[state] = bestIndex
                }
            }
            logProb = next
            backpointers.append(back)
        }

        var state = 0
        var bestFinal = -Float.infinity
        for candidate in 0..<stateCount where logProb[candidate] > bestFinal {
            bestFinal = logProb[candidate]
            state = candidate
        }
        var path = [Int](repeating: 0, count: windows.count)
        for index in stride(from: windows.count - 1, through: 0, by: -1) {
            path[index] = state
            state = backpointers[index][state]
        }
        return path.map { $0 == 0 ? nil : labels[$0 - 1] }
    }
}
