import CoreML
import Foundation

/// Native Core ML htdemucs_6s (tools/demucs_export/export_coreml.py): the same six-stem model as
/// the ONNX path, but as a single FP16 mlprogram — 0.48 s per 7.8 s chunk against ~1.7 s on the
/// ONNX CPU path (Benchmarks/STEM_SEPARATION.md, 2026-08-26), and it runs on the GPU, leaving the
/// CPU free for the transcription and refinement phases that now run concurrently.
///
/// Compute units are pinned to `.all` and are NOT a tuning knob: `.cpuOnly` produced 9.7 dB stems
/// (numerically wrong, not merely slow) and `.cpuAndGPU` with FP32 ops ran 90 s per chunk. Any
/// future change here must re-run the per-unit SDR table in the benchmark.
struct CoreMLNativeSixStemSeparationEngine: StemSeparationEngine, Sendable {
    static let metadata = StemSeparationEngineMetadata(
        engineIdentifier: "coreml-native-htdemucs-6s",
        engineVersion: "1",
        modelIdentifier: "htdemucs-6s-coreml-fp16",
        modelVersion: "1"
    )

    private let engine: CoreMLStemSeparationEngine
    let metadata: StemSeparationEngineMetadata

    init(modelURL: URL) async throws {
        metadata = Self.metadata
        let predictor = try await CoreMLSixStemChunkPredictor(modelURL: modelURL)
        engine = CoreMLStemSeparationEngine(
            predictor: predictor,
            // Identical chunking to the ONNX engine, so stitching behavior — and everything
            // downstream that was validated against it — carries over unchanged.
            segmentFrames: ONNXSixStemSeparationEngine.defaultSegmentFrames,
            overlapFrames: ONNXSixStemSeparationEngine.defaultSegmentFrames / 4,
            normalizesAudio: true,
            metadata: Self.metadata
        )
    }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        try await engine.separate(request: request, progress: progress)
    }
}

actor CoreMLSixStemChunkPredictor: StemChunkPredicting {
    /// demucs source order; matches the export and the ONNX predictor.
    private static let modelOutputOrder: [StemKind] = [
        .drums, .bass, .other, .vocals, .guitar, .piano,
    ]

    nonisolated let supportedStems = StemKind.allCases

    private var model: MLModel?
    private let frameCount: Int

    func releaseResources() {
        model = nil
    }

    init(
        modelURL: URL,
        frameCount: Int = ONNXSixStemSeparationEngine.defaultSegmentFrames
    ) async throws {
        self.frameCount = frameCount
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(
            contentsOf: await Self.compiledModelURL(for: modelURL),
            configuration: configuration
        )
    }

    /// Compiling the 172 MB mlpackage takes seconds; cache the .mlmodelc beside the app's other
    /// caches and reuse it while it is newer than its source.
    private static func compiledModelURL(for modelURL: URL) async throws -> URL {
        if modelURL.pathExtension == "mlmodelc" { return modelURL }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SongWorkbench", isDirectory: true)
            .appendingPathComponent("CompiledModels", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let cached = caches.appendingPathComponent(
            modelURL.deletingPathExtension().lastPathComponent + ".mlmodelc", isDirectory: true)
        let sourceDate =
            (try? modelURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let cachedDate =
            (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let sourceDate, let cachedDate, cachedDate >= sourceDate {
            return cached
        }
        let compiled = try await MLModel.compileModel(at: modelURL)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: compiled, to: cached)
        return cached
    }

    func predict(_ chunk: StereoAudioChunk) async throws -> StemChunkPrediction {
        guard chunk.frameCount == frameCount, chunk.channels.count == 2 else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        guard let model else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        // Per-chunk autorelease: Core ML prediction objects accumulate otherwise and a full song
        // crashed the June 4-stem benchmark without this.
        return try autoreleasepool {
            let input = try MLMultiArray(
                shape: [1, 2, NSNumber(value: frameCount)], dataType: .float32)
            let inputPointer = input.dataPointer.bindMemory(
                to: Float.self, capacity: 2 * frameCount)
            for channel in 0..<2 {
                chunk.channels[channel].withUnsafeBufferPointer { buffer in
                    inputPointer.advanced(by: channel * frameCount)
                        .update(from: buffer.baseAddress!, count: frameCount)
                }
            }
            let output = try model.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
            guard
                let array = output.featureValue(for: "output")?.multiArrayValue,
                array.shape.map(\.intValue) == [1, 6, 2, frameCount]
            else {
                throw CoreMLStemSeparationError.invalidPrediction
            }
            let stems = Self.extractStems(from: array, frameCount: frameCount)
            guard stems.count == Self.modelOutputOrder.count else {
                throw CoreMLStemSeparationError.invalidPrediction
            }
            return StemChunkPrediction(samplesByStem: stems)
        }
    }

    /// The mlprogram may hand back FLOAT16 with padded strides despite the interface declaring
    /// Float32 contiguous (observed on the June package) — honor `dataType` and `strides`.
    private static func extractStems(
        from array: MLMultiArray, frameCount: Int
    ) -> [StemKind: [[Float]]] {
        let strides = array.strides.map(\.intValue)
        var stems: [StemKind: [[Float]]] = [:]
        for (sourceIndex, kind) in modelOutputOrder.enumerated() {
            var channels = [[Float]]()
            channels.reserveCapacity(2)
            for channel in 0..<2 {
                let base = sourceIndex * strides[1] + channel * strides[2]
                var samples = [Float](repeating: 0, count: frameCount)
                switch array.dataType {
                case .float32:
                    let pointer = array.dataPointer.bindMemory(
                        to: Float.self, capacity: base + frameCount * strides[3])
                    for frame in 0..<frameCount {
                        samples[frame] = pointer[base + frame * strides[3]]
                    }
                case .float16:
                    let pointer = array.dataPointer.bindMemory(
                        to: Float16.self, capacity: base + frameCount * strides[3])
                    for frame in 0..<frameCount {
                        samples[frame] = Float(pointer[base + frame * strides[3]])
                    }
                default:
                    return [:]
                }
                channels.append(samples)
            }
            stems[kind] = channels
        }
        return stems
    }
}
