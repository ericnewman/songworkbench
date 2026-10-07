import CoreML
import Foundation

/// One chord the network heard: `start..<end` in seconds, `chord` in the app's spelling.
struct ChordNetSegment: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var chord: String
}

/// The chords of one stem. The pipeline injects it so tests, which have no app bundle, can run
/// without the model.
typealias ChordStemRecognizer = @Sendable (_ stemURL: URL) throws -> [ChordNetSegment]

/// Chords from the Jiang et al. 2019 large-vocabulary network (music-x-lab, MIT), converted to
/// Core ML by `tools/chord_model_export/export_coreml.py`, which checks it against PyTorch.
///
/// Eric, 2026-10-07: on the guitar stems of 22 charted songs it found 0.80 of the charts' chord
/// changes with 92 % of its chords in the chart's set, against 0.74 and 77 % for the app's
/// template matching; on his own Flip Flops chart, F1 0.86 against 0.58.
enum ChordNetRecognizer {
    private static let resourceName = "ChordNet"

    static var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mlpackage")
    }

    /// The bundled model, compiled once. Nil only without an app bundle (tests): the build fails
    /// when the package is missing, and the app does not analyze without its models (Eric,
    /// 2026-09-26).
    /// Core ML models are safe to predict from several threads.
    nonisolated(unsafe) static let bundledModel: MLModel? = bundledURL.flatMap {
        try? MLModel(contentsOf: MLModel.compileModel(at: $0))
    }

    @Sendable
    static func segmentsWithBundledModel(_ stem: URL) throws -> [ChordNetSegment] {
        guard let model = bundledModel else {
            throw SongAnalysisPipelineError.missingBundledModel(resourceName)
        }
        return try segments(stem: stem, model: model)
    }

    /// The chords of one stem, in order; "no chord" stretches are left out.
    static func segments(stem: URL, model: MLModel) throws -> [ChordNetSegment] {
        let samples = try MeasuredLyricTiming.monoSamples(
            at: stem, sampleRate: ChordNetFeatures.sampleRate)
        return try segments(
            spectrogram: ChordNetFeatures.spectrogram(samples: samples), model: model)
    }

    static func segments(spectrogram: [[Float]], model: MLModel) throws -> [ChordNetSegment] {
        // The network's convolutions need a few frames; anything shorter has no chords anyway.
        guard spectrogram.count >= 16 else { return [] }
        let path = ChordNetDecoder.decode(try heads(spectrogram: spectrogram, model: model))
        let seconds = 1 / ChordNetFeatures.framesPerSecond
        var out: [ChordNetSegment] = []
        var start = 0
        for frame in 1...path.count where frame == path.count || path[frame] != path[start] {
            if let chord = ChordNetDecoder.appLabel(ChordNetDecoder.vocabulary[path[start]].name) {
                out.append(
                    ChordNetSegment(
                        start: Double(start) * seconds, end: Double(frame) * seconds, chord: chord))
            }
            start = frame
        }
        return out
    }

    /// The whole song in one evaluation: the network normalises and runs its LSTM over all frames.
    static func heads(spectrogram: [[Float]], model: MLModel) throws -> ChordNetDecoder.Heads {
        let frames = spectrogram.count
        let bins = ChordNetFeatures.networkBins
        let input = try MLMultiArray(
            shape: [1, NSNumber(value: frames), NSNumber(value: bins)], dataType: .float32)
        let frameStride = input.strides[1].intValue
        let binStride = input.strides[2].intValue
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        for (frame, row) in spectrogram.enumerated() {
            for bin in 0..<bins { pointer[frame * frameStride + bin * binStride] = row[bin] }
        }
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["cqt": input]))
        func head(_ name: String, _ classes: Int) throws -> [Float] {
            guard let array = output.featureValue(for: name)?.multiArrayValue,
                array.count == frames * classes
            else { throw Failure.unexpectedModelOutput }
            // By index rather than raw pointer: the output's element type and strides are Core ML's.
            let lead = [NSNumber](repeating: 0, count: array.shape.count - 2)
            var values = [Float](repeating: 0, count: frames * classes)
            for frame in 0..<frames {
                for index in 0..<classes {
                    values[frame * classes + index] =
                        array[lead + [NSNumber(value: frame), NSNumber(value: index)]].floatValue
                }
            }
            return values
        }
        let classes = ChordNetDecoder.Heads.classes
        return ChordNetDecoder.Heads(
            frames: frames,
            triad: try head("triad", classes[0]), bass: try head("bass", classes[1]),
            seventh: try head("seventh", classes[2]), ninth: try head("ninth", classes[3]),
            eleventh: try head("eleventh", classes[4]),
            thirteenth: try head("thirteenth", classes[5]))
    }

    enum Failure: Error { case unexpectedModelOutput }
}
