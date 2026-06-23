import AVFoundation
import Foundation

@MainActor
final class StemPlaybackService: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoaded = false
    @Published private(set) var pitchSemitones = 0
    @Published private(set) var tempoRate = 1.0

    private let engine = AVAudioEngine()
    private let stemMixerNode = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let players = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0, AVAudioPlayerNode()) }
    )
    private var files: [StemKind: AVAudioFile] = [:]
    private var accessedURLs: [URL] = []
    private var generation = 0
    private var isScheduled = false
    private var referenceKind: StemKind?
    private var scheduledStartTime: TimeInterval = 0
    private var timer: Timer?

    init() {
        for player in players.values {
            engine.attach(player)
        }
        engine.attach(stemMixerNode)
        engine.attach(timePitch)
        engine.connect(stemMixerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    }

    isolated deinit {
        timer?.invalidate()
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func load(_ stems: StemFiles, mixer: StemMixerModel) throws {
        unload()
        for player in players.values {
            engine.disconnectNodeOutput(player)
        }

        do {
            for kind in StemKind.allCases {
                guard let url = stems[kind] else { continue }
                if url.startAccessingSecurityScopedResource() {
                    accessedURLs.append(url)
                }
                files[kind] = try AVAudioFile(forReading: url)
            }
            for kind in StemKind.allCases {
                guard let player = players[kind], let file = files[kind] else { continue }
                engine.connect(player, to: stemMixerNode, format: file.processingFormat)
            }
            referenceKind = files.max { duration(of: $0.value) < duration(of: $1.value) }?.key
            duration = files.values.map(duration(of:)).max() ?? 0
            apply(mixer)
            scheduleAll(from: 0)
            isLoaded = !files.isEmpty
        } catch {
            files.removeAll()
            duration = 0
            referenceKind = nil
            releaseSecurityScopes()
            throw error
        }
    }

    func apply(_ mixer: StemMixerModel) {
        for kind in StemKind.allCases {
            players[kind]?.volume = mixer.effectiveGain(for: kind)
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard isLoaded else { return }
        if currentTime >= duration {
            currentTime = 0
            scheduleAll(from: 0)
        } else if !isScheduled {
            scheduleAll(from: currentTime)
        }
        do {
            if !engine.isRunning { try engine.start() }
            for kind in StemKind.allCases where files[kind] != nil {
                players[kind]?.play()
            }
            isPlaying = true
            startTimer()
        } catch {
            isPlaying = false
            stopTimer()
        }
    }

    func pause() {
        updateCurrentTime()
        for player in players.values {
            player.pause()
        }
        isPlaying = false
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard isLoaded else { return }
        let shouldResume = isPlaying
        for player in players.values {
            player.stop()
        }
        stopTimer()
        isScheduled = false
        currentTime = min(max(time, 0), duration)
        scheduleAll(from: currentTime)
        if shouldResume, isScheduled {
            for kind in StemKind.allCases where files[kind] != nil {
                players[kind]?.play()
            }
            startTimer()
        } else if !isScheduled {
            isPlaying = false
        }
    }

    func setPitch(semitones: Int) {
        pitchSemitones = PitchShift.normalized(semitones)
        timePitch.pitch = PitchShift.cents(for: pitchSemitones)
    }

    func setTempo(rate: Double) {
        tempoRate = min(max(rate, 0.5), 1.5)
        timePitch.rate = Float(tempoRate)
    }

    func stop() {
        stop(resetPosition: true)
    }

    func unload() {
        stop(resetPosition: true)
        files.removeAll()
        duration = 0
        referenceKind = nil
        isLoaded = false
        releaseSecurityScopes()
    }

    private func stop(resetPosition: Bool) {
        generation += 1
        for player in players.values {
            player.stop()
        }
        engine.stop()
        isPlaying = false
        isScheduled = false
        stopTimer()
        if resetPosition {
            currentTime = 0
            scheduledStartTime = 0
        }
    }

    private func scheduleAll(from time: TimeInterval) {
        generation += 1
        let currentGeneration = generation
        scheduledStartTime = min(max(time, 0), duration)
        var scheduledAny = false

        for kind in StemKind.allCases {
            guard let player = players[kind], let file = files[kind] else { continue }
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = min(
                AVAudioFramePosition(scheduledStartTime * sampleRate),
                file.length
            )
            let remaining = file.length - startFrame
            guard remaining > 0 else { continue }
            scheduledAny = true

            if kind == referenceKind {
                player.scheduleSegment(
                    file,
                    startingFrame: startFrame,
                    frameCount: AVAudioFrameCount(remaining),
                    at: nil,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleCompletion(generation: currentGeneration)
                    }
                }
            } else {
                player.scheduleSegment(
                    file,
                    startingFrame: startFrame,
                    frameCount: AVAudioFrameCount(remaining),
                    at: nil
                )
            }
        }
        isScheduled = scheduledAny
    }

    private func updateCurrentTime() {
        guard
            let referenceKind,
            let player = players[referenceKind],
            let file = files[referenceKind],
            let renderTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: renderTime)
        else { return }

        let elapsed = Double(playerTime.sampleTime) / file.processingFormat.sampleRate
        currentTime = min(scheduledStartTime + elapsed, duration)
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

    private func handleCompletion(generation: Int) {
        guard generation == self.generation else { return }
        currentTime = duration
        isPlaying = false
        isScheduled = false
        stopTimer()
    }

    private func duration(of file: AVAudioFile) -> TimeInterval {
        Double(file.length) / file.processingFormat.sampleRate
    }

    private func releaseSecurityScopes() {
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
    }
}
