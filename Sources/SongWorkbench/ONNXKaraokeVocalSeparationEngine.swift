import Foundation
import OnnxRuntimeBindings

/// Splits a vocals parent stem into lead and backing vocals using our own waveform-in /
/// waveform-out export of the anvuew karaoke BS-RoFormer (`tools/karaoke_export/`).
///
/// Unlike `ONNXDrumPieceSeparationEngine`, this model carries its OWN STFT and inverse STFT
/// inside the exported graph, so there is no frequency-feature packing here and no
/// `HybridDemucsFrequencyFeatures` involvement — the predictor hands it raw samples and gets raw
/// samples back. That was the whole point of exporting it ourselves: the codebase has no ISTFT,
/// and a hand-rolled one would produce artifacts indistinguishable from model quality problems.
///
/// The model emits ONE stem (lead vocals). Backing is derived as `parent - lead`, so the two
/// children sum back to the parent by construction.
///
/// Intermediate `StemKind` slots are only a transport mapping for `NativeStemRefinementEngine`:
/// vocals→lead, other→backing.
struct ONNXKaraokeVocalSeparationEngine: StemSeparationEngine, Sendable {
    /// Fixed by the export. The training chunk (640000) OOMs the ONNX tracer, so the graph is
    /// built at 262144 samples (5.9 s at 44.1 kHz) and the input tensor shape is baked in.
    static let segmentFrames = 262_144
    /// Quarter-segment overlap, matching the base six-stem engine's ratio.
    static let overlapFrames = segmentFrames / 4

    private let engine: CoreMLStemSeparationEngine
    let metadata: StemSeparationEngineMetadata

    static let metadata = StemSeparationEngineMetadata(
        engineIdentifier: "onnxruntime-cpu-karaoke-bsroformer",
        engineVersion: "1",
        modelIdentifier: "karaoke-bsroformer-onnx",
        modelVersion: "anvuew-1"
    )

    /// Transport order: slot 0 carries lead, slot 1 carries backing.
    static let modelOutputOrder: [StemKind] = [.vocals, .other]

    static let refinementOutputs: [NativeStemRefinementOutput] = [
        NativeStemRefinementOutput(
            modelOutputID: StemKind.vocals.id,
            id: .vocalLead,
            displayName: "Lead Vocals",
            order: 200
        ),
        NativeStemRefinementOutput(
            modelOutputID: StemKind.other.id,
            id: .vocalBacking,
            displayName: "Backing Vocals",
            order: 201
        ),
    ]

    init(modelURL: URL) throws {
        let predictor = try ONNXKaraokeChunkPredictor(modelURL: modelURL)
        metadata = Self.metadata
        engine = CoreMLStemSeparationEngine(
            predictor: predictor,
            segmentFrames: Self.segmentFrames,
            overlapFrames: Self.overlapFrames,
            // The parity-verified export was measured on raw samples; peak-normalising first
            // would change the signal the model sees.
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

actor ONNXKaraokeChunkPredictor: StemChunkPredicting {
    let supportedStems = ONNXKaraokeVocalSeparationEngine.modelOutputOrder

    private var session: ORTSession?
    private let frameCount: Int

    /// Drop the onnxruntime session (and its arena) as soon as refinement finishes, so it isn't
    /// still resident through the later transcription/harmony stages.
    func releaseResources() {
        session = nil
    }

    init(
        modelURL: URL,
        frameCount: Int = ONNXKaraokeVocalSeparationEngine.segmentFrames
    ) throws {
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
        guard shape == [1, 2, frameCount] else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputData = try output.tensorData()
        let expectedFloats = 2 * frameCount
        guard outputData.length == expectedFloats * MemoryLayout<Float>.size else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputPointer = outputData.bytes.bindMemory(
            to: Float.self,
            capacity: expectedFloats
        )

        var lead = [[Float]]()
        var backing = [[Float]]()
        lead.reserveCapacity(2)
        backing.reserveCapacity(2)
        for channel in 0..<2 {
            let offset = channel * frameCount
            let leadChannel = Array(
                UnsafeBufferPointer(
                    start: outputPointer.advanced(by: offset),
                    count: frameCount
                ))
            // Backing is the residual, so lead + backing reconstructs the parent exactly.
            var backingChannel = [Float](repeating: 0, count: frameCount)
            let parent = chunk.channels[channel]
            for frame in 0..<frameCount {
                backingChannel[frame] = parent[frame] - leadChannel[frame]
            }
            lead.append(leadChannel)
            backing.append(backingChannel)
        }
        return StemChunkPrediction(samplesByStem: [.vocals: lead, .other: backing])
    }
}
