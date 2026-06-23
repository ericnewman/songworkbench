import SwiftUI

struct AnalysisWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var showReplacementConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Song Analysis", systemImage: "waveform.badge.magnifyingglass")
                    .font(.headline)
                Spacer()
                ModelPackagesView(model: model)
            }

            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(SongAnalysisStage.allCases, id: \.self) { stage in
                        Toggle(stageTitle(stage), isOn: stageBinding(stage))
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }
                }
                Picker("Transcription", selection: $model.transcriptionMode) {
                    Text("Fast Draft").tag(TranscriptionMode.fastDraft)
                    Text("Balanced Draft").tag(TranscriptionMode.balancedDraft)
                    Text("Accuracy").tag(TranscriptionMode.accuracy)
                }
                .pickerStyle(.segmented)
                .disabled(!model.selectedAnalysisStages.contains(.transcription))
            }

            HStack {
                if model.isSongAnalysisRunning {
                    Button("Cancel", role: .cancel) { model.cancelSongAnalysis() }
                } else {
                    Button("Analyze Song", systemImage: "sparkles") {
                        beginAnalysis()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedAnalysisStages.isEmpty)
                }
                if let progress = model.songAnalysisProgress {
                    ProgressView(value: progress.fractionCompleted)
                        .accessibilityLabel("Song analysis progress")
                        .accessibilityValue(progress.message)
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Spacer().frame(height: 16)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(SongAnalysisStage.allCases, id: \.self) { stage in
                    stageRow(stage)
                }
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(stageTitle(stage), systemImage: stageSymbol(record?.state))
                Spacer()
                Text(stageStatus(record))
                    .foregroundStyle(record?.state == .failed ? .red : .secondary)
                if record?.state == .failed || record?.state == .stale {
                    Button("Retry") {
                        if stage == .chordPro && model.requiresChordProReplacementConfirmation {
                            model.selectedAnalysisStages = [.chordPro]
                            showReplacementConfirmation = true
                        } else {
                            model.retryAnalysisStage(stage)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(stageDetail(record))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func beginAnalysis() {
        if model.selectedAnalysisStages.contains(.chordPro)
            && model.requiresChordProReplacementConfirmation
        {
            showReplacementConfirmation = true
        } else {
            model.analyzeSelectedSong()
        }
    }

    private func stageBinding(_ stage: SongAnalysisStage) -> Binding<Bool> {
        Binding(
            get: { model.selectedAnalysisStages.contains(stage) },
            set: { selected in
                if selected {
                    model.selectedAnalysisStages.insert(stage)
                } else {
                    model.selectedAnalysisStages.remove(stage)
                }
            }
        )
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
                    Text("Analysis Models").font(.headline)
                    Spacer()
                    Text(model.totalInstalledModelBytes, format: .byteCount(style: .file))
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Button("Verify") { model.verifyModelPackage(descriptor) }
            Button("Remove", role: .destructive) { model.removeModelPackage(descriptor) }
        case .invalid:
            Label("Invalid", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Button("Verify") { model.verifyModelPackage(descriptor) }
            Button("Remove", role: .destructive) { model.removeModelPackage(descriptor) }
        }
    }
}
