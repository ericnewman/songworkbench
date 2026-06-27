import Accelerate
import Foundation

// Phase 1: live chord detection on the Phase 0 capture path. Captured audio is transient,
// in-memory analysis input only — NO audio file is ever written and NO StoredAudioReference is
// ever created. We reuse the offline chord primitives unchanged and persist only the derived
// chart (chords + tempo + key) as a draft, with `AnalysisSourceKind.liveCapture` provenance.

/// Incremental, in-memory chord analyzer. Holds a growing mono sample buffer plus a framing
/// cursor and runs the EXACT offline chord path frame-by-frame as audio arrives:
/// `MonoSampleFramer` → `MagnitudeSpectrumAnalyzer` → `ChromaAnalyzer` → `ChordClassifier`.
///
/// Thread model: `append` runs on the realtime capture callback (any thread) and only copies
/// samples + updates level/mute state under a lock — cheap, no DFT. The DFT runs in
/// `drainNewObservations`, called from the main-actor session tick.
final class LiveHarmonyAnalyzer: @unchecked Sendable {
    /// Match the offline file path (`AudioFileAnalysisService`) so live and offline charts come
    /// from identical framing.
    static let frameLength = 8_192
    static let hopLength = 4_096

    /// Cap the retained buffer so an unbounded session can't grow memory without limit. A live
    /// chart covers the whole take, so we retain from the start and stop accepting past the cap
    /// rather than dropping the beginning.
    /// ponytail: fixed 12-minute cap; raise if longer single takes are needed.
    let maxDuration: TimeInterval

    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var nextFrameStart = 0
    private var observations: [ChordObservation] = []
    private var monitor: CaptureMuteMonitor
    private var latestSignal: CaptureSignalState = .pending
    private var latestLevel: Float = 0
    private var everLive = false
    private var reachedCap = false

    init(monitor: CaptureMuteMonitor = CaptureMuteMonitor(), maxDuration: TimeInterval = 12 * 60) {
        self.monitor = monitor
        self.maxDuration = maxDuration
    }

    /// Realtime-callback safe: copies samples, advances the mute monitor + level. No DFT here.
    func append(_ buffer: CaptureBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if sampleRate == 0 { sampleRate = buffer.sampleRate }
        let signal = monitor.observe(buffer)
        latestSignal = signal
        latestLevel = captureRMS(buffer.samples)
        if signal == .live { everLive = true }
        guard sampleRate > 0, !reachedCap else { return }
        if Double(samples.count) / sampleRate >= maxDuration {
            reachedCap = true
            return
        }
        samples.append(contentsOf: buffer.samples)
    }

    /// Frames + classifies every newly-complete frame since the last drain, appends those
    /// observations, and returns only the new ones. Absolute timestamps (seconds from capture
    /// start) come straight from the framer.
    func drainNewObservations() -> [ChordObservation] {
        lock.lock()
        let snapshot = samples
        let rate = sampleRate
        let start = nextFrameStart
        lock.unlock()

        guard
            rate > 0, snapshot.count >= Self.frameLength,
            let config = try? AudioAnalysisConfiguration(
                sampleRate: rate, frameLength: Self.frameLength, hopLength: Self.hopLength),
            let transform = try? MagnitudeSpectrumAnalyzer.makeTransform(
                frameLength: Self.frameLength)
        else { return [] }

        let framer = MonoSampleFramer(configuration: config)
        let spectrumAnalyzer = MagnitudeSpectrumAnalyzer()
        let chromaAnalyzer = ChromaAnalyzer()
        let classifier = ChordClassifier()

        var fresh: [ChordObservation] = []
        var cursor = start
        while cursor + Self.frameLength <= snapshot.count {
            let frame = framer.frame(from: snapshot, startIndex: cursor)
            if let spectrum = try? spectrumAnalyzer.analyze(
                frame, sampleRate: rate, transform: transform)
            {
                fresh.append(classifier.classify(chromaAnalyzer.analyze(spectrum)))
            }
            cursor += Self.hopLength
        }

        lock.lock()
        nextFrameStart = cursor
        observations.append(contentsOf: fresh)
        lock.unlock()
        return fresh
    }

    /// Live telemetry for the UI meter / mute indicator.
    var telemetry: (signal: CaptureSignalState, level: Float, duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        return (latestSignal, latestLevel, duration)
    }

