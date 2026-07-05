import AVFoundation
import Accelerate
import CoreGraphics
import Foundation

// Real device-backed capture sources for the Phase 0 spike. These COMPILE and are written
// to work on a real Mac, but cannot be exercised by `swift test` in a headless CI box
// (no audio devices, no TCC prompts). The viable, low-risk path is `AVAudioEngine` input,
// which serves BOTH the microphone and a user-installed loopback device (BlackHole), since
// a loopback shows up as an ordinary input device. The "capture another app" path
// (system-audio / process tap) is gated behind a feasibility probe — see
// `SystemAudioCaptureProbe` and the report — because it depends on the Screen & System
// Audio Recording TCC permission and on sandbox behavior that varies by macOS version.

/// Mic and loopback capture via `AVAudioEngine.inputNode`. Pass a `deviceID` to select a
/// specific input (e.g. BlackHole); omit it to use the default input (microphone).
final class AVAudioEngineCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let kind: CaptureSourceKind
    private let deviceID: PlatformAudioDeviceID?
    private let engine = AVAudioEngine()
    private var started = false

    /// - Parameters:
    ///   - kind: `.microphone` or `.loopbackDevice` (telemetry/UX only).
    ///   - deviceID: Core Audio device to capture from; `nil` = system default input.
    init(kind: CaptureSourceKind = .microphone, deviceID: PlatformAudioDeviceID? = nil) {
        self.kind = kind
        self.deviceID = deviceID
    }

    func start(onBuffer: @escaping @Sendable (CaptureBuffer) -> Void) throws {
        guard !started else { return }

        #if os(macOS)
            // Explicit HAL input-device selection (e.g. BlackHole) is a macOS concept;
            // iPadOS routes input through AVAudioSession instead.
            if let deviceID {
                try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
            }
        #endif

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CaptureError.sourceUnavailable(kind)
        }
        let sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            guard let mono = AVAudioEngineCaptureSource.downmix(buffer) else { return }
            onBuffer(CaptureBuffer(samples: mono, sampleRate: sampleRate))
        }

        engine.prepare()
        try engine.start()
        started = true
    }

    func stop() {
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
    }

    /// Average all channels of a float PCM buffer to a mono `[Float]`.
    static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let pointer = channelData[channel]
            for frame in 0..<frames {
                mono[frame] += pointer[frame]
            }
        }
        if channelCount > 1 {
            return vDSP.multiply(1 / Float(channelCount), mono)
        }
        return mono
    }
}

/// Microphone-input authorization helpers (TCC). Needed by the mic and any loopback that
/// the OS treats as a microphone-class input.
enum AudioInputAuthorization {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// MARK: - System-audio (capture another app) feasibility

/// What the spike can determine about the "capture another app's audio" path WITHOUT a
/// real capture run: OS support for the modern APIs and whether the Screen & System Audio
/// Recording permission is already granted.
struct SystemAudioFeasibility: Equatable, Sendable {
    /// ScreenCaptureKit audio capture is available (macOS 13+).
    let screenCaptureKitAvailable: Bool
    /// Core Audio process-tap API is available (macOS 14.4+).
    let processTapAvailable: Bool
    /// Screen & System Audio Recording TCC permission currently granted.
    let screenRecordingPermissionGranted: Bool
}

/// Read-only probe for the system-audio path. Does not start a capture — that requires a
/// real Mac and is the explicit on-device validation step before Phase 1 builds the real
/// `SystemAudioCaptureSource`.
enum SystemAudioCaptureProbe {
    static func evaluate() -> SystemAudioFeasibility {
        let screenCaptureKit: Bool
        if #available(macOS 13.0, *) { screenCaptureKit = true } else { screenCaptureKit = false }

        let processTap: Bool
        if #available(macOS 14.4, *) { processTap = true } else { processTap = false }

        return SystemAudioFeasibility(
            screenCaptureKitAvailable: screenCaptureKit,
            processTapAvailable: processTap,
            // Preflight is non-prompting; CGRequestScreenCaptureAccess() prompts at first use.
            screenRecordingPermissionGranted: PlatformCapture.screenRecordingPreflight()
        )
    }
}

// MARK: - Source selection

/// Selectable capture sources for the spike/UI. The system-audio source is intentionally
/// not constructible yet (probe-gated); everything else maps to a real implementation.
enum CaptureSourceCatalog {
    /// Kinds offered to a user (excludes `.synthetic`).
    static var selectableKinds: [CaptureSourceKind] {
        [.systemAudio, .loopbackDevice, .microphone]
    }

    static func makeSource(
        kind: CaptureSourceKind,
        deviceID: PlatformAudioDeviceID? = nil
    ) throws -> AudioCaptureSource {
        switch kind {
        case .microphone:
            return AVAudioEngineCaptureSource(kind: .microphone, deviceID: deviceID)
        case .loopbackDevice:
            return AVAudioEngineCaptureSource(kind: .loopbackDevice, deviceID: deviceID)
        case .systemAudio:
            // Real SCStream/process-tap impl is Phase 1, gated on on-device validation.
            throw CaptureError.requiresOnDeviceValidation(.systemAudio)
        case .synthetic:
            return SyntheticCaptureSource()
        }
    }
}
