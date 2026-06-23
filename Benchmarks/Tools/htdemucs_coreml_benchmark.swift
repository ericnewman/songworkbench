import AVFoundation
import CoreML
import Foundation

private enum BenchmarkError: Error {
    case invalidArguments
    case invalidAudio
    case invalidModelOutput
}

private let segmentFrames = 441_000
private let overlapFrames = 44_100
private let strideFrames = segmentFrames - overlapFrames
private let stemNames = ["vocals", "drums", "bass", "other"]

private func elapsedSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func loadStereoFloatAudio(at url: URL) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url)
    guard file.fileFormat.sampleRate == 44_100, file.fileFormat.channelCount == 2 else {
        throw BenchmarkError.invalidAudio
    }

    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 2,
        interleaved: false
    )!
    let capacity = AVAudioFrameCount(file.length)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!

    if file.processingFormat == format {
        try file.read(into: output)
        return output
    }

    let input = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: capacity
    )!
    try file.read(into: input)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
        throw BenchmarkError.invalidAudio
    }
    var suppliedInput = false
    var conversionError: NSError?
    converter.convert(to: output, error: &conversionError) { _, status in
        guard !suppliedInput else {
            status.pointee = .endOfStream
            return nil
        }
        suppliedInput = true
        status.pointee = .haveData
        return input
    }
    if let conversionError { throw conversionError }
    return output
}

private func makeInput(_ mix: AVAudioPCMBuffer, start: Int) throws -> MLMultiArray {
    let input = try MLMultiArray(
        shape: [1, 2, NSNumber(value: segmentFrames)],
        dataType: .float32
    )
    let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
    pointer.initialize(repeating: 0, count: input.count)
    let available = min(segmentFrames, Int(mix.frameLength) - start)
    guard available > 0, let channels = mix.floatChannelData else { return input }
    pointer.update(from: channels[0].advanced(by: start), count: available)
    pointer.advanced(by: segmentFrames)
        .update(from: channels[1].advanced(by: start), count: available)
    return input
}

private func separate(_ mix: AVAudioPCMBuffer, model: MLModel) throws -> [[[Float]]] {
    let frameCount = Int(mix.frameLength)
    let chunkCount = max(1, Int(ceil(Double(frameCount - overlapFrames) / Double(strideFrames))))
    var stems = Array(
        repeating: Array(repeating: [Float](repeating: 0, count: frameCount), count: 2),
        count: stemNames.count
    )
    var weights = [Float](repeating: 0, count: frameCount)

    for chunkIndex in 0..<chunkCount {
        let start = chunkIndex * strideFrames
        try autoreleasepool {
            let input = try makeInput(mix, start: start)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
            let prediction = try model.prediction(from: provider)
            guard let output = prediction.featureValue(for: "sources")?.multiArrayValue,
                  output.shape.map(\.intValue) == [1, 4, 2, segmentFrames] else {
                throw BenchmarkError.invalidModelOutput
            }
            let strides = output.strides.map(\.intValue)
            let float16Pointer = output.dataType == .float16
                ? output.dataPointer.bindMemory(to: Float16.self, capacity: output.count)
                : nil
            let float32Pointer = output.dataType == .float32
                ? output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
                : nil
            guard float16Pointer != nil || float32Pointer != nil else {
                throw BenchmarkError.invalidModelOutput
            }

            for localFrame in 0..<segmentFrames {
                let globalFrame = start + localFrame
                guard globalFrame < frameCount else { break }
                let fadeIn = min(1, Float(localFrame) / Float(overlapFrames))
                let fadeOut = min(1, Float(segmentFrames - 1 - localFrame) / Float(overlapFrames))
                let weight = min(fadeIn, fadeOut)
                weights[globalFrame] += weight
                for stem in stemNames.indices {
                    for channel in 0..<2 {
                        let offset = stem * strides[1]
                            + channel * strides[2]
                            + localFrame * strides[3]
                        let value = float16Pointer.map { Float($0[offset]) }
                            ?? float32Pointer![offset]
                        stems[stem][channel][globalFrame] += value * weight
                    }
                }
            }
        }
    }

    for frame in 0..<frameCount {
        let weight = max(weights[frame], 1e-6)
        for stem in stemNames.indices {
            stems[stem][0][frame] /= weight
            stems[stem][1][frame] /= weight
        }
    }
    return stems
}

private func write(_ stems: [[[Float]]], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 2,
        interleaved: false
    )!
    for stem in stemNames.indices {
        let frameCount = stems[stem][0].count
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        buffer.floatChannelData![0].update(from: stems[stem][0], count: frameCount)
        buffer.floatChannelData![1].update(from: stems[stem][1], count: frameCount)
        let file = try AVAudioFile(
            forWriting: directory.appendingPathComponent("\(stemNames[stem]).wav"),
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

guard CommandLine.arguments.count == 4 else {
    fputs("usage: htdemucs_coreml_benchmark MODEL.mlpackage INPUT.wav OUTPUT_DIR\n", stderr)
    throw BenchmarkError.invalidArguments
}

let modelPackage = URL(fileURLWithPath: CommandLine.arguments[1])
let inputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[3])
let mix = try loadStereoFloatAudio(at: inputURL)

let compileStart = ContinuousClock.now
let compiledModel = try MLModel.compileModel(at: modelPackage)
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndGPU
let model = try MLModel(contentsOf: compiledModel, configuration: configuration)
let loadDuration = compileStart.duration(to: .now)

let coldStart = ContinuousClock.now
_ = try separate(mix, model: model)
let coldDuration = coldStart.duration(to: .now)
let warmStart = ContinuousClock.now
let warmStems = try separate(mix, model: model)
let warmDuration = warmStart.duration(to: .now)
try write(warmStems, to: outputDirectory)

print("model_compile_load_seconds=\(elapsedSeconds(loadDuration))")
print("cold_full_file_seconds=\(elapsedSeconds(coldDuration))")
print("warm_full_file_seconds=\(elapsedSeconds(warmDuration))")
