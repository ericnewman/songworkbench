import SwiftUI

struct AnalysisWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var showReplacementConfirmation = false
    @State private var showReferenceLyrics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Song Analysis", systemImage: "waveform.badge.magnifyingglass")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                ModelPackagesView(model: model)
            }

            Picker("Transcription", selection: $model.transcriptionMode) {
                Text("Fast Draft").tag(TranscriptionMode.fastDraft)
                Text("Balanced Draft").tag(TranscriptionMode.balancedDraft)
                Text("Accuracy").tag(TranscriptionMode.accuracy)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                if model.isSongAnalysisRunning {
                    Button("Analyzing Song...", systemImage: "sparkles") {}
                        .disabled(true)
                } else {
                    Button("Analyze Song", systemImage: "sparkles") {
                        beginAnalysis()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedSong == nil)
                }
                Button("Reference Lyrics", systemImage: "text.alignleft") {
                    showReferenceLyrics = true
                }
                .disabled(model.selectedSong == nil || model.isSongAnalysisRunning)
                if !model.referenceLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.swMint)
                        .help("Lyrics are aligned to your reference text")
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(SongAnalysisStage.allCases, id: \.self) { stage in
                    stageRow(stage)
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(stageTitle(stage), systemImage: stageSymbol(record?.state))
                Spacer()
                Text(stageStatus(record))
                    .foregroundStyle(
                        record?.state == .failed ? Color.swCoral : Color.swTextSecondary)
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
            Text(stageDetail(record))
                .font(.swMono(10))
                .foregroundStyle(Color.swTextSecondary)
                .lineLimit(1)
        }
    }

    private func beginAnalysis() {
        if model.requiresChordProReplacementConfirmation {
            showReplacementConfirmation = true
        } else {
            model.analyzeSelectedSong()
        }
    }

    private func stageTitle(_ stage: SongAnalysisStage) -> String {
        switch stage {
        case .separation: "Stems"
        case .transcription: "Lyrics"
        case .harmony: "Tempo & Chords"
        case .chordPro: "ChordPro"
        }
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

private struct ReferenceLyricsSheet: View {
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
                .buttonStyle(.borderedProminent)
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
                Label(
                    model.reanalyzeAllStatus == nil ? "Analyzing Song" : "Re-analyzing Library",
                    systemImage: "sparkles"
                )
                .font(.swDisplay(15, weight: .semibold))
                .foregroundStyle(Color.swTextPrimary)
                Spacer()
                Text(percentComplete, format: .percent.precision(.fractionLength(0)))
                    .font(.swMono(15, weight: .semibold))
                    .foregroundStyle(Color.swMint)
            }

            if let bulk = model.reanalyzeAllStatus {
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
                    Text(model.totalInstalledModelBytes, format: .byteCount(style: .file))
                        .font(.swMono(12))
                        .foregroundStyle(Color.swTextSecondary)
                }
                ForEach(ModelCatalog.all, id: \.id) { descriptor in
                    modelRow(descriptor)
                    if descriptor.id != ModelCatalog.all.last?.id { Divider() }
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
