import AVFoundation
import CoreML
import Foundation

struct StereoAudioChunk: Sendable {
    let channels: [[Float]]

    init(left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        channels = [left, right]
    }

    var frameCount: Int { channels[0].count }
}

struct StemChunkPrediction: Sendable {
    let samplesByStem: [StemKind: [[Float]]]
}

protocol StemChunkPredicting: Sendable {
    var supportedStems: [StemKind] { get }
    func predict(_ chunk: StereoAudioChunk) async throws -> StemChunkPrediction
}

enum CoreMLStemSeparationError: Error, LocalizedError {
    case invalidConfiguration
    case unsupportedAudio
    case invalidPrediction
    case invalidOutput(StemKind)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Stem separation chunk configuration is invalid."
        case .unsupportedAudio:
            "The recording could not be converted to 44.1 kHz stereo audio."
        case .invalidPrediction:
            "The stem model returned an unsupported output."
        case .invalidOutput(let kind):
            "The generated \(kind.rawValue) stem is invalid."
        }
    }
}

struct CoreMLStemSeparationEngine: StemSeparationEngine, Sendable {
    private static let sampleRate = 44_100.0

    private let predictor: any StemChunkPredicting
    private let segmentFrames: Int
    private let overlapFrames: Int
    private let normalizesAudio: Bool

    let metadata: StemSeparationEngineMetadata

    init(
        predictor: any StemChunkPredicting,
        segmentFrames: Int = 441_000,
        overlapFrames: Int = 44_100,
        normalizesAudio: Bool = false,
        metadata: StemSeparationEngineMetadata = StemSeparationEngineMetadata(
            engineIdentifier: "coreml-htdemucs",
            engineVersion: "1",
            modelIdentifier: "htdemucs-coreml-fp16",
            modelVersion: "1.0.0"
        )
    ) {
        self.predictor = predictor
        self.segmentFrames = segmentFrames
        self.overlapFrames = overlapFrames
        self.normalizesAudio = normalizesAudio
        self.metadata = metadata
    }

