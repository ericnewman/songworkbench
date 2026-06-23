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
        let loadedAudio = try await Task.detached(priority: .userInitiated) {
            try Self.loadStereoFloatAudio(at: request.inputURL)
        }.value
        let normalization = normalizesAudio ? Self.normalized(loadedAudio) : nil
        let audio = normalization?.audio ?? loadedAudio
        try Task.checkCancellation()

        let strideFrames = segmentFrames - overlapFrames
        let chunkCount = max(
            1,
            Int(ceil(Double(max(audio.frameCount - overlapFrames, 1)) / Double(strideFrames)))
        )
        let totalUnits = chunkCount + 2
        progress(
            StemSeparationProgress(
                phase: .loadingModel,
                completedUnits: 1,
                totalUnits: totalUnits
            ))
        var stems = Dictionary(
            uniqueKeysWithValues: predictor.supportedStems.map { kind in
                (
                    kind,
                    [
                        [Float](repeating: 0, count: audio.frameCount),
                        [Float](repeating: 0, count: audio.frameCount),
                    ]
                )
            })
        var weights = [Float](repeating: 0, count: audio.frameCount)

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
            accumulate(
                prediction,
                into: &stems,
                weights: &weights,
                start: chunkStart,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                outputFrameCount: audio.frameCount
            )
            progress(
                StemSeparationProgress(
                    phase: .separating,
                    completedUnits: chunkIndex + 2,
                    totalUnits: totalUnits
                ))
        }
        normalize(&stems, weights: weights)
        try validate(stems)
        try Task.checkCancellation()

        progress(
            StemSeparationProgress(
                phase: .writingOutputs,
                completedUnits: totalUnits - 1,
                totalUnits: totalUnits
            ))
        let stemFiles = try publishAtomically(
            stems,
            frameCount: audio.frameCount,
            outputDirectory: request.outputDirectory
        )
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

    private func accumulate(
        _ prediction: StemChunkPrediction,
        into stems: inout [StemKind: [[Float]]],
        weights: inout [Float],
        start: Int,
        chunkIndex: Int,
        chunkCount: Int,
        outputFrameCount: Int
    ) {
        for localFrame in 0..<segmentFrames {
            let globalFrame = start + localFrame
            guard globalFrame < outputFrameCount else { break }
            let fadeIn =
                chunkIndex == 0
                ? Float(1)
                : min(1, Float(localFrame + 1) / Float(max(overlapFrames, 1)))
            let fadeOut =
                chunkIndex == chunkCount - 1
                ? Float(1)
                : min(1, Float(segmentFrames - localFrame) / Float(max(overlapFrames, 1)))
            let weight = min(fadeIn, fadeOut)
            weights[globalFrame] += weight
            for kind in predictor.supportedStems {
                for channel in 0..<2 {
                    stems[kind]![channel][globalFrame] +=
                        prediction.samplesByStem[kind]![channel][localFrame] * weight
                }
            }
        }
    }

    private func normalize(
        _ stems: inout [StemKind: [[Float]]],
        weights: [Float]
    ) {
        for frame in weights.indices {
            let weight = max(weights[frame], 1e-6)
            for kind in predictor.supportedStems {
                stems[kind]![0][frame] /= weight
                stems[kind]![1][frame] /= weight
            }
        }
    }

    private func validate(_ stems: [StemKind: [[Float]]]) throws {
        for kind in predictor.supportedStems {
            guard let channels = stems[kind], channels.joined().allSatisfy(\.isFinite) else {
                throw CoreMLStemSeparationError.invalidOutput(kind)
            }
        }
    }

    private func publishAtomically(
        _ stems: [StemKind: [[Float]]],
        frameCount: Int,
        outputDirectory: URL
    ) throws -> StemFiles {
        let fileManager = FileManager.default
        let parent = outputDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(outputDirectory.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        )!
        for kind in predictor.supportedStems {
            try Task.checkCancellation()
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )!
            buffer.frameLength = AVAudioFrameCount(frameCount)
            buffer.floatChannelData![0].update(from: stems[kind]![0], count: frameCount)
            buffer.floatChannelData![1].update(from: stems[kind]![1], count: frameCount)
            let file = try AVAudioFile(
                forWriting: staging.appendingPathComponent("\(kind.rawValue).wav"),
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        let accompanimentURL: URL?
        if predictor.supportedStems.contains(.guitar), predictor.supportedStems.contains(.piano) {
            var accompaniment = [
                [Float](repeating: 0, count: frameCount),
                [Float](repeating: 0, count: frameCount),
            ]
            for channel in 0..<2 {
                guard
                    let other = stems[.other]?[channel],
                    let guitar = stems[.guitar]?[channel],
                    let piano = stems[.piano]?[channel]
                else {
                    throw CoreMLStemSeparationError.invalidPrediction
                }
                for frame in 0..<frameCount {
                    accompaniment[channel][frame] = other[frame] + guitar[frame] + piano[frame]
                }
            }
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )!
            buffer.frameLength = AVAudioFrameCount(frameCount)
            buffer.floatChannelData![0].update(from: accompaniment[0], count: frameCount)
            buffer.floatChannelData![1].update(from: accompaniment[1], count: frameCount)
            let file = try AVAudioFile(
                forWriting: staging.appendingPathComponent("accompaniment.wav"),
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
            accompanimentURL = outputDirectory.appendingPathComponent("accompaniment.wav")
        } else {
            accompanimentURL = nil
        }

        if fileManager.fileExists(atPath: outputDirectory.path) {
            _ = try fileManager.replaceItemAt(
                outputDirectory,
                withItemAt: staging,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: staging, to: outputDirectory)
        }
        return StemFiles(
            vocals: outputDirectory.appendingPathComponent("vocals.wav"),
            drums: outputDirectory.appendingPathComponent("drums.wav"),
            bass: outputDirectory.appendingPathComponent("bass.wav"),
            guitar: predictor.supportedStems.contains(.guitar)
                ? outputDirectory.appendingPathComponent("guitar.wav") : nil,
            piano: predictor.supportedStems.contains(.piano)
                ? outputDirectory.appendingPathComponent("piano.wav") : nil,
            other: outputDirectory.appendingPathComponent("other.wav"),
            accompaniment: accompanimentURL
        )
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

        let output: AVAudioPCMBuffer
        if inputFormat == targetFormat {
            output = input
        } else {
            let ratio = sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
            guard
                let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputCapacity
                ),
                let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            else {
                throw CoreMLStemSeparationError.unsupportedAudio
            }
            var conversionError: NSError?
            let inputProvider = AudioConverterInputProvider(buffer: input)
            let status = converter.convert(to: converted, error: &conversionError) { _, flag in
                inputProvider.next(status: flag)
            }
            if let conversionError { throw conversionError }
            guard status != .error else {
                throw CoreMLStemSeparationError.unsupportedAudio
            }
            output = converted
        }
        guard let channels = output.floatChannelData else {
            throw CoreMLStemSeparationError.unsupportedAudio
        }
        let frameCount = Int(output.frameLength)
        return StereoAudio(channels: [
            Array(UnsafeBufferPointer(start: channels[0], count: frameCount)),
            Array(UnsafeBufferPointer(start: channels[1], count: frameCount)),
        ])
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
