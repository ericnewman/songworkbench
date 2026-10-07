import SwiftUI

/// The Settings window's Analysis pane (Eric, 2026-10-07: "that whole card could move to the
/// settings window"): model packages, every choice that costs analysis time with its running
/// estimate, and the selected song's stage status. The per-song actions (Analyze, Reference
/// Lyrics, Live Capture) and the analysis progress sheet stay in the main window's
/// `SongActionsCard`.
struct AnalysisWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var showReplacementConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Song Analysis", systemImage: "waveform.badge.magnifyingglass")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Spacer()
                ModelPackagesView(model: model)
            }

            // Every analysis runs every installed transcription mode; the Lyric Blend window
            // chooses between them per line (`AppModel.primaryTranscriptionMode`).
            Text("Analysis options")
                .font(.swDisplay(12, weight: .semibold))
                .foregroundStyle(Color.swTextSecondary)

            #if os(macOS)
                SeparationOptionControls(model: model)
            #endif

            Label(model.estimatedAnalysisSummary, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(
                    "Wall-clock estimate for the options above, scaled from measured pass "
                        + "times on an 8-core Mac. It updates as you change them; your "
                        + "machine and other load will move it."
                )

            Divider()

            Text(model.selectedSong.map { "Stages · \($0.title)" } ?? "Stages · no song selected")
                .font(.swDisplay(12, weight: .semibold))
                .foregroundStyle(Color.swTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(SongAnalysisStage.allCases, id: \.self) { stage in
                    stageRow(stage)
                }
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
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

struct AnalysisProgressSheet: View {
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
    /// Library". A single-song run names the song itself (the "Song i of N: Title" line below
    /// only renders for real batches, so without this a lone run showed no title at all).
    private var analysisSheetTitle: String {
        if let bulk = model.reanalyzeAllStatus, bulk.total > 1 {
            return "Analyzing \(bulk.total) Songs"
        }
        if let title = model.reanalyzeAllStatus?.title ?? model.selectedSong?.title,
            !title.isEmpty
        {
            return "Analyzing “\(title)”"
        }
        return "Analyzing Song"
    }
}

#if os(macOS)
    /// Every stem-separation choice that costs analysis time, on the main workspace card rather
    /// than behind a popover. Each refiner adds a whole extra model pass over a stem; the "+n min"
    /// labels come from the same measured factors as the card's headline estimate, so the two
    /// cannot disagree.
    private struct SeparationOptionControls: View {
        @ObservedObject var model: AppModel

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stem separation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    isOn: Binding(
                        get: { model.vocalVoiceSeparationEnabled },
                        set: { model.vocalVoiceSeparationEnabled = $0 }
                    )
                ) {
                    Text("Lead / backing vocals")
                        + Text("  \(model.vocalVoiceSeparationCostSummary)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .font(.caption)
                .help(
                    "Splits the vocals stem into lead and backing so each voice is playable and "
                        + "harmony rows can tell the singers apart. The slowest step in analysis."
                )
                Toggle(
                    isOn: Binding(
                        get: { model.drumPieceSeparationEnabled },
                        set: { model.drumPieceSeparationEnabled = $0 }
                    )
                ) {
                    Text("Drum pieces")
                        + Text("  \(model.drumPieceSeparationCostSummary)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .font(.caption)
                .help("Splits the drums stem into kick, snare, toms and cymbals.")
                if !model.advancedStemRefinementEnabled {
                    Text("Analysis runs the six base stems only — the fastest setting.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
#endif

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

    /// Verification re-hashes the entire package, so the row shows it working rather than
    /// appearing to ignore the click. The outcome itself lands in the error banner.
    @ViewBuilder
    private func verifyButton(_ descriptor: ModelPackageDescriptor) -> some View {
        if model.modelVerifyInProgress.contains(descriptor.id) {
            ProgressView().controlSize(.small)
        } else {
            Button("Verify") { model.verifyModelPackage(descriptor) }
        }
    }

    @ViewBuilder
    private func modelActions(_ descriptor: ModelPackageDescriptor) -> some View {
        switch model.modelPackageStatuses[descriptor.id] ?? .available {
        case .available where !descriptor.isHosted:
            // The artifact is not published yet, so Install can only ever fail on an unresolvable
            // placeholder URL and leave an error the user has to hunt for a way to clear. Say so
            // instead of offering a button that cannot work.
            Text("Manual install required — artifact not hosted yet")
                .font(.swDisplay(11))
                .foregroundStyle(Color.swTextSecondary)
        case .available:
            Button("Install") { model.installModelPackage(descriptor) }
                .disabled(model.modelInstallProgress[descriptor.id] != nil)
        case .installed(let package):
            Text(package.sizeBytes, format: .byteCount(style: .file))
                .font(.swMono(12))
                .foregroundStyle(Color.swTextSecondary)
            verifyButton(descriptor)
            Button("Remove", role: .destructive) { model.removeModelPackage(descriptor) }
        case .invalid(let reason):
            // Show WHY. The reason was previously discarded, leaving a bare "Invalid" chip that
            // said nothing about whether to verify, reinstall, or free disk space.
            Label("Invalid", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.swCoral)
                .help(reason)
            Text(reason)
                .font(.swDisplay(11))
                .foregroundStyle(Color.swCoral)
                .lineLimit(2)
            verifyButton(descriptor)
            Button("Remove", role: .destructive) { model.removeModelPackage(descriptor) }
        }
    }
}