    init(modelURL: URL) throws {
        self.init(predictor: try CoreMLStemChunkPredictor(modelURL: modelURL))
    }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        guard segmentFrames > 0, overlapFrames >= 0, overlapFrames < segmentFrames else {
            throw CoreMLStemSeparationError.invalidConfiguration
        }
        let start = ContinuousClock.now
        progress(
            StemSeparationProgress(
                phase: .preparingAudio,
                completedUnits: 0,
                totalUnits: 1
            ))
        let accessing = request.inputURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { request.inputURL.stopAccessingSecurityScopedResource() }
        }
        var loadedAudio = try await Task.detached(priority: .userInitiated) {
            try Self.loadStereoFloatAudio(at: request.inputURL)
        }.value
        let normalization = normalizesAudio ? Self.normalized(loadedAudio) : nil
        var audio = normalization?.audio ?? loadedAudio
        // When normalizing (the ONNX path), `audio` is a fresh full-length buffer, so the
        // pre-normalization copy (~85MB for a 4-min song) is dead weight for the rest of the
        // run. Drop it now to lower peak footprint on memory-constrained iPads.
        if normalization != nil { loadedAudio = StereoAudio(channels: [[], []]) }
        let frameCount = audio.frameCount
        try Task.checkCancellation()

        let strideFrames = segmentFrames - overlapFrames
        let chunkCount = max(
            1,
            Int(ceil(Double(max(frameCount - overlapFrames, 1)) / Double(strideFrames)))
        )
        let totalUnits = chunkCount + 2
        progress(
            StemSeparationProgress(
                phase: .loadingModel,
                completedUnits: 1,
                totalUnits: totalUnits
            ))
        // Stream each finalized region straight to disk as chunks complete, instead of
        // accumulating all six full-length stems in RAM until the end. HTDemucs overlap-add only
        // ever blends two ADJACENT chunks (overlap < stride), so we keep just a one-overlap
        // "carry" of the previous chunk's fade-out tail and write each stride-sized finalized
        // block to the stem WAVs immediately. This bounds accumulation memory to ~one segment
        // regardless of song length — the whole-song buffers scaled with duration and pushed long
        // songs past the iPad memory ceiling.
        let writer = try StreamingStemWriter(
            outputDirectory: request.outputDirectory,
            stems: predictor.supportedStems,
            sampleRate: Self.sampleRate
        )
        var writerFinalized = false
        defer { if !writerFinalized { writer.cleanupStaging() } }

        // Previous chunk's fade-out tail over its overlap region, folded into this chunk's head.
        var carry: [StemKind: [[Float]]]?
        var carryWeights = [Float]()

        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            let chunkStart = chunkIndex * strideFrames
            let chunk = makeChunk(from: audio, start: chunkStart)
            var prediction = try await predictor.predict(chunk)
            if let normalization {
                prediction = Self.denormalized(
                    prediction,
                    mean: normalization.mean,
                    standardDeviation: normalization.standardDeviation
                )
            }
            try validate(prediction)

            let isLast = chunkIndex == chunkCount - 1
            // Frames finalized by this chunk: [chunkStart, finalizeEnd). Every chunk but the last
            // finalizes its stride-sized lead (the trailing overlap is carried forward); the last
            // chunk finalizes everything remaining to the end of the song.
            let finalizeEnd = isLast ? frameCount : min(chunkStart + strideFrames, frameCount)
            let regionLength = max(0, finalizeEnd - chunkStart)

            var regionStems = Dictionary(
                uniqueKeysWithValues: predictor.supportedStems.map {
                    (
                        $0,
                        [
                            [Float](repeating: 0, count: regionLength),
                            [Float](repeating: 0, count: regionLength),
                        ]
                    )
                })
            for localFrame in 0..<regionLength {
                let w0 = chunkWeight(
                    localFrame: localFrame, chunkIndex: chunkIndex, chunkCount: chunkCount)
                let inHead = carry != nil && localFrame < overlapFrames
                let wTotal = inHead ? w0 + carryWeights[localFrame] : w0
                let inverse = 1 / max(wTotal, 1e-6)
                for kind in predictor.supportedStems {
                    for channel in 0..<2 {
                        var value = prediction.samplesByStem[kind]![channel][localFrame] * w0
                        if inHead { value += carry![kind]![channel][localFrame] }
                        regionStems[kind]![channel][localFrame] = value * inverse
                    }
                }
            }
            try writer.append(regionStems, frameCount: regionLength)

            // Carry this chunk's fade-out tail (its overlap with the next chunk) forward.
            if !isLast {
                let tailGlobal = chunkStart + strideFrames
                let tailLength = min(overlapFrames, max(0, frameCount - tailGlobal))
                var nextCarry = Dictionary(
                    uniqueKeysWithValues: predictor.supportedStems.map {
                        (
                            $0,
                            [
                                [Float](repeating: 0, count: overlapFrames),
                                [Float](repeating: 0, count: overlapFrames),
                            ]
                        )
                    })
                var nextWeights = [Float](repeating: 0, count: overlapFrames)
                for j in 0..<tailLength {
                    let localFrame = strideFrames + j
                    let w = chunkWeight(
                        localFrame: localFrame, chunkIndex: chunkIndex, chunkCount: chunkCount)
                    nextWeights[j] = w
                    for kind in predictor.supportedStems {
                        for channel in 0..<2 {
                            nextCarry[kind]![channel][j] =
                                prediction.samplesByStem[kind]![channel][localFrame] * w
                        }
                    }
                }
                carry = nextCarry
                carryWeights = nextWeights
            }

            progress(
                StemSeparationProgress(
                    phase: .separating,
                    completedUnits: chunkIndex + 2,
                    totalUnits: totalUnits
                ))
        }

        try Task.checkCancellation()
        audio = StereoAudio(channels: [[], []])
        progress(
            StemSeparationProgress(
                phase: .writingOutputs,
                completedUnits: totalUnits - 1,
                totalUnits: totalUnits
            ))
        let stemFiles = try writer.finalize()
        writerFinalized = true
        progress(
            StemSeparationProgress(
                phase: .writingOutputs,
                completedUnits: totalUnits,
                totalUnits: totalUnits
            ))
        return StemSeparationResult(
            stems: stemFiles,
            processingDuration: start.duration(to: .now)
        )
    }

    private func makeChunk(from audio: StereoAudio, start: Int) -> StereoAudioChunk {
        var left = [Float](repeating: 0, count: segmentFrames)
        var right = [Float](repeating: 0, count: segmentFrames)
        let available = max(0, min(segmentFrames, audio.frameCount - start))
        if available > 0 {
            left.replaceSubrange(
                0..<available, with: audio.channels[0][start..<(start + available)])
            right.replaceSubrange(
                0..<available, with: audio.channels[1][start..<(start + available)])
        }
        return StereoAudioChunk(left: left, right: right)
    }

    private func validate(_ prediction: StemChunkPrediction) throws {
        for kind in predictor.supportedStems {
            guard
                let channels = prediction.samplesByStem[kind],
                channels.count == 2,
                channels.allSatisfy({ $0.count == segmentFrames })
            else {
                throw CoreMLStemSeparationError.invalidPrediction
            }
        }
    }

    /// The overlap-add fade weight for a frame of a chunk: fade in over the first `overlapFrames`
    /// (except the first chunk) and fade out over the last `overlapFrames` (except the last), so
    /// two adjacent chunks cross-fade across their shared overlap. Identical to the previous
    /// whole-song `accumulate`, just evaluated per frame for the streaming writer.
    private func chunkWeight(localFrame: Int, chunkIndex: Int, chunkCount: Int) -> Float {
        let fadeIn =
            chunkIndex == 0
            ? Float(1)
            : min(1, Float(localFrame + 1) / Float(max(overlapFrames, 1)))
        let fadeOut =
            chunkIndex == chunkCount - 1
            ? Float(1)
            : min(1, Float(segmentFrames - localFrame) / Float(max(overlapFrames, 1)))
        return min(fadeIn, fadeOut)
    }

    private static func normalized(
        _ audio: StereoAudio
    ) -> (audio: StereoAudio, mean: Float, standardDeviation: Float) {
        let frameCount = max(audio.frameCount, 1)
        let mono = (0..<audio.frameCount).map {
            (audio.channels[0][$0] + audio.channels[1][$0]) * 0.5
        }
        let mean = mono.reduce(0, +) / Float(frameCount)
        let variance =
            mono.reduce(Float(0)) { total, sample in
                let delta = sample - mean
                return total + delta * delta
            } / Float(frameCount)
        let standardDeviation = max(sqrt(variance), 1e-8)
        return (
            StereoAudio(
                channels: audio.channels.map { channel in
                    channel.map { ($0 - mean) / standardDeviation }
                }),
            mean,
            standardDeviation
        )
    }

    private static func denormalized(
        _ prediction: StemChunkPrediction,
        mean: Float,
        standardDeviation: Float
    ) -> StemChunkPrediction {
        StemChunkPrediction(
            samplesByStem: prediction.samplesByStem.mapValues { channels in
                channels.map { channel in
                    channel.map { $0 * standardDeviation + mean }
                }
            })
    }

    private static func loadStereoFloatAudio(at url: URL) throws -> StereoAudio {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let inputCapacity = AVAudioFrameCount(file.length)
        guard
            let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: inputCapacity
            )
        else {
            throw CoreMLStemSeparationError.unsupportedAudio
        }
        try file.read(into: input)

        if inputFormat == targetFormat {
            guard let channels = input.floatChannelData else {
                throw CoreMLStemSeparationError.unsupportedAudio
            }
            let frameCount = Int(input.frameLength)
            return StereoAudio(channels: [
                Array(UnsafeBufferPointer(start: channels[0], count: frameCount)),
                Array(UnsafeBufferPointer(start: channels[1], count: frameCount)),
            ])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CoreMLStemSeparationError.unsupportedAudio
        }
        let ratio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        let inputProvider = AudioConverterInputProvider(buffer: input)
        return try StereoAudio(
            channels: drainConverter(
                converter, inputProvider: inputProvider, chunkCapacity: outputCapacity))
    }

    /// Repeatedly pulls from `converter` until it reports `.endOfStream`, appending each pass's
    /// output. A single `convert(to:error:withInputFrom:)` call is NOT guaranteed to fully drain
    /// a resample in one pass — sample-rate conversion can have internal priming/latency that
    /// needs several pulls to flush even after all input has been supplied — so treating one
    /// call's `frameLength` as "the whole answer" (the previous implementation) could silently
    /// return audio shorter than the real source, with everything downstream (chunking, ASR)
    /// faithfully processing that short buffer with no error ever surfaced. Reproduced on a real
    /// song: the separated vocals stem measured ~205s against a 225.6s source, truncating the
    /// last ~20s of transcription with no error and no "untranscribed vocals" flag (that audit
    /// reads the same, already-shortened, voiced intervals).
    private static func drainConverter(
        _ converter: AVAudioConverter,
        inputProvider: AudioConverterInputProvider,
        chunkCapacity: AVAudioFrameCount
    ) throws -> [[Float]] {
        var left: [Float] = []
        var right: [Float] = []
        // Bails out rather than looping forever if the converter ever reports "more to come"
        // while producing nothing, pass after pass.
        var consecutiveEmptyHaveData = 0

        while true {
            guard
                let chunk = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat, frameCapacity: chunkCapacity)
            else {
                throw CoreMLStemSeparationError.unsupportedAudio
            }
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError) { _, flag in
                inputProvider.next(status: flag)
            }
            if let conversionError { throw conversionError }
            guard status != .error else {
                throw CoreMLStemSeparationError.unsupportedAudio
            }

            let count = Int(chunk.frameLength)
            if count > 0, let channels = chunk.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
                right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: count))
            }

            if status == .endOfStream { break }
            if status == .haveData, count == 0 {
                consecutiveEmptyHaveData += 1
                guard consecutiveEmptyHaveData < 8 else {
                    throw CoreMLStemSeparationError.unsupportedAudio
                }
            } else {
                consecutiveEmptyHaveData = 0
            }
        }
        return [left, right]
    }
}

