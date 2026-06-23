import AVFoundation
import Foundation

struct SongAudioAnalysis: Codable, Equatable, Sendable {
    let beat: BeatEstimate?
    let chords: [ChordObservation]
    let estimatedKey: MusicalKey?

    init(beat: BeatEstimate?, chords: [ChordObservation], estimatedKey: MusicalKey? = nil) {
        self.beat = beat
        self.chords = chords
        self.estimatedKey = estimatedKey
    }
}

actor AudioFileAnalysisService {
    func analyze(url: URL) throws -> SongAudioAnalysis {
        let (samples, sampleRate) = try loadMonoSamples(url: url)
        try Task.checkCancellation()
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: sampleRate,
            frameLength: 8_192,
            hopLength: 4_096
        )
        let chords = try ChordAnalysisPipeline(configuration: configuration).analyze(
            samples: samples)
        return SongAudioAnalysis(
            beat: BeatTracker().analyze(samples: samples, sampleRate: sampleRate),
            chords: chords,
            estimatedKey: MusicalKeyEstimator().estimate(from: chords)
        )
    }

    private func loadMonoSamples(url: URL) throws -> ([Float], Double) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else {
                throw WaveformAnalyzerError.unsupportedAudioFormat
            }
            for frame in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    value += channels[channel][frame]
                }
                samples.append(value / Float(format.channelCount))
            }
        }
        return (samples, format.sampleRate)
    }
}

extension Chord {
    var displayName: String {
        let roots = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        return roots[root.rawValue] + (quality == .minor ? "m" : "")
    }
}
