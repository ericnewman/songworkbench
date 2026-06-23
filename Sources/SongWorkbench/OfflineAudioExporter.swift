import AVFoundation
import Foundation

struct OfflineExportSettings: Equatable, Sendable {
    var pitchSemitones: Int
    var tempoRate: Double

    mutating func normalize() {
        pitchSemitones = PitchShift.normalized(pitchSemitones)
        tempoRate = min(max(tempoRate, 0.5), 1.5)
    }
}

actor OfflineAudioExporter {
    func export(
        sourceURL: URL,
        destinationURL: URL,
        settings requestedSettings: OfflineExportSettings,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws {
        var settings = requestedSettings
        settings.normalize()

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        let accessingDestination = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            if accessingDestination { destinationURL.stopAccessingSecurityScopedResource() }
        }

        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.pitch = PitchShift.cents(for: settings.pitchSemitones)
        timePitch.rate = Float(settings.tempoRate)

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
        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: temporaryURL,
            settings: format.settings
        )
        let expectedFrames = max(
            AVAudioFramePosition(Double(source.length) / settings.tempoRate),
            1
        )
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: maximumFrames
            )
        else {
            throw OfflineAudioExportError.couldNotCreateBuffer
        }

        player.scheduleFile(source, at: nil)
        try engine.start()
        player.play()

        while engine.manualRenderingSampleTime < expectedFrames {
            try Task.checkCancellation()
            let remaining = expectedFrames - engine.manualRenderingSampleTime
            let frames = min(AVAudioFrameCount(remaining), maximumFrames)
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                try output?.write(from: buffer)
                progress(min(Double(engine.manualRenderingSampleTime) / Double(expectedFrames), 1))
            case .insufficientDataFromInputNode:
                continue
            case .cannotDoInCurrentContext:
                awaitRenderRetry()
            case .error:
                throw OfflineAudioExportError.renderFailed
            @unknown default:
                throw OfflineAudioExportError.renderFailed
            }
        }

        player.stop()
        engine.stop()
        output = nil
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        progress(1)
    }

    private func awaitRenderRetry() {
        Thread.sleep(forTimeInterval: 0.001)
    }
}

enum OfflineAudioExportError: LocalizedError {
    case couldNotCreateBuffer
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .couldNotCreateBuffer: "Could not allocate an offline render buffer."
        case .renderFailed: "Offline audio rendering failed."
        }
    }
}
