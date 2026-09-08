import AVFoundation
import Accelerate
import Foundation
import OnnxRuntimeBindings

/// Lead/backing split via UVR MDX-Net Karaoke 2.
///
/// The previous anvuew BS-RoFormer checkpoint was a vocals-vs-instrumental isolator. Fed the
/// already-separated vocals stem it emitted a ghost "lead" and dumped the parent into backing.
/// KARA_2 is a karaoke model (`is_karaoke: true`, primary stem Instrumental). It is in-distribution
/// on a full mix: instrumental = music + backing, residual = lead. Backing vocals are then
/// `vocals_parent − lead`, which is what `KaraokeVocalRefinementEngine` writes.
///
/// The ONNX graph is spectrogram-in/out `[1, 4, 2048, 256]`. STFT/ISTFT live here — not in
/// `HybridDemucsFrequencyFeatures`, whose 4096-point Demucs STFT DrumSep depends on.
///
/// Transport slots for the refiner: vocals→lead, other→backing.
struct ONNXKaraokeVocalSeparationEngine: StemSeparationEngine, Sendable {
    static let segmentFrames = MDXNetKaraokeSpectrogram.chunkSamples
    static let overlapFrames = MDXNetKaraokeSpectrogram.nFFT / 2

    private let engine: CoreMLStemSeparationEngine
    let metadata: StemSeparationEngineMetadata

    static let metadata = StemSeparationEngineMetadata(
        engineIdentifier: "onnxruntime-cpu-mdx-kara2",
        engineVersion: "1",
        modelIdentifier: "uvr-mdxnet-kara-2",
        modelVersion: "1"
    )

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

/// Runs KARA_2 on the original mix (in-distribution), then backing = vocals − lead.
///
/// `NativeStemRefinementEngine` feeds only the parent vocals stem. That is the right input for
/// DrumSep and the wrong input for a karaoke model, which was trained on full mixes.
struct KaraokeVocalRefinementEngine: StemRefinementEngine {
    let identifier: String
    let taxonomyVersion: Int
    let parentStemID: StemID
    let outputs: [NativeStemRefinementOutput]
    let engine: any StemSeparationEngine

    var outputStemIDs: [StemID] { outputs.map(\.id) }

    var cacheIdentity: String {
        let metadata = engine.metadata
        return [
            identifier,
            metadata.engineIdentifier,
            metadata.engineVersion,
            metadata.modelIdentifier ?? "",
            metadata.modelVersion ?? "",
        ].joined(separator: "@")
    }

    init(
        identifier: String,
        taxonomyVersion: Int = 1,
        parentStemID: StemID = StemKind.vocals.id,
        outputs: [NativeStemRefinementOutput] = ONNXKaraokeVocalSeparationEngine.refinementOutputs,
        engine: any StemSeparationEngine
    ) {
        self.identifier = identifier
        self.taxonomyVersion = taxonomyVersion
        self.parentStemID = parentStemID
        self.outputs = outputs
        self.engine = engine
    }

