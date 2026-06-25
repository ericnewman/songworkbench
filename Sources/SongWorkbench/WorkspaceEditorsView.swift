import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The workspace editor tabs, selected by a segmented control at the top of the
/// window so the editor content fills the right column.
enum EditorTab: String, CaseIterable, Identifiable {
    case lyrics
    case chords
    case chordPro
    case bassNotes
    case stems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: "Lyrics"
        case .chords: "Chords"
        case .chordPro: "ChordPro"
        case .bassNotes: "Bass Notes"
        case .stems: "Stems"
        }
    }

    var systemImage: String {
        switch self {
        case .lyrics: "text.quote"
        case .chords: "music.note"
        case .chordPro: "doc.plaintext"
        case .bassNotes: "music.note.list"
        case .stems: "slider.horizontal.3"
        }
    }
}

/// Renders the editor for the currently selected tab. The tab selector lives at
/// the top of the window (see `ContentView`); this view is just the content.
struct WorkspaceEditorsView: View {
    @ObservedObject var model: AppModel
    let selectedEditor: EditorTab

    var body: some View {
        Group {
            switch selectedEditor {
            case .lyrics: TimedLyricsEditor(model: model)
            case .chords: ChordTimelineEditor(model: model)
            case .chordPro: ChordProTabEditor(model: model, config: .chordPro)
            case .bassNotes: ChordProTabEditor(model: model, config: .bassNote)
            case .stems: StemMixerEditor(model: model)
            }
        }
        .padding(12)
        .swSurfacePanel(cornerRadius: 12)
        .frame(minHeight: 620, maxHeight: .infinity, alignment: .top)
    }
}

/// Transport card (left column, under the waveform): the source/mix badge plus
/// large skip / play-pause buttons.
struct PlaybackTransportCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var stemPlayback: StemPlaybackService

    init(model: AppModel) {
        self.model = model
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(sourceLabel)
                .font(.swDisplay(11))
                .foregroundStyle(Color.swTextSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.swSurface, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 24) {
                Button("Back 10 Seconds", systemImage: "gobackward.10") {
                    model.skipActivePlayback(by: -10)
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 24))
                .swAccentHoverBorder(cornerRadius: 8)

                playButton(
                    title: model.isActivePlaybackPlaying ? "Pause Song" : "Play Song",
                    disabled: model.selectedSong == nil,
                    isPlaying: model.isActivePlaybackPlaying,
                    help: "Play or pause the original recording"
                ) {
                    model.toggleActivePlayback()
                }

                playButton(
                    title: stemPlayback.isPlaying ? "Pause Stem Mix" : "Play Stem Mix",
                    disabled: !stemPlayback.isLoaded,
                    isPlaying: stemPlayback.isPlaying,
                    help: stemPlayback.isLoaded
                        ? "Play or pause the separated stem mix"
                        : "Run Stems separation to enable mix playback"
                ) {
                    model.toggleStemPlayback()
                }

                Button("Forward 10 Seconds", systemImage: "goforward.10") {
                    model.skipActivePlayback(by: 10)
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 24))
                .swAccentHoverBorder(cornerRadius: 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .swSurfacePanel(cornerRadius: 12)
    }

    /// A large play/pause button with a caption naming the track it controls.
    @ViewBuilder
    private func playButton(
        title: String,
        disabled: Bool,
        isPlaying: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 5) {
            Button(title, systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                action()
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 46))
            .disabled(disabled)
            .swAccentHoverBorder(cornerRadius: 24)

            Text(title)
                .font(.swDisplay(10))
                .foregroundStyle(
                    disabled ? Color.swTextSecondary.opacity(0.5) : Color.swTextSecondary
                )
                .lineLimit(1)
                .fixedSize()
        }
        .help(help)
    }

    private var sourceLabel: String {
        model.activePlaybackSource == .stemMix ? "Stem Mix" : "Recording"
    }
}

