import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceEditorsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var stemPlayback: StemPlaybackService

    init(model: AppModel) {
        self.model = model
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        VStack(spacing: 12) {
            PracticeTransportControls(model: model)
            HStack {
                Spacer()
                Button(
                    stemPlayback.isPlaying ? "Pause Mix" : "Play Mix",
                    systemImage: stemPlayback.isPlaying ? "pause.fill" : "play.fill"
                ) {
                    model.toggleStemPlayback()
                }
                .disabled(!stemPlayback.isLoaded)
                .swAccentHoverBorder(cornerRadius: 6)
            }
            .padding(.horizontal)
            Divider()
            TabView {
                TimedLyricsEditor(model: model)
                    .tabItem { Label("Lyrics", systemImage: "text.quote") }
                ChordTimelineEditor(model: model)
                    .tabItem { Label("Chords", systemImage: "music.note") }
                ChordProEditor(model: model)
                    .tabItem { Label("ChordPro", systemImage: "doc.plaintext") }
                BassNoteChordProEditor(model: model)
                    .tabItem { Label("Bass Notes", systemImage: "music.note") }
                StemMixerEditor(model: model)
                    .tabItem { Label("Stems", systemImage: "slider.horizontal.3") }
            }
        }
        .padding(.top, 12)
        .swSurfacePanel(cornerRadius: 12)
        .frame(minHeight: 620, maxHeight: .infinity, alignment: .top)
    }
}

private struct PracticeTransportControls: View {
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
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                ZStack {
                    Label("Playback", systemImage: "timeline.selection")
                        .font(.swDisplay(13, weight: .medium))
                        .foregroundStyle(Color.swTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 22) {
                        Button("Back 10 Seconds", systemImage: "gobackward.10") {
                            model.skipActivePlayback(by: -10)
                        }
                        .labelStyle(.iconOnly)
                        .swAccentHoverBorder(cornerRadius: 6)

                        Button(
                            model.isActivePlaybackPlaying ? "Pause" : "Play",
                            systemImage: model.isActivePlaybackPlaying
                                ? "pause.circle.fill" : "play.circle.fill"
                        ) {
                            model.toggleActivePlayback()
                        }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 34))
                        .disabled(model.selectedSong == nil)
                        .swAccentHoverBorder(cornerRadius: 18)

                        Button("Forward 10 Seconds", systemImage: "goforward.10") {
                            model.skipActivePlayback(by: 10)
                        }
                        .labelStyle(.iconOnly)
                        .swAccentHoverBorder(cornerRadius: 6)
                    }
                }
                HStack {
                    Text(sourceLabel)
                        .font(.swDisplay(11))
                        .foregroundStyle(Color.swTextSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.swSurface, in: Capsule())
                    Spacer()
                    Text("\(formatTime(seekPosition)) / \(formatTime(activeDuration))")
                        .font(.swMono(11))
                        .foregroundStyle(Color.swMint)
                }
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
            }

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
        .padding(.horizontal)
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

    private var activeDuration: TimeInterval {
        model.activePlaybackSource == .stemMix ? stemPlayback.duration : playback.duration
    }

    private var sourceLabel: String {
        model.activePlaybackSource == .stemMix ? "Stem Mix" : "Recording"
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

private struct ChordProEditor: View {
    private enum Mode: String, CaseIterable {
        case preview = "App Preview"
        case edit = "Edit"
    }

    @ObservedObject var model: AppModel
    @ObservedObject private var playback: AudioPlaybackService
    @ObservedObject private var stemPlayback: StemPlaybackService
    @State private var transpose = 0
    @State private var errorMessage: String?
    @State private var mode = Mode.preview

    init(model: AppModel) {
        self.model = model
        playback = model.playback
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ChordPro")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Text(model.chordProReviewState.rawValue.capitalized)
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.swSurface, in: Capsule())
                Button("Import...", systemImage: "square.and.arrow.down") {
                    importDocument()
                }
                Picker("ChordPro view", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                Button("Mark Reviewed", systemImage: "checkmark.seal") {
                    model.markChordProReviewed()
                }
                .disabled(model.chordProSource.isEmpty || model.chordProReviewState == .reviewed)
                Stepper("Transpose: \(transpose)", value: $transpose, in: -12...12)
                Button("Export...", systemImage: "square.and.arrow.up") {
                    exportDocument()
                }
                .disabled(model.chordProSource.isEmpty)
            }
            Group {
                switch mode {
                case .edit:
                    TextEditor(text: $model.chordProSource)
                        .font(.system(.body, design: .monospaced))
                        .border(.separator)
                case .preview:
                    ChordProAppPreview(
                        source: model.chordProSource,
                        transpose: transpose,
                        highlightContext: highlightContext(style: .chord)
                    )
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.swCoral)
            }
        }
        .padding()
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
        panel.nameFieldStringValue = "Song.cho"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportChordPro(to: url, transposedBy: transpose)
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

    private var currentPlaybackTime: TimeInterval {
        model.activePlaybackSource == .stemMix ? stemPlayback.currentTime : playback.currentTime
    }
}