    func refine(
        request: StemRefinementRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemRefinementResult {
        guard let parentAsset = request.manifest.assetsByID[parentStemID] else {
            throw StemRefinementError.missingParentStem(parentStemID)
        }
        let modelOutputDirectory = request.outputDirectory.appendingPathComponent(
            "ModelOutputs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modelOutputDirectory,
            withIntermediateDirectories: true
        )
        let modelResult = try await engine.separate(
            request: StemSeparationRequest(
                inputURL: request.inputURL,
                outputDirectory: modelOutputDirectory
            )
        ) { progress($0) }
        let modelAssets = modelResult.stemSet.assetsByID
        guard let leadAsset = modelAssets[StemKind.vocals.id] else {
            throw StemRefinementError.missingModelOutput(StemKind.vocals.id)
        }
        let backingURL = modelOutputDirectory.appendingPathComponent("other.wav")
        try KaraokeBackingResidual.write(
            vocalsURL: parentAsset.audioURL,
            leadURL: leadAsset.audioURL,
            outputURL: backingURL
        )
        var descriptors: [StemDescriptor] = []
        var assets: [StemAsset] = []
        for output in outputs {
            let audioURL: URL
            if output.modelOutputID == StemKind.vocals.id {
                audioURL = leadAsset.audioURL
            } else if output.modelOutputID == StemKind.other.id {
                audioURL = backingURL
            } else {
                throw StemRefinementError.missingModelOutput(output.modelOutputID)
            }
            descriptors.append(
                StemDescriptor(
                    id: output.id,
                    parentID: parentStemID,
                    role: .refinement,
                    displayName: output.displayName,
                    order: output.order
                )
            )
            assets.append(
                StemAsset(id: output.id, audioURL: audioURL, producerID: identifier)
            )
        }
        return StemRefinementResult(descriptors: descriptors, assets: assets)
    }
}

enum KaraokeBackingResidual {
    static func write(vocalsURL: URL, leadURL: URL, outputURL: URL) throws {
        let vocals = try loadStereo(vocalsURL)
        let lead = try loadStereo(leadURL)
        let frames = min(vocals[0].count, lead[0].count)
        guard frames > 0, vocals.count == 2, lead.count == 2 else {
            throw CoreMLStemSeparationError.unsupportedAudio
        }
        var backing = [
            [Float](repeating: 0, count: frames),
            [Float](repeating: 0, count: frames),
        ]
        for channel in 0..<2 {
            for frame in 0..<frames {
                backing[channel][frame] = vocals[channel][frame] - lead[channel][frame]
            }
        }
        try writeStereo(backing, to: outputURL)
    }

    static func loadStereo(_ url: URL) throws -> [[Float]] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount >= 1 else { throw CoreMLStemSeparationError.unsupportedAudio }
        let capacity = AVAudioFrameCount(file.length)
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { throw CoreMLStemSeparationError.unsupportedAudio }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard let channels = buffer.floatChannelData else {
            throw CoreMLStemSeparationError.unsupportedAudio
        }
        let left = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        if format.channelCount == 1 {
            return [left, left]
        }
        let right = Array(UnsafeBufferPointer(start: channels[1], count: frames))
        return [left, right]
    }

    static func writeStereo(_ channels: [[Float]], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(channels[0].count)
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(from: channels[0], count: Int(frames))
        buffer.floatChannelData![1].update(from: channels[1], count: Int(frames))
        try file.write(from: buffer)
    }
}

/// UVR MDX-Net Karaoke 2 spectrogram pack (`n_fft` 5120, hop 1024, dim_f 2048, dim_t 256).
/// Matches `tools/karaoke_export/probe_kara2.py` / seanghay ConvTDFNet: periodic Hann, zero
/// center-pad, numpy `rfft` bin layout, NOLA ISTFT.
enum MDXNetKaraokeSpectrogram {
    static let nFFT = 5_120
    static let hopLength = 1_024
    static let dimF = 2_048
    static let dimT = 256
    static let chunkSamples = hopLength * (dimT - 1)
    static let compensate: Float = 1.065
    static let channelCount = 4
    static var packedFloatCount: Int { channelCount * dimF * dimT }

    static func pack(left: [Float], right: [Float]) throws -> [Float] {
        precondition(left.count == chunkSamples && right.count == chunkSamples)
        let window = periodicHann(nFFT)
        var packed = [Float](repeating: 0, count: packedFloatCount)
        try pack(channel: left, window: window, packed: &packed, pairOffset: 0)
        try pack(channel: right, window: window, packed: &packed, pairOffset: 2)
        return packed
    }

    static func unpack(_ packed: [Float]) throws -> [[Float]] {
        precondition(packed.count == packedFloatCount)
        let window = periodicHann(nFFT)
        return [
            try unpack(channelPairOffset: 0, packed: packed, window: window),
            try unpack(channelPairOffset: 2, packed: packed, window: window),
        ]
    }

