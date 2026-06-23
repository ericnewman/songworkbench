import Foundation
import OnnxRuntimeBindings

struct ONNXSixStemSeparationEngine: StemSeparationEngine, Sendable {
    private static let segmentFrames = 343_980
    private static let overlapFrames = segmentFrames / 4

    private let engine: CoreMLStemSeparationEngine

    let metadata: StemSeparationEngineMetadata

    static let cpuMetadata = StemSeparationEngineMetadata(
        engineIdentifier: "onnxruntime-cpu-htdemucs-6s",
        engineVersion: "2",
        modelIdentifier: "htdemucs-6s-onnx",
        modelVersion: "125b3e0"
    )

    static let coreMLMetadata = StemSeparationEngineMetadata(
        engineIdentifier: "onnxruntime-coreml-htdemucs-6s",
        engineVersion: "2",
        modelIdentifier: "htdemucs-6s-onnx",
        modelVersion: "125b3e0"
    )

    init(modelURL: URL, usesCoreMLExecutionProvider: Bool = false) throws {
        let metadata = usesCoreMLExecutionProvider ? Self.coreMLMetadata : Self.cpuMetadata
        let predictor = try ONNXSixStemChunkPredictor(
            modelURL: modelURL,
            usesCoreMLExecutionProvider: usesCoreMLExecutionProvider
        )
        self.metadata = metadata
        engine = CoreMLStemSeparationEngine(
            predictor: predictor,
            segmentFrames: Self.segmentFrames,
            overlapFrames: Self.overlapFrames,
            normalizesAudio: true,
            metadata: metadata
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
    private static let frameCount = 343_980
    private static let modelOutputOrder: [StemKind] = [
        .drums, .bass, .other, .vocals, .guitar, .piano,
    ]

    let supportedStems = StemKind.allCases

    private let session: ORTSession

    init(modelURL: URL, usesCoreMLExecutionProvider: Bool = false) throws {
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
        guard chunk.frameCount == Self.frameCount else {
            throw CoreMLStemSeparationError.invalidPrediction
        }

        let inputData = NSMutableData(length: 2 * Self.frameCount * MemoryLayout<Float>.size)!
        let inputPointer = inputData.mutableBytes.bindMemory(
            to: Float.self,
            capacity: 2 * Self.frameCount
        )
        for channel in 0..<2 {
            inputPointer.advanced(by: channel * Self.frameCount).update(
                from: chunk.channels[channel],
                count: Self.frameCount
            )
        }
        let input = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [1, 2, NSNumber(value: Self.frameCount)]
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
        guard shape == [1, 6, 2, Self.frameCount] else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputData = try output.tensorData()
        let expectedFloats = 6 * 2 * Self.frameCount
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
                let offset = (sourceIndex * 2 + channel) * Self.frameCount
                channels.append(
                    Array(
                        UnsafeBufferPointer(
                            start: outputPointer.advanced(by: offset),
                            count: Self.frameCount
                        )))
            }
            stems[kind] = channels
        }
        return StemChunkPrediction(samplesByStem: stems)
    }
}
