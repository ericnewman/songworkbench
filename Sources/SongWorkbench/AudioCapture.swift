import Accelerate
import Foundation

// Live-capture feasibility spike (Phase 0). This file is the pure, headless-testable
// core: the capture-source protocol, RMS/silence classification, a synthetic source for
// unit tests, and a small probe that turns a capture run into a go/no-go verdict. Real
// device-backed sources live in `AudioCaptureSources.swift` and cannot be exercised
// without a real Mac + audio hardware.

/// A selectable place to tap live audio from. Drives source selection in the UI later.
enum CaptureSourceKind: String, CaseIterable, Sendable {
    /// Another app's / the system's output via the modern system-audio capture API.
    case systemAudio
    /// A user-installed virtual loopback input device (BlackHole / Loopback).
    case loopbackDevice
    /// The microphone or other real input device (room capture).
    case microphone
    /// In-memory injected buffers. Test/spike only; never offered in the UI.
    case synthetic
}

/// One chunk of captured mono PCM. Transient analysis input only — never persisted.
struct CaptureBuffer: Sendable, Equatable {
    /// Mono float samples, nominally in [-1, 1].
    let samples: [Float]
    let sampleRate: Double
}

enum CaptureError: LocalizedError, Equatable {
    case sourceUnavailable(CaptureSourceKind)
    case permissionDenied(CaptureSourceKind)
    /// The capture path compiles but must be proven on a real Mac before use.
    case requiresOnDeviceValidation(CaptureSourceKind)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let kind):
            return "Capture source \(kind.rawValue) is not available on this system."
        case .permissionDenied(let kind):
            return "Permission to capture from \(kind.rawValue) was denied."
        case .requiresOnDeviceValidation(let kind):
            return "Capture source \(kind.rawValue) needs on-device validation (Phase 0 spike)."
        }
    }
}

/// Narrow boundary over a live mono audio stream, mirroring the protocol-first shape of
/// `StemSeparationEngine` / `TranscriptionEngine`. The real pipeline consumes this; the
/// spike feeds synthetic buffers through it.
protocol AudioCaptureSource: AnyObject, Sendable {
    var kind: CaptureSourceKind { get }
    /// Begin delivering buffers. `onBuffer` may be called from a realtime audio thread.
    func start(onBuffer: @escaping @Sendable (CaptureBuffer) -> Void) throws
    func stop()
}

// MARK: - Silence / muted-capture detection (pure)

/// Linear RMS of a mono buffer. Pure; FairPlay-muted output is digital silence → 0.
func captureRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return vDSP.rootMeanSquare(samples)
}

/// What a window of audio looks like to the mute detector.
enum CaptureSignalState: Equatable, Sendable {
    /// Usable signal present.
    case live
    /// Below the floor, but still inside the grace period — not yet a verdict.
    case pending
    /// Sustained silence past the grace period: likely muted/blocked (e.g. FairPlay).
    case silent
}

/// Pure level classifier. A window counts as `live` when its loudest RMS reading reaches
/// the floor, otherwise `silent`. Time-based grace lives in `CaptureMuteMonitor`.
struct CaptureMuteDetector: Sendable {
    /// Linear RMS floor. ~-60 dBFS; tuning knob for real rooms/quiet passages.
    /// ponytail: fixed floor; make adaptive only if quiet real passages false-trip it.
    var silenceFloor: Float = 0.001

    func classify(rmsWindow: [Float]) -> CaptureSignalState {
        let peak = rmsWindow.max() ?? 0
        return peak >= silenceFloor ? .live : .silent
    }
}

/// Stateful sliding-window monitor: reports `silent` only after the stream stays below the
/// floor for `graceWindow`, so a brief gap or a slow start does not falsely flag a muted
/// (FairPlay) source. Any live buffer re-arms the grace period.
struct CaptureMuteMonitor: Sendable {
    var detector = CaptureMuteDetector()
    /// How long continuous silence must persist before we call it muted/blocked.
    var graceWindow: TimeInterval = 2.0

    private var silentElapsed: TimeInterval = 0
    private var sawLiveSignal = false

    init(detector: CaptureMuteDetector = CaptureMuteDetector(), graceWindow: TimeInterval = 2.0) {
        self.detector = detector
        self.graceWindow = graceWindow
    }

    /// Feed one buffer's RMS plus how long that buffer represents.
    mutating func observe(rms: Float, duration: TimeInterval) -> CaptureSignalState {
        if detector.classify(rmsWindow: [rms]) == .live {
            sawLiveSignal = true
            silentElapsed = 0
            return .live
        }
        silentElapsed += duration
        if silentElapsed >= graceWindow { return .silent }
        return sawLiveSignal ? .live : .pending
    }

    /// Convenience for a whole `CaptureBuffer`.
    mutating func observe(_ buffer: CaptureBuffer) -> CaptureSignalState {
        let duration =
            buffer.sampleRate > 0
            ? Double(buffer.samples.count) / buffer.sampleRate : 0
        return observe(rms: captureRMS(buffer.samples), duration: duration)
    }
}

// MARK: - Synthetic source (test injection)

/// Injects pre-made buffers through the protocol. Delivery is gated on start/stop so the
/// lifecycle is testable without any audio hardware.
final class SyntheticCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let kind: CaptureSourceKind
    private let lock = NSLock()
    private var sink: (@Sendable (CaptureBuffer) -> Void)?

    init(kind: CaptureSourceKind = .synthetic) {
        self.kind = kind
    }

    func start(onBuffer: @escaping @Sendable (CaptureBuffer) -> Void) {
        lock.lock()
        sink = onBuffer
        lock.unlock()
    }

    func stop() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    /// Push a buffer. Returns whether it was delivered (i.e. started and not stopped).
    @discardableResult
    func feed(_ buffer: CaptureBuffer) -> Bool {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(buffer)
        return sink != nil
    }
}

// MARK: - Spike probe (go/no-go)

/// Result of running a short capture window through the mute monitor.
struct CaptureProbeResult: Equatable, Sendable {
    let bufferCount: Int
    let peakRMS: Float
    /// Final verdict from the mute monitor over the captured window.
    let signalState: CaptureSignalState
}

/// Drives a source for the spike: collects buffers, tracks level, and produces a verdict.
/// This is the headless harness — point it at the synthetic source in tests, or a real
/// source on a Mac for the manual go/no-go.
final class CaptureFeasibilityProbe: @unchecked Sendable {
    private let source: AudioCaptureSource
    private var monitor: CaptureMuteMonitor
    private let lock = NSLock()
    private var bufferCount = 0
    private var peakRMS: Float = 0
    private var state: CaptureSignalState = .pending

    init(source: AudioCaptureSource, monitor: CaptureMuteMonitor = CaptureMuteMonitor()) {
        self.source = source
        self.monitor = monitor
    }

    func start() throws {
        try source.start { [weak self] buffer in
            guard let self else { return }
            self.lock.lock()
            self.bufferCount += 1
            self.peakRMS = max(self.peakRMS, captureRMS(buffer.samples))
            self.state = self.monitor.observe(buffer)
            self.lock.unlock()
        }
    }

    func stop() -> CaptureProbeResult {
        source.stop()
        lock.lock()
        defer { lock.unlock() }
        return CaptureProbeResult(
            bufferCount: bufferCount,
            peakRMS: peakRMS,
            signalState: state
        )
    }
}