    private static func pack(
        channel: [Float],
        window: [Float],
        packed: inout [Float],
        pairOffset: Int
    ) throws {
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: chunkSamples + 2 * pad)
        padded.replaceSubrange(pad..<(pad + chunkSamples), with: channel)
        var real = [Float](repeating: 0, count: nFFT)
        var imag = [Float](repeating: 0, count: nFFT)
        var outReal = [Float](repeating: 0, count: nFFT)
        var outImag = [Float](repeating: 0, count: nFFT)
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD) else {
            throw CoreMLStemSeparationError.invalidConfiguration
        }
        defer { vDSP_DFT_DestroySetup(setup) }
        for time in 0..<dimT {
            let start = time * hopLength
            for bin in 0..<nFFT {
                real[bin] = padded[start + bin] * window[bin]
                imag[bin] = 0
            }
            real.withUnsafeBufferPointer { realIn in
                imag.withUnsafeBufferPointer { imagIn in
                    outReal.withUnsafeMutableBufferPointer { realOut in
                        outImag.withUnsafeMutableBufferPointer { imagOut in
                            vDSP_DFT_Execute(
                                setup,
                                realIn.baseAddress!, imagIn.baseAddress!,
                                realOut.baseAddress!, imagOut.baseAddress!
                            )
                        }
                    }
                }
            }
            for freq in 0..<dimF {
                packed[index(pair: pairOffset, freq: freq, time: time)] = outReal[freq]
                packed[index(pair: pairOffset + 1, freq: freq, time: time)] = outImag[freq]
            }
        }
    }

    private static func unpack(
        channelPairOffset: Int,
        packed: [Float],
        window: [Float]
    ) throws -> [Float] {
        let pad = nFFT / 2
        let nBins = nFFT / 2 + 1
        var acc = [Float](repeating: 0, count: chunkSamples + 2 * pad)
        var windowSum = [Float](repeating: 0, count: chunkSamples + 2 * pad)
        var real = [Float](repeating: 0, count: nFFT)
        var imag = [Float](repeating: 0, count: nFFT)
        var outReal = [Float](repeating: 0, count: nFFT)
        var outImag = [Float](repeating: 0, count: nFFT)
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE) else {
            throw CoreMLStemSeparationError.invalidConfiguration
        }
        defer { vDSP_DFT_DestroySetup(setup) }
        let scale = Float(nFFT)
        for time in 0..<dimT {
            real = [Float](repeating: 0, count: nFFT)
            imag = [Float](repeating: 0, count: nFFT)
            for freq in 0..<dimF {
                real[freq] = packed[index(pair: channelPairOffset, freq: freq, time: time)]
                imag[freq] = packed[index(pair: channelPairOffset + 1, freq: freq, time: time)]
            }
            // Hermitian completion so the inverse DFT yields a real frame.
            for freq in 1..<nBins where freq < nFFT - freq {
                real[nFFT - freq] = real[freq]
                imag[nFFT - freq] = -imag[freq]
            }
            real.withUnsafeBufferPointer { realIn in
                imag.withUnsafeBufferPointer { imagIn in
                    outReal.withUnsafeMutableBufferPointer { realOut in
                        outImag.withUnsafeMutableBufferPointer { imagOut in
                            vDSP_DFT_Execute(
                                setup,
                                realIn.baseAddress!, imagIn.baseAddress!,
                                realOut.baseAddress!, imagOut.baseAddress!
                            )
                        }
                    }
                }
            }
            let start = time * hopLength
            for bin in 0..<nFFT {
                let value = (outReal[bin] / scale) * window[bin]
                acc[start + bin] += value
                windowSum[start + bin] += window[bin] * window[bin]
            }
        }
        var output = [Float](repeating: 0, count: chunkSamples)
        for i in 0..<chunkSamples {
            let denom = max(windowSum[pad + i], 1e-8)
            output[i] = acc[pad + i] / denom
        }
        return output
    }

    static func index(pair: Int, freq: Int, time: Int) -> Int {
        (pair * dimF + freq) * dimT + time
    }

    static func periodicHann(_ length: Int) -> [Float] {
        (0..<length).map { index in
            0.5 - 0.5 * cos(2 * Float.pi * Float(index) / Float(length))
        }
    }
}