/// Playback progress (seek) slider with elapsed/total time, shown inside the
/// waveform card just below the waveform.
struct PlaybackProgressSlider: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var playback: AudioPlaybackService
    @ObservedObject private var stemPlayback: StemPlaybackService
    @State private var seekPosition: TimeInterval = 0
    @State private var isSeeking = false

    init(model: AppModel) {
        self.model = model
        playback = model.playback
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: $seekPosition,
                in: 0...max(activeDuration, 0.01),
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing {
                        model.seekActivePlayback(to: seekPosition)
                    }
                }
            )
            .disabled(activeDuration <= 0)
            Text("\(formatTime(seekPosition)) / \(formatTime(activeDuration))")
                .font(.swMono(11))
                .foregroundStyle(Color.swMint)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear { seekPosition = model.activePlaybackTime }
        .onChange(of: playback.currentTime) { _, value in
            updateSeekPosition(value, for: .recording)
        }
        .onChange(of: stemPlayback.currentTime) { _, value in
            updateSeekPosition(value, for: .stemMix)
        }
        .onChange(of: model.activePlaybackSource) { _, _ in
            if !isSeeking { seekPosition = model.activePlaybackTime }
        }
    }

    private var activeDuration: TimeInterval {
        model.activePlaybackSource == .stemMix ? stemPlayback.duration : playback.duration
    }

    private func updateSeekPosition(_ value: TimeInterval, for source: PlaybackSource) {
        guard !isSeeking, model.activePlaybackSource == source else { return }
        seekPosition = value
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let totalSeconds = max(Int(time.rounded(.down)), 0)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// Pitch and Speed practice controls, shown as a card under the waveform.
struct PitchSpeedCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pitch & Speed", systemImage: "dial.medium")
                .font(.swDisplay(15, weight: .semibold))
                .foregroundStyle(Color.swTextPrimary)

            HStack(spacing: 12) {
                adjustmentControl(
                    title: "Pitch",
                    systemImage: "tuningfork",
                    value: pitchLabel
                ) {
                    Slider(
                        value: Binding(
                            get: { Double(model.pitchSemitones) },
                            set: { model.pitchSemitones = Int($0.rounded()) }
                        ),
                        in: Double(
                            PitchShift.range.lowerBound)...Double(PitchShift.range.upperBound),
                        step: 1
                    )
                }

                adjustmentControl(
                    title: "Speed",
                    systemImage: "metronome",
                    value: "\(Int((model.tempoRate * 100).rounded()))%"
                ) {
                    Slider(value: $model.tempoRate, in: 0.5...1.5, step: 0.05)
                }
            }

            HStack {
                Spacer()
                Button("Reset Pitch and Speed", systemImage: "arrow.counterclockwise") {
                    model.pitchSemitones = 0
                    model.tempoRate = 1
                }
                .disabled(model.pitchSemitones == 0 && model.tempoRate == 1)
            }
        }
        .padding(10)
        .swSurfacePanel(cornerRadius: 12)
    }

    private func adjustmentControl<Content: View>(
        title: String,
        systemImage: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.swDisplay(13, weight: .medium))
                    .foregroundStyle(Color.swTextPrimary)
                Spacer()
                Text(value)
                    .font(.swMono(13))
                    .foregroundStyle(Color.swTextSecondary)
            }
            content()
        }
        .padding(10)
        .swSurfacePanel(cornerRadius: 10)
    }

    private var pitchLabel: String {
        guard let key = model.estimatedKey else {
            return model.pitchSemitones == 0
                ? "Key unavailable" : "Key unavailable • \(semitoneLabel)"
        }
        guard model.pitchSemitones != 0 else { return key.displayName }
        return "\(key.displayName) → \(key.transposed(by: model.pitchSemitones).displayName)"
    }

    private var semitoneLabel: String {
        model.pitchSemitones > 0
            ? "+\(model.pitchSemitones) semitones" : "\(model.pitchSemitones) semitones"
    }
}

private struct TimedLyricsEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Timestamped Lyrics")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                reviewBadge(model.lyricReviewState)
                Spacer()
                Button("Mark Reviewed", systemImage: "checkmark.seal") {
                    model.markLyricsReviewed()
                }
                .disabled(model.lyricSegments.isEmpty || model.lyricReviewState == .reviewed)
                Button("Add at Playhead", systemImage: "plus") {
                    model.addLyricSegment()
                }
            }
            List {
                ForEach($model.lyricSegments) { $segment in
                    HStack {
                        TextField(
                            "Start", value: $segment.start,
                            format: .number.precision(.fractionLength(2))
                        )
                        .frame(width: 70)
                        TextField(
                            "End", value: $segment.end,
                            format: .number.precision(.fractionLength(2))
                        )
                        .frame(width: 70)
                        TextField("Lyric", text: $segment.text)
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            model.lyricSegments.removeAll { $0.id == segment.id }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            .overlay {
                if model.lyricSegments.isEmpty {
                    ContentUnavailableView(
                        "No Timed Lyrics",
                        systemImage: "text.quote",
                        description: Text("Add a line at the current playhead position.")
                    )
                }
            }
        }
        .padding()
    }

    private func reviewBadge(_ state: AnalysisReviewState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.swDisplay(11))
            .foregroundStyle(Color.swTextSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.swSurface, in: Capsule())
    }
}

