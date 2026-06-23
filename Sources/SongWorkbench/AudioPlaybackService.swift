import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackService: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var loadedURL: URL?
    @Published private(set) var errorMessage: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var scheduled = false
    private var timer: Timer?
    private var securityScopedURL: URL?
    private var loopRegion: LoopRegion?
    private var scheduleGeneration = 0

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }

    isolated deinit {
        timer?.invalidate()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    func load(_ url: URL) {
        stop(resetPosition: true)
        releaseSecurityScopedResource()

        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        if hasSecurityAccess {
            securityScopedURL = url
        }

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            loadedURL = url
            duration = Double(file.length) / file.processingFormat.sampleRate
            errorMessage = nil
            schedule(from: 0)
        } catch {
            audioFile = nil
            loadedURL = nil
            duration = 0
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
            releaseSecurityScopedResource()
        }
    }

    func unload() {
        stop(resetPosition: true)
        audioFile = nil
        loadedURL = nil
        duration = 0
        errorMessage = nil
        releaseSecurityScopedResource()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard audioFile != nil else { return }

        do {
            if !scheduled {
                if currentTime >= duration {
                    currentTime = 0
                }
                schedule(from: frame(for: currentTime))
            }
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
            isPlaying = true
            startTimer()
            errorMessage = nil
        } catch {
            isPlaying = false
            errorMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    func pause() {
        updateCurrentTime()
        player.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let shouldResume = isPlaying
        player.stop()
        scheduled = false
        currentTime = min(max(time, 0), duration)
        schedule(from: frame(for: currentTime))

        if shouldResume {
            player.play()
        }
    }

    func setPitch(semitones: Int) {
        timePitch.pitch = PitchShift.cents(for: semitones)
    }

    func setTempo(rate: Double) {
        timePitch.rate = Float(min(max(rate, 0.5), 1.5))
    }

    func setLoopRegion(_ region: LoopRegion?) {
        loopRegion = region?.clamped(to: duration)
    }

    private func stop(resetPosition: Bool) {
        scheduleGeneration += 1
        player.stop()
        engine.stop()
        scheduled = false
        isPlaying = false
        stopTimer()
        if resetPosition {
            currentTime = 0
            startFrame = 0
        }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let audioFile else { return }
        let boundedFrame = min(max(frame, 0), audioFile.length)
        let remaining = audioFile.length - boundedFrame
        guard remaining > 0 else {
            currentTime = 0
            startFrame = 0
            scheduled = false
            return
        }

        startFrame = boundedFrame
        scheduleGeneration += 1
        let generation = scheduleGeneration
        player.scheduleSegment(
            audioFile,
            startingFrame: boundedFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScheduledPlaybackCompletion(generation: generation)
            }
        }
        scheduled = true
    }

    private func frame(for time: TimeInterval) -> AVAudioFramePosition {
        guard let audioFile else { return 0 }
        return AVAudioFramePosition(time * audioFile.processingFormat.sampleRate)
    }

    private func updateCurrentTime() {
        guard
            let audioFile,
            let renderTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: renderTime)
        else { return }

        let elapsedFrames = AVAudioFramePosition(playerTime.sampleTime)
        let absoluteFrame = min(startFrame + elapsedFrames, audioFile.length)
        currentTime = Double(absoluteFrame) / audioFile.processingFormat.sampleRate

        if let loopRegion, currentTime >= loopRegion.end {
            seek(to: loopRegion.start)
            return
        }

        if absoluteFrame >= audioFile.length {
            player.stop()
            scheduled = false
            isPlaying = false
            stopTimer()
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentTime()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func handleScheduledPlaybackCompletion(generation: Int) {
        guard generation == scheduleGeneration else { return }
        scheduled = false
        if let loopRegion, isPlaying {
            currentTime = loopRegion.start
            schedule(from: frame(for: loopRegion.start))
            player.play()
        } else {
            currentTime = duration
            isPlaying = false
            stopTimer()
        }
    }

    private func releaseSecurityScopedResource() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
}
