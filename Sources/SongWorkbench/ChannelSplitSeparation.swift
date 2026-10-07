import AVFoundation
import Foundation

/// How alike a recording's two channels are. A 1960s "wide stereo" mix hard-pans whole
/// instruments, and the separator, trained on centred mixes, then hands a side-panned bass to
/// the guitar stem: on Eight Miles High the bass stem was silent (−79 dB) through the intro while
/// the guitar stem carried the bass line below 150 Hz at −27 dB.
enum StereoWidth {
    /// Below this left/right correlation a mix is wide enough to separate channel by channel.
    /// Eight Miles High measures −0.09…0.24; centred modern mixes sit well above 0.6.
    static let wideCorrelation: Float = 0.5

    /// Pearson correlation of the left and right channels over the whole file; 1 for mono.
    static func correlation(url: URL) throws -> Float {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount >= 2 else { return 1 }
        let capacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }
        var sumLL = 0.0
        var sumRR = 0.0
        var sumLR = 0.0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else { break }
            for i in 0..<Int(buffer.frameLength) {
                let l = Double(channels[0][i])
                let r = Double(channels[1][i])
                sumLL += l * l
                sumRR += r * r
                sumLR += l * r
            }
        }
        let denominator = (sumLL * sumRR).squareRoot()
        return denominator > 1e-12 ? Float(sumLR / denominator) : 1
    }

    static func isWide(url: URL) -> Bool {
        ((try? correlation(url: url)) ?? 1) < wideCorrelation
    }
}

/// Separates a wide stereo recording one channel at a time: each channel goes through the base
/// separator as centred dual mono, and each stem is put back together as left from the left pass
/// and right from the right pass (Eric, 2026-10-07: automatic for wide mixes). A centred mix goes
/// straight through, so its stems, metadata and cache are untouched.
///
/// Measured on the first 30 s of Eight Miles High: the stereo pass left the bass stem at −79 dB;
/// the left channel alone gave −20 dB, the bass line in the bass stem.
struct ChannelSplitStemEngine: StemSeparationEngine {
    /// Marks base assets made this way, so the cache can tell a wide song still holding stereo-pass
    /// stems (made before this existed) and re-separate it.
    static let producerSuffix = "|channel-split-1"

    let base: any StemSeparationEngine

