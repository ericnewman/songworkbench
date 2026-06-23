import XCTest

@testable import SongWorkbench

final class MusicalKeyTests: XCTestCase {
    func testTranspositionPreservesQualityAndWrapsPitchClass() {
        let key = MusicalKey(root: .b, quality: .minor)

        XCTAssertEqual(key.transposed(by: 2), MusicalKey(root: .cSharp, quality: .minor))
        XCTAssertEqual(key.transposed(by: -2), MusicalKey(root: .a, quality: .minor))
        XCTAssertEqual(key.displayName, "B minor")
    }

    func testEstimatorFindsMajorKeyFromDiatonicProgression() {
        let observations = observations([
            Chord(root: .g, quality: .major),
            Chord(root: .c, quality: .major),
            Chord(root: .d, quality: .major),
            Chord(root: .e, quality: .minor),
            Chord(root: .g, quality: .major),
        ])

        XCTAssertEqual(
            MusicalKeyEstimator().estimate(from: observations),
            MusicalKey(root: .g, quality: .major)
        )
    }

    func testEstimatorFindsRelativeMinorWhenMinorTonicDominates() {
        let observations = observations([
            Chord(root: .a, quality: .minor),
            Chord(root: .a, quality: .minor),
            Chord(root: .d, quality: .minor),
            Chord(root: .e, quality: .major),
            Chord(root: .f, quality: .major),
        ])

        XCTAssertEqual(
            MusicalKeyEstimator().estimate(from: observations),
            MusicalKey(root: .a, quality: .minor)
        )
    }

    func testEstimatorAcceptsEditableChordNamesAndSlashChords() {
        let events = [
            EditableChordEvent(time: 0, chord: "Bb", confidence: 0.9),
            EditableChordEvent(time: 1, chord: "Ebmaj7", confidence: 0.9),
            EditableChordEvent(time: 2, chord: "F/A", confidence: 0.9),
            EditableChordEvent(time: 3, chord: "Gm", confidence: 0.9),
            EditableChordEvent(time: 4, chord: "Bb/D", confidence: 0.9),
        ]

        XCTAssertEqual(
            MusicalKeyEstimator().estimate(from: events),
            MusicalKey(root: .aSharp, quality: .major)
        )
    }

    private func observations(_ chords: [Chord]) -> [ChordObservation] {
        chords.enumerated().map { index, chord in
            ChordObservation(timestamp: Double(index), chord: chord, confidence: 0.9)
        }
    }
}
