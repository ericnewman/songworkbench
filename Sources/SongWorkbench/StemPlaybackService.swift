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
    /// Parent of each playing stem, so a group fader reaches the children it names. Empty for
    /// the flat `StemFiles` path, which has no hierarchy.
    private var parentByID: [StemID: StemID] = [:]
    private var meterFiles: [StemID: AVAudioFile] = [:]
    private var accessedURLs: [URL] = []
    private var generation = 0
    private var isScheduled = false
    private var referenceID: StemID?
    private var scheduledStartTime: TimeInterval = 0
    private var timer: Timer?

    // Synthetic click channels: one short reusable sample scheduled at each of a list of times.
    // Neither is a separated stem and their memory use does not scale with song duration.
    // `beatClick` marks the tempo grid; `chordClick`, at a higher pitch so the two never blur
    // together, marks where the chords are currently PLACED — the audible half of the
    // chord-placement A/B, since a click that lands with or against the recording's own chord
    // change is far easier to judge than a highlight moving on screen.
    private let beatClick = ClickChannel(frequency: 1000)
    private let chordClick = ClickChannel(frequency: 1600)
    @Published var clickGain: Float = 0 {
        didSet { beatClick.gain = clickGain }
    }
    @Published var chordClickGain: Float = 0 {
        didSet { chordClick.gain = chordClickGain }
    }

    /// What the beat click marks. ON: a metronome — one rigid period (`60 / bpm`) phase-locked to
    /// the bar grid's first downbeat and never nudged by the recording's content; the reference
    /// every detected beat is judged against. OFF: each detected beat time verbatim, so the
    /// tracker's own answer (drum-snapped, jitter and all) is what you hear. Persisted so the
    /// choice survives relaunch like the beat-dots toggle does.
    @Published var metronomeEnabled: Bool = StemPlaybackService.storedMetronomeEnabled {
        didSet {
            guard metronomeEnabled != oldValue else { return }
            UserDefaults.standard.set(metronomeEnabled, forKey: Self.metronomeDefaultsKey)
            rebuildBeatClick()
        }
    }
    static let metronomeDefaultsKey = "clickMetronomeEnabled"
    private static var storedMetronomeEnabled: Bool {
        UserDefaults.standard.object(forKey: metronomeDefaultsKey) as? Bool ?? true
    }

    /// The last beat-click inputs, kept so flipping `metronomeEnabled` can rebuild the channel
    /// without the caller having to re-supply them.
    struct BeatClickSource: Equatable {
        var beatTimes: [TimeInterval]
        var bpm: Double?
        var barGrid: SongBarGrid?
    }
    private(set) var beatClickSource: BeatClickSource?

    init() {
        for player in players.values {
            engine.attach(player)
        }
        engine.attach(beatClick.player)
        engine.attach(chordClick.player)
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
        parentByID = StemMixerChannelProjector.parentByID(for: manifest)

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
            players[id]?.volume = mixer.effectiveGain(
                for: id, activeIDs: activeIDs, parentByID: parentByID)
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

    /// Builds the beat click and connects it. Call after `load`. An empty `beatTimes` leaves the
    /// channel silent. Safe to call while playing. `bpm`/`barGrid` are the analysis's reconciled
    /// tempo and bar grid; they decide the metronome's period and downbeat anchor (see
    /// `metronomeGrid`) and are ignored when `metronomeEnabled` is off.
    func loadClickTrack(beatTimes: [TimeInterval], bpm: Double? = nil, barGrid: SongBarGrid? = nil)
    {
        beatClickSource = BeatClickSource(beatTimes: beatTimes, bpm: bpm, barGrid: barGrid)
        rebuildBeatClick()
    }

    private func rebuildBeatClick() {
        guard let source = beatClickSource else { return }
        let times = Self.beatClickTimes(
            for: source, metronome: metronomeEnabled, duration: duration)
        load(beatClick, times: times)
    }

    /// The times the beat click fires at for a given source and mode. Pure, so the
    /// metronome/verbatim contract is testable without an audio engine.
    static func beatClickTimes(
        for source: BeatClickSource, metronome: Bool, duration: TimeInterval
    ) -> [TimeInterval] {
        guard metronome else { return source.beatTimes.sorted() }
        return metronomeGrid(
            beatTimes: source.beatTimes, bpm: source.bpm, barGrid: source.barGrid,
            duration: duration)
    }

    /// Builds the chord click from wherever the chords are CURRENTLY placed. Unlike the beat
    /// click these times are used verbatim — no `uniformBeatGrid` — because their irregularity is
    /// the entire thing under test: regularising them would erase the difference between the
    /// placement variants being compared. Safe to call while playing, which is what makes an A/B
    /// possible without stopping the music.
    func loadChordClickTrack(times: [TimeInterval]) {
        load(chordClick, times: times.sorted())
    }

    private func load(_ channel: ClickChannel, times: [TimeInterval]) {
        guard let sampleRate = files.values.first?.processingFormat.sampleRate else {
            channel.clear()
            return
        }
        channel.load(times: times, sampleRate: sampleRate, engine: engine, mixer: stemMixerNode)
        if isScheduled {
            channel.stop()
            channel.schedule(from: scheduledStartTime, duration: duration)
            if isPlaying { channel.play() }
        }
    }

    /// One synthesised click channel: a node, a reusable one-shot sample, and the list of times to
    /// fire it at. Extracted rather than duplicated when the chord click was added — the two
    /// channels differ only in pitch and in which times they mark, and a second hand-maintained
    /// copy of the connect/schedule/transport dance is exactly how one of them ends up silently
    /// missing a `stop()` on seek.
    ///
    /// `@MainActor` to match the service: every method touches the shared `AVAudioEngine`.
    @MainActor
    final class ClickChannel {
        let player = AVAudioPlayerNode()
        private let frequency: Double
        private var buffer: AVAudioPCMBuffer?
        private var times: [TimeInterval] = []
        private var isConnected = false
        var gain: Float = 0 {
            didSet { player.volume = max(min(gain, StemMixState.maximumGain), 0) }
        }

        init(frequency: Double) { self.frequency = frequency }

        func load(
            times: [TimeInterval], sampleRate: Double, engine: AVAudioEngine,
            mixer: AVAudioMixerNode
        ) {
            self.times = times
            buffer =
                times.isEmpty
                ? nil
                : StemPlaybackService.makeClickSample(sampleRate: sampleRate, frequency: frequency)
            if let buffer, !isConnected {
                engine.connect(player, to: mixer, format: buffer.format)
                isConnected = true
            }
            player.volume = max(min(gain, StemMixState.maximumGain), 0)
        }

        func clear() {
            buffer = nil
            times = []
        }

        func schedule(from time: TimeInterval, duration: TimeInterval) {
            guard let buffer, isConnected else { return }
            let sampleRate = buffer.format.sampleRate
            let startTime = min(max(time, 0), duration)
            for mark in times where mark >= startTime && mark <= duration {
                player.scheduleBuffer(
                    buffer,
                    at: AVAudioTime(
                        sampleTime: AVAudioFramePosition((mark - startTime) * sampleRate),
                        atRate: sampleRate),
                    options: [],
                    completionHandler: nil
                )
            }
        }

        func play() { if isConnected, buffer != nil { player.play() } }
        func pause() { player.pause() }
        func stop() { player.stop() }

        func disconnect(from engine: AVAudioEngine) {
            clear()
            if isConnected {
                engine.disconnectNodeOutput(player)
                isConnected = false
            }
        }
    }

    static func makeClickSample(sampleRate: Double, frequency: Double = 1000) -> AVAudioPCMBuffer? {
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
            channel[offset] = Float(sin(2 * Double.pi * frequency * seconds) * envelope * 0.6)
        }
        return buffer
    }

    /// A metronome: one rigid period extended both directions over [0, duration], never nudged
    /// by the recording's content. Period is `60 / bpm` — the analysis's reconciled tempo, the same
    /// number the chart shows — and the phase anchor is the detected beat the bar grid calls the
    /// first downbeat (`beatTimes[barPhase]`), so beat 1 of the click is beat 1 of the chart.
    /// Without a usable BPM the period falls back to the median inter-beat interval of the
    /// detected beats (`uniformBeatGrid`); with fewer than two beats there is nothing to fit and
    /// the input is returned as-is.
    static func metronomeGrid(
        beatTimes: [TimeInterval], bpm: Double?, barGrid: SongBarGrid?, duration: TimeInterval
    ) -> [TimeInterval] {
        let sorted = beatTimes.sorted()
        guard let first = sorted.first else { return [] }
        let anchorIndex = min(max(barGrid?.barPhase ?? 0, 0), sorted.count - 1)
        let anchor = sorted[anchorIndex]
        if let bpm, bpm.isFinite, bpm > 0 {
            let period = 60 / bpm
            guard period > 0.05 else { return sorted }
            return periodicGrid(period: period, anchor: anchor, duration: duration)
        }
        // No tempo: fit the period from the beats themselves, keeping the downbeat anchor.
        return uniformBeatGrid(from: sorted, anchor: anchor, duration: duration) ?? [first]
    }

    /// Median inter-beat interval of `sorted` as the period, phase-anchored at `anchor`. `nil`
    /// when there aren't enough beats (or they are degenerately spaced) to estimate a period.
    static func uniformBeatGrid(
        from sorted: [TimeInterval], anchor: TimeInterval, duration: TimeInterval
    ) -> [TimeInterval]? {
        guard sorted.count >= 2 else { return nil }
        var intervals: [TimeInterval] = []
        for index in 1..<sorted.count { intervals.append(sorted[index] - sorted[index - 1]) }
        intervals.sort()
        let period = intervals[intervals.count / 2]  // median
        guard period > 0.05 else { return nil }  // sanity: ignore degenerate spacing
        return periodicGrid(period: period, anchor: anchor, duration: duration)
    }

    /// `anchor + k·period` for every integer k that lands in [0, duration], ascending. Computed by
    /// index rather than by repeated addition so a 4-minute grid does not accumulate float drift.
    static func periodicGrid(
        period: TimeInterval, anchor: TimeInterval, duration: TimeInterval
    ) -> [TimeInterval] {
        guard period > 0, duration >= 0 else { return [] }
        let firstIndex = Int(ceil(-anchor / period))
        let lastIndex = Int(floor((duration - anchor) / period))
        guard lastIndex >= firstIndex else { return [] }
        return (firstIndex...lastIndex).map { anchor + Double($0) * period }
    }

    private func scheduleClick(from time: TimeInterval) {
        beatClick.schedule(from: time, duration: duration)
        chordClick.schedule(from: time, duration: duration)
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
            beatClick.play()
            chordClick.play()
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
        beatClick.pause()
        chordClick.pause()
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
        beatClick.stop()
        chordClick.stop()
        stopTimer()
        isScheduled = false
        currentTime = min(max(time, 0), duration)
        scheduleAll(from: currentTime)
        if shouldResume, isScheduled {
            for id in files.keys {
                players[id]?.play()
            }
            beatClick.play()
            chordClick.play()
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
        parentByID.removeAll()
        meterFiles.removeAll()
        duration = 0
        referenceID = nil
        isLoaded = false
        beatClickSource = nil
        beatClick.disconnect(from: engine)
        chordClick.disconnect(from: engine)
        releaseSecurityScopes()
    }

    private func stop(resetPosition: Bool) {
        generation += 1
        for player in players.values {
            player.stop()
        }
        beatClick.stop()
        chordClick.stop()
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
