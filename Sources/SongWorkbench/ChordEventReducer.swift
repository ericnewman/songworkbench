import Foundation

struct ChordEventReducer: Sendable {
    let beatsPerWindow: Int
    let minimumConfidence: Float
    let minimumWinningShare: Float
    let fallbackWindowDuration: TimeInterval

    init(
        beatsPerWindow: Int = 2,
        minimumConfidence: Float = 0.45,
        // The winner only needs a clear plurality of the window's confidence, not a super-majority.
        // Chord chroma routinely splits the vote between chords that share notes (e.g. A vs D vs
        // F#), so 0.55 dropped ~half of all windows as "ambiguous" — the main cause of missing
        // chords. 0.45 keeps the winner when it is clearly ahead while still rejecting true ties.
        minimumWinningShare: Float = 0.45,
        fallbackWindowDuration: TimeInterval = 2
    ) {
        self.beatsPerWindow = max(beatsPerWindow, 1)
        self.minimumConfidence = minimumConfidence
        self.minimumWinningShare = minimumWinningShare
        self.fallbackWindowDuration = max(fallbackWindowDuration, 0.25)
    }

    func events(from analysis: SongAudioAnalysis) -> [EditableChordEvent] {
        let observations = analysis.chords.filter { $0.confidence >= minimumConfidence }
        guard !observations.isEmpty else { return [] }

        let windows = beatWindows(
            beatTimes: analysis.beat?.beatTimes,
            observations: observations
        )
        var events: [EditableChordEvent] = []
        var previousChord: String?

        for (windowIndex, window) in windows.enumerated() {
            let candidates = observations.filter { observation in
                observation.timestamp >= window.start
                    && (observation.timestamp < window.end
                        || windowIndex == windows.indices.last
                            && observation.timestamp == window.end)
            }
            guard let winner = winningChord(in: candidates) else { continue }
            guard winner.name != previousChord else { continue }
            events.append(
                EditableChordEvent(
                    time: window.start,
                    chord: winner.name,
                    confidence: winner.confidence
                ))
            previousChord = winner.name
        }
        return events
    }

    private func beatWindows(
        beatTimes: [TimeInterval]?,
        observations: [ChordObservation]
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        if let beatTimes, beatTimes.count >= 2 {
            return stride(from: 0, to: beatTimes.count - 1, by: beatsPerWindow).compactMap {
                startIndex in
                let endIndex = min(startIndex + beatsPerWindow, beatTimes.count - 1)
                guard beatTimes[endIndex] > beatTimes[startIndex] else { return nil }
                return (beatTimes[startIndex], beatTimes[endIndex])
            }
        }

        let start = max(observations.first?.timestamp ?? 0, 0)
        let end = max(observations.last?.timestamp ?? start, start) + fallbackWindowDuration
        return stride(from: start, through: end, by: fallbackWindowDuration).dropLast().map {
            ($0, min($0 + fallbackWindowDuration, end))
        }
    }

    private func winningChord(
        in observations: [ChordObservation]
    ) -> (name: String, confidence: Float)? {
        guard !observations.isEmpty else { return nil }
        let grouped = Dictionary(grouping: observations, by: { $0.chord.displayName })
        let scores = grouped.mapValues { values in
            values.reduce(Float.zero) { $0 + $1.confidence }
        }
        guard let winner = scores.max(by: { $0.value < $1.value }) else { return nil }
        let totalScore = scores.values.reduce(Float.zero, +)
        guard totalScore > 0, winner.value / totalScore >= minimumWinningShare else { return nil }
        let winnerObservations = grouped[winner.key] ?? []
        return (
            winner.key,
            winner.value / Float(max(winnerObservations.count, 1))
        )
    }
}