actor ONNXKaraokeChunkPredictor: StemChunkPredicting {
    let supportedStems = ONNXKaraokeVocalSeparationEngine.modelOutputOrder
    static let threadCountDefaultsKey = "SongWorkbench.karaokeStemRefinementIntraOpThreads"
    static let threadCountEnvironmentKey = "SW_KARAOKE_STEM_THREADS"

    private var session: ORTSession?
    private let frameCount: Int

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
        let threadCount = Self.resolvedIntraOpThreadCount()
        try options.setIntraOpNumThreads(threadCount)
        session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
    }

    static func resolvedIntraOpThreadCount(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaultValue: Int? = UserDefaults.standard.object(forKey: threadCountDefaultsKey)
            as? Int
    ) -> Int32 {
        let available = max(activeProcessorCount - 1, 1)
        if let value = environment[threadCountEnvironmentKey].flatMap(Int.init), value > 0 {
            return Int32(min(value, available))
        }
        if let userDefaultValue, userDefaultValue > 0 {
            return Int32(min(userDefaultValue, available))
        }
        #if os(macOS)
            return Int32(min(available, 8))
        #else
            return Int32(min(available, 4))
        #endif
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

        let packed = try MDXNetKaraokeSpectrogram.pack(
            left: chunk.channels[0],
            right: chunk.channels[1]
        )
        let inputData = NSMutableData(length: packed.count * MemoryLayout<Float>.size)!
        inputData.mutableBytes.bindMemory(to: Float.self, capacity: packed.count)
            .update(from: packed, count: packed.count)
        let input = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [
                1,
                NSNumber(value: MDXNetKaraokeSpectrogram.channelCount),
                NSNumber(value: MDXNetKaraokeSpectrogram.dimF),
                NSNumber(value: MDXNetKaraokeSpectrogram.dimT),
            ]
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
        guard
            shape == [
                1, MDXNetKaraokeSpectrogram.channelCount, MDXNetKaraokeSpectrogram.dimF,
                MDXNetKaraokeSpectrogram.dimT,
            ]
        else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputData = try output.tensorData()
        let expectedFloats = MDXNetKaraokeSpectrogram.packedFloatCount
        guard outputData.length == expectedFloats * MemoryLayout<Float>.size else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        let outputPointer = outputData.bytes.bindMemory(to: Float.self, capacity: expectedFloats)
        let predicted = Array(UnsafeBufferPointer(start: outputPointer, count: expectedFloats))
        let instrumental = try MDXNetKaraokeSpectrogram.unpack(predicted)
        var lead: [[Float]] = []
        var backing: [[Float]] = []
        lead.reserveCapacity(2)
        backing.reserveCapacity(2)
        for channel in 0..<2 {
            var primary = instrumental[channel]
            for frame in 0..<frameCount {
                primary[frame] *= MDXNetKaraokeSpectrogram.compensate
            }
            var leadChannel = [Float](repeating: 0, count: frameCount)
            let mix = chunk.channels[channel]
            for frame in 0..<frameCount {
                leadChannel[frame] = mix[frame] - primary[frame]
            }
            lead.append(leadChannel)
            backing.append(primary)
        }
        // On a mix, `.other` is instrumental (music + backing). KaraokeVocalRefinementEngine
        // overwrites that file with vocals − lead. The predictor still has to emit both slots
        // so CoreMLStemSeparationEngine will write them.
        return StemChunkPrediction(samplesByStem: [.vocals: lead, .other: backing])
    }
}
