import XCTest

@testable import SongWorkbench

final class AudioCaptureTests: XCTestCase {
    private let sampleRate = 44_100.0

    private func tone(amplitude: Float = 0.5, count: Int = 4_410) -> CaptureBuffer {
        let frequency = 440.0
        let samples = (0..<count).map { index -> Float in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        return CaptureBuffer(samples: samples, sampleRate: sampleRate)
    }

    private func silence(count: Int = 4_410) -> CaptureBuffer {
        CaptureBuffer(samples: Array(repeating: 0, count: count), sampleRate: sampleRate)
    }

    // MARK: RMS + pure classification

    func testRMSOfToneMatchesAmplitudeOverRootTwo() {
        let rms = captureRMS(tone(amplitude: 0.5).samples)
        XCTAssertEqual(rms, Float(0.5 / 2.0.squareRoot()), accuracy: 0.01)
    }

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(captureRMS(silence().samples), 0)
    }

    func testToneClassifiesAsLive() {
        let detector = CaptureMuteDetector()
        XCTAssertEqual(detector.classify(rmsWindow: [captureRMS(tone().samples)]), .live)
    }

    func testSilenceClassifiesAsSilent() {
        let detector = CaptureMuteDetector()
        XCTAssertEqual(detector.classify(rmsWindow: [captureRMS(silence().samples)]), .silent)
    }

    // MARK: Time-based mute monitor (FairPlay/muted-source detection)

    func testMonitorReportsPendingThenSilentPastGrace() {
        var monitor = CaptureMuteMonitor(graceWindow: 0.25)
        // Each buffer is 4410/44100 = 0.1s.
        let s = silence()
        let first = monitor.observe(s)
        let second = monitor.observe(s)
        let third = monitor.observe(s)
        XCTAssertEqual(first, .pending)
        XCTAssertEqual(second, .pending)
        XCTAssertEqual(third, .silent)
    }

    func testLiveSignalReArmsGracePeriod() {
        var monitor = CaptureMuteMonitor(graceWindow: 0.25)
        let s = silence()
        let beforeSignal = monitor.observe(s)
        let signal = monitor.observe(tone())
        // Grace restarts after the live buffer.
        let afterSignal1 = monitor.observe(s)
        let afterSignal2 = monitor.observe(s)
        let afterSignal3 = monitor.observe(s)
        XCTAssertEqual(beforeSignal, .pending)
        XCTAssertEqual(signal, .live)
        XCTAssertEqual(afterSignal1, .live)
        XCTAssertEqual(afterSignal2, .live)
        XCTAssertEqual(afterSignal3, .silent)
    }

    // MARK: Synthetic source lifecycle

    func testSourceDeliversBuffersOnlyWhileStarted() {
        let source = SyntheticCaptureSource()
        let received = LockedBox<[CaptureBuffer]>([])

        XCTAssertFalse(source.feed(tone()), "no delivery before start")

        source.start { buffer in received.mutate { $0.append(buffer) } }
        XCTAssertTrue(source.feed(tone()))
        XCTAssertTrue(source.feed(silence()))

        source.stop()
        XCTAssertFalse(source.feed(tone()), "no delivery after stop")

        XCTAssertEqual(received.value.count, 2)
    }

    // MARK: End-to-end probe (the spike go/no-go)

    func testProbeReportsLiveForTone() throws {
        let source = SyntheticCaptureSource()
        let probe = CaptureFeasibilityProbe(
            source: source,
            monitor: CaptureMuteMonitor(graceWindow: 0.25)
        )
        try probe.start()
        for _ in 0..<5 { source.feed(tone()) }
        let result = probe.stop()

        XCTAssertEqual(result.bufferCount, 5)
        XCTAssertEqual(result.signalState, .live)
        XCTAssertGreaterThan(result.peakRMS, 0.001)
    }

    func testProbeReportsSilentForMutedSource() throws {
        // Mirrors a FairPlay-muted tap: buffers arrive but carry digital silence.
        let source = SyntheticCaptureSource()
        let probe = CaptureFeasibilityProbe(
            source: source,
            monitor: CaptureMuteMonitor(graceWindow: 0.25)
        )
        try probe.start()
        for _ in 0..<5 { source.feed(silence()) }
        let result = probe.stop()

        XCTAssertEqual(result.bufferCount, 5)
        XCTAssertEqual(result.signalState, .silent)
        XCTAssertEqual(result.peakRMS, 0)
    }

    // MARK: Source selection

    func testCatalogExcludesSyntheticFromSelectableKinds() {
        XCTAssertFalse(CaptureSourceCatalog.selectableKinds.contains(.synthetic))
    }

    func testCatalogMakesDeviceSourcesAndGatesSystemAudio() throws {
        XCTAssertEqual(try CaptureSourceCatalog.makeSource(kind: .microphone).kind, .microphone)
        XCTAssertEqual(
            try CaptureSourceCatalog.makeSource(kind: .loopbackDevice).kind, .loopbackDevice)
        XCTAssertThrowsError(try CaptureSourceCatalog.makeSource(kind: .systemAudio)) { error in
            XCTAssertEqual(
                error as? CaptureError, .requiresOnDeviceValidation(.systemAudio))
        }
    }
}

/// Tiny thread-safe box so the synthetic source's `@Sendable` callback can collect results.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
