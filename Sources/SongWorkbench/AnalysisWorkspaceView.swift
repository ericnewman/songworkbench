import SwiftUI

struct AnalysisWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var showReplacementConfirmation = false
    @State private var showReferenceLyrics = false
    @State private var showLiveCapture = false
    /// Collapsed/expanded state of the card, persisted across launches. The header row (with
    /// its disclosure triangle) is always visible; the controls and stage rows fold away.
    @AppStorage("songAnalysisCardExpanded") private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.swTextSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Label("Song Analysis", systemImage: "waveform.badge.magnifyingglass")
                            .font(.swDisplay(15, weight: .semibold))
                            .foregroundStyle(Color.swTextPrimary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse Song Analysis" : "Expand Song Analysis")
                // Always-visible activity indicator so a long background run (stem separation
                // can take minutes on iPad) never looks stalled — shows even when the card is
                // collapsed.
                if model.isSongAnalysisRunning, let p = model.songAnalysisProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(
                            "\(p.stage.map(stageTitle) ?? "Analyzing")… "
                                + "\(Int((p.fractionCompleted * 100).rounded()))%"
                        )
                        .font(.swMono(11, weight: .medium))
                        .foregroundStyle(Color.swMint)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.leading, 8)
                }
                Spacer()
                ModelPackagesView(model: model)
            }

            if isExpanded {
                // No more Fast/Balanced/Accuracy picker (backlog #11, Lyric Blending): every
                // analysis now runs every installed transcription mode, and the "Lyric Blend"
                // window is how the user chooses between them per line — see
                // `AppModel.primaryTranscriptionMode`/`runLyricBlendPasses`.
                HStack(spacing: 8) {
                    Text("Decode speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.accuracyDecodeSpeed, in: 0.75...1.0, step: 0.05)
                    Text(
                        model.accuracyDecodeSpeed >= 0.999
                            ? "Off"
                            : "\(Int((model.accuracyDecodeSpeed * 100).rounded()))%"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                }
                .help(
                    "Slows the vocals (pitch preserved) before Whisper to help fast or dense "
                        + "singing; timestamps are mapped back. 100% = off. Changing this "
                        + "re-transcribes on the next Analyze.")

                HStack(spacing: 8) {
                    Text("Blank unsure words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.lyricConfidenceThreshold, in: 0...0.9, step: 0.05)
                    Text(
                        model.lyricConfidenceThreshold <= 0
                            ? "Off"
                            : "\(Int((model.lyricConfidenceThreshold * 100).rounded()))%"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                }
                .help(
                    "Shows a word as ___ when the transcriber's own confidence in it falls below "
                        + "this. Display only — the real words stay in the document, nothing is "
                        + "exported blanked, and no re-analysis is needed. Function words and "
                        + "lines you have corrected yourself are never blanked.")
                if model.lyricConfidenceThreshold > 0, model.selectedSong != nil {
                    Text(
                        model.blankedLyricWordCount == 0
                            ? "No words below this confidence."
                            : "\(model.blankedLyricWordCount) word"
                                + (model.blankedLyricWordCount == 1 ? "" : "s")
                                + " shown as ___"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                // The workspace lives in a fixed 360pt column; on iOS the bordered buttons
                // render large and, with full text labels, wrapped to multiple lines and
                // overflowed. Keep the primary Analyze button labeled but make the secondary
                // actions icon-only (with accessibility labels + help), and shrink the whole
                // row to a small control size so it fits the column on every platform.
                HStack(spacing: 8) {
                    // Compact re-run right where the settings live, so changing the
                    // transcription mode / decode speed can be applied without reaching
                    // for the header's Analyze button.
                    AnalyzeSongButton(model: model)
                        .swProminentButtonStyle()
                        .lineLimit(1)
                        .fixedSize()
                    Button("Reference Lyrics", systemImage: "text.alignleft") {
                        showReferenceLyrics = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Reference Lyrics")
                    .disabled(model.selectedSong == nil || model.isSongAnalysisRunning)
                    .help("Paste the real lyrics to align words and line breaks exactly.")
                    Button("Live Capture", systemImage: "dot.radiowaves.left.and.right") {
                        showLiveCapture = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Live Capture")
                    .disabled(model.selectedSong == nil || model.isSongAnalysisRunning)
                    .help(
                        "Detect chords in real time from a loopback device, mic, or another app.")
                    if !model.referenceLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Color.swMint)
                            .help("Lyrics are aligned to your reference text")
                    }
                    Spacer()
                }
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(SongAnalysisStage.allCases, id: \.self) { stage in
                        stageRow(stage)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .swSurfacePanel(cornerRadius: 12)
        .alert("Replace Existing ChordPro?", isPresented: $showReplacementConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                model.analyzeSelectedSong(replaceExistingChordPro: true)
            }
        } message: {
            Text(
                "The current ChordPro was reviewed or imported manually. Replacement creates a new draft."
            )
        }
        .sheet(isPresented: analysisProgressPresentation) {
            AnalysisProgressSheet(model: model)
        }
        .sheet(isPresented: $showReferenceLyrics) {
            ReferenceLyricsSheet(model: model)
        }
        .sheet(isPresented: $showLiveCapture) {
            LiveCaptureSheet(model: model)
        }
    }

    private var analysisProgressPresentation: Binding<Bool> {
        Binding(
            // Stay presented across the whole "Re-analyze All" run, not just each song, so the
            // sheet doesn't flicker between songs as isSongAnalysisRunning toggles.
            get: { model.isSongAnalysisRunning || model.reanalyzeAllStatus != nil },
            set: { isPresented in
                if !isPresented, model.isSongAnalysisRunning {
                    model.cancelSongAnalysis()
                }
            }
        )
    }

    private func stageRow(_ stage: SongAnalysisStage) -> some View {
        let record = model.analysisStageRecords[stage]
        // The stage currently being worked on: show a live spinner + percent + progress bar so
        // a long-running stage (stem separation) is visibly progressing, not stuck.
        let progress = model.songAnalysisProgress
        let isActive = model.isSongAnalysisRunning && progress?.stage == stage
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(stageTitle(stage), systemImage: stageSymbol(record?.state))
                if isActive {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if isActive, let progress {
                    Text(progress.stageFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.swMono(11, weight: .medium))
                        .foregroundStyle(Color.swMint)
                } else {
                    Text(stageStatus(record))
                        .foregroundStyle(
                            record?.state == .failed ? Color.swCoral : Color.swTextSecondary)
                }
                if record?.state == .failed || record?.state == .stale {
                    Button("Retry") {
                        if stage == .chordPro && model.requiresChordProReplacementConfirmation {
                            showReplacementConfirmation = true
                        } else {
                            model.retryAnalysisStage(stage)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if isActive, let progress {
                ProgressView(value: progress.stageFraction)
                    .tint(Color.swMint)
                Text(progress.message)
                    .font(.swMono(10))
                    .foregroundStyle(Color.swTextSecondary)
                    .lineLimit(1)
            } else {
                Text(stageDetail(record))
                    .font(.swMono(10))
                    .foregroundStyle(Color.swTextSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Hoisted to `AppModel.stageTitle` so the top-of-window background-status row names stages
    /// the same way these cards do (one list of labels, not two).
    private func stageTitle(_ stage: SongAnalysisStage) -> String {
        AppModel.stageTitle(stage)
    }

    private func stageStatus(_ record: AnalysisStageRecord?) -> String {
        guard let record else { return "Not run" }
        if record.provenance?.loadedFromCache == true { return "Cached" }
        return record.state.rawValue.capitalized
    }

    private func stageSymbol(_ state: AnalysisStageState?) -> String {
        switch state {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .stale: "clock.arrow.circlepath"
        case nil: "circle.dashed"
        }
    }

    private func stageDetail(_ record: AnalysisStageRecord?) -> String {
        if let error = record?.errorMessage { return error }
        guard let provenance = record?.provenance else { return "" }
        let completion = provenance.completedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(provenance.engineIdentifier) \(provenance.engineVersion) • \(completion)"
    }
}

/// The header Analyze action (lives in `SongActionsCard`, upper right of the main window).
/// Carries the same replace-confirmation flow the card's button had; progress is still
/// presented by `AnalysisWorkspaceView`'s model-driven sheet, so it appears no matter who
/// starts analysis.
struct AnalyzeSongButton: View {
    @ObservedObject var model: AppModel
    @State private var showReplacementConfirmation = false

    var body: some View {
        Button {
            if model.requiresChordProReplacementConfirmation {
                showReplacementConfirmation = true
            } else {
                model.analyzeSelectedSong()
            }
        } label: {
            if model.isSongAnalysisRunning {
                Label("Analyzing…", systemImage: "sparkles")
            } else {
                Label("Analyze Song", systemImage: "sparkles")
            }
        }
        .disabled(model.selectedSong == nil || model.isSongAnalysisRunning)
        .help("Run the full analysis pipeline on the selected song")
        .alert("Replace Existing ChordPro?", isPresented: $showReplacementConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                model.analyzeSelectedSong(replaceExistingChordPro: true)
            }
        } message: {
            Text(
                "The current ChordPro was reviewed or imported manually. Replacement creates a new draft."
            )
        }
    }
}

/// Not `private`: also presented from the Lyrics tab's reference-lyrics prompt banner (C1,
/// backlog #8) via `TimedLyricsEditor` in `WorkspaceEditorsView.swift`, not just from this
/// view's own "Reference Lyrics" button — same sheet, two entry points.
struct ReferenceLyricsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Reference Lyrics", systemImage: "text.alignleft")
                .font(.swDisplay(15, weight: .semibold))
                .foregroundStyle(Color.swTextPrimary)
            Text(
                "Paste the song's real lyrics, one line per line. These exact words and line breaks "
                    + "are aligned to the audio using the detected timings — the most accurate "
                    + "lyrics when you know them. Leave empty to use the raw transcription."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Fill from current transcription", systemImage: "arrow.down.doc") {
                    draft = model.currentLyricsAsText
                }
                .disabled(model.lyricSegments.isEmpty)
                .help(
                    "Copy the current lyric lines here — e.g. run Accuracy first, then reuse its "
                        + "clean line breaks so Fast/Balanced align to the same lines.")
                Spacer()
            }
            TextEditor(text: $draft)
                .font(.swMono(12))
                .frame(minHeight: 300)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Clear", role: .destructive) { draft = "" }
                    .disabled(draft.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Align to Audio") {
                    model.referenceLyrics = draft
                    model.applyReferenceLyrics()
                    dismiss()
                }
                .swProminentButtonStyle()
                .disabled(draft == model.referenceLyrics || model.selectedSong == nil)
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear { draft = model.referenceLyrics }
    }
}

private struct AnalysisProgressSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(analysisSheetTitle, systemImage: "sparkles")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Spacer()
                Text(percentComplete, format: .percent.precision(.fractionLength(0)))
                    .font(.swMono(15, weight: .semibold))
                    .foregroundStyle(Color.swMint)
            }

            // Per-song line only when there's genuinely a batch of more than one; a single
            // (e.g. first-time import) song would read a pointless "Song 1 of 1".
            if let bulk = model.reanalyzeAllStatus, bulk.total > 1 {
                Text("Song \(bulk.index) of \(bulk.total): \(bulk.title)")
                    .font(.swDisplay(13, weight: .medium))
                    .foregroundStyle(Color.swTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let progress = model.songAnalysisProgress {
                ProgressView(value: progress.fractionCompleted) {
                    Text(progress.message)
                        .lineLimit(2)
                }
                .accessibilityLabel("Song analysis progress")
                .accessibilityValue(progress.message)
            } else {
                ProgressView {
                    Text("Preparing analysis")
                }
                .accessibilityLabel("Song analysis progress")
                .accessibilityValue("Preparing analysis")
            }

            Divider()

            HStack {
                Text("This window closes when analysis finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelSongAnalysis()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 420)
        .interactiveDismissDisabled(model.isSongAnalysisRunning)
    }

    private var percentComplete: Double {
        model.songAnalysisProgress?.fractionCompleted ?? 0
    }

    /// The queue backs both first-time imports and "Re-analyze All", so title by count rather
    /// than assuming any batch is a re-analyze — a first import was reading "Re-analyzing
    /// Library".
    private var analysisSheetTitle: String {
        if let bulk = model.reanalyzeAllStatus, bulk.total > 1 {
            return "Analyzing \(bulk.total) Songs"
        }
        return "Analyzing Song"
    }
}

private struct ModelPackagesView: View {
    @ObservedObject var model: AppModel
    @State private var isPresented = false

    var body: some View {
        Button("Models", systemImage: "externaldrive.badge.checkmark") {
            isPresented = true
        }
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Analysis Models").font(.swDisplay(15, weight: .semibold))
                    Spacer()
                    Label(
                        model.analysisCapabilityProfile.displayName,
                        systemImage: model.analysisCapabilityProfile.platform == .desktop
                            ? "desktopcomputer" : "ipad"
                    )
                    .font(.swDisplay(12, weight: .medium))
                    .foregroundStyle(Color.swMint)
                    Text(model.totalInstalledModelBytes, format: .byteCount(style: .file))
                        .font(.swMono(12))
                        .foregroundStyle(Color.swTextSecondary)
                }
                #if os(macOS)
                    Toggle(
                        "Advanced stem refinement",
                        isOn: Binding(
                            get: { model.advancedStemRefinementEnabled },
                            set: { model.advancedStemRefinementEnabled = $0 }
                        )
                    )
                    .font(.swDisplay(12))
                    .help(
                        "When enabled and DrumSep is installed, Analyze refines drums into kick, snare, cymbals, and toms. Mixer and waveforms follow those children."
                    )
                #endif
                // Hide packages outside the active product tier instead of offering installs
                // that cannot be used by that build. Includes optional refiners via offersModelPackage.
                let installable = ModelCatalog.all.filter {
                    $0.requiresDownloadOnCurrentPlatform
                        && model.analysisCapabilityProfile.offersModelPackage($0)
                }
                ForEach(installable, id: \.id) { descriptor in
                    modelRow(descriptor)
                    if descriptor.id != installable.last?.id { Divider() }
                }
            }
            .padding()
            .frame(width: 470)
        }
    }

    private func modelRow(_ descriptor: ModelPackageDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading) {
                    Text(descriptor.displayName)
                    Text(
                        "\(descriptor.purpose) • v\(descriptor.version) • \(descriptor.license.name)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                modelActions(descriptor)
            }
            Text(descriptor.license.attribution)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let progress = model.modelInstallProgress[descriptor.id] {
                ProgressView(value: progress) {
                    Text(
                        "Downloading \(descriptor.expectedDownloadBytes, format: .byteCount(style: .file))"
                    )
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        model.cancelModelPackageInstall(descriptor)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelActions(_ descriptor: ModelPackageDescriptor) -> some View {
        switch model.modelPackageStatuses[descriptor.id] ?? .available {
        case .available:
            Button("Install") { model.installModelPackage(descriptor) }
                .disabled(model.modelInstallProgress[descriptor.id] != nil)
        case .installed(let package):
            Text(package.sizeBytes, format: .byteCount(style: .file))
                .font(.swMono(12))
                .foregroundStyle(Color.swTextSecondary)
            Button("Verify") { model.verifyModelPackage(descriptor) }
            Button("Remove", role: .destructive) { model.removeModelPackage(descriptor) }
        case .invalid:
            Label("Invalid", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.swCoral)
            Button("Verify") { model.verifyModelPackage(descriptor) }
            Button("Remove", role: .destructive) { model.removeModelPackage(descriptor) }
        }
    }
}
