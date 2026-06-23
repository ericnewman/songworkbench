import AVFoundation
import Foundation

actor StemMixExporter {
    func export(
        stems: StemFiles,
        to destinationURL: URL,
        mixer: StemMixerModel,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws {
        try Task.checkCancellation()
        progress(0)

        let availableKinds = stems.availableKinds
        let accessedURLs = availableKinds.filter {
            stems[$0]?.startAccessingSecurityScopedResource() == true
        }
        let accessedDestination = destinationURL.startAccessingSecurityScopedResource()
        defer {
            for kind in accessedURLs {
                stems[kind]?.stopAccessingSecurityScopedResource()
            }
            if accessedDestination { destinationURL.stopAccessingSecurityScopedResource() }
        }

        let files = Dictionary(
            uniqueKeysWithValues: try availableKinds.map { kind in
                (kind, try AVAudioFile(forReading: stems[kind]!))
            }
        )
        guard let referenceFile = files[.vocals] else {
            throw StemMixExportError.missingStem
        }

        let sampleRate = referenceFile.processingFormat.sampleRate
        guard
            let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 2
            )
        else {
            throw StemMixExportError.couldNotCreateOutputFormat
        }

        let expectedFrames = files.values.reduce(AVAudioFramePosition(0)) { longest, file in
            let duration = Double(file.length) / file.processingFormat.sampleRate
            return max(longest, AVAudioFramePosition(ceil(duration * sampleRate)))
        }
        guard expectedFrames > 0 else {
            throw StemMixExportError.emptyStems
        }

        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let engine = AVAudioEngine()
        var players: [StemKind: AVAudioPlayerNode] = [:]
        for kind in availableKinds {
            guard let file = files[kind] else { continue }
            let player = AVAudioPlayerNode()
            player.volume = mixer.effectiveGain(for: kind)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            players[kind] = player
        }

        let maximumFrames: AVAudioFrameCount = 4_096
        try engine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: maximumFrames
        )
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: maximumFrames
            )
        else {
            throw StemMixExportError.couldNotCreateBuffer
        }

        do {
            let output = try AVAudioFile(forWriting: temporaryURL, settings: outputFormat.settings)
            for kind in availableKinds {
                guard let player = players[kind], let file = files[kind] else { continue }
                player.scheduleFile(file, at: nil)
            }

            try engine.start()
            for player in players.values {
                player.play()
            }
            defer {
                for player in players.values {
                    player.stop()
                }
                engine.stop()
            }

            while engine.manualRenderingSampleTime < expectedFrames {
                try Task.checkCancellation()
                let remaining = expectedFrames - engine.manualRenderingSampleTime
                let frameCount = min(AVAudioFrameCount(remaining), maximumFrames)
                let status = try engine.renderOffline(frameCount, to: buffer)
                switch status {
                case .success:
                    try output.write(from: buffer)
                    let completed =
                        Double(engine.manualRenderingSampleTime) / Double(expectedFrames)
                    progress(min(max(completed, 0), 1))
                case .insufficientDataFromInputNode:
                    continue
                case .cannotDoInCurrentContext:
                    Thread.sleep(forTimeInterval: 0.001)
                case .error:
                    throw StemMixExportError.renderFailed
                @unknown default:
                    throw StemMixExportError.renderFailed
                }
            }
        }

        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        progress(1)
    }
}

enum StemMixExportError: LocalizedError {
    case missingStem
    case emptyStems
    case couldNotCreateOutputFormat
    case couldNotCreateBuffer
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .missingStem: "All four stem files are required."
        case .emptyStems: "The stem files contain no audio."
        case .couldNotCreateOutputFormat: "Could not create a stereo output format."
        case .couldNotCreateBuffer: "Could not allocate an offline render buffer."
        case .renderFailed: "Offline stem rendering failed."
        }
    }
}