    var metadata: StemSeparationEngineMetadata { base.metadata }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        guard StereoWidth.isWide(url: request.inputURL) else {
            return try await base.separate(request: request, progress: progress)
        }
        let started = ContinuousClock.now
        let work = request.outputDirectory.appendingPathComponent(
            ".channel-split", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var passes: [StemSeparationResult] = []
        for channel in 0..<2 {
            try Task.checkCancellation()
            let input = work.appendingPathComponent("channel-\(channel).wav")
            try Self.writeDualMono(from: request.inputURL, channel: channel, to: input)
            let output = work.appendingPathComponent("out-\(channel)", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let result = try await base.separate(
                request: StemSeparationRequest(inputURL: input, outputDirectory: output)
            ) { value in
                // Each pass is half the work.
                let total = max(value.totalUnits, 1)
                progress(
                    StemSeparationProgress(
                        phase: value.phase, completedUnits: channel * total + value.completedUnits,
                        totalUnits: 2 * total))
            }
            passes.append(result)
        }

        var urls: [URL: URL] = [:]
        var assets: [StemAsset] = []
        let right = passes[1].stemSet.assetsByID
        for asset in passes[0].stemSet.assets {
            guard let rightAsset = right[asset.id] else { continue }
            let destination = request.outputDirectory.appendingPathComponent(
                asset.audioURL.lastPathComponent)
            try Self.writeStereo(left: asset.audioURL, right: rightAsset.audioURL, to: destination)
            urls[asset.audioURL] = destination
            assets.append(
                StemAsset(
                    id: asset.id, audioURL: destination,
                    producerID: asset.producerID + Self.producerSuffix))
        }
        let leftStems = passes[0].stems
        func mapped(_ url: URL?) -> URL? { url.map { urls[$0] ?? $0 } }
        let stems = StemFiles(
            vocals: mapped(leftStems.vocals)!, drums: mapped(leftStems.drums)!,
            bass: mapped(leftStems.bass)!, guitar: mapped(leftStems.guitar),
            piano: mapped(leftStems.piano), other: mapped(leftStems.other)!,
            accompaniment: mapped(leftStems.accompaniment))
        let manifest = StemSetManifest(
            descriptors: passes[0].stemSet.descriptors, assets: assets,
            recipeIdentity: passes[0].stemSet.recipeIdentity)
        return StemSeparationResult(
            stems: stems, stemSet: manifest, processingDuration: ContinuousClock.now - started)
    }

    /// True when a wide song's stored stems came from a plain stereo pass and must be redone.
    static func needsResplit(sourceURL: URL, storedStemSet: StoredStemSetManifest?) -> Bool {
        guard let manifest = storedStemSet?.resolved(followingBookmarks: false) else {
            return false
        }
        let baseAssets = manifest.assets.filter { asset in
            manifest.descriptorsByID[asset.id]?.role == .source
        }
        guard !baseAssets.isEmpty,
            !baseAssets.allSatisfy({ $0.producerID.hasSuffix(producerSuffix) })
        else { return false }
        return StereoWidth.isWide(url: sourceURL)
    }

    /// `channel` of the source, written to both channels of a 44.1 kHz stereo file.
    static func writeDualMono(from source: URL, channel: Int, to url: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 2,
                interleaved: false)
        else { throw WaveformAnalyzerError.unsupportedAudioFormat }
        let output = try AVAudioFile(
            forWriting: url, settings: outFormat.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let capacity: AVAudioFrameCount = 65_536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { throw WaveformAnalyzerError.unsupportedAudioFormat }
        let source = min(channel, Int(format.channelCount) - 1)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            let remaining = input.length - input.framePosition
            try input.read(into: inBuffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let from = inBuffer.floatChannelData, let to = outBuffer.floatChannelData else {
                break
            }
            let frames = Int(inBuffer.frameLength)
            for i in 0..<frames {
                to[0][i] = from[source][i]
                to[1][i] = from[source][i]
            }
            outBuffer.frameLength = inBuffer.frameLength
            try output.write(from: outBuffer)
        }
    }

    /// A stereo stem from two dual-mono passes: each pass's channel average on its own side.
    static func writeStereo(left: URL, right: URL, to url: URL) throws {
        let leftFile = try AVAudioFile(forReading: left)
        let rightFile = try AVAudioFile(forReading: right)
        let sampleRate = leftFile.processingFormat.sampleRate
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2,
                interleaved: false)
        else { throw WaveformAnalyzerError.unsupportedAudioFormat }
        try? FileManager.default.removeItem(at: url)
        let output = try AVAudioFile(
            forWriting: url, settings: outFormat.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let capacity: AVAudioFrameCount = 65_536
        guard
            let leftBuffer = AVAudioPCMBuffer(
                pcmFormat: leftFile.processingFormat, frameCapacity: capacity),
            let rightBuffer = AVAudioPCMBuffer(
                pcmFormat: rightFile.processingFormat, frameCapacity: capacity),
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { throw WaveformAnalyzerError.unsupportedAudioFormat }
        func average(_ buffer: AVAudioPCMBuffer, _ i: Int) -> Float {
            guard let data = buffer.floatChannelData else { return 0 }
            let count = Int(buffer.format.channelCount)
            var sum: Float = 0
            for channel in 0..<count { sum += data[channel][i] }
            return sum / Float(max(count, 1))
        }
        while leftFile.framePosition < leftFile.length {
            try Task.checkCancellation()
            let remaining = leftFile.length - leftFile.framePosition
            let frames = min(capacity, AVAudioFrameCount(remaining))
            try leftFile.read(into: leftBuffer, frameCount: frames)
            let rightRemaining = rightFile.length - rightFile.framePosition
            if rightRemaining > 0 {
                try rightFile.read(
                    into: rightBuffer, frameCount: min(frames, AVAudioFrameCount(rightRemaining)))
            } else {
                rightBuffer.frameLength = 0
            }
            guard let to = outBuffer.floatChannelData else { break }
            for i in 0..<Int(leftBuffer.frameLength) {
                to[0][i] = average(leftBuffer, i)
                to[1][i] = i < Int(rightBuffer.frameLength) ? average(rightBuffer, i) : 0
            }
            outBuffer.frameLength = leftBuffer.frameLength
            try output.write(from: outBuffer)
        }
    }
}
