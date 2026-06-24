import XCTest

@testable import SongWorkbench

final class BassLineAnalyzerTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// Builds a mono sine buffer at `frequency` for `duration` seconds.
    private func sine(frequency: Double, duration: Double, amplitude: Float = 0.7) -> [Float] {
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            samples[index] = amplitude * Float(sin(phase))
        }
        return samples
    }

    func testDetectsA2From110HzTone() {
        let observations = BassLineAnalyzer().analyze(
            samples: sine(frequency: 110, duration: 1.5),
            sampleRate: sampleRate
        )
        let note = try? XCTUnwrap(observations.first)
        XCTAssertEqual(note?.midiNote ?? 0, 45, accuracy: 1)  // A2
    }

    func testDetectsE2From82HzTone() {
        let observations = BassLineAnalyzer().analyze(
            samples: sine(frequency: 82.41, duration: 1.5),
            sampleRate: sampleRate
        )
        let note = try? XCTUnwrap(observations.first)
        XCTAssertEqual(note?.midiNote ?? 0, 40, accuracy: 1)  // E2
    }

    func testSilenceProducesNoObservations() {
        let silence = [Float](repeating: 0, count: Int(sampleRate * 1.5))
        let observations = BassLineAnalyzer().analyze(
            samples: silence,
            sampleRate: sampleRate
        )
        XCTAssertTrue(observations.isEmpty)
    }

    func testTwoToneSequenceProducesTwoSegmentsInOrder() {
        var samples = sine(frequency: 110, duration: 1.0)  // A2 / midi 45
        samples.append(contentsOf: sine(frequency: 146.83, duration: 1.0))  // D3 / midi 50
        let observations = BassLineAnalyzer().analyze(
            samples: samples,
            sampleRate: sampleRate
        )

        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.first?.midiNote ?? 0, 45, accuracy: 1)
        XCTAssertEqual(observations.last?.midiNote ?? 0, 50, accuracy: 1)
        if observations.count == 2 {
            XCTAssertLessThan(observations[0].timestamp, observations[1].timestamp)
        }
    }

    func testNoteNamingMapsPitchClass() {
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 45), "A")  // A2
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 40), "E")  // E2
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 50), "D")  // D3
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 49), "C#")  // C#3
    }
}