    /// True once any buffer reached the live floor. Drives the muted-capture decision: a stream
    /// that never went live yields the muted message and no chart.
    var sawLiveSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return everLive
    }

    /// Reduce everything captured so far into a clean, de-duplicated chord readout (no beat grid
    /// yet — that's computed once on `finish`). Cheap; safe to call every tick.
    func currentChart() -> [EditableChordEvent] {
        lock.lock()
        let all = observations
        lock.unlock()
        return ChordEventReducer().events(
            from: SongAudioAnalysis(beat: nil, chords: all))
    }

    /// Final pass over the retained buffer: runs `BeatTracker` + `MusicalKeyEstimator` exactly
    /// like the offline path and returns the assembled analysis. In-memory only.
    func finish() -> SongAudioAnalysis {
        lock.lock()
        let all = observations
        let snapshot = samples
        let rate = sampleRate
        lock.unlock()
        let beat = rate > 0 ? BeatTracker().analyze(samples: snapshot, sampleRate: rate) : nil
        return SongAudioAnalysis(
            beat: beat,
            chords: all,
            estimatedKey: MusicalKeyEstimator().estimate(from: all)
        )
    }
}

/// Orchestrates a live-capture run: picks a source, streams its buffers into the analyzer, and
/// publishes live state for the UI. On stop it assembles the result (or reports a muted source).
/// The captured audio never leaves memory; only the derived chart is handed back for saving.
@MainActor
final class LiveCaptureSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case capturing
        case stopped
        /// Sustained silence with no usable signal (e.g. FairPlay-muted Apple Music). No chart.
        case muted
        case failed(String)
    }

    /// Outcome handed back on stop.
    enum Outcome: Equatable {
        case chart(SongAudioAnalysis)
        /// No usable audio reached us — surface the muted message, never a blank chart.
        case muted
        case empty
    }

    static let mutedMessage =
        "No audio detected from this source — protected or streaming audio (e.g. Apple Music) "
        + "can't be analyzed. Try a local file played in another app, a loopback device, or the "
        + "microphone."

    @Published private(set) var phase: Phase = .idle
    @Published var sourceKind: CaptureSourceKind = .loopbackDevice
    @Published private(set) var signalState: CaptureSignalState = .pending
    @Published private(set) var level: Float = 0
    @Published private(set) var capturedDuration: TimeInterval = 0
    /// Rolling, de-duplicated chord readout shown while capturing.
    @Published private(set) var liveChords: [EditableChordEvent] = []

    private var analyzer = LiveHarmonyAnalyzer()
    private var source: AudioCaptureSource?
    private var tickTask: Task<Void, Never>?
    /// Override for tests: supply a source (e.g. `SyntheticCaptureSource`) instead of the catalog.
    private let makeSource: (CaptureSourceKind) throws -> AudioCaptureSource

    init(
        makeSource: @escaping (CaptureSourceKind) throws -> AudioCaptureSource = {
            try CaptureSourceCatalog.makeSource(kind: $0)
        }
    ) {
        self.makeSource = makeSource
    }

    var isCapturing: Bool { phase == .capturing }

    /// Selectable kinds for the UI source picker.
    var selectableKinds: [CaptureSourceKind] { CaptureSourceCatalog.selectableKinds }

    func start() {
        guard phase != .capturing else { return }
        analyzer = LiveHarmonyAnalyzer()
        liveChords = []
        level = 0
        capturedDuration = 0
        signalState = .pending
        let analyzer = self.analyzer
        do {
            let source = try makeSource(sourceKind)
            try source.start { buffer in
                // Realtime thread: cheap append only (no DFT, no main-actor hop).
                analyzer.append(buffer)
            }
            self.source = source
            phase = .capturing
            startTicking()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops capture, assembles the result, and returns the outcome. A stream that never went
    /// live becomes `.muted` (no chart); silence with zero detected chords becomes `.empty`.
    @discardableResult
    func stop() -> Outcome {
        guard phase == .capturing else { return .empty }
        source?.stop()
        source = nil
        tickTask?.cancel()
        tickTask = nil
        _ = analyzer.drainNewObservations()

        guard analyzer.sawLiveSignal else {
            phase = .muted
            return .muted
        }
        let analysis = analyzer.finish()
        let chart = ChordEventReducer().events(from: analysis)
        guard !chart.isEmpty else {
            phase = .muted
            return .muted
        }
        phase = .stopped
        return .chart(analysis)
    }

    func cancel() {
        source?.stop()
        source = nil
        tickTask?.cancel()
        tickTask = nil
        phase = .idle
        liveChords = []
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    /// One UI refresh: drain new frames, recompute the rolling readout + telemetry. Also callable
    /// directly from tests to drive the session without the timer.
    func tick() {
        _ = analyzer.drainNewObservations()
        let telemetry = analyzer.telemetry
        signalState = telemetry.signal
        level = telemetry.level
        capturedDuration = telemetry.duration
        liveChords = analyzer.currentChart()
    }
}
