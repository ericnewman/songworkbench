import Foundation

/// The song's ONE definition of "these lines are the same sung line" — the repetition signal
/// behind both the chart's Chorus labels (`SongStructureAnalyzer`) and the chord vote below.
/// Word-set Jaccard, so near-verbatim ASR variants of a repeated line still count as repeats.
///
/// Before this existed the two consumers each had a private matcher (exact normalized text here,
/// Jaccard in the analyzer), so a line the chart labelled "Chorus" could be excluded from its own
/// chorus's chord vote. One matcher, and the disagreement is impossible.
enum RepeatedLyricLineGroups {
    /// Lines whose normalized (letters+digits) text is shorter than this never form or join a
    /// group — "oh oh" repeating is not chorus evidence, and its chords should not vote.
    static let defaultMinimumNormalizedLength = 8

    static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    /// Groups of two or more mutually similar lines, each group sorted by start time, groups
    /// ordered by their first instance. Greedy seed clustering: the earliest unassigned line
    /// seeds a group and later lines join the first seed they match — deterministic, and never
    /// chains two dissimilar variants together through an intermediate.
    static func groups(
        in lyrics: [TimedLyricSegment],
        similarity: Double = 0.7,
        minimumNormalizedLength: Int = defaultMinimumNormalizedLength
    ) -> [[TimedLyricSegment]] {
        let lines =
            lyrics
            .filter { normalizedLength($0.text) >= minimumNormalizedLength }
            .sorted { $0.start < $1.start }
        let words = lines.map { wordSet($0.text) }
        var assigned = [Bool](repeating: false, count: lines.count)
        var result: [[TimedLyricSegment]] = []
        for i in lines.indices where !assigned[i] {
            assigned[i] = true
            var group = [i]
            for j in (i + 1)..<lines.count where !assigned[j] {
                if jaccard(words[i], words[j]) >= similarity {
                    group.append(j)
                    assigned[j] = true
                }
            }
            if group.count >= 2 { result.append(group.map { lines[$0] }) }
        }
        return result
    }

    private static func normalizedLength(_ text: String) -> Int {
        text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
    }
}

/// A-phase A3 (tasks/todo.md "Reconstruction-accuracy" plan): identically-sung sections must get
/// the SAME chords. The chroma decoder processes each chorus independently, so noise makes
/// repeated choruses disagree (~40 % agreement measured on Summertime). This pass takes the
/// song's REPEATED LYRIC LINES (`RepeatedLyricLineGroups` — chorus material), aligns
/// their chords by beat offset from each line's start, and lets the instances VOTE
/// (confidence-weighted) on one label per beat slot. Dissenting labels are rewritten to the
/// winner only when it holds a clear majority (`winnerWeightFraction`).
///
/// Conservative by design: labels are only REWRITTEN — events are never added, removed, or
/// re-timed — and ties/weak majorities leave the original label untouched. Deterministic
/// (groups and slots are processed in sorted order).
///
/// **This is agreement-by-analogy, and it ranks below direct audio evidence.** It describes the
/// arrangement's tendencies, not this bar — which is what makes it dangerous: it is right most of
/// the time, and it fails precisely on the bars where the arrangement deliberately changes. A
/// second chorus that swaps a chord is exactly the case a majority vote overwrites. `protectedIDs`
/// is the guard: events whose own pitch content positively confirmed their label (see
/// `ChordQualityAudit`) are excluded from rewriting, so a vote can fix noise but can never
/// overrule the recording.
enum ChorusChordConsensus {
    static func applied(
        chords: [EditableChordEvent],
        lyrics: [TimedLyricSegment],
        beatTimes: [TimeInterval],
        protectedIDs: Set<UUID> = [],
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

        // Repeated lyric lines, from the song's ONE repetition matcher — the same groups the
        // chart's Chorus labels come from, so a line labelled Chorus always votes with its
        // siblings (the old private exact-text matcher here silently disagreed with the chart
        // on near-verbatim ASR variants).
        let groups = RepeatedLyricLineGroups.groups(in: lyrics)

        var events = chords.sorted {
            if $0.time == $1.time { return $0.chord < $1.chord }
            return $0.time < $1.time
        }

        for instances in groups {
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
                    // Direct pitch evidence outranks the vote — but only about what it actually
                    // measured. `ChordQualityAudit` arbitrates the THIRD, so a protected event
                    // resists a rewrite that only flips major/minor on the same root (that IS the
                    // arrangement changing, not noise to smooth away). A rewrite that changes the
                    // ROOT is about something the quality audit never examined, so the vote still
                    // wins there and A3 keeps its main effect.
                    if protectedIDs.contains(events[entry.eventIndex].id),
                        sameRoot(entry.label, winner.key)
                    {
                        continue
                    }
                    events[entry.eventIndex].chord = winner.key
                }
            }
        }
        return events
    }

    /// Whether two chord labels name the same root, i.e. differ only in quality. Unparseable
    /// labels are treated as different roots so protection never blocks a rewrite on a name the
    /// quality audit could not have examined either.
    private static func sameRoot(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = ChordQualityAudit.parse(lhs), let right = ChordQualityAudit.parse(rhs)
        else { return false }
        return left.root == right.root
    }
}
