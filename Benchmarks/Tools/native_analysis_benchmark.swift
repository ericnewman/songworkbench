import AVFoundation
import Foundation

@main
struct NativeAnalysisBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: native_analysis_benchmark input.wav\n", stderr)
            exit(2)
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            let channels = buffer.floatChannelData!
            for frame in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    value += channels[channel][frame]
                }
                samples.append(value / Float(format.channelCount))
            }
        }

        let beat = BeatTracker().analyze(samples: samples, sampleRate: format.sampleRate)
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: format.sampleRate,
            frameLength: 8_192,
            hopLength: 4_096
        )
        print("bpm=\(beat?.bpm ?? 0)")
        print("beat_count=\(beat?.beatTimes.count ?? 0)")

        let rootNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        func name(_ observation: ChordObservation) -> String {
            rootNames[observation.chord.root.rawValue]
                + (observation.chord.quality == .minor ? "m" : "")
        }

        // Trial-and-error sweep: print the chord timeline for several root weightings so a
        // known progression (e.g. the intro Eb Ab Cm Ab) can be compared across variants.
        let rootWeights: [Float] = [1.0, 1.3, 1.6, 2.0]
        for rootWeight in rootWeights {
            let start = ContinuousClock.now
            let observations = try ChordAnalysisPipeline(
                configuration: configuration, rootWeight: rootWeight
            ).analyze(samples: samples)
            let elapsed = start.duration(to: .now)
            let seconds =
                Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            print(
                "--- rootWeight=\(rootWeight) observations=\(observations.count) "
                    + "elapsed_seconds=\(seconds) ---")
            guard let beat else { continue }
            var previous: String?
            for index in stride(from: 0, to: beat.beatTimes.count - 1, by: 4) {
                let endIndex = min(index + 4, beat.beatTimes.count - 1)
                let startTime = beat.beatTimes[index]
                let endTime = beat.beatTimes[endIndex]
                let candidates = observations.filter {
                    $0.timestamp >= startTime && $0.timestamp < endTime && $0.confidence >= 0.45
                }
                let scores = Dictionary(grouping: candidates, by: name)
                    .mapValues { $0.reduce(Float.zero) { $0 + $1.confidence } }
                guard let winner = scores.max(by: { $0.value < $1.value }) else { continue }
                guard winner.key != previous else { continue }
                print(String(format: "%.2f %@ %.3f", startTime, winner.key, winner.value))
                previous = winner.key
            }
        }
    }
}
