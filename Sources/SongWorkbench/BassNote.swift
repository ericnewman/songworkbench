import Foundation

/// The bass note implied by a chord symbol: the slash-bass note when one is
/// written (e.g. `G/B` → `B`), otherwise the chord root (e.g. `Cm7` → `C`).
///
/// This value type is the single home for chord-symbol → bass-note parsing,
/// shared by the bass-note ChordPro draft and the playback highlight so the two
/// never diverge.
struct BassNote: Equatable, Sendable {
    /// Display label for the bass note, e.g. `C`, `F#`, `Bb`.
    let label: String

    /// Parses the bass note from a chord symbol such as `C`, `Cm7`, or `G/B`.
    /// Returns `nil` when no pitch letter can be read.
    init?(chordSymbol: String) {
        let trimmed = chordSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(
            separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        if components.count == 2, let bass = Self.parseNote(components[1]) {
            label = bass
            return
        }
        guard let root = Self.parseNote(components[0]) else { return nil }
        label = root
    }

    private static func parseNote(_ source: Substring) -> String? {
        guard let first = source.first else { return nil }
        let letter = String(first).uppercased()
        guard ["A", "B", "C", "D", "E", "F", "G"].contains(letter) else { return nil }
        let remainder = source.dropFirst()
        if remainder.first == "#" || remainder.first == "b" {
            return letter + String(remainder.first!)
        }
        return letter
    }
}
