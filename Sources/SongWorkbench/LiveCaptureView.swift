import SwiftUI

/// Minimal live-capture flow: pick a source, start/stop, watch the chords detect live, then
/// save the derived chart onto the selected song as a draft. No audio is ever saved. The saved
/// chart lands in the existing Chord Timeline editor, where the ChordPro ball-offset slider
/// nudges its timing to correct the near-constant capture latency.
struct LiveCaptureSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var session = LiveCaptureSession()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Live Capture", systemImage: "dot.radiowaves.left.and.right")
                    .font(.swDisplay(16, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Spacer()
                Text("Detecting chords only — lyrics are a later phase")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Source", selection: $session.sourceKind) {
                ForEach(session.selectableKinds, id: \.self) { kind in
                    Text(sourceLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(session.isCapturing)

            Text(sourceHint(session.sourceKind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            signalRow

            if case .muted = session.phase {
                Label(LiveCaptureSession.mutedMessage, systemImage: "speaker.slash.fill")
                    .font(.callout)
                    .foregroundStyle(Color.swCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = session.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.swCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            liveReadout

            Label(
                "Audio is not saved — only the detected chord chart is.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                if model.selectedSong == nil {
                    Text("Select a song first — the chart attaches to it.")
                        .font(.caption)
                        .foregroundStyle(Color.swCoral)
                }
                Spacer()
                Button("Cancel") {
                    session.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if session.isCapturing {
                    Button("Stop & Save", systemImage: "stop.fill") {
                        finish()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start", systemImage: "record.circle") {
                        session.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedSong == nil)
                }
            }
        }
        .padding()
        .frame(width: 520)
    }

    private var signalRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(signalColor)
                .frame(width: 10, height: 10)
            Text(signalText)
                .font(.swDisplay(12, weight: .medium))
                .foregroundStyle(Color.swTextSecondary)
            ProgressView(value: Double(min(max(session.level * 4, 0), 1)))
                .frame(maxWidth: .infinity)
            Text(timeLabel(session.capturedDuration))
                .font(.swMono(12))
                .foregroundStyle(Color.swTextSecondary)
        }
    }

    private var liveReadout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detected chords")
                .font(.swDisplay(12, weight: .semibold))
                .foregroundStyle(Color.swTextSecondary)
            if session.liveChords.isEmpty {
                Text(session.isCapturing ? "Listening…" : "No chords yet.")
                    .font(.swMono(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        // Show the most recent chords on the trailing edge as they detect.
                        ForEach(session.liveChords.suffix(24)) { event in
                            Text(event.chord)
                                .font(.swMono(13, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.swSurface, in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(Color.swTextPrimary)
                        }
                    }
                }
                .frame(minHeight: 60)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .swSurfacePanel(cornerRadius: 8)
    }

    private func finish() {
        let outcome = session.stop()
        if case .chart(let analysis) = outcome {
            model.applyLiveCaptureChart(analysis)
            dismiss()
        }
        // .muted / .empty leave the sheet open so the user sees why nothing was saved.
    }

    private var signalColor: Color {
        switch session.signalState {
        case .live: Color.swMint
        case .pending: Color.swTextSecondary
        case .silent: Color.swCoral
        }
    }

    private var signalText: String {
        switch session.signalState {
        case .live: "Signal"
        case .pending: session.isCapturing ? "Waiting for signal…" : "Idle"
        case .silent: "No audio"
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%01d:%02d", whole / 60, whole % 60)
    }

    private func sourceLabel(_ kind: CaptureSourceKind) -> String {
        switch kind {
        case .systemAudio: "Another app"
        case .loopbackDevice: "Loopback"
        case .microphone: "Microphone"
        case .synthetic: "Synthetic"
        }
    }

    private func sourceHint(_ kind: CaptureSourceKind) -> String {
        switch kind {
        case .systemAudio:
            "Captures another app's output (needs Screen & System Audio Recording). Apple Music and "
                + "other protected audio may be muted by macOS — that's expected and can't be bypassed."
        case .loopbackDevice:
            "Routes an app through a virtual device (BlackHole/Loopback). Most reliable for "
                + "unprotected app audio."
        case .microphone:
            "Captures the room through the mic. Usable for sketching; room noise degrades accuracy."
        case .synthetic:
            ""
        }
    }
}
