import SwiftUI

/// Static "about" metadata for the application: author, third-party libraries,
/// downloadable models, and noteworthy implementation facts. Kept as plain data
/// so the About window is a thin presentation over it.
enum AboutInfo {
    static let appName = "SongWorkbench"
    static let version = "1.0"
    static let author = "Eric Newman"
    /// The line under the Endogen logo at the foot of the About box (brand core rule 8), current year.
    static var copyright: String {
        "© \(Calendar.current.component(.year, from: Date())) Endogen LLC"
    }
    /// What VoiceOver reads for the "by" + Endogen lockup attribution.
    static let byline = "by Endogen"
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
        ScrollView { AboutContent() }
            .background(Color.swCanvas)
    }
}

/// The About window's contents, apart from its scroll view (which offscreen renders can't draw).
struct AboutContent: View {
    var body: some View {
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

            // Endogen's attribution closes the About box: "by", the color lockup, the copyright.
            Divider()
            EndogenAttribution(copyright: AboutInfo.copyright)
        }
        .padding(28)
        .frame(width: 520, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppTitleBlock(showsEndogen: false)
            Text("Version \(AboutInfo.version)  ·  \(AboutInfo.author)")
                .font(.swMono(11))
                .foregroundStyle(Color.swTextSecondary)
            Text(AboutInfo.tagline)
                .font(.swDisplay(12))
                .foregroundStyle(Color.swTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// The app as the hero of its own screens (Endogen brand core rule 8): its icon and its name in
/// the brand's `h1` style, with Endogen's logo beneath as attribution. Shared by the About window,
/// the first-run welcome sheet and the launch view, so the three stay alike. The About window
/// passes `showsEndogen: false` and puts `EndogenAttribution` at its foot instead.
struct AppTitleBlock: View {
    var axis: Axis = .horizontal
    var showsEndogen = true

    var body: some View {
        let layout =
            axis == .horizontal
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .center, spacing: 12))
        layout {
            AppIconImage(size: axis == .horizontal ? 72 : 112)
            VStack(alignment: axis == .horizontal ? .leading : .center, spacing: 6) {
                Text(AboutInfo.appName)
                    .font(Font.Endogen.h1)
                    .tracking(-0.96)  // h1: -2%
                    .foregroundStyle(Color.swTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if showsEndogen {
                    EndogenAttribution()
                }
            }
        }
    }
}

/// Endogen's attribution on an app screen (brand core rule 8): a small "by" in the `label` style,
/// then the color Endogen lockup at 160 pt wide (rule: 140 to 180), and in About boxes the
/// copyright line under it in `small` Mist. The app is dark only (`.preferredColorScheme(.dark)`),
/// so the lockup is always the dark-background artwork, copied unaltered from the brand kit.
struct EndogenAttribution: View {
    var copyright: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text("by")
                    .font(Font.Endogen.label)
                    .textCase(.uppercase)
                    .tracking(1.3)
                    .foregroundStyle(Color.swTextSecondary)
                Image("EndogenLockup")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    // A fixed height too (the artwork is 600 x 246), so the logo never gives up
                    // height to a stack that is laying out under a tight vertical proposal.
                    .frame(width: 160, height: 160 * 246 / 600)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AboutInfo.byline)
            if let copyright {
                Text(copyright)
                    .font(Font.Endogen.small)
                    .foregroundStyle(Color.swTextSecondary)
            }
        }
    }
}

/// The app's own icon, rounded the way the system shows app icons (the asset is square).
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        icon
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }

    private var icon: Image {
        #if os(macOS)
            Image(nsImage: NSApplication.shared.applicationIconImage)
        #else
            Image(systemName: "waveform")
        #endif
    }
}
