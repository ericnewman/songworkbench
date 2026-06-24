import SwiftUI

/// Static "about" metadata for the application: author, third-party libraries,
/// downloadable models, and noteworthy implementation facts. Kept as plain data
/// so the About window is a thin presentation over it.
enum AboutInfo {
    static let appName = "SongWorkbench"
    static let version = "1.0"
    static let author = "Eric Newman"
    static let copyright = "© 2026 Eric Newman"
    static let tagline =
        "A local-first macOS workbench for decoding a recording into lyrics, chords, bass lines, and stems."

    struct Credit: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let license: String
    }

    static let libraries: [Credit] = [
        Credit(
            name: "ONNX Runtime 1.24.2",
            detail: "Microsoft — runs the HTDemucs stem-separation graph on-device.",
            license: "MIT"
        ),
        Credit(
            name: "FluidAudio 0.15.4",
            detail: "FluidInference — Core ML Parakeet fast-draft transcription.",
            license: "Apache-2.0"
        ),
        Credit(
            name: "whisper.cpp",
            detail: "ggml-org (Georgi Gerganov) — accuracy lyric transcription.",
            license: "MIT"
        ),
        Credit(
            name: "Apple frameworks",
            detail: "SwiftUI, AVFoundation / AVAudioEngine, Accelerate / vDSP, Core ML, AppKit.",
            license: "System"
        ),
    ]

    static let models: [Credit] = [
        Credit(
            name: "HTDemucs 6-Source ONNX",
            detail:
                "Six-stem separation (vocals, drums, bass, guitar, piano, other). HTDemucs by Meta; ONNX export by MansfieldPlumbing.",
            license: "CC-BY-NC-4.0"
        ),
        Credit(
            name: "Whisper Large V3 Turbo (Q5_0)",
            detail: "Accuracy lyric transcription. Whisper by OpenAI; GGML conversion by ggml-org.",
            license: "MIT"
        ),
        Credit(
            name: "Parakeet TDT 0.6B V3 (Core ML)",
            detail:
                "Fast-draft lyric transcription. Parakeet by NVIDIA; Core ML conversion by FluidInference.",
            license: "CC-BY-4.0"
        ),
    ]

    static let facts: [String] = [
        "Local-first: analysis runs entirely on-device and works offline once models are installed. Source recordings are never modified.",
        "Chords, beat, and key are estimated natively with Accelerate / vDSP (chroma + autocorrelation) — no ML model required.",
        "Transcription and harmony run concurrently; results are cached by source content + engine / model / schema identity, so re-runs are instant.",
        "ChordPro generation is deterministic, and lyrics and chords stay editable regardless of which models are installed.",
        "A beat-synced bouncing ball traces the lyric line over the detected beats.",
    ]
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("Open-source libraries", credits: AboutInfo.libraries)
                section("Models", credits: AboutInfo.models)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Under the hood")
                        .font(.swDisplay(13, weight: .semibold))
                        .foregroundStyle(Color.swTextPrimary)
                    ForEach(Array(AboutInfo.facts.enumerated()), id: \.offset) { _, fact in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color.swMint)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(fact)
                                .font(.swDisplay(12))
                                .foregroundStyle(Color.swTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text(AboutInfo.copyright)
                    .font(.swMono(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding(28)
            .frame(width: 520, alignment: .leading)
        }
        .background(Color.swCanvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.swAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AboutInfo.appName)
                        .font(.swDisplay(24, weight: .semibold))
                        .foregroundStyle(Color.swTextPrimary)
                    Text("Version \(AboutInfo.version)  ·  \(AboutInfo.author)")
                        .font(.swMono(11))
                        .foregroundStyle(Color.swTextSecondary)
                }
            }
            Text(AboutInfo.tagline)
                .font(.swDisplay(12))
                .foregroundStyle(Color.swTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func section(_ title: String, credits: [AboutInfo.Credit]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.swDisplay(13, weight: .semibold))
                .foregroundStyle(Color.swTextPrimary)
            ForEach(credits) { credit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(credit.name)
                            .font(.swDisplay(12, weight: .medium))
                            .foregroundStyle(Color.swTextPrimary)
                        Text(credit.license)
                            .font(.swMono(10))
                            .foregroundStyle(Color.swTextSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.swSurface, in: Capsule())
                    }
                    Text(credit.detail)
                        .font(.swDisplay(11))
                        .foregroundStyle(Color.swTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
