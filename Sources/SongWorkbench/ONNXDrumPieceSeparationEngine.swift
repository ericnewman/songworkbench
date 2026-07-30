import Foundation
import OnnxRuntimeBindings

/// Separates a drums parent stem into kick / snare / cymbals / toms using the
/// Gridshift DrumSep Hybrid-Demucs ONNX export.
///
/// Intermediate `StemKind` slots are only a transport mapping for
/// `NativeStemRefinementEngine`:
/// vocals→kick, drums→snare, bass→cymbals, other→toms.
struct ONNXDrumPieceSeparationEngine: StemSeparationEngine, Sendable {
    static let segmentFrames = 1_764_000
    static let overlapFrames = 882_000

    private let engine: CoreMLStemSeparationEngine
    let metadata: StemSeparationEngineMetadata

    static let metadata = StemSeparationEngineMetadata(
        engineIdentifier: "onnxruntime-cpu-drumsep",
        engineVersion: "1",
        modelIdentifier: "drumsep-onnx",
        modelVersion: "1.0.0"
    )

    /// StemKind transport order matching DrumSep manifest
    /// `["kick", "snare", "cymbals", "toms"]`.
    static let modelOutputOrder: [StemKind] = [.vocals, .drums, .bass, .other]

    static let refinementOutputs: [NativeStemRefinementOutput] = [
        NativeStemRefinementOutput(
            modelOutputID: StemKind.vocals.id,
            id: .drumKick,
            displayName: "Kick",
            order: 100
        ),
        NativeStemRefinementOutput(
            modelOutputID: StemKind.drums.id,
            id: .drumSnare,
            displayName: "Snare",
            order: 101
        ),
        NativeStemRefinementOutput(
            modelOutputID: StemKind.bass.id,
            id: .drumCymbals,
            displayName: "Cymbals",
            order: 102
        ),
        NativeStemRefinementOutput(
            modelOutputID: StemKind.other.id,
            id: .drumToms,
            displayName: "Toms",
            order: 103
        ),
    ]

    init(modelURL: URL) throws {
        let predictor = try ONNXDrumPieceChunkPredictor(modelURL: modelURL)
        metadata = Self.metadata
        engine = CoreMLStemSeparationEngine(
            predictor: predictor,
            segmentFrames: Self.segmentFrames,
            overlapFrames: Self.overlapFrames,
            normalizesAudio: false,
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

actor ONNXDrumPieceChunkPredictor: StemChunkPredicting {
    let supportedStems = ONNXDrumPieceSeparationEngine.modelOutputOrder

    private var session: ORTSession?
    private let frameCount: Int

    func releaseResources() {
        session = nil
    }

    init(modelURL: URL, frameCount: Int = ONNXDrumPieceSeparationEngine.segmentFrames) throws {
        self.frameCount = frameCount
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        #if os(macOS)
            let threadCount = Int32(max(ProcessInfo.processInfo.activeProcessorCount - 1, 1))
        #else
            let threadCount = Int32(
                min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 1), 4))
        #endif
        try options.setIntraOpNumThreads(threadCount)
        session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
    }

    func predict(_ chunk: StereoAudioChunk) async throws -> StemChunkPrediction {
        try autoreleasepool {
            try predictRetainingOnlySwiftOutput(chunk)
        }
    }

    private func predictRetainingOnlySwiftOutput(
        _ chunk: StereoAudioChunk
    ) throws -> StemChunkPrediction {
        guard chunk.frameCount == frameCount else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        guard let session else {
            throw CoreMLStemSeparationError.invalidPrediction
        }

        let mixData = NSMutableData(length: 2 * frameCount * MemoryLayout<Float>.size)!
        let mixPointer = mixData.mutableBytes.bindMemory(to: Float.self, capacity: 2 * frameCount)
        for channel in 0..<2 {
            mixPointer.advanced(by: channel * frameCount).update(
                from: chunk.channels[channel],
                count: frameCount
            )
        }
        let mix = try ORTValue(
            tensorData: mixData,
            elementType: .float,
            shape: [1, 2, NSNumber(value: frameCount)]
        )

        let features = try HybridDemucsFrequencyFeatures.complexChannelFeatures(
            left: chunk.channels[0],
            right: chunk.channels[1]
        )
        let frequencyBins = HybridDemucsFrequencyFeatures.frequencyBins
        let featureFrames = HybridDemucsFrequencyFeatures.frameCount(forSampleCount: frameCount)
        guard
            features.count == 4,
            features.allSatisfy({
                $0.count == frequencyBins && $0.allSatisfy({ $0.count == featureFrames })
            })
        else {
            throw CoreMLStemSeparationError.invalidPrediction
        }

        let magCount = 4 * frequencyBins * featureFrames
        let magData = NSMutableData(length: magCount * MemoryLayout<Float>.size)!
        let magPointer = magData.mutableBytes.bindMemory(to: Float.self, capacity: magCount)
        var offset = 0
        for channel in 0..<4 {
            for bin in 0..<frequencyBins {
                for frame in 0..<featureFrames {
                    magPointer[offset] = features[channel][bin][frame]
                    offset += 1
                }
            }
        }
        let mag = try ORTValue(
            tensorData: magData,
            elementType: .float,
            shape: [
                1,
                4,
                NSNumber(value: frequencyBins),
                NSNumber(value: featureFrames),
            ]
        )

        let outputs = try session.run(
            withInputs: [
                "mix": mix,
                "mag": mag,
            ],
            outputNames: ["time_out"],
            runOptions: nil
        )
        guard let output = outputs["time_out"] else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        guard shape == [1, 4, 2, frameCount] else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputData = try output.tensorData()
        let expectedFloats = 4 * 2 * frameCount
        guard outputData.length == expectedFloats * MemoryLayout<Float>.size else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputPointer = outputData.bytes.bindMemory(to: Float.self, capacity: expectedFloats)

        var stems: [StemKind: [[Float]]] = [:]
        for (sourceIndex, kind) in ONNXDrumPieceSeparationEngine.modelOutputOrder.enumerated() {
            var channels = [[Float]]()
            channels.reserveCapacity(2)
            for channel in 0..<2 {
                let stemOffset = (sourceIndex * 2 + channel) * frameCount
                channels.append(
                    Array(
                        UnsafeBufferPointer(
                            start: outputPointer.advanced(by: stemOffset),
                            count: frameCount
                        )))
            }
            stems[kind] = channels
        }
        return StemChunkPrediction(samplesByStem: stems)
    }
}
