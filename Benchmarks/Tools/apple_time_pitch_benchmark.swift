import AVFoundation
import Foundation

enum BenchmarkError: Error {
    case usage
    case buffer
    case render
}

func run() throws {
    guard CommandLine.arguments.count == 5 else { throw BenchmarkError.usage }
    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let semitones = Float(CommandLine.arguments[3]) ?? 0
    let tempo = Float(CommandLine.arguments[4]) ?? 1

    let source = try AVAudioFile(forReading: inputURL)
    let format = source.processingFormat
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    timePitch.pitch = semitones * 100
    timePitch.rate = tempo
    engine.attach(player)
    engine.attach(timePitch)
    engine.connect(player, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)

    let maximumFrames: AVAudioFrameCount = 4_096
    try engine.enableManualRenderingMode(
        .offline,
        format: format,
        maximumFrameCount: maximumFrames
    )
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: engine.manualRenderingFormat,
        frameCapacity: maximumFrames
    ) else { throw BenchmarkError.buffer }
    let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
    let expectedFrames = AVAudioFramePosition(Double(source.length) / Double(tempo))

    player.scheduleFile(source, at: nil)
    try engine.start()
    player.play()
    let start = ContinuousClock.now
    while engine.manualRenderingSampleTime < expectedFrames {
        let remaining = expectedFrames - engine.manualRenderingSampleTime
        let frames = min(AVAudioFrameCount(remaining), maximumFrames)
        switch try engine.renderOffline(frames, to: buffer) {
        case .success:
            try output.write(from: buffer)
        case .insufficientDataFromInputNode:
            continue
        case .cannotDoInCurrentContext:
            Thread.sleep(forTimeInterval: 0.001)
        case .error:
            throw BenchmarkError.render
        @unknown default:
            throw BenchmarkError.render
        }
    }
    let elapsed = start.duration(to: .now)
    print("elapsed_seconds=\(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
    print("input_frames=\(source.length)")
    print("output_frames=\(expectedFrames)")
}

do {
    try run()
} catch BenchmarkError.usage {
    fputs("usage: apple_time_pitch_benchmark input.wav output.wav semitones tempo\n", stderr)
    exit(2)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