private struct ChordProAppPreview: View {
    let source: String
    var transpose: Int = 0
    var highlightContext: ChordProPlaybackHighlightContext?

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
                                            )
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
            if case .lyric(let line) = block, !line.lyric.isEmpty {
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
}

private struct ChordProPreviewIndexedBlock {
    let offset: Int
    let block: ChordProPreviewBlock
    let lyricOrdinal: Int?
}

private struct BassNoteChordProEditor: View {
    private enum Mode: String, CaseIterable {
        case preview = "App Preview"
        case source = "Source"
    }

    @ObservedObject var model: AppModel
    @ObservedObject private var playback: AudioPlaybackService
    @ObservedObject private var stemPlayback: StemPlaybackService
    @State private var errorMessage: String?
    @State private var mode = Mode.preview

    init(model: AppModel) {
        self.model = model
        playback = model.playback
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        let source = model.bassNoteChordProSource
        VStack(spacing: 8) {
            HStack {
                Text("Bass Note ChordPro")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Text("Generated")
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.swSurface, in: Capsule())
                Picker("Bass note ChordPro view", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                Button("Export...", systemImage: "square.and.arrow.up") {
                    exportDocument()
                }
                .disabled(source.isEmpty || model.chordEvents.isEmpty)
            }

            if model.chordEvents.isEmpty {
                ContentUnavailableView(
                    "No Bass Notes",
                    systemImage: "music.note",
                    description: Text("Run Tempo & Chords or add chord events first.")
                )
            } else {
                Group {
                    switch mode {
                    case .source:
                        ScrollView([.horizontal, .vertical]) {
                            Text(source)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(8)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .border(.separator)
                    case .preview:
                        ChordProAppPreview(
                            source: source,
                            highlightContext: highlightContext(style: .bassNote)
                        )
                    }
                }
            }

            Text(
                "Bass notes are derived from detected chords: slash-bass notes are used first, otherwise the chord root is used."
            )
            .font(.swDisplay(11))
            .foregroundStyle(Color.swTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.swCoral)
            }
        }
        .padding()
    }

    private func exportDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cho") ?? .plainText]
        panel.nameFieldStringValue = "Bass Notes.cho"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportBassNoteChordPro(to: url)
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

    private var currentPlaybackTime: TimeInterval {
        model.activePlaybackSource == .stemMix ? stemPlayback.currentTime : playback.currentTime
    }
}

private struct ChordProPreviewBlockView: View {
    let block: ChordProPreviewBlock
    var highlight: ChordProLinePlaybackHighlight?

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
            ChordProPreviewLineView(line: line, highlight: highlight)
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

    let line: ChordProPreviewLine
    var highlight: ChordProLinePlaybackHighlight?

    var body: some View {
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
        .frame(
            width: CGFloat(max(1, lineWidth)) * Self.characterWidth,
            height: line.chords.isEmpty ? 20 : 42,
            alignment: .topLeading
        )
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
