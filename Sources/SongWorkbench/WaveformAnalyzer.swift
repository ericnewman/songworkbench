import AVFoundation
import Foundation

struct WaveformEnvelope: Codable, Equatable, Sendable {
    let peaks: [Float]
    let duration: TimeInterval
}

enum WaveformAnalyzerError: Error {
    case unsupportedAudioFormat
}

actor WaveformAnalyzer {
    func analyze(url: URL, targetSampleCount: Int = 1_200) throws -> WaveformEnvelope {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount > 0, targetSampleCount > 0 else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }

        let totalFrames = max(Int(file.length), 1)
        var peaks = [Float](repeating: 0, count: targetSampleCount)
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }

        var absoluteFrame = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            let requestedFrames = min(AVAudioFrameCount(remaining), capacity)
            try file.read(into: buffer, frameCount: requestedFrames)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }

            guard let channels = buffer.floatChannelData else {
                throw WaveformAnalyzerError.unsupportedAudioFormat
            }
            for frame in 0..<frameCount {
                var amplitude: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    amplitude = max(amplitude, abs(channels[channel][frame]))
                }
                let bin = min(
                    (absoluteFrame + frame) * targetSampleCount / totalFrames,
                    targetSampleCount - 1
                )
                peaks[bin] = max(peaks[bin], amplitude)
            }
            absoluteFrame += frameCount
        }

        return WaveformEnvelope(
            peaks: peaks,
            duration: Double(file.length) / format.sampleRate
        )
    }
}