private struct StereoAudio: Sendable {
    let channels: [[Float]]
    var frameCount: Int { channels[0].count }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

actor CoreMLStemChunkPredictor: StemChunkPredicting {
    private static let expectedShape = [1, 4, 2, 441_000]
    private let model: MLModel
    let supportedStems = StemKind.legacyRequired

    static func halfPrecisionFloatValue(bitPattern: UInt16) -> Float {
        let sign: Float = (bitPattern & 0x8000) == 0 ? 1 : -1
        let exponent = Int((bitPattern >> 10) & 0x1F)
        let fraction = Int(bitPattern & 0x03FF)

        if exponent == 0 {
            guard fraction != 0 else { return sign == 1 ? 0 : -0 }
            return sign * Float(fraction) / 1_024 * pow(2, -14)
        }
        if exponent == 0x1F {
            return fraction == 0 ? sign * .infinity : .nan
        }
        return sign * (1 + Float(fraction) / 1_024) * pow(2, Float(exponent - 15))
    }

    init(modelURL: URL) throws {
        let loadURL: URL
        if modelURL.pathExtension == "mlpackage" || modelURL.pathExtension == "mlmodel" {
            loadURL = try MLModel.compileModel(at: modelURL)
        } else {
            loadURL = modelURL
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: loadURL, configuration: configuration)
    }

    func predict(_ chunk: StereoAudioChunk) throws -> StemChunkPrediction {
        guard chunk.frameCount == 441_000 else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        return try autoreleasepool {
            let input = try MLMultiArray(
                shape: [1, 2, NSNumber(value: chunk.frameCount)],
                dataType: .float32
            )
            let inputStrides = input.strides.map(\.intValue)
            let inputPointer = input.dataPointer.bindMemory(
                to: Float.self,
                capacity: input.count
            )
            for channel in 0..<2 {
                for frame in 0..<chunk.frameCount {
                    inputPointer[channel * inputStrides[1] + frame * inputStrides[2]] =
                        chunk.channels[channel][frame]
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
            let prediction = try model.prediction(from: provider)
            guard
                let output = prediction.featureValue(for: "sources")?.multiArrayValue,
                output.shape.map(\.intValue) == Self.expectedShape
            else {
                throw CoreMLStemSeparationError.invalidPrediction
            }
            let strides = output.strides.map(\.intValue)
            let float16Pointer =
                output.dataType == .float16
                ? output.dataPointer.bindMemory(to: UInt16.self, capacity: output.count)
                : nil
            let float32Pointer =
                output.dataType == .float32
                ? output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
                : nil
            guard float16Pointer != nil || float32Pointer != nil else {
                throw CoreMLStemSeparationError.invalidPrediction
            }

            var stems: [StemKind: [[Float]]] = [:]
            for (stemIndex, kind) in supportedStems.enumerated() {
                var channels = [
                    [Float](repeating: 0, count: chunk.frameCount),
                    [Float](repeating: 0, count: chunk.frameCount),
                ]
                for channel in 0..<2 {
                    for frame in 0..<chunk.frameCount {
                        let offset =
                            stemIndex * strides[1]
                            + channel * strides[2]
                            + frame * strides[3]
                        channels[channel][frame] =
                            float16Pointer.map {
                                Self.halfPrecisionFloatValue(bitPattern: $0[offset])
                            }
                            ?? float32Pointer![offset]
                    }
                }
                stems[kind] = channels
            }
            return StemChunkPrediction(samplesByStem: stems)
        }
    }
}

/// Writes stem WAVs incrementally as the separation streams finalized regions, so the whole song
/// never has to be held in RAM at once. Each stem (plus the guitar+piano+other accompaniment
/// mixdown) gets one `AVAudioFile` opened up front in a staging directory; `append` writes the
/// next block to every file, and `finalize` closes them and atomically swaps staging into place.
private final class StreamingStemWriter {
    private let fileManager = FileManager.default
    private let outputDirectory: URL
    private let staging: URL
    private let format: AVAudioFormat
    private let stems: [StemKind]
    private let includeAccompaniment: Bool
    private var files: [StemKind: AVAudioFile] = [:]
    private var accompanimentFile: AVAudioFile?

    init(outputDirectory: URL, stems: [StemKind], sampleRate: Double) throws {
        self.outputDirectory = outputDirectory
        self.stems = stems
        self.includeAccompaniment = stems.contains(.guitar) && stems.contains(.piano)
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2,
            interleaved: false)!
        let parent = outputDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        staging = parent.appendingPathComponent(
            ".\(outputDirectory.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for kind in stems {
            files[kind] = try AVAudioFile(
                forWriting: staging.appendingPathComponent("\(kind.rawValue).wav"),
                settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        if includeAccompaniment {
            accompanimentFile = try AVAudioFile(
                forWriting: staging.appendingPathComponent("accompaniment.wav"),
                settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    func append(_ region: [StemKind: [[Float]]], frameCount: Int) throws {
        guard frameCount > 0 else { return }
        for kind in stems {
            guard let channels = region[kind], channels.count == 2 else {
                throw CoreMLStemSeparationError.invalidPrediction
            }
            guard channels.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
                throw CoreMLStemSeparationError.invalidOutput(kind)
            }
            try write(channels, to: files[kind]!, frameCount: frameCount)
        }
        if includeAccompaniment, let accompanimentFile {
            var accompaniment = [
                [Float](repeating: 0, count: frameCount),
                [Float](repeating: 0, count: frameCount),
            ]
            for channel in 0..<2 {
                guard
                    let other = region[.other]?[channel],
                    let guitar = region[.guitar]?[channel],
                    let piano = region[.piano]?[channel]
                else { throw CoreMLStemSeparationError.invalidPrediction }
                for frame in 0..<frameCount {
                    accompaniment[channel][frame] = other[frame] + guitar[frame] + piano[frame]
                }
            }
            try write(accompaniment, to: accompanimentFile, frameCount: frameCount)
        }
    }

    private func write(_ channels: [[Float]], to file: AVAudioFile, frameCount: Int) throws {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        buffer.floatChannelData![0].update(from: channels[0], count: frameCount)
        buffer.floatChannelData![1].update(from: channels[1], count: frameCount)
        try file.write(from: buffer)
    }

    func finalize() throws -> StemFiles {
        // Close every file (AVAudioFile flushes/closes on deinit) before moving the directory.
        files.removeAll()
        accompanimentFile = nil
        if fileManager.fileExists(atPath: outputDirectory.path) {
            _ = try fileManager.replaceItemAt(
                outputDirectory, withItemAt: staging, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: staging, to: outputDirectory)
        }
        return StemFiles(
            vocals: outputDirectory.appendingPathComponent("vocals.wav"),
            drums: outputDirectory.appendingPathComponent("drums.wav"),
            bass: outputDirectory.appendingPathComponent("bass.wav"),
            guitar: stems.contains(.guitar)
                ? outputDirectory.appendingPathComponent("guitar.wav") : nil,
            piano: stems.contains(.piano)
                ? outputDirectory.appendingPathComponent("piano.wav") : nil,
            other: outputDirectory.appendingPathComponent("other.wav"),
            accompaniment: includeAccompaniment
                ? outputDirectory.appendingPathComponent("accompaniment.wav") : nil
        )
    }

    func cleanupStaging() {
        files.removeAll()
        accompanimentFile = nil
        try? fileManager.removeItem(at: staging)
    }
}
