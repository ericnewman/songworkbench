import AVFoundation
import Foundation

/// One stem's left/right meter reading in `[0, 1]`.
struct StemStereoLevel: Equatable, Sendable {
    var left: Float
    var right: Float
    static let zero = StemStereoLevel(left: 0, right: 0)
}

@MainActor
final class StemPlaybackService: ObservableObject, PlaybackClock {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoaded = false
    @Published private(set) var pitchSemitones = 0
    @Published private(set) var tempoRate = 1.0
    @Published private(set) var stemLevels = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0.id, Float(0)) }
    )
    /// Post-fader, post-pan left/right levels per stem, for the channel strips' horizontal
    /// L/R meters.
    @Published private(set) var stemStereoLevels = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0.id, StemStereoLevel.zero) }
    )
    /// The mixer state currently applied to the players — kept so metering can apply the
    /// same pan law the audio path uses.
    private var appliedMixer = StemMixerModel()

    private let engine = AVAudioEngine()
    private let stemMixerNode = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var players = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0.id, AVAudioPlayerNode()) }
    )
    private var files: [StemID: AVAudioFile] = [:]
    private var meterFiles: [StemID: AVAudioFile] = [:]
    private var accessedURLs: [URL] = []
    private var generation = 0
    private var isScheduled = false
    private var referenceID: StemID?
    private var scheduledStartTime: TimeInterval = 0
    private var timer: Timer?

    // Synthetic click-track channel: one short reusable sample scheduled on each detected beat.
    // It is not a separated stem and its memory use does not scale with song duration.
    private let clickPlayer = AVAudioPlayerNode()
    private var clickBuffer: AVAudioPCMBuffer?
    private var clickBeatTimes: [TimeInterval] = []
    private var isClickConnected = false
    @Published var clickGain: Float = 0 {
        didSet { clickPlayer.volume = max(min(clickGain, StemMixState.maximumGain), 0) }
    }

    init() {
        for player in players.values {
            engine.attach(player)
        }
        engine.attach(clickPlayer)
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

    private func player(for id: StemID) -> AVAudioPlayerNode {
        if let player = players[id] { return player }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        players[id] = player
        return player
    }

    func load(_ stems: StemFiles, mixer: StemMixerModel) throws {
        try load(stems.stemSetManifest, mixer: mixer)
    }

    func load(_ manifest: StemSetManifest, mixer: StemMixerModel) throws {
        unload()
        for player in players.values {
            engine.disconnectNodeOutput(player)
        }
        let activeNodes = StemMixGraph(manifest: manifest).activeNodes

        do {
            for node in activeNodes {
                let url = node.audioURL
                if url.startAccessingSecurityScopedResource() {
                    accessedURLs.append(url)
                }
                files[node.id] = try AVAudioFile(forReading: url)
                meterFiles[node.id] = try AVAudioFile(forReading: url)
            }
            for node in activeNodes {
                let player = player(for: node.id)
                guard let file = files[node.id] else { continue }
                engine.connect(player, to: stemMixerNode, format: file.processingFormat)
            }
            referenceID = files.max { duration(of: $0.value) < duration(of: $1.value) }?.key
            duration = files.values.map(duration(of:)).max() ?? 0
            apply(mixer)
            scheduleAll(from: 0)
            isLoaded = !files.isEmpty
        } catch {
            resetStemLevels()
            files.removeAll()
            meterFiles.removeAll()
            duration = 0
            referenceID = nil
            releaseSecurityScopes()
            throw error
        }
    }

    func apply(_ mixer: StemMixerModel) {
        appliedMixer = mixer
        let activeIDs = files.keys.sorted()
        for id in activeIDs {
            players[id]?.volume = mixer.effectiveGain(for: id, activeIDs: activeIDs)
            // AVAudioPlayerNode adopts AVAudioMixing: pan applies on the mixer input bus
            // (balance for stereo stems, constant-power placement for mono).
            players[id]?.pan = mixer[id].pan
        }
        // Master fader: every stem player AND the click both already route into
        // `stemMixerNode` (see `init`/`load`/`loadClickTrack`), so its own output volume is
        // the single downstream point that scales the whole mix at once.
        stemMixerNode.outputVolume = mixer.masterGain
    }

    /// Constant-power pan gains for the L/R meters, matching the audible pan law:
    /// center ⇒ (≈0.707, ≈0.707), hard left ⇒ (1, 0), hard right ⇒ (0, 1).
    static func panGains(for pan: Float) -> (left: Float, right: Float) {
        let clamped = min(max(pan, -1), 1)
        let angle = (Double(clamped) + 1) * .pi / 4
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// Builds the click track from the song's beat times and connects it. Call after `load`. A
    /// nil/empty `beatTimes` leaves the channel silent. Safe to call while playing.
    func loadClickTrack(beatTimes: [TimeInterval]) {
        guard let sampleRate = files.values.first?.processingFormat.sampleRate else {
            clickBuffer = nil
            clickBeatTimes = []
            return
        }
        clickBeatTimes = Self.uniformBeatGrid(from: beatTimes, duration: duration)
        clickBuffer =
            clickBeatTimes.isEmpty ? nil : Self.makeClickSample(sampleRate: sampleRate)
        if let clickBuffer, !isClickConnected {
            engine.connect(clickPlayer, to: stemMixerNode, format: clickBuffer.format)
            isClickConnected = true
        }
        clickPlayer.volume = max(min(clickGain, StemMixState.maximumGain), 0)
        if isScheduled {
            clickPlayer.stop()
            scheduleClick(from: scheduledStartTime)
            if isPlaying, clickBuffer != nil { clickPlayer.play() }
        }
    }

    static func makeClickSample(sampleRate: Double) -> AVAudioPCMBuffer? {
        guard sampleRate > 0,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return nil }
        let clickFrames = max(AVAudioFrameCount(0.03 * sampleRate), 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: clickFrames),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = clickFrames
        for offset in 0..<Int(clickFrames) {
            let seconds = Double(offset) / sampleRate
            let envelope = exp(-seconds * 90)
            channel[offset] = Float(sin(2 * Double.pi * 1000 * seconds) * envelope * 0.6)
        }
        return buffer
    }

    /// Converts the (possibly jittery, onset-derived) beat times into a perfectly periodic grid:
    /// the median inter-beat interval as the period, phase-anchored to the first detected beat, and
    /// extended both directions to cover [0, duration]. This makes the click track totally
    /// consistent while staying aligned to the song's tempo and downbeat phase. Falls back to the
    /// input when there aren't enough beats to estimate a period.
    private static func uniformBeatGrid(
        from beatTimes: [TimeInterval], duration: TimeInterval
    ) -> [TimeInterval] {
        let sorted = beatTimes.sorted()
        guard sorted.count >= 2 else { return beatTimes }
        var intervals: [TimeInterval] = []
        for index in 1..<sorted.count { intervals.append(sorted[index] - sorted[index - 1]) }
        intervals.sort()
        let period = intervals[intervals.count / 2]  // median
        guard period > 0.05 else { return beatTimes }  // sanity: ignore degenerate spacing

        let anchor = sorted[0]
        var grid: [TimeInterval] = []
        var time = anchor
        while time >= 0 {  // backfill toward the start
            grid.append(time)
            time -= period
        }
        time = anchor + period
        while time <= duration {  // forward to the end
            grid.append(time)
            time += period
        }
        return grid.sorted()
    }

    private func scheduleClick(from time: TimeInterval) {
        guard let clickBuffer, isClickConnected else { return }
        let sampleRate = clickBuffer.format.sampleRate
        let startTime = min(max(time, 0), duration)
        for beat in clickBeatTimes where beat >= startTime && beat <= duration {
            let relativeFrame = AVAudioFramePosition((beat - startTime) * sampleRate)
            clickPlayer.scheduleBuffer(
                clickBuffer,
                at: AVAudioTime(sampleTime: relativeFrame, atRate: sampleRate),
                options: [],
                completionHandler: nil
            )
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
            // Re-push mixing parameters now the engine is running: AVAudioMixing values
            // (volume/pan) set on a node before the engine (re)starts can be dropped by
            // graph rebuilds — field-verified in the exporter's manual-rendering path.
            apply(appliedMixer)
            for id in files.keys {
                players[id]?.play()
            }
            if isClickConnected { clickPlayer.play() }
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
        clickPlayer.pause()
        isPlaying = false
        stopTimer()
        resetStemLevels()
    }

    func seek(to time: TimeInterval) {
        guard isLoaded else { return }
        let shouldResume = isPlaying
        for player in players.values {
            player.stop()
        }
        clickPlayer.stop()
        stopTimer()
        isScheduled = false
        currentTime = min(max(time, 0), duration)
        scheduleAll(from: currentTime)
        if shouldResume, isScheduled {
            for id in files.keys {
                players[id]?.play()
            }
            if isClickConnected { clickPlayer.play() }
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
        meterFiles.removeAll()
        duration = 0
        referenceID = nil
        isLoaded = false
        clickBuffer = nil
        clickBeatTimes = []
        if isClickConnected {
            engine.disconnectNodeOutput(clickPlayer)
            isClickConnected = false
        }
        releaseSecurityScopes()
    }

    private func stop(resetPosition: Bool) {
        generation += 1
        for player in players.values {
            player.stop()
        }
        clickPlayer.stop()
        engine.stop()
        isPlaying = false
        isScheduled = false
        stopTimer()
        resetStemLevels()
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

        for id in files.keys.sorted() {
            guard let player = players[id], let file = files[id] else { continue }
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = min(
                AVAudioFramePosition(scheduledStartTime * sampleRate),
                file.length
            )
            let remaining = file.length - startFrame
            guard remaining > 0 else { continue }
            scheduledAny = true

            if id == referenceID {
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
        scheduleClick(from: scheduledStartTime)
        isScheduled = scheduledAny
    }

    private func updateCurrentTime() {
        guard
            let referenceID,
            let player = players[referenceID],
            let elapsed = PlayerClock.elapsedSeconds(player)
        else { return }

        // PlayerClock divides sampleTime by the player's OWN timebase (its output-bus
        // rate), which is correct regardless of the file's sample rate.
        currentTime = min(scheduledStartTime + elapsed, duration)
    }

    private func startTimer() {
        stopTimer()
        // 30Hz, not 60Hz — see the matching comment in AudioPlaybackService.startTimer(): every
        // tick republishes `currentTime`, which forces the ChordPro chart's whole body (measure
        // grid, waveform slicing, chord layout) to re-evaluate even though none of that depends on
        // the playhead. Halving the rate halves that redundant work; stem meters read fine at 30Hz
        // (real VU meters commonly update in the 15-30Hz range).
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePlaybackMeters()
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
        resetStemLevels()
    }

    private func duration(of file: AVAudioFile) -> TimeInterval {
        Double(file.length) / file.processingFormat.sampleRate
    }

    private func updatePlaybackMeters() {
        updateCurrentTime()
        guard isPlaying else {
            resetStemLevels()
            return
        }
        for id in meterFiles.keys {
            let stereo = meterStereoLevel(for: id, at: currentTime)
            stemStereoLevels[id] = stereo
            stemLevels[id] = max(stereo.left, stereo.right)
        }
    }

    /// Post-fader, post-pan, post-master L/R RMS for one stem at `time` — one file read feeds
    /// both the vertical VU (max of the sides) and the horizontal L/R meter.
    private func meterStereoLevel(for id: StemID, at time: TimeInterval) -> StemStereoLevel {
        guard let file = meterFiles[id], file.length > 0 else { return .zero }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = min(
            max(AVAudioFramePosition(time * sampleRate), 0),
            file.length - 1
        )
        let frameCount = min(AVAudioFrameCount(2_048), AVAudioFrameCount(file.length - startFrame))
        guard
            frameCount > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else { return .zero }

        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: frameCount)
            let source = Self.stereoMeterLevel(from: buffer)
            let volume = players[id]?.volume ?? 0
            let gains = Self.panGains(for: appliedMixer[id].pan)
            // Constant-power law: ×√2 restores unity at center so the meters read the same
            // as the old mono meter for an unpanned stem.
            let normalization = Float(2).squareRoot()
            let master = appliedMixer.masterGain
            return StemStereoLevel(
                left: min(source.left * volume * gains.left * normalization * master, 1),
                right: min(source.right * volume * gains.right * normalization * master, 1)
            )
        } catch {
            return .zero
        }
    }

    private func resetStemLevels() {
        let ids = Set(stemLevels.keys).union(meterFiles.keys)
        for id in ids {
            stemLevels[id] = 0
            stemStereoLevels[id] = .zero
        }
    }

    static func meterLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sumOfSquares += sample * sample
            }
        }
        let meanSquare = sumOfSquares / Float(channelCount * frameLength)
        return min(max(sqrt(meanSquare), 0), 1)
    }

    /// Per-side RMS of the buffer's first two channels; a mono buffer reads the same on both
    /// sides (its signal feeds both speakers equally before panning).
    static func stereoMeterLevel(from buffer: AVAudioPCMBuffer) -> StemStereoLevel {
        guard let channelData = buffer.floatChannelData else { return .zero }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return .zero }

        func rms(channel: Int) -> Float {
            let samples = channelData[channel]
            var sumOfSquares: Float = 0
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sumOfSquares += sample * sample
            }
            return min(max(sqrt(sumOfSquares / Float(frameLength)), 0), 1)
        }

        let left = rms(channel: 0)
        let right = channelCount > 1 ? rms(channel: 1) : left
        return StemStereoLevel(left: left, right: right)
    }

    private func releaseSecurityScopes() {
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
    }
}
