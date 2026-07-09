import Foundation
import OnnxRuntimeBindings

struct ONNXSixStemSeparationEngine: StemSeparationEngine, Sendable {
    /// Full-quality 7.8s segment used on macOS (ample RAM). Must match the stock
    /// demucsv4.onnx fixed input length.
    static let defaultSegmentFrames = 343_980
    /// Shorter 3.5s segment bundled on iPad so the FP32 forward pass fits the per-process
    /// memory limit (onnxruntime peak ~1.95GB vs ~3.46GB at 7.8s). Same six stems; validated
    /// against the 7.8s model at 79dB SDR. Must match the bundled export's fixed input length.
    static let iPadSegmentFrames = 154_350

    private let engine: CoreMLStemSeparationEngine

    let metadata: StemSeparationEngineMetadata

    static func metadata(usesCoreML: Bool, segmentFrames: Int) -> StemSeparationEngineMetadata {
        StemSeparationEngineMetadata(
            engineIdentifier: usesCoreML
                ? "onnxruntime-coreml-htdemucs-6s" : "onnxruntime-cpu-htdemucs-6s",
            // engineVersion 2 -> 3 fixed the AVAudioConverter under-drain truncation. Keep the
            // historical "3" cache key for the default 7.8s segment; any other segment gets its
            // own key so its stems never alias with the 7.8s ones.
            engineVersion: segmentFrames == defaultSegmentFrames ? "3" : "3-seg\(segmentFrames)",
            modelIdentifier: "htdemucs-6s-onnx",
            modelVersion: "125b3e0"
        )
    }

    static let cpuMetadata = metadata(usesCoreML: false, segmentFrames: defaultSegmentFrames)
    static let coreMLMetadata = metadata(usesCoreML: true, segmentFrames: defaultSegmentFrames)

    /// Metadata for the stem engine actually used on THIS platform — the caching policy must
    /// key on this so iPad's 3.5s stems and macOS's 7.8s stems never alias.
    static var currentPlatformMetadata: StemSeparationEngineMetadata {
        #if os(macOS)
            return cpuMetadata
        #else
            return metadata(usesCoreML: false, segmentFrames: iPadSegmentFrames)
        #endif
    }

    init(
        modelURL: URL,
        usesCoreMLExecutionProvider: Bool = false,
        segmentFrames: Int = defaultSegmentFrames
    ) throws {
        let meta = Self.metadata(
            usesCoreML: usesCoreMLExecutionProvider, segmentFrames: segmentFrames)
        let predictor = try ONNXSixStemChunkPredictor(
            modelURL: modelURL,
            usesCoreMLExecutionProvider: usesCoreMLExecutionProvider,
            frameCount: segmentFrames
        )
        self.metadata = meta
        engine = CoreMLStemSeparationEngine(
            predictor: predictor,
            segmentFrames: segmentFrames,
            overlapFrames: segmentFrames / 4,
            normalizesAudio: true,
            metadata: meta
        )
    }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        try await engine.separate(request: request, progress: progress)
    }
}

actor ONNXSixStemChunkPredictor: StemChunkPredicting {
    private static let modelOutputOrder: [StemKind] = [
        .drums, .bass, .other, .vocals, .guitar, .piano,
    ]

    let supportedStems = StemKind.allCases

    private let session: ORTSession
    private let frameCount: Int

    init(
        modelURL: URL,
        usesCoreMLExecutionProvider: Bool = false,
        frameCount: Int = 343_980
    ) throws {
        self.frameCount = frameCount
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        let threadCount = Int32(max(ProcessInfo.processInfo.activeProcessorCount - 1, 1))
        try options.setIntraOpNumThreads(threadCount)
        if usesCoreMLExecutionProvider, ORTIsCoreMLExecutionProviderAvailable() {
            let coreMLOptions = ORTCoreMLExecutionProviderOptions()
            coreMLOptions.enableOnSubgraphs = true
            try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        }
        session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
    }

    func predict(_ chunk: StereoAudioChunk) throws -> StemChunkPrediction {
        guard chunk.frameCount == frameCount else {
            throw CoreMLStemSeparationError.invalidPrediction
        }

        let inputData = NSMutableData(length: 2 * frameCount * MemoryLayout<Float>.size)!
        let inputPointer = inputData.mutableBytes.bindMemory(
            to: Float.self,
            capacity: 2 * frameCount
        )
        for channel in 0..<2 {
            inputPointer.advanced(by: channel * frameCount).update(
                from: chunk.channels[channel],
                count: frameCount
            )
        }
        let input = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [1, 2, NSNumber(value: frameCount)]
        )
        let outputs = try session.run(
            withInputs: ["input": input],
            outputNames: ["output"],
            runOptions: nil
        )
        guard let output = outputs["output"] else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        guard shape == [1, 6, 2, frameCount] else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputData = try output.tensorData()
        let expectedFloats = 6 * 2 * frameCount
        guard outputData.length == expectedFloats * MemoryLayout<Float>.size else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputPointer = outputData.bytes.bindMemory(
            to: Float.self,
            capacity: expectedFloats
        )

        var stems: [StemKind: [[Float]]] = [:]
        for (sourceIndex, kind) in Self.modelOutputOrder.enumerated() {
            var channels = [[Float]]()
            channels.reserveCapacity(2)
            for channel in 0..<2 {
                let offset = (sourceIndex * 2 + channel) * frameCount
                channels.append(
                    Array(
                        UnsafeBufferPointer(
                            start: outputPointer.advanced(by: offset),
                            count: frameCount
                        )))
            }
            stems[kind] = channels
        }
        return StemChunkPrediction(samplesByStem: stems)
    }
}
