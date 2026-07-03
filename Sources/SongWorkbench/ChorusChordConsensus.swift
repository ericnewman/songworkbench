import Foundation

/// A-phase A3 (tasks/todo.md "Reconstruction-accuracy" plan): identically-sung sections must get
/// the SAME chords. The chroma decoder processes each chorus independently, so noise makes
/// repeated choruses disagree (~40 % agreement measured on Summertime). This pass finds REPEATED
/// LYRIC LINES (normalized text appearing ≥ `minimumInstances` times — chorus material), aligns
/// their chords by beat offset from each line's start, and lets the instances VOTE
/// (confidence-weighted) on one label per beat slot. Dissenting labels are rewritten to the
/// winner only when it holds a clear majority (`winnerWeightFraction`).
///
/// Conservative by design: labels are only REWRITTEN — events are never added, removed, or
/// re-timed — and ties/weak majorities leave the original label untouched. Deterministic
/// (groups and slots are processed in sorted order).
enum ChorusChordConsensus {
    static func applied(
        chords: [EditableChordEvent],
        lyrics: [TimedLyricSegment],
        beatTimes: [TimeInterval],
        minimumInstances: Int = 2,
        winnerWeightFraction: Double = 0.6
    ) -> [EditableChordEvent] {
        guard chords.count > 1, lyrics.count > 1, beatTimes.count > 2 else { return chords }
        let beats = beatTimes.sorted()

        func beatIndex(_ time: TimeInterval) -> Int {
            // beats is sorted: binary search for the nearest beat.
            var low = 0
            var high = beats.count - 1
            while low < high {
                let mid = (low + high) / 2
                if beats[mid] < time { low = mid + 1 } else { high = mid }
            }
            if low > 0, abs(beats[low - 1] - time) <= abs(beats[low] - time) { return low - 1 }
            return low
        }

        // Repeated lyric lines, keyed by normalized text (chorus lines recur near-verbatim).
        var groups: [String: [TimedLyricSegment]] = [:]
        for line in lyrics {
            let normalized = line.text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .joined()
            guard normalized.count >= 8 else { continue }  // ignore trivial lines
            groups[normalized, default: []].append(line)
        }

        var events = chords.sorted {
            if $0.time == $1.time { return $0.chord < $1.chord }
            return $0.time < $1.time
        }

        for key in groups.keys.sorted() {
            let instances = groups[key]!.sorted { $0.start < $1.start }
            guard instances.count >= minimumInstances else { continue }

            // Collect every chord event inside each instance, keyed by its beat offset from
            // the instance's start beat.
            var slots: [Int: [(eventIndex: Int, label: String, weight: Double)]] = [:]
            for line in instances {
                let baseBeat = beatIndex(line.start)
                for (index, event) in events.enumerated()
                where event.time >= line.start - 0.25 && event.time < line.end {
                    let offset = beatIndex(event.time) - baseBeat
                    slots[offset, default: []].append(
                        (index, event.chord, Double(event.confidence ?? 0.5)))
                }
            }

            // Per beat slot: confidence-weighted vote; rewrite dissenters to a CLEAR winner.
            for offset in slots.keys.sorted() {
                let entries = slots[offset]!
                guard entries.count >= minimumInstances else { continue }
                var weightByLabel: [String: Double] = [:]
                for entry in entries {
                    weightByLabel[entry.label, default: 0] += max(entry.weight, 0.01)
                }
                let total = weightByLabel.values.reduce(0, +)
                guard total > 0,
                    let winner = weightByLabel.max(by: {
                        if $0.value == $1.value { return $0.key > $1.key }  // deterministic tie
                        return $0.value < $1.value
                    }),
                    winner.value / total >= winnerWeightFraction
                else { continue }
                for entry in entries where entry.label != winner.key {
                    events[entry.eventIndex].chord = winner.key
                }
            }
        }
        return events
    }
}
