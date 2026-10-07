import CoreML
import XCTest

@testable import SongWorkbench

final class ChordNetTests: XCTestCase {
    /// Heads that name `chords[i]` for `frames[i]` frames each, with some doubt everywhere.
    static func heads(_ runs: [(chord: String, frames: Int)]) -> ChordNetDecoder.Heads {
        let classes = ChordNetDecoder.Heads.classes
        let total = runs.map(\.frames).reduce(0, +)
        var tables = classes.map { [Float](repeating: 0, count: total * $0) }
        var frame = 0
        for run in runs {
            let indices = ChordNetDecoder.vocabulary.first { $0.name == run.chord }!.heads
            for _ in 0..<run.frames {
                for head in 0..<6 {
                    // Bass is stored -1...11 against the head's "no bass" class 0.
                    let target = head == 1 ? indices[1] + 1 : max(indices[head], 0)
                    for index in 0..<classes[head] {
                        tables[head][frame * classes[head] + index] =
                            index == target ? 0.8 : 0.2 / Float(classes[head] - 1)
                    }
                }
                frame += 1
            }
        }
        return ChordNetDecoder.Heads(
            frames: total, triad: tables[0], bass: tables[1], seventh: tables[2],
            ninth: tables[3], eleventh: tables[4], thirteenth: tables[5])
    }

    func testDecoderFollowsHeldChordsAndIgnoresAFlicker() {
        let path = ChordNetDecoder.decode(
            Self.heads([("C:maj", 40), ("G:maj", 2), ("C:maj", 20), ("A:min", 40)]))
        var names: [String] = []
        for index in path where names.last != ChordNetDecoder.vocabulary[index].name {
            names.append(ChordNetDecoder.vocabulary[index].name)
        }
        // Starts on "no chord" as the reference does; a two-frame flicker costs more than it earns.
        XCTAssertEqual(names.drop { $0 == "N" }, ["C:maj", "A:min"])
    }

    func testAppLabelsDropInversionsAndSpellQualities() {
        XCTAssertEqual(ChordNetDecoder.appLabel("G:maj/3"), "G")
        XCTAssertEqual(ChordNetDecoder.appLabel("A:min7"), "Am7")
        XCTAssertEqual(ChordNetDecoder.appLabel("Bb:hdim7"), "Bbm7b5")
        XCTAssertEqual(ChordNetDecoder.appLabel("E:sus4(b7)"), "E7sus4")
        XCTAssertNil(ChordNetDecoder.appLabel("N"))
    }

    func testFeaturesPutAPureToneInItsBin() throws {
        // A4 = 440 Hz is 51 semitones above F#0, so bin 153 of 288, network bin 135.
        let samples = (0..<22050 * 2).map { Float(sin(2 * Double.pi * 440 * Double($0) / 22050)) }
        let frames = try ChordNetFeatures.spectrogram(samples: samples)
        XCTAssertEqual(frames.count, 1 + samples.count / 512)
        let middle = frames[frames.count / 2]
        XCTAssertEqual(middle.indices.max { middle[$0] < middle[$1] }, 135)
    }

    /// Writes one stem's features as raw little-endian Float32 `[frame][252]` for comparison with
    /// librosa: `SW_CHORDNET_DUMP=<stem>|<output>`.
    func testDumpFeatures() throws {
        guard let spec = ProcessInfo.processInfo.environment["SW_CHORDNET_DUMP"] else {
            throw XCTSkip("set SW_CHORDNET_DUMP")
        }
        let parts = spec.split(separator: "|").map(String.init)
        let samples = try MeasuredLyricTiming.monoSamples(
            at: URL(fileURLWithPath: parts[0]), sampleRate: ChordNetFeatures.sampleRate)
        let start = Date()
        let frames = try ChordNetFeatures.spectrogram(samples: samples)
        print("CHORDNET features \(frames.count) frames in \(Date().timeIntervalSince(start)) s")
        let flat = frames.flatMap { $0 }
        try flat.withUnsafeBufferPointer { Data(buffer: $0) }.write(
            to: URL(fileURLWithPath: parts[1]))
        if parts.count > 2 {
            let model = try MLModel(
                contentsOf: MLModel.compileModel(at: URL(fileURLWithPath: parts[2])))
            let segments = try ChordNetRecognizer.segments(spectrogram: frames, model: model)
            let lab = segments.map { String(format: "%.3f\t%.3f\t%@", $0.start, $0.end, $0.chord) }
            try lab.joined(separator: "\n").write(
                toFile: parts[1] + ".lab", atomically: true, encoding: .utf8)
        }
    }
}
