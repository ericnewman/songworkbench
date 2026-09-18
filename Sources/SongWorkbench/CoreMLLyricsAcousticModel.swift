import CoreML
import Foundation

/// The bundled lyrics-alignment acoustic model, run through Core ML.
///
/// Converted from `jhuang448/LyricsAlignment-MTL` (MIT) by
/// `tools/lyrics_align_spike/convert_coreml.py`, which also verifies it against PyTorch:
/// 100.00 % argmax agreement, max absolute difference 3.4e-05. Argmax is what matters — forced
/// alignment compares classes within a frame, not absolute logit values.
///
/// The conversion folds the model's own post-processing in, so this emits `[T, 41]` **log
/// probabilities** directly: the pitch head is already summed out and `log_softmax` applied.
/// Nothing here should transform the output further.
///
/// Absent model, no crash: `load()` returns nil and the caller reports that alignment is
/// unavailable, the same posture the separation path takes when its bundled model is missing.
/// The package is gitignored like the other bundled models, so a fresh clone has to build it.
/// `@unchecked Sendable` because `MLModel` is not marked `Sendable` but its `prediction` is
/// documented as safe to call concurrently, and nothing here mutates after `init`.
struct CoreMLLyricsAcousticModel: LyricsAcousticModel, @unchecked Sendable {
    /// Mel frames per evaluation. Fixed at conversion time: 2049 mel frames is 683 output frames,
    /// about 23.8 s. Changing it means reconverting — the shape is baked into the package.
    let melFramesPerWindow = 2049

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    private static let resourceName = "LyricsAlignmentMTL"

    init(model: MLModel) {
        self.model = model
        let description = model.modelDescription
        inputName = description.inputDescriptionsByName.keys.first ?? "mel"
        outputName = description.outputDescriptionsByName.keys.first ?? "logprobs"
    }

    /// Loads the bundled package, or nil when it is not present or cannot be compiled.
    static func load(configuration: MLModelConfiguration = MLModelConfiguration()) -> Self? {
        guard
            let url = Bundle.main.url(
                forResource: resourceName, withExtension: "mlpackage")
        else { return nil }
        // A .mlpackage has to be compiled before it can be loaded; Core ML caches the result.
        guard let compiled = try? MLModel.compileModel(at: url),
            let model = try? MLModel(contentsOf: compiled, configuration: configuration)
        else { return nil }
        return Self(model: model)
    }

    enum Failure: Error, Equatable {
        case wrongWindowLength(expected: Int, received: Int)
        case unexpectedOutput
    }

    func logProbabilities(melWindow: [[Float]]) throws -> [[Float]] {
        guard melWindow.count == melFramesPerWindow else {
            throw Failure.wrongWindowLength(
                expected: melFramesPerWindow, received: melWindow.count)
        }
        let bands = LyricsAlignmentMel.melBands

        // The model takes (1, 1, mel, time) — mel-major, so this transposes on the way in.
        let input = try MLMultiArray(
            shape: [1, 1, NSNumber(value: bands), NSNumber(value: melFramesPerWindow)],
            dataType: .float32)
        // Address through the array's OWN strides rather than assuming it is packed. Core ML
        // pads rows for alignment (the output of this very model has a frame stride of 48 for 41
        // classes), and computing offsets from the shape silently reads and writes the wrong
        // cells — which looks like a working model producing confident nonsense.
        let inputBandStride = input.strides[2].intValue
        let inputFrameStride = input.strides[3].intValue
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        for frame in 0..<melFramesPerWindow {
            let row = melWindow[frame]
            guard row.count == bands else {
                throw Failure.wrongWindowLength(expected: bands, received: row.count)
            }
            for band in 0..<bands {
                pointer[band * inputBandStride + frame * inputFrameStride] = row[band]
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
        let prediction = try model.prediction(from: provider)
        guard let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw Failure.unexpectedOutput
        }

        // (1, T, 41), but NOT packed — see the note above. `count` covers the padding too, so
        // the frame count comes from the shape, and every read goes through the strides.
        guard output.shape.count == 3 else { throw Failure.unexpectedOutput }
        let frames = output.shape[1].intValue
        let classes = output.shape[2].intValue
        guard classes == ArpabetVocabulary.classCount else { throw Failure.unexpectedOutput }
        let frameStride = output.strides[1].intValue
        let classStride = output.strides[2].intValue
        let values = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
        return (0..<frames).map { frame in
            let base = frame * frameStride
            return (0..<classes).map { values[base + $0 * classStride] }
        }
    }
}