private struct ChordTimelineEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Chord Timeline")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                reviewBadge(model.chordReviewState)
                if let bpm = model.estimatedBPM {
                    Text("\(bpm, format: .number.precision(.fractionLength(1))) BPM")
                        .font(.swMono(12))
                        .foregroundStyle(Color.swMint)
                }
                if let sourceKind = model.analysisStageRecords[.harmony]?.provenance?.sourceKind {
                    Label(
                        harmonySourceLabel(sourceKind),
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .font(.swDisplay(11))
                    .foregroundStyle(
                        sourceKind == .recording ? Color.swCoral : Color.swTextSecondary)
                }
                Spacer()
                Button("Mark Reviewed", systemImage: "checkmark.seal") {
                    model.markChordsReviewed()
                }
                .disabled(model.chordEvents.isEmpty || model.chordReviewState == .reviewed)
                if isAnalysisRunning {
                    Button("Cancel", role: .cancel) { model.cancelChordAnalysis() }
                } else {
                    Button("Analyze Accompaniment", systemImage: "waveform.badge.magnifyingglass") {
                        model.runChordAnalysis()
                    }
                    .disabled(!model.canAnalyzeAccompaniment)
                    .help("Requires the separated accompaniment stem.")
                }
                Button("Add at Playhead", systemImage: "plus") {
                    model.addChordEvent()
                }
            }
            if let progress = model.analysisJobSnapshot?.progress, isAnalysisRunning {
                ProgressView(
                    progress.message ?? "Analyzing...",
                    value: progress.fractionCompleted
                )
            }
            HStack(spacing: 12) {
                Label("ChordPro confidence", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.callout)
                Slider(
                    value: Binding(
                        get: { Double(model.chordConfidenceThreshold) },
                        set: { model.chordConfidenceThreshold = Float($0) }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                .accessibilityLabel("Minimum ChordPro chord confidence")
                Text(model.chordConfidenceThreshold, format: .percent.precision(.fractionLength(0)))
                    .font(.swMono(12))
                    .foregroundStyle(Color.swTextSecondary)
                    .frame(width: 42, alignment: .trailing)
                Text("\(model.includedChordEventCount) of \(model.chordEvents.count) included")
                    .font(.swMono(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .frame(minWidth: 96, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .swSurfacePanel(cornerRadius: 8)
            .help(
                "Detected chords below this confidence are omitted from generated ChordPro. "
                    + "Manual chords are always included."
            )
            List {
                ForEach($model.chordEvents) { $event in
                    HStack {
                        Image(
                            systemName: model.isChordIncludedInChordPro(event)
                                ? "checkmark.circle.fill" : "minus.circle"
                        )
                        .foregroundStyle(
                            model.isChordIncludedInChordPro(event)
                                ? Color.swAccent : Color.swTextSecondary
                        )
                        .help(
                            model.isChordIncludedInChordPro(event)
                                ? "Included in generated ChordPro"
                                : "Excluded by confidence threshold"
                        )
                        TextField(
                            "Time", value: $event.time,
                            format: .number.precision(.fractionLength(2))
                        )
                        .frame(width: 80)
                        TextField("Chord", text: $event.chord)
                            .frame(width: 100)
                        if let confidence = event.confidence {
                            Text(confidence, format: .percent.precision(.fractionLength(0)))
                                .font(.swMono(12))
                                .foregroundStyle(Color.swTextSecondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            model.chordEvents.removeAll { $0.id == event.id }
                        }
                        .labelStyle(.iconOnly)
                    }
                    .opacity(model.isChordIncludedInChordPro(event) ? 1 : 0.55)
                }
            }
            .overlay {
                if model.chordEvents.isEmpty {
                    ContentUnavailableView(
                        "No Chords",
                        systemImage: "music.note",
                        description: Text("Add a chord at the current playhead position.")
                    )
                }
            }
        }
        .padding()
    }

    private var isAnalysisRunning: Bool {
        guard let state = model.analysisJobSnapshot?.state else { return false }
        return !state.isTerminal
    }

    private func harmonySourceLabel(_ sourceKind: AnalysisSourceKind) -> String {
        switch sourceKind {
        case .accompanimentStem, .stemSet:
            "Accompaniment stem"
        case .recording:
            "Full recording fallback"
        case .vocalsStem:
            "Vocal stem"
        }
    }

    private func reviewBadge(_ state: AnalysisReviewState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.swDisplay(11))
            .foregroundStyle(Color.swTextSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.swSurface, in: Capsule())
    }
}

/// Captures every static difference between the ChordPro tab and the Bass Notes tab so that
/// a single `ChordProTabEditor` can render both. Model-dependent behavior (status text,
/// preview source, export, empty state) is keyed off `kind` inside the editor; everything
/// else is shared.
private struct ChordProTabConfig: Sendable {
    /// Identifies which tab this is; drives the model-dependent branches in the editor.
    enum Kind: Sendable, Equatable {
        case chordPro
        case bassNote
    }

    /// The secondary segmented mode (App Preview is always first and the default).
    enum SecondaryMode: Sendable {
        /// Editable monospaced `TextEditor` bound to `model.chordProSource`.
        case edit
        /// Read-only monospaced source view of the generated text.
        case source
    }

    let kind: Kind
    let title: String
    let pickerAccessibilityLabel: String
    let secondaryModeLabel: String
    let secondaryMode: SecondaryMode
    let highlightStyle: ChordProPlaybackHighlightStyle
    let exportFileName: String
    /// Whether the transpose stepper is shown and fed into the preview/export.
    let supportsTranspose: Bool
    /// Whether the Import button is shown.
    let supportsImport: Bool
    /// Whether the Mark Reviewed button is shown.
    let supportsMarkReviewed: Bool
    /// Footer caption shown beneath the body, if any.
    let footerNote: String?

    static let chordPro = ChordProTabConfig(
        kind: .chordPro,
        title: "ChordPro",
        pickerAccessibilityLabel: "ChordPro view",
        secondaryModeLabel: "Edit",
        secondaryMode: .edit,
        highlightStyle: .chord,
        exportFileName: "Song.cho",
        supportsTranspose: true,
        supportsImport: true,
        supportsMarkReviewed: true,
        footerNote: nil
    )

    static let bassNote = ChordProTabConfig(
        kind: .bassNote,
        title: "Bass Note ChordPro",
        pickerAccessibilityLabel: "Bass note ChordPro view",
        secondaryModeLabel: "Source",
        secondaryMode: .source,
        highlightStyle: .bassNote,
        exportFileName: "Bass Notes.cho",
        supportsTranspose: true,
        supportsImport: false,
        supportsMarkReviewed: false,
        footerNote:
            "Bass notes are detected from the separated bass stem when available; "
            + "otherwise they fall back to chord roots (slash-bass first, else the chord root)."
    )
}

private struct ChordProTabEditor: View {
    private enum Mode: Hashable {
        case preview
        case secondary
    }

    @ObservedObject var model: AppModel
    @ObservedObject private var playback: AudioPlaybackService
    @ObservedObject private var stemPlayback: StemPlaybackService
    @AppStorage("bouncingBallEnabled") private var bouncingBallEnabled = true
    @State private var errorMessage: String?
    @State private var mode = Mode.preview

    private let config: ChordProTabConfig

    init(model: AppModel, config: ChordProTabConfig) {
        self.model = model
        self.config = config
        playback = model.playback
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(config.title)
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Text(statusBadge)
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.swSurface, in: Capsule())
                if config.supportsImport {
                    Button("Import...", systemImage: "square.and.arrow.down") {
                        importDocument()
                    }
                }
                Picker(config.pickerAccessibilityLabel, selection: $mode) {
                    Text("App Preview").tag(Mode.preview)
                    Text(config.secondaryModeLabel).tag(Mode.secondary)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                Toggle("Bouncing ball", isOn: $bouncingBallEnabled)
                    .toggleStyle(.checkbox)
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .help("Show a beat-synced bouncing ball over the current lyric line")
                Spacer()
                if config.supportsMarkReviewed {
                    Button("Mark Reviewed", systemImage: "checkmark.seal") {
                        model.markChordProReviewed()
                    }
                    .disabled(
                        model.chordProSource.isEmpty || model.chordProReviewState == .reviewed
                    )
                }
                if config.supportsTranspose {
                    Stepper(
                        "Transpose: \(model.chordProTranspose)",
                        value: $model.chordProTranspose, in: -12...12)
                }
                Button("Export...", systemImage: "square.and.arrow.up") {
                    exportDocument()
                }
                .disabled(!isExportEnabled)
            }

            if showsEmptyState {
                ContentUnavailableView(
                    "No Bass Notes",
                    systemImage: "music.note",
                    description: Text("Run Tempo & Chords or add chord events first.")
                )
            } else {
                Group {
                    switch mode {
                    case .secondary:
                        secondaryBody
                    case .preview:
                        ChordProAppPreview(
                            source: previewSource,
                            transpose: config.supportsTranspose ? model.chordProTranspose : 0,
                            highlightContext: highlightContext(style: config.highlightStyle),
                            beatBall: beatBallInput
                        )
                    }
                }
            }

            if let footerNote = config.footerNote {
                Text(footerNote)
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.swCoral)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var secondaryBody: some View {
        switch config.secondaryMode {
        case .edit:
            TextEditor(text: $model.chordProSource)
                .font(.system(.body, design: .monospaced))
                .border(.separator)
        case .source:
            ScrollView([.horizontal, .vertical]) {
                Text(previewSource)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(.separator)
        }
    }

    private var statusBadge: String {
        switch config.kind {
        case .chordPro:
            return model.chordProReviewState.rawValue.capitalized
        case .bassNote:
            return "Generated"
        }
    }

    private var previewSource: String {
        switch config.kind {
        case .chordPro:
            return model.chordProSource
        case .bassNote:
            return model.bassNoteChordProSource
        }
    }

    private var isExportEnabled: Bool {
        switch config.kind {
        case .chordPro:
            return !model.chordProSource.isEmpty
        case .bassNote:
            return !model.bassNoteChordProSource.isEmpty && !model.chordEvents.isEmpty
        }
    }

    /// Bass Notes shows an empty state in place of the body when there are no chord events;
    /// ChordPro lets `ChordProAppPreview` handle its own empty state.
    private var showsEmptyState: Bool {
        config.kind == .bassNote && model.chordEvents.isEmpty
    }

    private func importDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cho") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importChordPro(from: url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cho") ?? .plainText]
        panel.nameFieldStringValue = config.exportFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch config.kind {
            case .chordPro:
                try model.exportChordPro(to: url, transposedBy: model.chordProTranspose)
            case .bassNote:
                try model.exportBassNoteChordPro(to: url)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func highlightContext(
        style: ChordProPlaybackHighlightStyle
    ) -> ChordProPlaybackHighlightContext {
        ChordProPlaybackHighlightContext(
            currentTime: currentPlaybackTime,
            lyricSegments: model.lyricSegments,
            chordEvents: model.chordEvents,
            confidenceThreshold: model.chordConfidenceThreshold,
            style: style
        )
    }

    /// Lead applied to the highlight/ball clock while playing, to compensate for
    /// the gap between the reported playhead and what the listener actually hears
    /// (audio output + time-pitch processing latency, and transcription timestamp
    /// bias). Without it the highlight trails the sung word by ~0.5s. Tunable.
    private static let highlightLeadSeconds: TimeInterval = 0.45

    /// Playback position that drives the lyric highlight and bouncing ball. While
    /// playing it leads by `highlightLeadSeconds` so the highlight lands on the
    /// word being heard; paused, it reflects the exact playhead position.
    private var currentPlaybackTime: TimeInterval {
        let base =
            model.activePlaybackSource == .stemMix
            ? stemPlayback.currentTime : playback.currentTime
        return model.isActivePlaybackPlaying ? base + Self.highlightLeadSeconds : base
    }

    /// Drives the karaoke bouncing ball over the active lyric line during playback.
    /// `nil` whenever nothing is active or there is no beat data (neither explicit
    /// beat times nor a usable BPM) to position the ball.
    /// Gaps shorter than this don't get a waiting ball — only noticeable instrumental
    /// stretches (intros, breaks) park the ball at the upcoming line.
    private static let waitingBallMinimumGap: TimeInterval = 2

    private var beatBallInput: BeatBallInput? {
        guard bouncingBallEnabled else { return nil }
        let deriver = ChordProHighlightDeriver(
            lyricSegments: model.lyricSegments,
            chordEvents: model.chordEvents,
            confidenceThreshold: model.chordConfidenceThreshold
        )

        let bpm = model.estimatedBPM
        let beatTimes = model.beatTimes
        // Need either explicit beats or a usable BPM to synthesize them.
        guard !beatTimes.isEmpty || (bpm.map { $0 > 0 } ?? false) else { return nil }
        let now = currentPlaybackTime

        // A lyric is active: bounce over its words.
        if let ordinal = deriver.lyricOrdinal(at: now),
            let segment = deriver.segment(atOrdinal: ordinal)
        {
            return BeatBallInput(
                currentTime: now,
                ordinal: ordinal,
                windowStart: segment.start,
                windowEnd: segment.end,
                words: segment.words,
                bpm: bpm,
                beatTimes: beatTimes,
                isWaiting: false
            )
        }

        // No active lyric: if we're in a long enough instrumental gap before an
        // upcoming line, park a waiting ball at the start of that line.
        guard
            let upcoming = deriver.upcomingLyricOrdinal(at: now),
            let upSegment = deriver.segment(atOrdinal: upcoming)
        else { return nil }
        let gapStart = deriver.segment(atOrdinal: upcoming - 1)?.end ?? 0
        guard now >= gapStart, upSegment.start - gapStart >= Self.waitingBallMinimumGap
        else { return nil }

        // Chords playing during the gap (same filter the chart's chord-only line uses),
        // so the ball can bounce across them instead of just parking at the next line.
        let gapChordTimes =
            model.chordEvents
            .filter { event in
                event.time >= gapStart && event.time < upSegment.start
                    && (event.confidence.map { $0 >= model.chordConfidenceThreshold } ?? true)
            }
            .map(\.time)
            .sorted()

        return BeatBallInput(
            currentTime: now,
            ordinal: upcoming,
            windowStart: gapStart,
            windowEnd: upSegment.start,
            words: [],
            bpm: bpm,
            beatTimes: beatTimes,
            isWaiting: true,
            chordTimes: gapChordTimes
        )
    }
}

/// Per-frame inputs the App Preview needs to draw the beat-synced bouncing ball over
/// the active lyric line. `nil` upstream when nothing is active or no beat data exists.
struct BeatBallInput: Equatable {
    let currentTime: TimeInterval
    let ordinal: Int
    /// Time window the ball bounces across: the active lyric's span, or the
    /// instrumental gap before the upcoming line when `isWaiting`.
    let windowStart: TimeInterval
    let windowEnd: TimeInterval
    let words: [TimedLyricWord]
    let bpm: Double?
    let beatTimes: [TimeInterval]
    /// When true the ball pulses in place at the left of the upcoming line instead of
    /// tracking words across an active line.
    let isWaiting: Bool
    /// Chord onset times within the gap (when `isWaiting`), used to bounce the ball
    /// across the gap's chord-only line in sync with the chords.
    var chordTimes: [TimeInterval] = []
}

private struct ChordProAppPreview: View {
    let source: String
    var transpose: Int = 0
    var highlightContext: ChordProPlaybackHighlightContext?
    var beatBall: BeatBallInput?

    var body: some View {
        Group {
            if source.isEmpty {
                ContentUnavailableView(
                    "No ChordPro",
                    systemImage: "music.note.list",
                    description: Text("Switch to Edit to enter or import a chart.")
                )
            } else {
                switch previewResult {
                case .success(let document):
                    GeometryReader { viewport in
                        ScrollViewReader { scrollProxy in
                            ScrollView([.horizontal, .vertical]) {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(indexedBlocks(for: document), id: \.offset) { item in
                                        ChordProPreviewBlockView(
                                            block: item.block,
                                            highlight: highlightContext?.highlight(
                                                forLyricOrdinal: item.lyricOrdinal
                                            ),
                                            beatBall: beatBallValue(for: item, in: document)
                                        )
                                        .id(item.offset)
                                    }
                                }
                                .padding(12)
                                .frame(
                                    minWidth: viewport.size.width,
                                    alignment: .topLeading
                                )
                            }
                            .defaultScrollAnchor(.topLeading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .border(.separator)
                            .onChange(of: highlightContext?.currentLyricOrdinal) { _, ordinal in
                                guard
                                    let ordinal,
                                    let offset = blockOffset(
                                        forLyricOrdinal: ordinal, in: document
                                    )
                                else { return }
                                withAnimation {
                                    scrollProxy.scrollTo(offset, anchor: .center)
                                }
                            }
                            // While waiting through an instrumental gap, bring the
                            // upcoming line (where the ball is parked) into view.
                            .onChange(of: waitingOrdinal) { _, ordinal in
                                guard
                                    let ordinal,
                                    let offset = blockOffset(
                                        forLyricOrdinal: ordinal, in: document
                                    )
                                else { return }
                                withAnimation {
                                    scrollProxy.scrollTo(offset, anchor: .center)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .failure(let error):
                    ContentUnavailableView(
                        "ChordPro Preview Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(
                            "\(error.localizedDescription) Switch to Edit to correct it.")
                    )
                }
            }
        }
        .accessibilityIdentifier("chordpro-app-preview")
    }

    private var previewResult: Result<ChordProPreviewDocument, Error> {
        Result {
            let document = try ChordProDocument(parsing: source)
            return ChordProPreviewDocument(document: document.transposed(by: transpose))
        }
    }

    private func indexedBlocks(
        for document: ChordProPreviewDocument
    ) -> [ChordProPreviewIndexedBlock] {
        var lyricOrdinal = 0
        return document.blocks.enumerated().map { offset, block in
            let ordinal: Int?
            // Only lines with real (non-whitespace) lyric text are lyric lines; chord-only
            // lines (intro/instrumental/outro) carry whitespace lyric and must not consume
            // an ordinal, or highlight/ball alignment shifts off the real lyrics.
            if case .lyric(let line) = block, line.lyric.contains(where: { !$0.isWhitespace }) {
                ordinal = lyricOrdinal
                lyricOrdinal += 1
            } else {
                ordinal = nil
            }
            return ChordProPreviewIndexedBlock(
                offset: offset,
                block: block,
                lyricOrdinal: ordinal
            )
        }
    }

    private func blockOffset(
        forLyricOrdinal ordinal: Int,
        in document: ChordProPreviewDocument
    ) -> Int? {
        indexedBlocks(for: document).first { $0.lyricOrdinal == ordinal }?.offset
    }

    /// The upcoming line the ball is parked at while waiting, used to drive auto-scroll.
    private var waitingOrdinal: Int? {
        guard let beatBall, beatBall.isWaiting else { return nil }
        return beatBall.ordinal
    }

    /// The offset of the chord-only line (intro/instrumental) immediately preceding the
    /// given lyric line, if one exists — the line the waiting ball should bounce across.
    private func chordOnlyLineOffset(
        beforeLyricOrdinal ordinal: Int,
        in document: ChordProPreviewDocument
    ) -> Int? {
        let items = indexedBlocks(for: document)
        guard let lyricIndex = items.firstIndex(where: { $0.lyricOrdinal == ordinal }) else {
            return nil
        }
        var index = lyricIndex - 1
        while index >= 0 {
            let item = items[index]
            guard case .lyric(let line) = item.block else {
                index -= 1
                continue  // skip directives like {comment: Intro}
            }
            let hasText = line.lyric.contains(where: { !$0.isWhitespace })
            if !line.chords.isEmpty, !hasText { return item.offset }  // chord-only line
            if hasText { return nil }  // reached a real lyric line first
            index -= 1  // blank separator line
        }
        return nil
    }

    /// Resolves the ball for a given block: the active lyric carries a word-tracking ball;
    /// during an instrumental gap the ball bounces across the gap's chord-only line (synced
    /// to the chords) or, if there is none, parks at the upcoming lyric line.
    private func beatBallValue(
        for item: ChordProPreviewIndexedBlock,
        in document: ChordProPreviewDocument
    ) -> LineBeatBall? {
        guard let beatBall else { return nil }

        if beatBall.isWaiting {
            let chordOffset = chordOnlyLineOffset(
                beforeLyricOrdinal: beatBall.ordinal, in: document)
            if let chordOffset, !beatBall.chordTimes.isEmpty, item.offset == chordOffset {
                return LineBeatBall(
                    currentTime: beatBall.currentTime,
                    segmentStart: beatBall.windowStart,
                    segmentEnd: beatBall.windowEnd,
                    bpm: beatBall.bpm,
                    beatTimes: beatBall.beatTimes,
                    chordTimes: beatBall.chordTimes
                )
            }
            // No chord-only line to track: park at the upcoming lyric line.
            if chordOffset == nil, item.lyricOrdinal == beatBall.ordinal {
                return LineBeatBall(
                    currentTime: beatBall.currentTime,
                    segmentStart: beatBall.windowStart,
                    segmentEnd: beatBall.windowEnd,
                    bpm: beatBall.bpm,
                    beatTimes: beatBall.beatTimes,
                    isWaiting: true
                )
            }
            return nil
        }

        guard item.lyricOrdinal == beatBall.ordinal else { return nil }
        return LineBeatBall(
            currentTime: beatBall.currentTime,
            segmentStart: beatBall.windowStart,
            segmentEnd: beatBall.windowEnd,
            bpm: beatBall.bpm,
            beatTimes: beatBall.beatTimes,
            words: beatBall.words
        )
    }
}

/// The minimal, per-line slice of `BeatBallInput` the line view needs to position the
/// ball relative to its OWN rendered lyric text.
struct LineBeatBall: Equatable {
    let currentTime: TimeInterval
    let segmentStart: TimeInterval
    let segmentEnd: TimeInterval
    let bpm: Double?
    let beatTimes: [TimeInterval]
    /// Real per-word timings within the active segment, when available. Empty falls back
    /// to beat-driven positioning with interpolated word x-positions.
    var words: [TimedLyricWord] = []
    /// When true the ball pulses in place at the left of the line (waiting for the next
    /// lyric during an instrumental gap) rather than tracking words.
    var isWaiting = false
    /// Chord onset times for a chord-only line; when present the ball bounces across the
    /// line's chords (paired in order) in sync with these times.
    var chordTimes: [TimeInterval] = []
}

private struct ChordProPreviewIndexedBlock {
    let offset: Int
    let block: ChordProPreviewBlock
    let lyricOrdinal: Int?
}

private struct ChordProPreviewBlockView: View {
    let block: ChordProPreviewBlock
    var highlight: ChordProLinePlaybackHighlight?
    var beatBall: LineBeatBall?

    var body: some View {
        switch block {
        case .title(let title):
            Text(title)
                .font(.title2.bold())
                .padding(.bottom, 2)
        case .metadata(let label, let value):
            HStack(spacing: 5) {
                Text(label + ":")
                    .foregroundStyle(.secondary)
                Text(value)
            }
            .font(.subheadline)
        case .section(let name):
            Text(name)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        case .comment(let comment):
            Text(comment)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
        case .lyric(let line):
            ChordProPreviewLineView(line: line, highlight: highlight, beatBall: beatBall)
        case .directive(let source):
            Text(source)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ChordProPreviewLineView: View {
    private static let lyricFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private static let characterWidth = NSString(string: "M").size(
        withAttributes: [.font: lyricFont]
    ).width

    /// Extra top space reserved above the content so the bouncing ball (and its arc
    /// apex) is never clipped. Content is shifted down by this amount, leaving the
    /// existing lyric/chord layout visually unchanged.
    private static let ballTopReserve: CGFloat = 22
    /// Apex travel above the tap baseline.
    private static let ballApexHeight: CGFloat = 18
    private static let ballDiameter: CGFloat = 11

    let line: ChordProPreviewLine
    var highlight: ChordProLinePlaybackHighlight?
    var beatBall: LineBeatBall?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                lyricText
                    .offset(y: line.chords.isEmpty ? 0 : 20)

                ForEach(Array(line.chords.enumerated()), id: \.offset) { _, chord in
                    Text(chord.name)
                        .font(
                            .system(
                                size: 13,
                                weight: chordWeight(for: chord),
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.tint)
                        .offset(x: CGFloat(chord.column) * Self.characterWidth)
                }
            }
            .offset(y: Self.ballTopReserve)

            if let ball = ballPosition {
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.ballDiameter, height: Self.ballDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .opacity(0.95)
                    .position(x: ball.x, y: ball.y)
            }
        }
        .frame(
            width: CGFloat(max(1, lineWidth)) * Self.characterWidth,
            height: (line.chords.isEmpty ? 20 : 42) + Self.ballTopReserve,
            alignment: .topLeading
        )
    }

    /// The ball's center in this line's coordinate space, or `nil` when no ball should
    /// be drawn (no beat-ball value, no resolvable beats, or playhead outside the arc).
    private var ballPosition: (x: CGFloat, y: CGFloat)? {
        guard let beatBall else { return nil }
        // The ball pulses on the detected beats (BPM-synthesized when no beat
        // times are available); at each beat it sits over the word being sung
        // then — from real word timings when present, else an interpolated
        // position — and arcs to the next beat's word. While waiting through an
        // instrumental gap it pulses in place at the left of the upcoming line.
        let tracksChords = !beatBall.chordTimes.isEmpty && !line.chords.isEmpty
        guard tracksChords || beatBall.isWaiting || !beatBall.words.isEmpty || !wordCenters.isEmpty
        else { return nil }

        let beats = BouncingBall.beats(
            in: beatBall.segmentStart,
            beatBall.segmentEnd,
            beatTimes: beatBall.beatTimes,
            bpm: beatBall.bpm
        )
        guard !beats.isEmpty else { return nil }

        let xs: [CGFloat]
        if tracksChords {
            xs = beats.map { chordCenterX(at: $0, beatBall: beatBall) }
        } else if beatBall.isWaiting {
            xs = beats.map { _ in Self.characterWidth / 2 }
        } else {
            xs = beats.map { wordCenterX(at: $0, beatBall: beatBall) }
        }
        let ball = BouncingBall(beatTimes: beats, beatX: xs)
        guard let position = ball.position(at: beatBall.currentTime) else { return nil }

        // Tap baseline sits just above the content's top (which is shifted down by the
        // reserve); apex rises `ballApexHeight` above that baseline.
        let baseline = Self.ballTopReserve - 2
        let y = baseline - position.lift * Self.ballApexHeight
        return (x: position.x, y: y)
    }

    /// The x the ball should sit over for a beat at `beatTime`: the center of the word
    /// being sung at that moment (from real word timings, aligned character-for-character
    /// with `line.lyric`) when available, otherwise an interpolated position across the
    /// line so the ball still tracks the lyric.
    private func wordCenterX(at beatTime: TimeInterval, beatBall: LineBeatBall) -> CGFloat {
        let characterCount = line.lyric.count
        if !beatBall.words.isEmpty {
            let active =
                beatBall.words.last(where: { $0.start <= beatTime && beatTime < $0.end })
                ?? beatBall.words.last(where: { $0.start <= beatTime })
                ?? beatBall.words.first
            if let word = active {
                let lower = min(max(word.characterRange.lowerBound, 0), characterCount)
                let upper = min(max(word.characterRange.upperBound, lower), characterCount)
                return (CGFloat(lower) + CGFloat(upper)) / 2 * Self.characterWidth
            }
        }
        let centers = wordCenters
        guard !centers.isEmpty else { return 0 }
        let span = max(beatBall.segmentEnd - beatBall.segmentStart, 0.0001)
        let relative = min(max((beatTime - beatBall.segmentStart) / span, 0), 1)
        let index = min(Int(relative * Double(centers.count)), centers.count - 1)
        return centers[index]
    }

    /// The x the ball should sit over for a beat at `beatTime` on a chord-only line: the
    /// center of the chord sounding then. `chordTimes` pairs in order with `line.chords`;
    /// on a count mismatch it interpolates across the chords by time.
    private func chordCenterX(at beatTime: TimeInterval, beatBall: LineBeatBall) -> CGFloat {
        let chords = line.chords
        guard !chords.isEmpty else { return Self.characterWidth / 2 }
        let times = beatBall.chordTimes
        let index: Int
        if times.count == chords.count {
            var active = 0
            for i in times.indices where times[i] <= beatTime { active = i }
            index = active
        } else {
            let span = max(beatBall.segmentEnd - beatBall.segmentStart, 0.0001)
            let relative = min(max((beatTime - beatBall.segmentStart) / span, 0), 1)
            index = min(Int(relative * Double(chords.count)), chords.count - 1)
        }
        let chord = chords[index]
        return (CGFloat(chord.column) + CGFloat(chord.name.count) / 2) * Self.characterWidth
    }

    /// Center x of each whitespace-delimited word in this line's OWN lyric, using the
    /// monospaced character width so it lines up with the rendered text.
    private var wordCenters: [CGFloat] {
        let characters = Array(line.lyric)
        var centers: [CGFloat] = []
        var start: Int?
        func close(_ end: Int) {
            if let wordStart = start {
                let length = end - wordStart
                let center = (CGFloat(wordStart) + CGFloat(length) / 2) * Self.characterWidth
                centers.append(center)
                start = nil
            }
        }
        for index in characters.indices {
            if characters[index].isWhitespace {
                close(index)
            } else if start == nil {
                start = index
            }
        }
        close(characters.count)
        return centers
    }

    private var lineWidth: Int {
        max(
            line.lyric.count,
            line.chords.map { $0.column + $0.name.count }.max() ?? 0
        )
    }

    private var lyricText: Text {
        guard !line.lyric.isEmpty else {
            return Text(" ").font(.system(size: 15, design: .monospaced))
        }
        let characters = Array(line.lyric)
        var output = Text("")
        for index in characters.indices {
            let isHighlighted = highlight?.wordRange?.contains(index) == true
            output =
                output
                + Text(String(characters[index]))
                .font(
                    .system(
                        size: 15,
                        weight: isHighlighted ? .bold : .regular,
                        design: .monospaced
                    )
                )
                .foregroundColor(isHighlighted ? .swAmber : .swTextPrimary)
        }
        return output
    }

    private func chordWeight(for chord: ChordProPreviewChord) -> Font.Weight {
        highlight?.chordLabels.contains(chord.name) == true ? .bold : .semibold
    }
}

private struct StemMixerEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var stemPlayback: StemPlaybackService
    @State private var errorMessage: String?

    init(model: AppModel) {
        self.model = model
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Stem Mixer")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Spacer()
                Button("Load Stem Folder...", systemImage: "folder") { loadStemFolder() }
                Button("Export Mix...", systemImage: "square.and.arrow.up") { exportMix() }
                    .disabled(model.stemFiles == nil || model.isExporting)
            }

            if model.stemFiles == nil {
                ContentUnavailableView(
                    "No Stems Loaded",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text(
                        "Choose a folder containing vocals, drums, bass, guitar, piano, and other audio files."
                    )
                )
            } else {
                if model.hasStaleStemPlayback {
                    Label(
                        "Saved stems are stale. Rerun Stems before playing the mix.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(Color.swCoral)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(StemKind.allCases, id: \.self) { kind in
                    stemRow(kind)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.swCoral)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func stemRow(_ kind: StemKind) -> some View {
        let state = model.stemMixer[kind]
        let isAvailable = model.stemFiles?[kind] != nil
        return HStack {
            Text(kind.rawValue.capitalized)
                .font(.swDisplay(13))
                .foregroundStyle(Color.swTextPrimary)
                .frame(width: 70, alignment: .leading)
            StemLevelMeter(level: stemPlayback.stemLevels[kind] ?? 0)
                .frame(width: 92, height: 10)
                .accessibilityLabel("\(kind.rawValue.capitalized) level")
                .accessibilityValue(
                    Text(
                        stemPlayback.stemLevels[kind] ?? 0,
                        format: .percent.precision(.fractionLength(0))
                    )
                )
            Slider(
                value: Binding(
                    get: { Double(model.stemMixer[kind].gain) },
                    set: { model.setStemGain(Float($0), for: kind) }
                ),
                in: 0...1
            )
            Text(state.gain, format: .percent.precision(.fractionLength(0)))
                .font(.swMono(12))
                .foregroundStyle(Color.swTextSecondary)
                .frame(width: 45, alignment: .trailing)
            Toggle(
                "Mute",
                isOn: Binding(
                    get: { model.stemMixer[kind].isMuted },
                    set: { model.setStemMuted($0, for: kind) }
                )
            )
            .toggleStyle(.button)
            Toggle(
                "Solo",
                isOn: Binding(
                    get: { model.stemMixer[kind].isSoloed },
                    set: { model.setStemSoloed($0, for: kind) }
                )
            )
            .toggleStyle(.button)
        }
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
    }

    private func loadStemFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importStems(from: url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportMix() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Stem Mix.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportStemMix(to: url)
    }
}

private struct StemLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.black.opacity(0.22))
                RoundedRectangle(cornerRadius: 3)
                    .fill(meterGradient)
                    .frame(width: proxy.size.width * CGFloat(clampedLevel))
                    .animation(.linear(duration: 0.08), value: clampedLevel)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(.secondary.opacity(0.35), lineWidth: 0.5)
        }
    }

    private var clampedLevel: Float {
        min(max(level, 0), 1)
    }

    private var meterGradient: LinearGradient {
        // Mint = healthy data level; coral reserved for the clipping (hot) end.
        LinearGradient(
            colors: [.swMint, .swMint, .swMint, .swCoral],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
