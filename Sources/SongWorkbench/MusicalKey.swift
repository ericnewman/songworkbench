import Foundation

struct MusicalKey: Codable, Equatable, Sendable {
    let root: PitchClass
    let quality: ChordQuality

    var displayName: String {
        Self.names[root.rawValue] + (quality == .minor ? " minor" : " major")
    }

    func transposed(by semitones: Int) -> MusicalKey {
        let rawValue = (root.rawValue + semitones % 12 + 12) % 12
        return MusicalKey(root: PitchClass(rawValue: rawValue)!, quality: quality)
    }

    private static let names = [
        "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B",
    ]
}

struct MusicalKeyEstimator: Sendable {
    func estimate(from events: [EditableChordEvent]) -> MusicalKey? {
        estimate(
            from: events.compactMap { event in
                guard let chord = parseChord(event.chord) else { return nil }
                return ChordObservation(
                    timestamp: event.time,
                    chord: chord,
                    confidence: event.confidence ?? 0.6
                )
            }
        )
    }

    func estimate(from observations: [ChordObservation]) -> MusicalKey? {
        let usable = observations.filter { $0.confidence >= 0.45 }
        guard !usable.isEmpty else { return nil }

        return PitchClass.allCases
            .flatMap { root in
                [ChordQuality.major, .minor].map { MusicalKey(root: root, quality: $0) }
            }
            .max { score($0, observations: usable) < score($1, observations: usable) }
    }

    private func score(_ key: MusicalKey, observations: [ChordObservation]) -> Float {
        observations.reduce(Float.zero) { total, observation in
            let interval = (observation.chord.root.rawValue - key.root.rawValue + 12) % 12
            return total + observation.confidence
                * weight(
                    interval: interval,
                    chordQuality: observation.chord.quality,
                    keyQuality: key.quality
                )
        }
    }

    private func parseChord(_ source: String) -> Chord? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let accidental = trimmed.dropFirst().first.flatMap { $0 == "#" || $0 == "b" ? $0 : nil }
        let rootName = String(first).uppercased() + (accidental.map(String.init) ?? "")
        let roots = [
            "C": PitchClass.c, "B#": .c,
            "C#": .cSharp, "Db": .cSharp,
            "D": .d,
            "D#": .dSharp, "Eb": .dSharp,
            "E": .e, "Fb": .e,
            "F": .f, "E#": .f,
            "F#": .fSharp, "Gb": .fSharp,
            "G": .g,
            "G#": .gSharp, "Ab": .gSharp,
            "A": .a,
            "A#": .aSharp, "Bb": .aSharp,
            "B": .b, "Cb": .b,
        ]
        guard let root = roots[rootName] else { return nil }
        let suffix = trimmed.dropFirst(rootName.count).lowercased()
        let quality: ChordQuality =
            suffix.hasPrefix("m") && !suffix.hasPrefix("maj")
            ? .minor : .major
        return Chord(root: root, quality: quality)
    }

    private func weight(
        interval: Int,
        chordQuality: ChordQuality,
        keyQuality: ChordQuality
    ) -> Float {
        switch keyQuality {
        case .major:
            switch (interval, chordQuality) {
            case (0, .major): 6
            case (5, .major), (7, .major): 3.5
            case (2, .minor), (4, .minor), (9, .minor): 2.5
            default: 0
            }
        case .minor:
            switch (interval, chordQuality) {
            case (0, .minor): 6
            case (5, .minor): 3.5
            case (3, .major), (8, .major), (10, .major): 3
            case (7, .minor), (7, .major): 2.5
            default: 0
            }
        }
    }
}
