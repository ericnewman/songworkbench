import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The workspace editor tabs, selected by a segmented control at the top of the
/// window so the editor content fills the right column.
enum EditorTab: String, CaseIterable, Identifiable {
    case lyrics
    case chords
    case chordPro
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: "Lyrics"
        case .chords: "Chords"
        case .chordPro: "ChordPro"
        case .review: "Review"
        }
    }

    var systemImage: String {
        switch self {
        case .lyrics: "text.quote"
        case .chords: "music.note"
        case .chordPro: "doc.plaintext"
        case .review: "text.badge.checkmark"
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
            case .chordPro: ChordProTrueView(model: model)
            case .review: ChordProReviewTab(model: model)
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
        // One THIN full-width bar: identity · transport · scrubber (flexible) · pitch/speed.
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Playback", systemImage: "play.circle")
                    .font(.swDisplay(12, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                    .lineLimit(1)
                Text(sourceLabel)
                    .font(.swDisplay(10))
                    .foregroundStyle(Color.swTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.swSurface, in: Capsule())
            }
            .fixedSize()

            HStack(spacing: 12) {
                Button("Back 10 Seconds", systemImage: "gobackward.10") {
                    model.skipActivePlayback(by: -10)
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 18))
                .swAccentHoverBorder(cornerRadius: 6)
                .help("Back 10 seconds")

                compactPlayButton(
                    title: model.isActivePlaybackPlaying ? "Pause Song" : "Play Song",
                    disabled: model.selectedSong == nil,
                    isPlaying: model.isActivePlaybackPlaying,
                    help: "Play or pause the original recording"
                ) {
                    model.toggleActivePlayback()
                }

                compactPlayButton(
                    title: stemPlayback.isPlaying ? "Pause Stem Mix" : "Play Stem Mix",
                    disabled: !stemPlayback.isLoaded,
                    isPlaying: stemPlayback.isPlaying,
                    symbolVariant: "square.stack",
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
                .font(.system(size: 18))
                .swAccentHoverBorder(cornerRadius: 6)
                .help("Forward 10 seconds")
            }
            .fixedSize()

            // Compact scrubber (~3in) — enough travel for seeking without dominating the bar.
            PlaybackProgressSlider(model: model)
                .frame(width: 220)

            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 1) {
                    Slider(
                        value: Binding(
                            get: { Double(model.pitchSemitones) },
                            set: { model.pitchSemitones = Int($0.rounded()) }
                        ),
                        in: Double(
                            PitchShift.range.lowerBound)...Double(PitchShift.range.upperBound),
                        step: 1
                    )
                    .controlSize(.mini)
                    Text("Pitch \(compactPitchLabel)")
                        .font(.swDisplay(9))
                        .foregroundStyle(Color.swTextSecondary)
                        .lineLimit(1)
                }
                .frame(width: 108)
                .help("Pitch shift (semitones); playback speed is unaffected")
                VStack(spacing: 1) {
                    Slider(value: $model.tempoRate, in: 0.5...1.5, step: 0.05)
                        .controlSize(.mini)
                    Text("Speed \(Int((model.tempoRate * 100).rounded()))%")
                        .font(.swDisplay(9))
                        .foregroundStyle(Color.swTextSecondary)
                        .lineLimit(1)
                }
                .frame(width: 108)
                .help("Playback speed (pitch preserved)")
                Button("Reset Pitch and Speed", systemImage: "arrow.counterclockwise") {
                    model.pitchSemitones = 0
                    model.tempoRate = 1
                }
                .labelStyle(.iconOnly)
                .disabled(model.pitchSemitones == 0 && model.tempoRate == 1)
                .help("Reset pitch and speed")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .swSurfacePanel(cornerRadius: 12)
    }

    /// Short pitch caption that fits the compact card: the key transposition when known
    /// ("Db→Eb"), otherwise the semitone offset.
    private var compactPitchLabel: String {
        let semitones = model.pitchSemitones
        if let key = model.estimatedKey {
            guard semitones != 0 else { return key.displayName }
            return "\(key.displayName)→\(key.transposed(by: semitones).displayName)"
        }
        return semitones > 0 ? "+\(semitones) st" : "\(semitones) st"
    }

    /// A compact play/pause icon button (badge overlay distinguishes the stem-mix control;
    /// the caption moved into the tooltip to keep the bar thin).
    @ViewBuilder
    private func compactPlayButton(
        title: String,
        disabled: Bool,
        isPlaying: Bool,
        symbolVariant: String? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill") {
            action()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 26))
        .disabled(disabled)
        .swAccentHoverBorder(cornerRadius: 13)
        .overlay(alignment: .bottomTrailing) {
            if let symbolVariant {
                Image(systemName: symbolVariant)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(
                        disabled ? Color.swTextSecondary.opacity(0.5) : Color.swTextSecondary
                    )
                    .offset(x: 3, y: 2)
            }
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

    // Duration for whichever source is active — delegates to `AppModel.activeClock` rather
    // than re-deriving the branch here; `playback`/`stemPlayback` above are kept only so
    // SwiftUI's `.onChange` has concrete `@Published` values to observe.
    private var activeDuration: TimeInterval { model.activePlaybackDuration }

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
    // Observe playback so the active-line highlight follows the playhead live.
    @ObservedObject private var playback: AudioPlaybackService
    @ObservedObject private var stemPlayback: StemPlaybackService
    /// When true, show the lyrics as plain read-only paragraphs (no timestamps) instead of the
    /// editable timestamped list.
    @State private var showPlainText = false
    /// Whether to show the review flags on suspect (possible mis-split) lines. Off by default.
    @AppStorage("showSuspectLineFlags") private var showSuspectFlags = false
    /// C1 (backlog #8): reference-lyrics-first prompt banner state. Presents the SAME
    /// `ReferenceLyricsSheet` `AnalysisWorkspaceView`'s "Reference Lyrics" button does — this is
    /// just a second, more discoverable entry point where a user actually reviews lyrics, not a
    /// separate feature.
    @State private var showReferenceLyrics = false
    /// Session-only dismissal, keyed by song so switching to a different un-referenced song
    /// shows the prompt again rather than staying dismissed forever after the first song.
    @State private var dismissedReferenceBannerForSongID: Song.ID?

    init(model: AppModel) {
        self.model = model
        playback = model.playback
        stemPlayback = model.stemPlayback
    }

    private var timelineSections: [LyricTimelineSection] {
        LyricSectionDeriver().sections(
            lyrics: model.lyricSegments,
            beatTimes: model.beatTimes,
            tempo: model.estimatedBPM,
            sourceDuration: model.sourceDuration)
    }

    /// 1-based line number for each lyric line (section headers don't count), shown in a left
    /// gutter so lines can be referenced ("line 7") — matching the ChordPro preview's numbering.
    private var lyricLineNumbers: [TimedLyricSegment.ID: Int] {
        var map: [TimedLyricSegment.ID: Int] = [:]
        var number = 0
        for row in timestampedRows {
            if case .lyric(let id) = row {
                number += 1
                map[id] = number
            }
        }
        return map
    }

    /// Lyric lines that look like mis-splits (off the probable beats-per-line or off the beat grid),
    /// keyed by id → reason. Shown as a review flag; use Merge/Split to correct.
    private var suspectReasons: [TimedLyricSegment.ID: String] {
        guard showSuspectFlags else { return [:] }
        return LyricLineDiagnostics.suspectReasons(
            model.lyricSegments, beatTimes: model.beatTimes, tempo: model.estimatedBPM)
    }

    /// Lyric lines and section headers merged in timeline order for the timestamped list.
    private var timestampedRows: [LyricsEditorRow] {
        let segments = model.lyricSegments.sorted { $0.start < $1.start }
        let sections = timelineSections
        var rows: [LyricsEditorRow] = []
        var sectionIndex = 0
        for segment in segments {
            while sectionIndex < sections.count,
                sections[sectionIndex].start <= segment.start + 0.001
            {
                rows.append(.section(sections[sectionIndex]))
                sectionIndex += 1
            }
            rows.append(.lyric(segment.id))
        }
        while sectionIndex < sections.count {
            rows.append(.section(sections[sectionIndex]))
            sectionIndex += 1
        }
        return rows
    }

    /// C1: show the reference-lyrics prompt when this song has transcribed lyrics to review,
    /// no reference text is set yet, and the user hasn't dismissed it this session for THIS song.
    private var shouldShowReferenceLyricsPrompt: Bool {
        ReferenceLyricsPromptPolicy.shouldPrompt(
            referenceLyrics: model.referenceLyrics,
            hasLyricSegments: !model.lyricSegments.isEmpty,
            selectedSongID: model.selectedSongID,
            dismissedForSongID: dismissedReferenceBannerForSongID)
    }

    /// Playhead shared with the waveform (`ContentView` uses `activePlaybackTime`).
    private var playheadTime: TimeInterval { model.lyricHighlightTime }

    /// Lyric line active at `playheadTime`: spans extend through instrumental gaps until the next
    /// line starts; overlaps resolve to the latest-starting segment.
    private var activeSegmentID: TimedLyricSegment.ID? {
        let segments = model.lyricSegments
        guard
            let index = ChordProHighlightDeriver.activeSegmentIndex(
                at: playheadTime, in: segments)
        else { return nil }
        let sorted = segments.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.text < $1.text
        }
        return sorted[index].id
    }

    /// Intro / Instrumental / Outro header highlighted when the playhead is in that region and no
    /// lyric line is active (typically the intro before the first sung line).
    private var activeSectionID: String? {
        ChordProHighlightDeriver.activeInstrumentalSection(
            at: playheadTime,
            sections: timelineSections,
            lyricSegments: model.lyricSegments,
            sourceDuration: model.sourceDuration
        )?.id
    }

    var body: some View {
        VStack(spacing: 8) {
            if shouldShowReferenceLyricsPrompt {
                ReferenceLyricsPromptBanner(
                    pasteAction: { showReferenceLyrics = true },
                    dismissAction: { dismissedReferenceBannerForSongID = model.selectedSongID }
                )
            }
            HStack {
                Text("Timestamped Lyrics")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                reviewBadge(model.lyricReviewState)
                Spacer()
                Button(
                    showPlainText ? "Timestamps" : "Paragraphs",
                    systemImage: showPlainText ? "list.bullet" : "text.alignleft"
                ) {
                    showPlainText.toggle()
                }
                .disabled(model.lyricSegments.isEmpty)
                .help("Toggle between the editable timestamped list and a plain paragraph view.")
                Button(
                    "Review Flags",
                    systemImage: showSuspectFlags
                        ? "flag.fill" : "flag.slash"
                ) {
                    showSuspectFlags.toggle()
                }
                .labelStyle(.iconOnly)
                .disabled(model.lyricSegments.isEmpty || showPlainText)
                .help(
                    "Show/hide review flags on lines that look like mis-splits (short/long vs the "
                        + "typical line, or starting off the beat). Off by default.")
                Button("Mark Reviewed", systemImage: "checkmark.seal") {
                    model.markLyricsReviewed()
                }
                .disabled(model.lyricSegments.isEmpty || model.lyricReviewState == .reviewed)
                Button("Add Line", systemImage: "plus") {
                    model.addLyricSegment()
                }
                .help(
                    "Inserts an empty lyric line at the current playback time (the playhead in the "
                        + "waveform above). Play or scrub to the moment, click Add Line, then type "
                        + "the words. You can also edit the start/end times directly.")
            }
            if showPlainText {
                ScrollView {
                    Text(plainLyricsText.isEmpty ? "No lyrics yet." : plainLyricsText)
                        .font(.swMono(14))
                        .foregroundStyle(Color.swTextPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(timestampedRows) { row in
                            switch row {
                            case .section(let section):
                                LyricSectionHeaderRow(section: section)
                                    .listRowBackground(
                                        section.id == activeSectionID
                                            ? Color.swAccent.opacity(0.18)
                                            : Color.swSurface.opacity(0.35))
                            case .lyric(let segmentID):
                                if let index = model.lyricSegments.firstIndex(where: {
                                    $0.id == segmentID
                                }) {
                                    let isActive = segmentID == activeSegmentID
                                    HStack {
                                        Text(lyricLineNumbers[segmentID].map(String.init) ?? "")
                                            .font(.swMono(10))
                                            .foregroundStyle(Color.swTextSecondary)
                                            .frame(width: 24, alignment: .trailing)
                                        LyricTimeField(seconds: $model.lyricSegments[index].start)
                                            .frame(width: 70)
                                        LyricTimeField(seconds: $model.lyricSegments[index].end)
                                            .frame(width: 70)
                                        if let reason = suspectReasons[segmentID] {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(Color.swAmber)
                                                .help(reason)
                                                .accessibilityLabel("Possible mis-split line")
                                        }
                                        TextField(
                                            "Lyric", text: $model.lyricSegments[index].text)
                                        Button("Split line", systemImage: "scissors") {
                                            model.splitLyricSegment(segmentID)
                                        }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                        .help("Split this line at its largest internal gap")
                                        .disabled(model.lyricSegments[index].words.count < 2)
                                        Button(
                                            "Merge with next line",
                                            systemImage: "arrow.triangle.merge"
                                        ) {
                                            model.mergeLyricSegmentWithNext(segmentID)
                                        }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                        .help("Merge this line into the next")
                                        Button("Remove", systemImage: "trash", role: .destructive) {
                                            model.lyricSegments.removeAll { $0.id == segmentID }
                                        }
                                        .labelStyle(.iconOnly)
                                    }
                                    .id(segmentID)
                                    .listRowBackground(
                                        isActive ? Color.swAccent.opacity(0.18) : Color.clear)
                                }
                            }
                        }
                    }
                    .onChange(of: activeSegmentID) { _, id in
                        guard let id else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .overlay {
                    if model.lyricSegments.isEmpty {
                        ContentUnavailableView(
                            "No Timed Lyrics",
                            systemImage: "text.quote",
                            description: Text(
                                "Analyze the song, or play to a spot and click Add Line to enter "
                                    + "lyrics by hand.")
                        )
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $showReferenceLyrics) {
            ReferenceLyricsSheet(model: model)
        }
    }

    /// The lyrics as plain read-only paragraphs: section headers and one line per segment, with a
    /// blank line inserted at instrumental gaps (≥ 4s between lines) so verses read as paragraphs.
    private var plainLyricsText: String {
        let segments = model.lyricSegments
            .sorted { $0.start < $1.start }
            .filter { $0.text.contains(where: { !$0.isWhitespace }) }
        let sections = timelineSections
        var lines: [String] = []
        var sectionIndex = 0
        var previousEnd: TimeInterval?
        for segment in segments {
            while sectionIndex < sections.count,
                sections[sectionIndex].start <= segment.start + 0.001
            {
                if !lines.isEmpty { lines.append("") }
                lines.append("[\(sections[sectionIndex].label)]")
                sectionIndex += 1
            }
            if let previousEnd, segment.start - previousEnd >= 4 { lines.append("") }
            lines.append(segment.text)
            previousEnd = segment.end
        }
        while sectionIndex < sections.count {
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(sections[sectionIndex].label)]")
            sectionIndex += 1
        }
        return lines.joined(separator: "\n")
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

/// Pure gating logic for the Lyrics tab's reference-lyrics prompt banner (C1, backlog #8),
/// factored out of `TimedLyricsEditor.shouldShowReferenceLyricsPrompt` so it's directly unit
/// testable without standing up the view's `@ObservedObject`/`@State` machinery. Not `private`
/// so `SongWorkbenchTests` can call it via `@testable import`.
enum ReferenceLyricsPromptPolicy {
    static func shouldPrompt(
        referenceLyrics: String,
        hasLyricSegments: Bool,
        selectedSongID: Song.ID?,
        dismissedForSongID: Song.ID?
    ) -> Bool {
        guard let selectedSongID, hasLyricSegments else { return false }
        guard referenceLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return dismissedForSongID != selectedSongID
    }
}

/// C1 (backlog #8): a lightweight, dismissible prompt shown at the top of the Lyrics tab —
/// where a user actually notices ASR mistakes — for songs with no reference lyrics set yet.
/// Makes pasting real lyrics (when they exist, e.g. a cover) the discoverable/primary path
/// instead of a small button buried in the collapsible Song Analysis card. That original
/// button + sheet stay as-is; this just opens the SAME `ReferenceLyricsSheet` from a second,
/// better-placed entry point.
private struct ReferenceLyricsPromptBanner: View {
    let pasteAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(Color.swAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Have the real lyrics for this song?")
                    .font(.swDisplay(12, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Text("Paste them for perfectly accurate words and line breaks.")
                    .font(.caption)
                    .foregroundStyle(Color.swTextSecondary)
            }
            Spacer()
            Button("Paste Lyrics", action: pasteAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Dismiss", systemImage: "xmark", action: dismissAction)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(
                    "Hide this prompt for this song (you can still use Reference Lyrics in the "
                        + "Song Analysis card).")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.swAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum LyricsEditorRow: Identifiable {
    case section(LyricTimelineSection)
    case lyric(TimedLyricSegment.ID)

    var id: String {
        switch self {
        case .section(let section): "section-\(section.id)"
        case .lyric(let segmentID): "lyric-\(segmentID.uuidString)"
        }
    }
}

private struct LyricSectionHeaderRow: View {
    let section: LyricTimelineSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(Color.swAccent)
                .frame(width: 70, alignment: .trailing)
            Text(section.label)
                .font(.swDisplay(13, weight: .semibold))
                .foregroundStyle(Color.swTextSecondary)
            Spacer()
            Text(formattedTime(section.start))
                .font(.swMono(11))
                .foregroundStyle(Color.swTextSecondary.opacity(0.8))
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.label) at \(formattedTime(section.start))")
    }

    private var iconName: String {
        switch section.kind {
        case .intro: "arrow.right.to.line"
        case .instrumental: "music.note"
        case .outro: "arrow.left.to.line"
        case .vocal: "text.quote"
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// A seconds field that edits as PLAIN TEXT and commits only on Return or when focus leaves, so
/// typing isn't fought by live number reformatting (the old `TextField(value:format: .number)`
/// turned a mid-typed "22.0" into "0.0022.0"). The bound value updates only on commit.
private struct LyricTimeField: View {
    @Binding var seconds: Double
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("0.00", text: $text)
            .multilineTextAlignment(.leading)
            .focused($isFocused)
            .onAppear { text = Self.format(seconds) }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    text = Self.format(seconds)  // show full precision while editing
                } else {
                    commit()
                }
            }
            .onChange(of: seconds) { _, newValue in
                if !isFocused { text = Self.format(newValue) }
            }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let parsed = Double(trimmed) { seconds = max(0, parsed) }
        text = Self.format(seconds)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
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
                Button("Add Chord", systemImage: "plus") {
                    model.addChordEvent()
                }
                .help(
                    "Adds a chord at the current playback time (the playhead in the waveform). "
                        + "Then type the chord name, e.g. Ab, and adjust its time if needed.")
            }
            if let progress = model.analysisJobSnapshot?.progress, isAnalysisRunning {
                ProgressView(
                    progress.message ?? "Analyzing...",
                    value: progress.fractionCompleted
                )
            }
            HStack(spacing: 12) {
                Button {
                    model.chordConfidenceThreshold = 0.5
                } label: {
                    Label("ChordPro confidence", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.callout)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to reset the confidence threshold to its default (50%)")
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
        case .liveCapture:
            "Live capture"
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
    @AppStorage("beatDotsEnabled") private var beatDotsEnabled = false
    @AppStorage("chordProBarlinesEnabled") private var barlinesEnabled = false
    @AppStorage("rhythmicSpacing") private var rhythmicSpacing = false
    @AppStorage("chordProShowWaveform") private var showWaveform = false

    /// Lyric segments sorted into the order the highlight/ball ordinals use (so ordinal N indexes
    /// the same line across words, windows, and highlight).
    private var sortedLyricSegments: [TimedLyricSegment] {
        model.lyricSegments.sorted {
            if $0.start == $1.start, $0.end == $1.end { return $0.text < $1.text }
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
    }

    /// Lyric-line word timings sorted into the same order the highlight/ball ordinals use, so the
    /// App Preview can space each line's words by their onset in rhythmic mode.
    private var sortedLyricLineWords: [[TimedLyricWord]] {
        sortedLyricSegments.map(\.words)
    }

    /// Each lyric line's [start, end] time window, by ordinal — for slicing the per-line audio strip.
    private var sortedLyricLineWindows: [ClosedRange<TimeInterval>] {
        sortedLyricSegments.map { min($0.start, $0.end)...max($0.start, $0.end) }
    }
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
                    .labelStyle(.iconOnly)
                    .help("Import a ChordPro file")
                }
                Picker(config.pickerAccessibilityLabel, selection: $mode) {
                    Text("App Preview").tag(Mode.preview)
                    Text(config.secondaryModeLabel).tag(Mode.secondary)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                timingOffsetControl
                // The four display toggles live in one compact "View" menu so their labels can't
                // wrap and crowd the toolbar.
                Menu {
                    Toggle("Bouncing ball", isOn: $bouncingBallEnabled)
                    Toggle("Beat dots", isOn: $beatDotsEnabled)
                    Toggle("Barlines", isOn: $barlinesEnabled)
                    Toggle("Rhythmic spacing", isOn: $rhythmicSpacing)
                    Toggle("Waveform", isOn: $showWaveform)
                } label: {
                    Label("View", systemImage: "eye")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(
                    "Show/hide the bouncing ball, beat dots, measure barlines, rhythmic spacing, "
                        + "and the per-line waveform")
                Spacer()
                if config.supportsMarkReviewed {
                    Button("Mark Reviewed", systemImage: "checkmark.seal") {
                        model.markChordProReviewed()
                    }
                    .labelStyle(.iconOnly)
                    .help("Mark the chart reviewed")
                    .disabled(
                        model.chordProSource.isEmpty || model.chordProReviewState == .reviewed
                    )
                }
                if config.supportsTranspose {
                    Stepper(
                        "Transpose \(model.chordProTranspose)",
                        value: $model.chordProTranspose, in: -12...12
                    )
                    .fixedSize()
                }
                Button("Export...", systemImage: "square.and.arrow.up") {
                    exportDocument()
                }
                .labelStyle(.iconOnly)
                .help("Export the chart to a ChordPro file")
                .disabled(!isExportEnabled)
                if config.kind == .chordPro {
                    Button("JustChords", systemImage: "arrow.up.forward.app") {
                        openInJustChords()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.chordProSource.isEmpty)
                    .help("Export the current chart and open it in the JustChords app.")
                }
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
                            beatBall: beatBallInput,
                            beatDots: beatDotContext,
                            showBarlines: barlinesEnabled,
                            rhythmicSpacing: rhythmicSpacing,
                            lyricLineWords: sortedLyricLineWords,
                            showWaveform: showWaveform,
                            audioEnvelope: model.vocalWaveform ?? model.waveform,
                            audioEnvelopeIsVocals: model.vocalWaveform != nil,
                            guitarEnvelope: model.stemWaveforms.first { $0.kind == .guitar }?
                                .envelope,
                            pianoEnvelope: model.stemWaveforms.first { $0.kind == .piano }?
                                .envelope,
                            drumsEnvelope: model.stemWaveforms.first { $0.kind == .drums }?
                                .envelope,
                            bassEnvelope: model.stemWaveforms.first { $0.kind == .bass }?
                                .envelope,
                            lyricLineWindows: sortedLyricLineWindows,
                            bpm: model.estimatedBPM,
                            beatTimes: model.beatTimes,
                            chordOnsetTimes: model.chordEvents.map(\.time).sorted(),
                            untranscribedLineNumbers: Set(
                                (model.songTimelineForPreview()?.rows
                                    .filter(\.containsUntranscribedVocals)
                                    .map(\.number)) ?? []),
                            // B3: authoritative per-row chord TIMES so the preview places
                            // each chord at its real moment instead of re-deriving it from
                            // character columns (nil-safe: empty for edited charts).
                            timelineChordTimesByLine: Dictionary(
                                uniqueKeysWithValues: (model.songTimelineForPreview()?.rows ?? [])
                                    .map { ($0.number, $0.chordTimes) })
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

    /// Writes the current (transposed) ChordPro to a temp file and opens it in the JustChords app.
    private func openInJustChords() {
        let baseName = (config.exportFileName as NSString).deletingPathExtension
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(baseName.isEmpty ? "chart" : baseName)
            .appendingPathExtension("cho")
        do {
            try model.exportChordPro(to: fileURL, transposedBy: model.chordProTranspose)
        } catch {
            errorMessage = "Could not prepare the chart: \(error.localizedDescription)"
            return
        }
        guard let appURL = Self.justChordsApplicationURL() else {
            errorMessage = "JustChords wasn’t found in Applications."
            return
        }
        let openConfig = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: openConfig) {
            _, error in
            if let error {
                DispatchQueue.main.async {
                    errorMessage = "Could not open JustChords: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Locates the JustChords app in the standard install locations.
    private static func justChordsApplicationURL() -> URL? {
        let candidates = [
            "/Applications/JustChords.app",
            "\(NSHomeDirectory())/Applications/JustChords.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
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

    /// Lead applied to the highlight/ball clock while playing. Historically 0.45s to compensate for
    /// LATE ASR word timestamps; now that word times are pinned to the actual vocal-stem energy
    /// (audio-as-reference), that bias is gone and the lead made highlights fire early. Kept at 0 so
    /// the highlight matches the waveform energy; the per-song offset slider remains for fine tuning.
    private static let highlightLeadSeconds: TimeInterval = 0

    /// Playback position that drives the lyric highlight and bouncing ball. While
    /// playing it leads by `highlightLeadSeconds` so the highlight lands on the
    /// word being heard; paused, it reflects the exact playhead position.
    private var currentPlaybackTime: TimeInterval {
        // Single clock accessor (audit 3d): AppModel owns the active-source selection; this
        // view no longer picks between services itself. (The @ObservedObject services are
        // still observed so SwiftUI re-renders on every tick.)
        let base = model.activePlaybackTime
        let lead = model.isActivePlaybackPlaying ? base + Self.highlightLeadSeconds : base
        // Render-only: shift where the ball/highlight is drawn by the user's tuned
        // offset. Audio playback time is untouched. Single source: model.chordProTimingOffsetMS.
        return lead + Double(model.chordProTimingOffsetMS) / 1000.0
    }

    /// Drives the karaoke bouncing ball over the active lyric line during playback.
    /// `nil` whenever nothing is active or there is no beat data (neither explicit
    /// beat times nor a usable BPM) to position the ball.
    /// Gaps shorter than this don't get a waiting ball — only noticeable instrumental
    /// stretches (intros, breaks) park the ball at the upcoming line.
    private static let waitingBallMinimumGap: TimeInterval = 2

    /// Compact render-only timing-offset tuner for the bouncing ball / position
    /// indicator. −500…+500 ms, center = 0. Only shown when the ball is enabled.
    @ViewBuilder private var timingOffsetControl: some View {
        if bouncingBallEnabled {
            let offsetBinding = Binding<Double>(
                get: { Double(model.chordProTimingOffsetMS) },
                set: { raw in
                    // Center detent: snap small drags back to exactly 0.
                    let snapped = abs(raw) < 15 ? 0 : raw
                    model.chordProTimingOffsetMS = Int(snapped.rounded())
                }
            )
            HStack(spacing: 6) {
                VStack(spacing: 1) {
                    Slider(value: offsetBinding, in: -500...500)
                        .frame(width: 90)
                    Text("Timing")
                        .font(.swDisplay(10))
                        .foregroundStyle(Color.swTextSecondary)
                        .fixedSize()
                }
                .help(
                    "Shift the bouncing ball earlier/later relative to playback "
                        + "(render only; does not change audio). Reset to remove the offset.")
                Button("Reset") { model.chordProTimingOffsetMS = 0 }
                    .font(.swDisplay(11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.swTextSecondary)
                    .fixedSize()
                    .disabled(model.chordProTimingOffsetMS == 0)
                    .help("Reset timing offset to 0 ms")
                let sign = model.chordProTimingOffsetMS > 0 ? "+" : ""
                Text("\(sign)\(model.chordProTimingOffsetMS) ms")
                    .font(.swDisplay(11).monospacedDigit())
                    .foregroundStyle(Color.swTextSecondary)
                    .fixedSize()
                    .frame(width: 52, alignment: .leading)
            }
        }
    }

    private var beatBallInput: BeatBallInput? {
        guard bouncingBallEnabled else { return nil }
        let bpm = model.estimatedBPM
        let beatTimes = model.beatTimes
        // Need either explicit beats or a usable BPM to synthesize them.
        guard !beatTimes.isEmpty || (bpm.map { $0 > 0 } ?? false) else { return nil }
        let now = currentPlaybackTime

        // Preferred path: the SongTimeline gives every rendered row an authoritative window
        // (audit RC-2) — the ball simply follows the row containing the playhead, so a
        // multi-row intro is tracked row by row instead of compressing the whole gap onto
        // the single row nearest the next lyric.
        if let timeline = model.songTimelineForPreview(), !timeline.rows.isEmpty {
            return timelineBeatBall(
                timeline: timeline, now: now, bpm: bpm, beatTimes: beatTimes)
        }
        return legacyBeatBall(now: now, bpm: bpm, beatTimes: beatTimes)
    }

    /// Row-window ball from the `SongTimeline` (generated charts — the proven-aligned path).
    private func timelineBeatBall(
        timeline: SongTimeline, now: TimeInterval, bpm: Double?, beatTimes: [TimeInterval]
    ) -> BeatBallInput? {
        if let row = timeline.row(at: now) {
            switch row.kind {
            case .lyric(let ordinal):
                // Sung line (or the short held tail after it — hold-through-gap semantics).
                let deriver = ChordProHighlightDeriver(
                    lyricSegments: model.lyricSegments,
                    chordEvents: model.chordEvents,
                    confidenceThreshold: model.chordConfidenceThreshold
                )
                let segment = deriver.segment(atOrdinal: ordinal)
                return BeatBallInput(
                    currentTime: now,
                    ordinal: ordinal,
                    windowStart: row.start,
                    windowEnd: row.end,
                    words: segment?.words ?? [],
                    bpm: bpm,
                    beatTimes: beatTimes,
                    isWaiting: false,
                    rowNumber: row.number
                )
            case .instrumental:
                guard !row.chordTimes.isEmpty else { return nil }
                return BeatBallInput(
                    currentTime: now,
                    ordinal: -1,
                    windowStart: row.start,
                    windowEnd: row.end,
                    words: [],
                    bpm: bpm,
                    beatTimes: beatTimes,
                    isWaiting: true,
                    chordTimes: row.chordTimes,
                    rowNumber: row.number
                )
            }
        }
        // Before the first row (a short intro that has no chord-only row of its own):
        // park a waiting ball at the first row when the wait is noticeable.
        guard
            let next = timeline.nextRow(after: now),
            next.start - now > 0, next.start >= Self.waitingBallMinimumGap
        else { return nil }
        return BeatBallInput(
            currentTime: now,
            ordinal: -1,
            windowStart: 0,
            windowEnd: next.start,
            words: [],
            bpm: bpm,
            beatTimes: beatTimes,
            isWaiting: true,
            rowNumber: next.number
        )
    }

    /// Pre-SongTimeline fallback: derives the ball's window/words straight from the
    /// ChordPro source (ordinal + block-walking) instead of an authoritative row.
    ///
    /// KEEP THIS. It is not dead legacy code — it is the ONLY path available for a chart
    /// `AppModel.songTimelineForPreview()` can't validate: that method rebuilds the draft
    /// from the current analysis data and requires the result to match `chordProSource`
    /// BYTE-FOR-BYTE before it will hand back a `SongTimeline`. The moment a user edits or
    /// reviews the chart, the live source and the rebuildable draft diverge and
    /// `songTimelineForPreview()` returns nil on purpose — there is no "row" data left to
    /// consult, only the ChordPro text itself. `beatBallInput` falls back to this function
    /// in exactly that case (see the `guard`/`if let timeline` above). Deleting this would
    /// silently kill the bouncing ball for every user-edited chart. Known limitation this
    /// path still has (accepted, not a bug to "fix" here): RC-2 from
    /// tasks/audit-ball-timing.md — a multi-row instrumental gap collapses onto the single
    /// chord-only row nearest the upcoming line instead of being tracked row by row, because
    /// the per-row windows only exist in `SongTimeline`, which isn't available here.
    private func legacyBeatBall(
        now: TimeInterval, bpm: Double?, beatTimes: [TimeInterval]
    ) -> BeatBallInput? {
        let deriver = ChordProHighlightDeriver(
            lyricSegments: model.lyricSegments,
            chordEvents: model.chordEvents,
            confidenceThreshold: model.chordConfidenceThreshold
        )

        // A lyric is within its sung window: bounce over its words.
        if let ordinal = deriver.lyricOrdinal(at: now, holdThroughGaps: false),
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
        else {
            // Past the last lyric: bounce across the trailing instrumental (outro) chords, the same
            // chord-tracking fallback the intro/gap uses.
            return outroBeatBall(now: now, bpm: bpm, beatTimes: beatTimes)
        }
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

    /// The waiting/chord-tracking ball for a trailing instrumental (outro) after the last lyric:
    /// bounces across the outro's chords. `ordinal` is set one past the last lyric as a sentinel
    /// that `beatBallValue` maps to the trailing chord-only line.
    private func outroBeatBall(now: TimeInterval, bpm: Double?, beatTimes: [TimeInterval])
        -> BeatBallInput?
    {
        let segments = model.lyricSegments.sorted { $0.start < $1.start }
        guard let lastEnd = segments.last?.end, now >= lastEnd else { return nil }
        let outroChordTimes =
            model.chordEvents
            .filter { event in
                event.time >= lastEnd
                    && (event.confidence.map { $0 >= model.chordConfidenceThreshold } ?? true)
            }
            .map(\.time)
            .sorted()
        guard !outroChordTimes.isEmpty else { return nil }
        let songEnd = model.timelineDuration
        let windowEnd = max(songEnd, (outroChordTimes.last ?? lastEnd) + 1, now + 0.1)
        return BeatBallInput(
            currentTime: now,
            ordinal: segments.count,  // sentinel: past the last lyric
            windowStart: lastEnd,
            windowEnd: windowEnd,
            words: [],
            bpm: bpm,
            beatTimes: beatTimes,
            isWaiting: true,
            chordTimes: outroChordTimes
        )
    }

    /// Per-line beat data for the "Beat dots" overlay, when the toggle is on. `nil` when
    /// disabled or there is no beat data.
    private var beatDotContext: BeatDotContext? {
        guard beatDotsEnabled else { return nil }
        let segments =
            model.lyricSegments
            .filter { !$0.text.isEmpty }
            .sorted {
                if $0.start == $1.start, $0.end == $1.end { return $0.text < $1.text }
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }
        let bpm = model.estimatedBPM
        let beatTimes = model.beatTimes
        guard !segments.isEmpty, !beatTimes.isEmpty || (bpm.map { $0 > 0 } ?? false) else {
            return nil
        }
        return BeatDotContext(
            segments: segments,
            beatTimes: beatTimes,
            bpm: bpm,
            songDuration: model.timelineDuration
        )
    }
}

/// The Review/Annotate tab (backlog #15): the SAME interactive App Preview/Edit editor that used
/// to be the whole `chordPro` tab (bouncing ball, beat dots, waveform, playback highlight —
/// unchanged, moved here as-is), plus a new panel below it for accepting or correcting
/// low-confidence lyric lines and chord events one at a time. The `chordPro` tab itself now shows
/// only `ChordProTrueView`, a spec-exact read-only render with none of this chrome.
struct ChordProReviewTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            // Unchanged: same GeometryReader/ScrollViewReader-driven layout as before, so it
            // keeps sizing/scrolling itself exactly as it always has.
            ChordProTabEditor(model: model, config: .chordPro)
            Divider()
            // A bounded companion region below, not an outer ScrollView around everything above —
            // wrapping ChordProTabEditor's own GeometryReader-based preview in another ScrollView
            // would starve it of a real height proposal.
            ScrollView {
                ChordProReviewAnnotationsPanel(model: model)
                    .padding(.bottom, 12)
            }
            .frame(maxHeight: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Per-line beat positions for the "Beat dots" overlay: the sorted lyric segments plus the
/// song's beats, mapped per lyric line by ordinal.
struct BeatDotContext: Equatable {
    let segments: [TimedLyricSegment]
    let beatTimes: [TimeInterval]
    let bpm: Double?
    /// Full song duration for intro/outro/instrumental line windows on the timeline.
    let songDuration: TimeInterval
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
    /// The `SongTimeline` row (1-based musical line number == preview displayLineNumber)
    /// this ball belongs to. Non-nil only on the proven-aligned timeline path; the preview
    /// then matches rows by number instead of walking blocks with adjacency heuristics.
    var rowNumber: Int? = nil
}

private struct ChordProAppPreview: View {
    let source: String
    var transpose: Int = 0
    var highlightContext: ChordProPlaybackHighlightContext?
    var beatBall: BeatBallInput?
    var beatDots: BeatDotContext?
    /// Draw faint measure barlines on the shared grid, independent of the beat-dots toggle.
    var showBarlines = false
    var rhythmicSpacing = false
    /// Per-lyric-line word timings, indexed by lyric ordinal (same order the highlight/ball use),
    /// for rhythmic spacing — available regardless of playback.
    var lyricLineWords: [[TimedLyricWord]] = []
    /// Whether to draw the per-line vocal-audio strip beneath each lyric line.
    var showWaveform = false
    /// Vocal-stem (or full-mix fallback) waveform used to slice each line's audio strip.
    var audioEnvelope: WaveformEnvelope?
    /// Whether `audioEnvelope` is the isolated vocals stem (mint) rather than the full-mix
    /// fallback. Drives lyric-line strip color so a full-mix strip isn't mislabeled as vocal.
    var audioEnvelopeIsVocals = true
    /// Guitar stem waveform — primary anchor for instrumental (chord-only) lines.
    var guitarEnvelope: WaveformEnvelope?
    /// Piano stem waveform — fallback anchor for instrumental lines when no guitar is present.
    var pianoEnvelope: WaveformEnvelope?
    /// Drums stem waveform — primary accent cue for detecting the bar downbeat (kick lands on 1).
    var drumsEnvelope: WaveformEnvelope?
    /// Bass stem waveform — secondary downbeat accent cue (bass root usually on beat 1).
    var bassEnvelope: WaveformEnvelope?
    /// Each lyric line's [start, end] time window, by ordinal, for slicing the strip.
    var lyricLineWindows: [ClosedRange<TimeInterval>] = []
    /// Song tempo, used to size a 4/4 measure so a line that starts mid-measure is indented to its
    /// beat rather than pinned flush-left.
    var bpm: Double?
    /// Detected beat times; the first is the measure-grid phase for the measure indent.
    var beatTimes: [TimeInterval] = []
    /// All detected chord-change onsets (sorted), so each chord's leading edge sits at its true
    /// impulse onset on the line timeline.
    var chordOnsetTimes: [TimeInterval] = []
    /// Display line numbers whose timeline row overlaps a sung-but-untranscribed region
    /// (audit RC-4): those rows get a "vocals — not transcribed" badge.
    var untranscribedLineNumbers: Set<Int> = []
    /// Authoritative chord onset times per display line (from `SongTimeline` rows, chart
    /// order) — lets chords render at their REAL time instead of a column-derived guess.
    var timelineChordTimesByLine: [Int: [TimeInterval]] = [:]

    /// Beats per bar: 4/4 by default, but estimated from the lyric-line phrase structure so a
    /// song whose lines are consistently spaced by e.g. 5 detected beats (tactus found at a 5:4
    /// metrical level) gets a 5-beat bar — otherwise every line lands one beat later in the bar
    /// than the previous and the rendered rows cascade rightward.
    private var beatsPerBar: Int {
        DownbeatEstimator.estimateBeatsPerBar(
            beatTimes: beatTimes,
            onsets: lyricLineWords.compactMap { $0.first?.start })
    }

    /// Seconds per beat (60/bpm), or 0 without a tempo.
    private var beatLengthSeconds: TimeInterval { (bpm.map { $0 > 0 ? 60 / $0 : 0 }) ?? 0 }

    /// Pickup gutter width: two beats to the left of the shared downbeat column.
    private var gutterSeconds: TimeInterval { beatLengthSeconds * 2 }

    /// Accent energy at each beat, sampled from drums + bass stems (a short window around the beat
    /// to catch the transient) — CACHED (see `gridDependencyKey`/`refreshGrid()` below). This scan
    /// is O(beats × envelopes × window-samples): recomputing it as a plain computed property made
    /// the WHOLE view redo it on every 30-60Hz playback tick even though it only depends on static
    /// analysis data, never on the playhead — the actual cause of the CPU-during-playback /
    /// laggy-ball-and-highlight report (playback CPU/lag investigation). Empty until the first
    /// `.onChange(initial: true)` fires, and whenever a real dependency changes.
    @State private var beatStrengths: [Double] = []

    /// The detected bar phase — CACHED alongside `beatStrengths` for the same reason.
    @State private var barPhase: Int = 0

    /// The shared measure grid — CACHED alongside `beatStrengths` for the same reason.
    @State private var measureGrid: MeasureGrid?

    /// Every input `beatStrengths`/`barPhase`/`measureGrid` actually depend on. Recomputing this
    /// key itself is cheap (array/optional equality, not a beat-by-envelope scan), so comparing it
    /// every tick to decide whether a refresh is needed is a huge net win over recomputing the
    /// grid itself every tick.
    private struct GridDependencyKey: Equatable {
        let beatTimes: [TimeInterval]
        let bpm: Double?
        let drumsEnvelope: WaveformEnvelope?
        let bassEnvelope: WaveformEnvelope?
        let lyricLineWords: [[TimedLyricWord]]
    }

    private var gridDependencyKey: GridDependencyKey {
        GridDependencyKey(
            beatTimes: beatTimes, bpm: bpm, drumsEnvelope: drumsEnvelope,
            bassEnvelope: bassEnvelope, lyricLineWords: lyricLineWords)
    }

    /// Recomputes `beatStrengths`/`barPhase`/`measureGrid` from scratch — the ORIGINAL logic these
    /// three properties used to run inline on every render, now run only when `gridDependencyKey`
    /// actually changes (see the `.onChange` in `body`).
    private func refreshGrid() {
        guard !beatTimes.isEmpty else {
            beatStrengths = []
            barPhase = 0
            measureGrid = nil
            return
        }
        let envelopes = [drumsEnvelope, bassEnvelope].compactMap { $0 }
            .filter { $0.duration > 0 && !$0.peaks.isEmpty }
        let strengths: [Double]
        if envelopes.isEmpty {
            strengths = []
        } else {
            let half = beatLengthSeconds > 0 ? beatLengthSeconds * 0.25 : 0.1
            strengths = beatTimes.map { beat in
                var strength = 0.0
                for env in envelopes {
                    let count = env.peaks.count
                    let lo = max(0, Int(((beat - half) / env.duration) * Double(count)))
                    let hi = min(
                        count, max(lo + 1, Int(((beat + half) / env.duration) * Double(count))))
                    var peak = 0.0
                    for i in lo..<hi { peak = max(peak, Double(env.peaks[i])) }
                    strength += peak
                }
                return strength
            }
        }
        beatStrengths = strengths

        guard bpm != nil else {
            barPhase = 0
            measureGrid = nil
            return
        }
        let resolvedBarPhase: Int
        if DownbeatEstimator.downbeatConfidence(beatStrengths: strengths, beatsPerBar: beatsPerBar)
            >= 0.08
        {
            resolvedBarPhase = DownbeatEstimator.barPhase(
                beatStrengths: strengths, beatsPerBar: beatsPerBar)
        } else {
            let onsets = lyricLineWords.compactMap { $0.first?.start }
            resolvedBarPhase = DownbeatEstimator.barPhase(
                beatTimes: beatTimes, onsets: onsets, beatsPerBar: beatsPerBar)
        }
        barPhase = resolvedBarPhase

        guard let bpm, bpm > 0 else {
            measureGrid = nil
            return
        }
        measureGrid = MeasureGrid(
            beatTimes: beatTimes, bpm: bpm, beatsPerBar: beatsPerBar, barPhase: resolvedBarPhase)
    }

    /// Whether the vocal entrances actually sit on the beat grid. When they do, metric downbeat
    /// anchoring makes the repeating cadence visible (pickups indent identically line to line).
    /// When they don't (loose/rubato delivery — Summertime scores ≈ -0.09), the "honest" metric
    /// indents scatter meaninglessly, so rows anchor on their first word instead.
    private var vocalsFollowBeatGrid: Bool {
        let onsets = lyricLineWords.compactMap { $0.first?.start }
        return DownbeatEstimator.beatAlignment(beatTimes: beatTimes, onsets: onsets) >= 0.3
    }

    /// The time a row's origin column represents: the bar downbeat the line resolves onto when
    /// the performance is beat-aligned (shared cadence column), or the first word itself when it
    /// isn't (uniform left margin). Nil without a grid.
    private func rowDownbeatTime(forFirstWordAt onset: TimeInterval?) -> TimeInterval? {
        guard let onset, let grid = measureGrid else { return nil }
        return vocalsFollowBeatGrid ? grid.nearestDownbeatTime(toTime: onset) : onset
    }

    /// Guitar/melody-stem peaks (and lane color) covering a lyric line's pre-vocal gap
    /// [firstWord − ~2 beats, firstWord], so the "waiting for the vocal" lead-in shows the melody
    /// actually sounding. Bounded so it never reaches back past the previous sung line.
    private func leadingMelodyFill(
        firstWordOnset: TimeInterval?, previousLineEnd: TimeInterval?
    ) -> (peaks: [Float], color: Color, seconds: TimeInterval) {
        guard let onset = firstWordOnset, let lane = instrumentalLane else {
            return ([], .swViolet, 0)
        }
        // When the pre-vocal gap is a real instrumental section (≥ 4 bars — the same threshold
        // that renders Intro/Instrumental chord-only rows), that audio is ALREADY drawn on those
        // rows; a lead-in strip here would duplicate intro material onto the verse's first line.
        let gapStart = previousLineEnd ?? 0
        let barSeconds = beatLengthSeconds * Double(beatsPerBar)
        if barSeconds > 0, (onset - gapStart) / barSeconds >= 4 {
            return ([], lane.color, 0)
        }
        let cap = onset - gutterSeconds
        let start = max(cap, previousLineEnd ?? -.greatestFiniteMagnitude)
        let seconds = max(0, onset - start)
        guard seconds > 0.05 else { return ([], lane.color, 0) }
        return (peaks(in: (start, onset), from: lane.envelope), lane.color, seconds)
    }

    /// Guitar/melody-stem peaks for the instrumental tail AFTER a line's last word, up to ~2 beats
    /// but never into the next line's first word — the symmetric end-of-line counterpart to
    /// `leadingMelodyFill`. Empty when there's no tail or no melody stem.
    private func trailingMelodyFill(
        lastWordEnd: TimeInterval?, nextLineStart: TimeInterval?
    ) -> (peaks: [Float], seconds: TimeInterval) {
        guard let end = lastWordEnd, let lane = instrumentalLane else { return ([], 0) }
        var stop = end + gutterSeconds
        if let next = nextLineStart { stop = min(stop, next) }
        let seconds = max(0, stop - end)
        guard seconds > 0.05 else { return ([], 0) }
        return (peaks(in: (end, stop), from: lane.envelope), seconds)
    }

    /// The instrumental anchor for chord-only lines: guitar first, then piano. The color matches
    /// the stem's lane color in the waveform panel (guitar = amber, piano = primary text).
    private var instrumentalLane: (envelope: WaveformEnvelope, color: Color)? {
        if let g = guitarEnvelope, g.duration > 0, !g.peaks.isEmpty {
            return (g, StemKind.guitar.laneColor)
        }
        if let p = pianoEnvelope, p.duration > 0, !p.peaks.isEmpty {
            return (p, StemKind.piano.laneColor)
        }
        return nil
    }

    /// Peaks for an arbitrary [start, end] window sliced from an envelope (for chord-only lines,
    /// which have no lyric ordinal). Empty when the strip is off or no data is available.
    private func peaks(
        in window: (start: TimeInterval, end: TimeInterval),
        from envelope: WaveformEnvelope
    ) -> [Float] {
        guard showWaveform, envelope.duration > 0, !envelope.peaks.isEmpty else { return [] }
        let count = envelope.peaks.count
        let lo = Int((window.start / envelope.duration) * Double(count))
        let hi = Int((window.end / envelope.duration) * Double(count))
        let start = max(0, min(count - 1, lo))
        let end = max(start + 1, min(count, hi))
        return Array(envelope.peaks[start..<end])
    }

    /// The audio strip (peaks, window duration, color) to draw beneath a rendered line:
    /// vocals (mint) for lyric lines; guitar→piano (amber/primary) for instrumental chord-only
    /// lines; empty for everything else.
    private func lineStrip(
        for item: ChordProPreviewIndexedBlock,
        in document: ChordProPreviewDocument
    ) -> (peaks: [Float], duration: TimeInterval, color: Color) {
        // Lyric lines use the vocals lane color (matches the waveform panel); a full-mix fallback is
        // neutral so it isn't mislabeled as the isolated vocal.
        let lyricColor: Color = audioEnvelopeIsVocals ? StemKind.vocals.laneColor : .swTextSecondary
        if let ordinal = item.lyricOrdinal {
            return (
                vocalPeaks(forLyricOrdinal: ordinal),
                lineDuration(forLyricOrdinal: ordinal), lyricColor
            )
        }
        guard case .lyric(let line) = item.block, !line.chords.isEmpty,
            !line.lyric.contains(where: { !$0.isWhitespace }),
            let lane = instrumentalLane,
            let window = chordOnlyLineWindow(for: item, in: document)
        else { return ([], 0, .swTextSecondary) }
        return (
            peaks(in: window, from: lane.envelope),
            max(0, window.end - window.start), lane.color
        )
    }

    private func wordTimings(forLyricOrdinal ordinal: Int?) -> [TimedLyricWord] {
        guard let ordinal, lyricLineWords.indices.contains(ordinal) else { return [] }
        return lyricLineWords[ordinal]
    }

    /// The duration (seconds) of a lyric line's time window, so its audio strip can be drawn on the
    /// SAME pixels-per-second time scale the words use (words and waveform share one time axis).
    private func lineDuration(forLyricOrdinal ordinal: Int?) -> TimeInterval {
        guard let ordinal, lyricLineWindows.indices.contains(ordinal) else { return 0 }
        let window = lyricLineWindows[ordinal]
        return max(0, window.upperBound - window.lowerBound)
    }

    /// Normalized audio peaks covering a lyric line's time window (for its strip), or [] when the
    /// strip is off or no envelope/window is available.
    private func vocalPeaks(forLyricOrdinal ordinal: Int?) -> [Float] {
        guard showWaveform, let ordinal,
            lyricLineWindows.indices.contains(ordinal),
            let envelope = audioEnvelope, envelope.duration > 0, !envelope.peaks.isEmpty
        else { return [] }
        let window = lyricLineWindows[ordinal]
        let count = envelope.peaks.count
        let lo = Int((window.lowerBound / envelope.duration) * Double(count))
        let hi = Int((window.upperBound / envelope.duration) * Double(count))
        let start = max(0, min(count - 1, lo))
        let end = max(start + 1, min(count, hi))
        return Array(envelope.peaks[start..<end])
    }

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
                                        let strip = lineStrip(for: item, in: document)
                                        let lineWords = wordTimings(
                                            forLyricOrdinal: item.lyricOrdinal)
                                        let firstWordOnset = lineWords.first?.start
                                        // Resolving bar downbeat for the shared metric grid (nil
                                        // when there's no beat grid → first-word-flush fallback).
                                        let rowDownbeat =
                                            rhythmicSpacing
                                            ? rowDownbeatTime(forFirstWordAt: firstWordOnset) : nil
                                        // Melody peaks for the pre-vocal gap (bounded so it can't
                                        // overrun the previous sung line).
                                        let prevLineEnd: TimeInterval? =
                                            (item.lyricOrdinal).flatMap { ord in
                                                ord > 0
                                                    && lyricLineWindows.indices.contains(ord - 1)
                                                    ? lyricLineWindows[ord - 1].upperBound : nil
                                            }
                                        // Next sung line's start, so the trailing tail can't overrun it.
                                        let nextLineStart: TimeInterval? =
                                            (item.lyricOrdinal).flatMap { ord in
                                                lyricLineWindows.indices.contains(ord + 1)
                                                    ? lyricLineWindows[ord + 1].lowerBound : nil
                                            }
                                        let leadingMelody = leadingMelodyFill(
                                            firstWordOnset: firstWordOnset,
                                            previousLineEnd: prevLineEnd)
                                        let trailingMelody = trailingMelodyFill(
                                            lastWordEnd: lineWords.last?.end,
                                            nextLineStart: nextLineStart)
                                        ChordProPreviewBlockView(
                                            block: item.block,
                                            highlight: highlightContext?.highlight(
                                                forLyricOrdinal: item.lyricOrdinal
                                            ),
                                            beatBall: beatBallValue(for: item, in: document),
                                            beatDots: beatDotValue(for: item, in: document),
                                            rhythmicSpacing: rhythmicSpacing,
                                            rhythmicWordTimings: lineWords,
                                            vocalPeaks: strip.peaks,
                                            lineDuration: strip.duration,
                                            stripColor: strip.color,
                                            rowDownbeatSeconds: rowDownbeat,
                                            gutterSeconds: gutterSeconds,
                                            beatLengthSeconds: beatLengthSeconds,
                                            beatsPerBar: beatsPerBar,
                                            // In first-word-anchor mode the row origin is not a
                                            // downbeat, so bar lines would mark false bars.
                                            showBarlines: showBarlines && vocalsFollowBeatGrid,
                                            chordOnsetTimes: chordOnsetTimes,
                                            leadingMelodyPeaks: leadingMelody.peaks,
                                            melodyColor: leadingMelody.color,
                                            leadingMelodySeconds: leadingMelody.seconds,
                                            trailingMelodyPeaks: trailingMelody.peaks,
                                            trailingMelodySeconds: trailingMelody.seconds,
                                            lineNumber: item.displayLineNumber,
                                            trailingRestSeconds: trailingRestSeconds(
                                                lastWordEnd: lineWords.last?.end,
                                                nextLineStart: nextLineStart),
                                            hasUntranscribedVocals: item.displayLineNumber
                                                .map(untranscribedLineNumbers.contains) ?? false,
                                            rowChordTimes: item.displayLineNumber
                                                .flatMap { timelineChordTimesByLine[$0] } ?? []
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
                            // line the ball is on (or parked at) into view.
                            .onChange(of: waitingTarget) { _, target in
                                let offset: Int?
                                switch target {
                                case .displayLine(let number):
                                    offset = blockOffset(forDisplayLine: number, in: document)
                                case .lyricOrdinal(let ordinal):
                                    offset = blockOffset(forLyricOrdinal: ordinal, in: document)
                                case nil:
                                    offset = nil
                                }
                                guard let offset else { return }
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
        // Recompute the measure grid/beat-strength cache only when its real inputs change — NOT
        // on every playback tick (see `refreshGrid()`'s doc comment: this is the fix for the
        // CPU-during-playback / laggy-ball-and-highlight report).
        .onChange(of: gridDependencyKey, initial: true) { _, _ in refreshGrid() }
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
        var displayLine = 0
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
            // Number every musical line — lyric lines AND chord-only instrumental lines — in a
            // single running sequence, so instrumental sections are referenceable too. Section
            // headers, titles, metadata, and directives are not numbered.
            let displayNumber: Int?
            if case .lyric(let line) = block,
                line.lyric.contains(where: { !$0.isWhitespace }) || !line.chords.isEmpty
            {
                displayLine += 1
                displayNumber = displayLine
            } else {
                displayNumber = nil
            }
            return ChordProPreviewIndexedBlock(
                offset: offset,
                block: block,
                lyricOrdinal: ordinal,
                displayLineNumber: displayNumber
            )
        }
    }

    private func blockOffset(
        forLyricOrdinal ordinal: Int,
        in document: ChordProPreviewDocument
    ) -> Int? {
        indexedBlocks(for: document).first { $0.lyricOrdinal == ordinal }?.offset
    }

    /// The line the ball is parked at/tracking while waiting, used to drive auto-scroll.
    /// Timeline path targets the row's display line number; legacy path a lyric ordinal.
    private enum WaitingScrollTarget: Equatable {
        case displayLine(Int)
        case lyricOrdinal(Int)
    }
    private var waitingTarget: WaitingScrollTarget? {
        guard let beatBall, beatBall.isWaiting else { return nil }
        if let rowNumber = beatBall.rowNumber { return .displayLine(rowNumber) }
        return .lyricOrdinal(beatBall.ordinal)
    }

    /// The offset of the block rendered with the given musical line number.
    private func blockOffset(forDisplayLine number: Int, in document: ChordProPreviewDocument)
        -> Int?
    {
        indexedBlocks(for: document).first { $0.displayLineNumber == number }?.offset
    }

    /// A short TRUE rest after this line's last sung word (audit RC-4 render half): at least
    /// 2 beats of silence before the next line, but under the 4-bar threshold (longer gaps
    /// get their own instrumental rows). Word ends are vocal-energy-normalized upstream, so
    /// "after the last word" is where the voice actually stops. 0 = no marker.
    private func trailingRestSeconds(
        lastWordEnd: TimeInterval?, nextLineStart: TimeInterval?
    ) -> TimeInterval {
        guard let lastWordEnd, let nextLineStart, beatLengthSeconds > 0 else { return 0 }
        let gap = nextLineStart - lastWordEnd
        let barSeconds = beatLengthSeconds * Double(beatsPerBar)
        guard gap >= beatLengthSeconds * 2, gap < barSeconds * 4 else { return 0 }
        return gap
    }

    /// The offset of the trailing chord-only line (outro/instrumental) after the LAST lyric line,
    /// if one exists — the line the outro ball bounces across.
    ///
    /// Block-walking helper for the `legacyBeatBall`/`outroBeatBall` fallback only (edited
    /// charts with no `SongTimeline`; see the comment on `legacyBeatBall`). The timeline path
    /// never calls this — it identifies rows by `rowNumber` instead of walking blocks.
    private func trailingChordOnlyLineOffset(in document: ChordProPreviewDocument) -> Int? {
        let items = indexedBlocks(for: document)
        guard
            let lastLyricIndex = items.lastIndex(where: { item in
                if case .lyric(let line) = item.block {
                    return line.lyric.contains(where: { !$0.isWhitespace })
                }
                return false
            })
        else { return nil }
        for index in (lastLyricIndex + 1)..<items.count {
            if case .lyric(let line) = items[index].block, !line.chords.isEmpty,
                !line.lyric.contains(where: { !$0.isWhitespace })
            {
                return items[index].offset
            }
        }
        return nil
    }

    /// The offset of the chord-only line (intro/instrumental) immediately preceding the
    /// given lyric line, if one exists — the line the waiting ball should bounce across.
    ///
    /// Block-walking helper for the `legacyBeatBall` fallback only (edited charts with no
    /// `SongTimeline`; see the comment on `legacyBeatBall`). This is the RC-2 whole-gap
    /// heuristic (tasks/audit-ball-timing.md): when a long intro/gap splits into several
    /// chord-only rows, this walks up to the SINGLE row nearest the upcoming lyric and
    /// `beatBallValue` gives it the entire gap window — a multi-row intro isn't tracked row
    /// by row here. That bug is fixed for generated charts (the timeline path uses each
    /// row's own authoritative window), but there is no equivalent per-row data for an
    /// edited chart, so this coarser behavior is the accepted fallback, not a regression.
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

        // Timeline path (audit RC-2): the ball's row is identified by musical line NUMBER —
        // proven to match this preview's numbering — so no block-walking heuristics.
        if let rowNumber = beatBall.rowNumber {
            guard item.displayLineNumber == rowNumber else { return nil }
            if beatBall.isWaiting {
                if !beatBall.chordTimes.isEmpty {
                    // Instrumental row: track its own chords across its own window.
                    return LineBeatBall(
                        currentTime: beatBall.currentTime,
                        segmentStart: beatBall.windowStart,
                        segmentEnd: beatBall.windowEnd,
                        bpm: beatBall.bpm,
                        beatTimes: beatBall.beatTimes,
                        chordTimes: beatBall.chordTimes
                    )
                }
                // No chords to track (short un-rowed intro): pulse at the upcoming row.
                return LineBeatBall(
                    currentTime: beatBall.currentTime,
                    segmentStart: beatBall.windowStart,
                    segmentEnd: beatBall.windowEnd,
                    bpm: beatBall.bpm,
                    beatTimes: beatBall.beatTimes,
                    isWaiting: true
                )
            }
            return LineBeatBall(
                currentTime: beatBall.currentTime,
                segmentStart: beatBall.windowStart,
                segmentEnd: beatBall.windowEnd,
                bpm: beatBall.bpm,
                beatTimes: beatBall.beatTimes,
                words: beatBall.words
            )
        }

        if beatBall.isWaiting {
            // Outro: the ball's ordinal is past the last lyric → bounce across the trailing
            // instrumental's chords (anchored to the guitar/instrumental onsets).
            let lyricCount = indexedBlocks(for: document).filter { $0.lyricOrdinal != nil }.count
            if beatBall.ordinal >= lyricCount, !beatBall.chordTimes.isEmpty,
                let outroOffset = trailingChordOnlyLineOffset(in: document),
                item.offset == outroOffset
            {
                return LineBeatBall(
                    currentTime: beatBall.currentTime,
                    segmentStart: beatBall.windowStart,
                    segmentEnd: beatBall.windowEnd,
                    bpm: beatBall.bpm,
                    beatTimes: beatBall.beatTimes,
                    chordTimes: beatBall.chordTimes
                )
            }
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

    /// Per-line beat dots. Lyric lines use their own segment window and words. Chord-only lines
    /// (intro/outro/instrumental) have no lyric segment, so they borrow a time window from the
    /// surrounding lyric lines (or the song bounds at the ends) and show dots with no words —
    /// `ChordProPreviewLineView` spreads those across the line by time.
    private func beatDotValue(
        for item: ChordProPreviewIndexedBlock,
        in document: ChordProPreviewDocument
    ) -> LineBeatBall? {
        guard let beatDots else { return nil }
        if let ordinal = item.lyricOrdinal, beatDots.segments.indices.contains(ordinal) {
            let segment = beatDots.segments[ordinal]
            return LineBeatBall(
                currentTime: 0,
                segmentStart: segment.start,
                segmentEnd: segment.end,
                bpm: beatDots.bpm,
                beatTimes: beatDots.beatTimes,
                words: segment.words
            )
        }
        // Chord-only line: dots over the instrumental section between lyrics.
        guard case .lyric(let line) = item.block, !line.chords.isEmpty,
            !line.lyric.contains(where: { !$0.isWhitespace }),
            let window = chordOnlyLineWindow(for: item, in: document)
        else { return nil }
        return LineBeatBall(
            currentTime: 0,
            segmentStart: window.start,
            segmentEnd: window.end,
            bpm: beatDots.bpm,
            beatTimes: beatDots.beatTimes,
            words: []
        )
    }

    /// Time window a chord-only line occupies: from the previous lyric line's end to the next
    /// lyric line's start. Intro lines start at 0; outro lines end at the song duration (derived
    /// from an available stem/mix envelope). Derived from the lyric line windows so the
    /// instrumental strip anchors to its guitar/piano stem regardless of the "Beat dots" toggle.
    /// `nil` when no usable bound exists.
    private func chordOnlyLineWindow(
        for item: ChordProPreviewIndexedBlock,
        in document: ChordProPreviewDocument
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let items = indexedBlocks(for: document)
        guard let index = items.firstIndex(where: { $0.offset == item.offset }) else { return nil }
        func window(at i: Int) -> ClosedRange<TimeInterval>? {
            guard let ordinal = items[i].lyricOrdinal,
                lyricLineWindows.indices.contains(ordinal)
            else { return nil }
            return lyricLineWindows[ordinal]
        }
        var start: TimeInterval?
        var before = index - 1
        while before >= 0 {
            if let seg = window(at: before) {
                start = seg.upperBound
                break
            }
            before -= 1
        }
        var end: TimeInterval?
        var after = index + 1
        while after < items.count {
            if let seg = window(at: after) {
                end = seg.lowerBound
                break
            }
            after += 1
        }
        let resolvedStart = start ?? 0
        // Outro fallback: the longest available envelope duration is the song length.
        let songDuration =
            [audioEnvelope, guitarEnvelope, pianoEnvelope]
            .compactMap { $0?.duration }
            .max() ?? 0
        let resolvedEnd = end ?? (songDuration > 0 ? songDuration : nil)
        guard let resolvedEnd, resolvedEnd > resolvedStart else { return nil }
        // A long instrumental span is emitted as several consecutive chord-only rows (see
        // ChordProDraftBuilder.instrumentalLines). Give each row an equal slice of the gap so their
        // widths and waveforms match that split, instead of every row spanning the whole gap.
        func isChordOnlyRow(_ i: Int) -> Bool {
            guard items.indices.contains(i), items[i].lyricOrdinal == nil,
                case .lyric(let line) = items[i].block
            else { return false }
            return !line.chords.isEmpty && !line.lyric.contains(where: { !$0.isWhitespace })
        }
        var runStart = index
        while isChordOnlyRow(runStart - 1) { runStart -= 1 }
        var runEnd = index
        while isChordOnlyRow(runEnd + 1) { runEnd += 1 }
        let rowCount = max(1, runEnd - runStart + 1)
        let position = index - runStart
        let span = resolvedEnd - resolvedStart
        let sliceStart = resolvedStart + span * Double(position) / Double(rowCount)
        let sliceEnd = resolvedStart + span * Double(position + 1) / Double(rowCount)
        return (sliceStart, sliceEnd)
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
    /// 1-based running number across all musical lines (lyric + chord-only instrumental), or nil
    /// for non-musical blocks (titles, section headers, metadata, directives).
    var displayLineNumber: Int?
}

private struct ChordProPreviewBlockView: View {
    let block: ChordProPreviewBlock
    var highlight: ChordProLinePlaybackHighlight?
    var beatBall: LineBeatBall?
    var beatDots: LineBeatBall?
    var rhythmicSpacing = false
    var rhythmicWordTimings: [TimedLyricWord] = []
    var vocalPeaks: [Float] = []
    var lineDuration: TimeInterval = 0
    /// Color of this line's audio strip (matches the stem's lane color in the waveform panel).
    var stripColor: Color = .swAmber
    /// The bar downbeat time this line resolves onto (shared metric grid origin); nil = no grid.
    var rowDownbeatSeconds: TimeInterval?
    /// Pickup gutter (seconds) to the left of the shared downbeat column.
    var gutterSeconds: TimeInterval = 0
    /// Seconds per beat (60/bpm), for barlines.
    var beatLengthSeconds: TimeInterval = 0
    /// Beats per bar (4/4).
    var beatsPerBar: Int = 4
    /// Draw faint measure barlines on the shared grid (own toggle, independent of beat dots).
    var showBarlines = false
    /// Detected chord onset times (sorted) so each chord sits at its true impulse onset.
    var chordOnsetTimes: [TimeInterval] = []
    /// Guitar/melody peaks for the pre-vocal instrumental gap, drawn before the vocal enters.
    var leadingMelodyPeaks: [Float] = []
    /// Color for the melody fill (guitar/piano lane color).
    var melodyColor: Color = .swViolet
    /// Seconds of real instrumental gap the melody fill spans (≤ the indent; bounded by the
    /// previous line's end so it doesn't overrun into the line above).
    var leadingMelodySeconds: TimeInterval = 0
    /// Guitar/melody peaks for the post-vocal instrumental tail, drawn after the last word.
    var trailingMelodyPeaks: [Float] = []
    /// Seconds of real instrumental gap the trailing melody spans (bounded by the next line's start).
    var trailingMelodySeconds: TimeInterval = 0
    /// 1-based number shown in a left gutter for lyric lines, so they can be referenced ("line 7").
    var lineNumber: Int?
    /// Seconds of true silence after this line's last word (< 4 bars) — rendered as a rest
    /// marker in rhythmic mode. 0 = none.
    var trailingRestSeconds: TimeInterval = 0
    /// True when this row's music contains vocals the transcription missed (audit RC-4).
    var hasUntranscribedVocals = false
    /// Authoritative chord onset times for this row (chart order; empty when unavailable).
    var rowChordTimes: [TimeInterval] = []

    var body: some View {
        // Bottom-aligned so the number sits on the words/waveform row of the line, not up on
        // the beat-dot / ball reserve at the top of the block.
        HStack(alignment: .bottom, spacing: 8) {
            Text(lineNumber.map(String.init) ?? "")
                .font(.swMono(10))
                .foregroundStyle(Color.swTextSecondary)
                .frame(width: 22, alignment: .trailing)
                .padding(.bottom, 3)
            VStack(alignment: .leading, spacing: 2) {
                blockContent
                if hasUntranscribedVocals {
                    Label(
                        "vocals — not transcribed",
                        systemImage: "waveform.badge.exclamationmark"
                    )
                    .font(.swDisplay(9))
                    .foregroundStyle(Color.swAmber)
                    .help(
                        "The audio here contains singing the transcription missed — "
                            + "re-run Analyze (Accuracy) or add reference lyrics.")
                }
            }
        }
    }

    @ViewBuilder private var blockContent: some View {
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
            ChordProPreviewLineView(
                line: line, highlight: highlight, beatBall: beatBall, beatDots: beatDots,
                rhythmicSpacing: rhythmicSpacing, rhythmicWordTimings: rhythmicWordTimings,
                vocalPeaks: vocalPeaks, lineDuration: lineDuration, stripColor: stripColor,
                rowDownbeatSeconds: rowDownbeatSeconds, gutterSeconds: gutterSeconds,
                beatLengthSeconds: beatLengthSeconds, beatsPerBar: beatsPerBar,
                showBarlines: showBarlines,
                chordOnsetTimes: chordOnsetTimes,
                leadingMelodyPeaks: leadingMelodyPeaks, melodyColor: melodyColor,
                leadingMelodySeconds: leadingMelodySeconds,
                trailingMelodyPeaks: trailingMelodyPeaks,
                trailingMelodySeconds: trailingMelodySeconds,
                trailingRestSeconds: trailingRestSeconds,
                rowChordTimes: rowChordTimes)
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

    /// Pixels per second of song time used to space words in rhythmic mode. Sized so one beat at
    /// typical tempos exceeds a monospace glyph, so words rarely have to be nudged off their true
    /// time position to avoid overlapping — keeping the layout on a consistent beat grid.
    private static let pixelsPerSecond: CGFloat = 100

    /// Thin top row reserved above rhythmic-mode content for the beat dots, so they sit
    /// above the words instead of overlapping them.
    private static let rhythmicDotTopReserve: CGFloat = 8

    let line: ChordProPreviewLine
    var highlight: ChordProLinePlaybackHighlight?
    var beatBall: LineBeatBall?
    var beatDots: LineBeatBall?
    /// When true (and real word timings are available), words are spaced by their onset time
    /// instead of one monospace space apart, so the layout reflects the sung rhythm.
    var rhythmicSpacing = false
    /// This line's per-word timings (from its lyric segment), available regardless of playback.
    var rhythmicWordTimings: [TimedLyricWord] = []
    /// Normalized vocal-audio peaks for this line's time window; when non-empty, drawn as a strip
    /// beneath the line so word↔voice alignment is visible.
    var vocalPeaks: [Float] = []
    /// Duration (seconds) of this line's time window, so the strip can be drawn on the SAME
    /// pixels-per-second scale as the rhythmic words (words and waveform share one time axis).
    var lineDuration: TimeInterval = 0
    /// Color of the audio strip — matches the source stem's lane color in the waveform panel.
    var stripColor: Color = .swAmber
    /// The song time of the bar downbeat this line resolves onto. All rows pin this downbeat to a
    /// fixed column (`gutterSeconds` from the left), so on the shared constant-pixels-per-second
    /// scale every bar is the same width and beats line up vertically across rows — the song's
    /// repeating cadence. `nil` (no beat grid) falls back to first-word-flush-left.
    var rowDownbeatSeconds: TimeInterval?
    /// Pickup gutter to the LEFT of the shared downbeat column, in seconds (×pixelsPerSecond → px),
    /// so anacrusis words that begin before the downbeat render before it instead of clipping.
    var gutterSeconds: TimeInterval = 0
    /// Seconds per beat (60/bpm), used to draw faint barlines at the bar downbeats.
    var beatLengthSeconds: TimeInterval = 0
    /// Beats per bar (4/4).
    var beatsPerBar: Int = 4
    /// Draw faint measure barlines on the shared grid — own toggle, independent of the beat dots.
    var showBarlines = false
    /// All detected chord-change onset times (sorted), used to place each chord's leading edge at
    /// its true impulse onset rather than the beat or the word it's typeset over.
    var chordOnsetTimes: [TimeInterval] = []
    /// Guitar/melody-stem peaks covering the real instrumental gap before this line's first word,
    /// drawn in the leading space so the "waiting for the vocal" gap shows the instrument sounding.
    var leadingMelodyPeaks: [Float] = []
    /// Color of the melody fill (the guitar/piano stem lane color).
    var melodyColor: Color = .swViolet
    /// Duration (seconds) the melody fill spans, ending at the first word — ≤ the indent, bounded so
    /// it never reaches back into the previous line's time.
    var leadingMelodySeconds: TimeInterval = 0
    /// Guitar/melody-stem peaks covering the real instrumental gap AFTER this line's last word,
    /// drawn to the right of the last word so the "end of line" instrumental tail shows the
    /// instrument still sounding. Empty when there's no trailing gap or no melody stem.
    var trailingMelodyPeaks: [Float] = []
    /// Duration (seconds) the trailing melody fill spans, starting at the last word's end — bounded
    /// so it never reaches into the NEXT line's first word.
    var trailingMelodySeconds: TimeInterval = 0
    /// Seconds of TRUE vocal silence after this line's last word (≥ 2 beats, < 4 bars) —
    /// drawn as a rest marker so short real breaks are visible (audit RC-4). 0 = none.
    var trailingRestSeconds: TimeInterval = 0
    /// Authoritative chord onset times for this row (chart order, from `SongTimeline`).
    /// When it pairs 1:1 with `line.chords`, chords render at these REAL times.
    var rowChordTimes: [TimeInterval] = []

    private var rhythmicWords: [TimedLyricWord] {
        rhythmicSpacing ? rhythmicWordTimings : []
    }

    /// Origin time of the shared metric grid for this row: the resolving bar downbeat when a beat
    /// grid is present, else the first word (flush-left fallback).
    private var gridOriginTime: TimeInterval {
        rowDownbeatSeconds ?? (rhythmicWords.first?.start ?? 0)
    }

    /// Left px of the shared downbeat column (the pickup gutter width). Zero without a grid.
    private var gutterPx: CGFloat {
        rowDownbeatSeconds == nil ? 0 : max(0, CGFloat(gutterSeconds) * Self.pixelsPerSecond)
    }

    /// x of a song time on the shared, constant-scale metric grid: the downbeat sits at `gutterPx`
    /// on EVERY row, and each beat is `beatLengthSeconds × pixelsPerSecond` further right — so beats
    /// align vertically across rows and the repeating cadence reads the same on every line.
    private func metricX(forTime time: TimeInterval) -> CGFloat {
        max(0, gutterPx + CGFloat(time - gridOriginTime) * Self.pixelsPerSecond)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if rhythmicWords.isEmpty {
                monospaceContent
            } else {
                rhythmicContent
            }
            if !vocalPeaks.isEmpty {
                waveformStrip
            }
        }
    }

    /// Width of this line's rendered content. Measured from the ACTUAL lyric string (not
    /// charCount × "M"-advance), so glyph substitution and any sub-pixel advance differences are
    /// captured — otherwise the rendered text overruns the frame by a few px and the strip below
    /// (which shares this width) ends up visibly shorter than the line. Chord-only lines fall back
    /// to the chord extent. Both the content frame and the strip use this single value so they
    /// always end at exactly the same x.
    private var monospaceWidth: CGFloat {
        let lyricSample = line.lyric.contains(where: { !$0.isWhitespace }) ? line.lyric : " "
        let lyricWidth = ceil(
            NSString(string: lyricSample).size(withAttributes: [.font: Self.lyricFont]).width)
        let chordExtent =
            CGFloat(line.chords.map { $0.column + $0.name.count }.max() ?? 0) * Self.characterWidth
        return max(Self.characterWidth, lyricWidth, chordExtent)
    }

    /// An instrumental (chord-only) line: chords present, no sung lyric text.
    private var isInstrumentalLine: Bool {
        !line.chords.isEmpty && !line.lyric.contains(where: { !$0.isWhitespace })
    }

    /// The chord row's text extent, in characters (rightmost chord column + its name length).
    private var chordColumnExtent: CGFloat {
        CGFloat(line.chords.map { $0.column + $0.name.count }.max() ?? 0)
    }

    /// Width for an instrumental line's content + strip: proportional to its time window (same
    /// `pixelsPerSecond` scale lyric lines use), so a long interlude reads visibly wider than a
    /// short verse line instead of collapsing to its chord-text width. Never narrower than the
    /// chords themselves.
    private var instrumentalTimeWidth: CGFloat {
        max(chordColumnExtent * Self.characterWidth, CGFloat(lineDuration) * Self.pixelsPerSecond)
    }

    /// X of a chord on an instrumental line, spread proportionally across `instrumentalTimeWidth`
    /// (its column is already time-proportional from the draft builder); monospace column x
    /// otherwise.
    private func monospaceChordX(_ chord: ChordProPreviewChord) -> CGFloat {
        guard isInstrumentalLine, lineDuration > 0, chordColumnExtent > 0 else {
            return CGFloat(chord.column) * Self.characterWidth
        }
        return instrumentalTimeWidth * CGFloat(chord.column) / chordColumnExtent
    }

    /// The line's window start (its first word's onset), the origin for the strip's time mapping.
    private var lineStartTime: TimeInterval { rhythmicWords.first?.start ?? 0 }

    /// Maps a song time to the x where the WORDS actually place it — interpolating between the
    /// (clamp-adjusted) word anchor positions, extrapolating beyond the ends at pixelsPerSecond.
    /// This is the key to alignment: the strip must follow the words' real layout, not an
    /// independent time scale, because words are nudged apart to avoid overlapping.
    private func rhythmicX(forTime time: TimeInterval) -> CGFloat {
        let words = rhythmicWords
        let xs = rhythmicWordXs
        guard !words.isEmpty, xs.count == words.count else { return 0 }
        if time <= words[0].start {
            return max(0, xs[0] - CGFloat(words[0].start - time) * Self.pixelsPerSecond)
        }
        for i in 1..<words.count where time <= words[i].start {
            let t0 = words[i - 1].start
            let t1 = words[i].start
            let frac = t1 > t0 ? CGFloat((time - t0) / (t1 - t0)) : 0
            return xs[i - 1] + frac * (xs[i] - xs[i - 1])
        }
        let last = words.count - 1
        return xs[last] + CGFloat(time - words[last].start) * Self.pixelsPerSecond
    }

    /// Width the audio strip should span: in rhythmic mode it covers the line's full time window on
    /// the words' own x-axis (so it's never shorter than the words); monospace uses the text width.
    private var stripWidth: CGFloat {
        if isInstrumentalLine, lineDuration > 0 { return instrumentalTimeWidth }
        guard !rhythmicWords.isEmpty, lineDuration > 0 else { return monospaceWidth }
        let endX = rhythmicX(forTime: lineStartTime + lineDuration)
        let wordsWidth =
            (rhythmicWordXs.last ?? 0)
            + CGFloat(max(rhythmicWords.last?.text.count ?? 1, 1)) * Self.characterWidth
            + Self.characterWidth
        let trailingEndX =
            trailingMelodySeconds > 0
            ? rhythmicX(forTime: (rhythmicWords.last?.end ?? lineStartTime) + trailingMelodySeconds)
            : 0
        return max(1, max(max(endX, wordsWidth), trailingEndX))
    }

    /// A thin vocal-stem audio strip for this line, drawn through the words' actual x-axis so energy
    /// at time t sits under the word at time t.
    private var waveformStrip: some View {
        Canvas { context, size in
            let count = vocalPeaks.count
            guard count > 0 else { return }
            // Normalize to the line's own peak so quiet lines still show their energy shape (it's
            // the WHERE of the energy, not its absolute level, that reveals word alignment).
            let maxPeak = max(vocalPeaks.max() ?? 1, 0.0001)
            if !rhythmicWords.isEmpty, lineDuration > 0 {
                let start = lineStartTime
                // Melody (guitar) fill in the pre-vocal gap: the time [firstWord − seconds, firstWord]
                // maps through rhythmicX to the left of the first word, showing the instrument
                // sounding before the vocal enters.
                if leadingMelodySeconds > 0.02, !leadingMelodyPeaks.isEmpty {
                    let mCount = leadingMelodyPeaks.count
                    let mMax = max(leadingMelodyPeaks.max() ?? 1, 0.0001)
                    let mStart = start - leadingMelodySeconds
                    for (index, peak) in leadingMelodyPeaks.enumerated() {
                        let t0 = mStart + leadingMelodySeconds * Double(index) / Double(mCount)
                        let t1 = mStart + leadingMelodySeconds * Double(index + 1) / Double(mCount)
                        let x0 = rhythmicX(forTime: t0)
                        let x1 = rhythmicX(forTime: t1)
                        let height = max(CGFloat(peak / mMax) * size.height, 1)
                        let rect = CGRect(
                            x: x0, y: size.height - height, width: max(x1 - x0, 1), height: height)
                        context.fill(Path(rect), with: .color(melodyColor.opacity(0.7)))
                    }
                }
                for (index, peak) in vocalPeaks.enumerated() {
                    let t0 = start + lineDuration * Double(index) / Double(count)
                    let t1 = start + lineDuration * Double(index + 1) / Double(count)
                    let x0 = rhythmicX(forTime: t0)
                    let x1 = rhythmicX(forTime: t1)
                    let height = max(CGFloat(peak / maxPeak) * size.height, 1)
                    let rect = CGRect(
                        x: x0, y: size.height - height, width: max(x1 - x0, 1), height: height)
                    context.fill(Path(rect), with: .color(stripColor.opacity(0.7)))
                }
                // Melody (guitar) fill in the post-vocal tail: [lastWord.end, +trailingSeconds]
                // maps to x right of the last word, showing the instrument still sounding.
                if trailingMelodySeconds > 0.02, !trailingMelodyPeaks.isEmpty,
                    let lastEnd = rhythmicWords.last?.end
                {
                    let tCount = trailingMelodyPeaks.count
                    let tMax = max(trailingMelodyPeaks.max() ?? 1, 0.0001)
                    for (index, peak) in trailingMelodyPeaks.enumerated() {
                        let t0 = lastEnd + trailingMelodySeconds * Double(index) / Double(tCount)
                        let t1 =
                            lastEnd + trailingMelodySeconds * Double(index + 1) / Double(tCount)
                        let x0 = rhythmicX(forTime: t0)
                        let x1 = rhythmicX(forTime: t1)
                        let height = max(CGFloat(peak / tMax) * size.height, 1)
                        let rect = CGRect(
                            x: x0, y: size.height - height, width: max(x1 - x0, 1), height: height)
                        context.fill(Path(rect), with: .color(melodyColor.opacity(0.7)))
                    }
                }
            } else {
                let step = size.width / CGFloat(count)
                for (index, peak) in vocalPeaks.enumerated() {
                    let x = CGFloat(index) * step
                    let height = max(CGFloat(peak / maxPeak) * size.height, 1)
                    let rect = CGRect(
                        x: x, y: size.height - height, width: max(step, 1), height: height)
                    context.fill(Path(rect), with: .color(stripColor.opacity(0.7)))
                }
            }
        }
        .frame(width: max(1, stripWidth), height: 18)
    }

    /// Words positioned by their onset time (clamped so they never overlap), with each chord
    /// anchored over the word it lands on (collisions nudged apart). The bouncing ball is drawn
    /// over the rhythmic word positions when active.
    private var rhythmicContent: some View {
        let words = rhythmicWords
        let xs = rhythmicWordXs
        let dots = rhythmicBeatDotPositions
        let chordXs = rhythmicChordXs
        let ball = rhythmicBallPosition
        // Reserve space above the content: the full ball reserve when the ball is shown, else a
        // thin row for the beat dots, else nothing (so lines without either keep their height).
        let topReserve: CGFloat =
            ball != nil
            ? Self.ballTopReserve : (dots.isEmpty ? 0 : Self.rhythmicDotTopReserve)
        let totalWidth =
            (xs.last ?? 0) + CGFloat(max(words.last?.text.count ?? 1, 1))
            * Self.characterWidth + Self.characterWidth
        let contentHeight = (line.chords.isEmpty ? 20 : 42) + topReserve
        return ZStack(alignment: .topLeading) {
            ForEach(Array(barlineXs.enumerated()), id: \.offset) { _, x in
                Rectangle()
                    .fill(Color.swTextSecondary.opacity(0.16))
                    .frame(width: 1, height: contentHeight)
                    .position(x: x, y: contentHeight / 2)
            }
            ForEach(Array(dots.enumerated()), id: \.offset) { _, x in
                Circle()
                    .fill(Color.swTextSecondary.opacity(0.55))
                    .frame(width: 3.5, height: 3.5)
                    .position(x: x, y: 4)
            }
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let isHighlighted =
                    highlight?.wordRange.map { $0.overlaps(word.characterRange) } ?? false
                Text(word.text)
                    .font(
                        .system(
                            size: 15, weight: isHighlighted ? .bold : .regular, design: .monospaced)
                    )
                    .foregroundColor(isHighlighted ? .swAmber : .swTextPrimary)
                    .offset(x: xs[index], y: (line.chords.isEmpty ? 0 : 20) + topReserve)
            }
            ForEach(Array(line.chords.enumerated()), id: \.offset) { index, chord in
                Text(chord.name)
                    .font(.system(size: 13, weight: chordWeight(for: chord), design: .monospaced))
                    .foregroundStyle(.tint)
                    .offset(x: chordXs[index], y: topReserve)
            }
            // Rest marker: a short TRUE break after the last word (audit RC-4) — so the pause
            // the musician hears is visible on the chart instead of unexplained blank space.
            if trailingRestSeconds > 0, beatLengthSeconds > 0,
                let lastX = xs.last, let lastWord = words.last
            {
                let restBeats = max(Int((trailingRestSeconds / beatLengthSeconds).rounded()), 2)
                Text("𝄽\(restBeats)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.swTextSecondary.opacity(0.75))
                    .offset(
                        x: lastX + CGFloat(max(lastWord.text.count, 1)) * Self.characterWidth + 10,
                        y: (line.chords.isEmpty ? 0 : 20) + topReserve
                    )
                    .help(
                        "\(restBeats)-beat rest: the voice stops here before the next line")
            }
            if let ball {
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.ballDiameter, height: Self.ballDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .opacity(0.95)
                    .position(x: ball.x, y: ball.y)
            }
        }
        .frame(
            width: max(1, totalWidth),
            height: (line.chords.isEmpty ? 20 : 42) + topReserve,
            alignment: .topLeading
        )
    }

    /// Chord x positions for rhythmic mode. Each chord snaps to the x of the beat it coincides
    /// with (so chords line up with the beat dots); when no beat data is available it falls back
    /// to its word's position. Either way collisions are pushed right so chords never overlap.
    /// Aligns by index with `line.chords`.
    private var rhythmicChordXs: [CGFloat] {
        let words = rhythmicWords
        let xs = rhythmicWordXs
        guard !words.isEmpty, xs.count == words.count else {
            return Array(repeating: 0, count: line.chords.count)
        }
        // B3 (precise placement): when the SongTimeline supplies this row's chord TIMES
        // (1:1 with the rendered chords), place each chord directly at its real onset on
        // the row's time axis — no column→word→nearest-onset round trip to drift through.
        let authoritativeTimes =
            rowChordTimes.count == line.chords.count ? rowChordTimes : nil

        var result: [CGFloat] = []
        var cursor = -CGFloat.greatestFiniteMagnitude
        for (index, chord) in line.chords.enumerated() {
            let base: CGFloat
            if let authoritativeTimes {
                base = rhythmicX(forTime: authoritativeTimes[index])
            } else {
                // Fallback (edited charts, no timeline): the chord's LEADING EDGE sits at its
                // true detected onset. We take the word it's over as an anchor time, match it
                // to the nearest detected chord change, and map that onset onto the line's
                // time axis; the word/column position when no timing is available. An
                // END-OF-LINE chord (typeset past the text: a trailing chord that sounds
                // after the last word) searches further forward, since its onset is a beat
                // or two past the word — it must render to the RIGHT of it.
                let isTrailing = chord.column >= line.lyric.count
                let anchor = chordTimeInLine(chord, words: words)
                let onset = anchor.map {
                    nearestChordOnset(to: $0, tolerance: isTrailing ? 1.6 : 0.6) ?? $0
                }
                base =
                    onset.map { rhythmicX(forTime: $0) }
                    ?? chordRhythmicX(chord, words: words, xs: xs)
            }
            // Never let two labels overlap: nudge right to clear the previous chord.
            let x = max(base, cursor)
            result.append(x)
            cursor = x + CGFloat(chord.name.count + 1) * Self.characterWidth
        }
        return result
    }

    /// The detected chord-change onset nearest `time` (the real start of the chord impulse), or nil
    /// when none is within `tolerance` — so a chord snaps to its actual onset rather than the
    /// word it's typeset over. End-of-line trailing chords pass a wider tolerance.
    private func nearestChordOnset(
        to time: TimeInterval, tolerance: TimeInterval = 0.6
    ) -> TimeInterval? {
        var best: TimeInterval?
        var bestDelta = TimeInterval.greatestFiniteMagnitude
        for onset in chordOnsetTimes {
            let delta = abs(onset - time)
            if delta < bestDelta {
                bestDelta = delta
                best = onset
            }
        }
        return bestDelta <= tolerance ? best : nil
    }

    /// Beat times for this line's window (same sequence the rhythmic beat dots use, so a beat's
    /// index lines up with its dot x in `rhythmicBeatDotPositions`).
    private var rhythmicBeats: [TimeInterval] {
        guard let beatDots else { return [] }
        return BouncingBall.beats(
            in: beatDots.segmentStart,
            beatDots.segmentEnd,
            beatTimes: beatDots.beatTimes,
            bpm: beatDots.bpm
        )
    }

    /// Approximate song time a chord sounds at: the onset of the word it sits over (or the end of
    /// the last word before it). Used to snap the chord to the nearest beat.
    private func chordTimeInLine(
        _ chord: ChordProPreviewChord, words: [TimedLyricWord]
    ) -> TimeInterval? {
        if let word = words.first(where: { $0.characterRange.contains(chord.column) }) {
            return word.start
        }
        if let word = words.last(where: { $0.characterRange.lowerBound <= chord.column }) {
            return word.end
        }
        return words.first?.start
    }

    /// The bouncing ball's center in rhythmic mode, positioned over the rhythmic word x-layout
    /// (mirrors `ballPosition` but maps each beat to the rhythmic word being sung). `nil` when no
    /// ball should draw.
    private var rhythmicBallPosition: (x: CGFloat, y: CGFloat)? {
        guard let beatBall else { return nil }
        let words = rhythmicWords
        guard beatBall.isWaiting || !words.isEmpty else { return nil }
        let ballModel: BouncingBall
        if beatBall.isWaiting {
            // Waiting through an instrumental gap: pulse in place on the beat at the line's left.
            let beats = BouncingBall.beats(
                in: beatBall.segmentStart, beatBall.segmentEnd,
                beatTimes: beatBall.beatTimes, bpm: beatBall.bpm)
            guard !beats.isEmpty else { return nil }
            ballModel = BouncingBall(
                beatTimes: beats, beatX: beats.map { _ in Self.characterWidth / 2 })
        } else if !words.isEmpty {
            // TAP THE WORDS (user-chosen model 2026-07-02): each bounce bottoms on a word's
            // ONSET, centered over the word exactly as rendered (the nudged rhythmic layout),
            // so the ball and the lyrics can never disagree. A final tap at the line's end
            // gives the last word a full arc.
            let xs = rhythmicWordXs
            var taps = words.map(\.start)
            var tapXs = words.enumerated().map { index, word in
                (xs.indices.contains(index) ? xs[index] : 0)
                    + CGFloat(max(word.text.count, 1)) / 2 * Self.characterWidth
            }
            let lineEnd = max(beatBall.segmentEnd, (taps.last ?? 0) + 0.3)
            taps.append(lineEnd)
            tapXs.append(tapXs.last ?? 0)
            ballModel = BouncingBall(beatTimes: taps, beatX: tapXs)
        } else {
            // Fallback (no word timings): bounce on the beat at the metric columns.
            let beats = BouncingBall.beats(
                in: beatBall.segmentStart, beatBall.segmentEnd,
                beatTimes: beatBall.beatTimes, bpm: beatBall.bpm)
            guard !beats.isEmpty else { return nil }
            ballModel = BouncingBall(
                beatTimes: beats, beatX: beats.map { metricX(forTime: $0) })
        }
        guard let position = ballModel.position(at: beatBall.currentTime) else { return nil }
        let baseline = Self.ballTopReserve - 2
        let y = baseline - position.lift * Self.ballApexHeight
        return (x: position.x, y: y)
    }

    /// Beat-dot x positions for rhythmic mode: each beat sits over the word being sung at
    /// that moment, using the same rhythmic word x-layout as the rendered text. Empty unless
    /// beat dots are enabled and this line has rhythmic word timings.
    private var rhythmicBeatDotPositions: [CGFloat] {
        guard let beatDots else { return [] }
        guard !rhythmicWords.isEmpty else { return [] }
        let beats = BouncingBall.beats(
            in: beatDots.segmentStart,
            beatDots.segmentEnd,
            beatTimes: beatDots.beatTimes,
            bpm: beatDots.bpm
        )
        // Pure metric positions so the dots form fixed vertical columns shared across rows,
        // rather than tracking the (locally nudged) word positions.
        return beats.map { metricX(forTime: $0) }
    }

    /// x of each bar downbeat across this line's rendered width, on the shared metric grid — for
    /// faint barlines that make the repeating measure structure visible. Computed purely from the
    /// grid (its own `showBarlines` toggle), so it does NOT depend on the beat-dots toggle. Empty
    /// without a usable grid.
    private var barlineXs: [CGFloat] {
        guard showBarlines, rowDownbeatSeconds != nil, beatLengthSeconds > 0, beatsPerBar > 0,
            !rhythmicWords.isEmpty
        else { return [] }
        let barPx = CGFloat(beatLengthSeconds * Double(beatsPerBar)) * Self.pixelsPerSecond
        guard barPx > 1 else { return [] }
        // The downbeat sits at gutterPx; barlines step one bar apart across the row's content width.
        let maxX =
            (rhythmicWordXs.last ?? 0)
            + CGFloat(max(rhythmicWords.last?.text.count ?? 1, 1)) * Self.characterWidth
        var x = gutterPx.truncatingRemainder(dividingBy: barPx)
        if x < 0 { x += barPx }
        var result: [CGFloat] = []
        while x <= maxX + 1 {
            result.append(x)
            x += barPx
        }
        return result
    }

    /// Left x of each word on the shared metric grid (constant pixels-per-second, downbeat pinned to
    /// the gutter column), with only a local right-nudge for crowded syllables so words never
    /// overlap. The nudge never moves the row's downbeat anchor, so vertical beat alignment holds.
    private var rhythmicWordXs: [CGFloat] {
        let words = rhythmicWords
        guard !words.isEmpty else { return [] }
        var xs: [CGFloat] = []
        var cursor: CGFloat = 0
        for (index, word) in words.enumerated() {
            let desired = metricX(forTime: word.start)
            let x = index == 0 ? desired : max(desired, cursor)
            xs.append(x)
            cursor =
                x + CGFloat(max(word.text.count, 1)) * Self.characterWidth + Self.characterWidth
        }
        return xs
    }

    private func chordRhythmicX(
        _ chord: ChordProPreviewChord, words: [TimedLyricWord], xs: [CGFloat]
    ) -> CGFloat {
        if let index = words.firstIndex(where: { $0.characterRange.contains(chord.column) }) {
            return xs[index]
        }
        if let index = words.lastIndex(where: { $0.characterRange.lowerBound <= chord.column }) {
            return xs[index]
                + CGFloat(words[index].text.count + 1) * Self.characterWidth
        }
        return 0
    }

    private var monospaceContent: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(beatDotPositions.enumerated()), id: \.offset) { _, x in
                Circle()
                    .fill(Color.swTextSecondary.opacity(0.55))
                    .frame(width: 3.5, height: 3.5)
                    .position(x: x, y: 4)
            }

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
                        .offset(x: monospaceChordX(chord))
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
            width: isInstrumentalLine && lineDuration > 0 ? instrumentalTimeWidth : monospaceWidth,
            height: (line.chords.isEmpty ? 20 : 42) + Self.ballTopReserve,
            alignment: .topLeading
        )
    }

    /// The x of each beat within this line's time span, for the static beat-dot overlay —
    /// positioned over the word sung at each beat (same mapping the bouncing ball uses). On a
    /// chord-only line (no words) the dots are spread across the line width by their time, so
    /// instrumental sections (intro/outro/breaks) still show the beat.
    private var beatDotPositions: [CGFloat] {
        guard let beatDots else { return [] }
        let beats = BouncingBall.beats(
            in: beatDots.segmentStart,
            beatDots.segmentEnd,
            beatTimes: beatDots.beatTimes,
            bpm: beatDots.bpm
        )
        guard !beats.isEmpty else { return [] }
        if !beatDots.words.isEmpty || !wordCenters.isEmpty {
            return beats.map { wordCenterX(at: $0, beatBall: beatDots) }
        }
        guard !line.chords.isEmpty else { return [] }
        let span = max(beatDots.segmentEnd - beatDots.segmentStart, 0.0001)
        let width =
            isInstrumentalLine && lineDuration > 0
            ? instrumentalTimeWidth : CGFloat(max(1, lineWidth)) * Self.characterWidth
        return beats.map { beat in
            let relative = min(max((beat - beatDots.segmentStart) / span, 0), 1)
            return CGFloat(relative) * width
        }
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

        var times = beats
        let xs: [CGFloat]
        if tracksChords {
            if isInstrumentalLine, lineDuration > 0 {
                // Instrumental rows are drawn TIME-scaled (strip + chords), so the ball must
                // travel the same axis: each beat lands at its time-proportional x, not at the
                // chord token's character column (which no longer matches the rendered layout).
                let span = max(beatBall.segmentEnd - beatBall.segmentStart, 0.0001)
                let width = instrumentalTimeWidth
                xs = beats.map {
                    width * CGFloat(min(max(($0 - beatBall.segmentStart) / span, 0), 1))
                }
            } else {
                xs = beats.map { chordCenterX(at: $0, beatBall: beatBall) }
            }
        } else if beatBall.isWaiting {
            xs = beats.map { _ in Self.characterWidth / 2 }
        } else if !beatBall.words.isEmpty {
            // TAP THE WORDS (user-chosen model 2026-07-02): bounce bottoms land on word
            // ONSETS over the sung word; the beat grid is only the no-word-timing fallback.
            var taps = beatBall.words.map(\.start)
            var tapXs = taps.map { wordCenterX(at: $0, beatBall: beatBall) }
            taps.append(max(beatBall.segmentEnd, (taps.last ?? 0) + 0.3))
            tapXs.append(tapXs.last ?? 0)
            times = taps
            xs = tapXs
        } else {
            xs = beats.map { wordCenterX(at: $0, beatBall: beatBall) }
        }
        let ball = BouncingBall(beatTimes: times, beatX: xs)
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

/// Compact duplicate of the stem-mixer controls for the main window's right rail: one thin
/// row per stem (label, mute/solo, gain slider, live level bar) plus the click track — the
/// same `AppModel`/`StemPlaybackService` bindings as the full Stems editor, so the two stay
/// in sync. Designed to be as narrow as possible while staying usable (~230 pt).
struct StemMixSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var stemPlayback: StemPlaybackService
    /// Collapsed/expanded state, persisted. `PlayerView` reads the same key to shrink the
    /// rail's width when collapsed, reclaiming the space for the editor.
    @AppStorage(StemMixSidebar.expansionDefaultsKey) private var isExpanded = true
    static let expansionDefaultsKey = "stemMixRailExpanded"
    @State private var errorMessage: String?

    init(model: AppModel) {
        self.model = model
        stemPlayback = model.stemPlayback
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

    var body: some View {
        Group {
            if isExpanded {
                expandedContent
            } else {
                Button {
                    withAnimation(.snappy) { isExpanded = true }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(Color.swTextSecondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Expand Stem Mix")
            }
        }
        .padding(isExpanded ? 10 : 8)
        .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .swSurfacePanel(cornerRadius: 12)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button {
                    withAnimation(.snappy) { isExpanded = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.swTextSecondary)
                            .rotationEffect(.degrees(90))
                        Label("Stem Mix", systemImage: "slider.horizontal.3")
                            .font(.swDisplay(13, weight: .semibold))
                            .foregroundStyle(Color.swTextPrimary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse Stem Mix")
                Spacer()
                Button("Reset Levels", systemImage: "arrow.counterclockwise") {
                    model.resetStemMixer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!model.isStemMixerModified)
                .help("Reset all stem levels, mutes, and solos")
                // Load/Export moved here from the removed Stems editor tab.
                Menu {
                    Button("Load Stem Folder…", systemImage: "folder") { loadStemFolder() }
                    Button("Export Mix…", systemImage: "square.and.arrow.up") { exportMix() }
                        .disabled(model.stemFiles == nil || model.isExporting)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Load a stem folder or export the current mix")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.swCoral)
            }
            if model.stemFiles == nil {
                Text("Run Stems separation to enable the mix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                if model.hasStaleStemPlayback {
                    Label(
                        "Stems are stale — rerun Stems.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.swCoral)
                }
                // Slim console: the SAME channel strips as the Stems editor (full-height
                // vertical fader + segmented VU meter, M/S, scribble label), just narrower.
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(StemKind.allCases, id: \.self) { kind in
                        slimStrip(kind)
                    }
                    slimClickStrip
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func slimStrip(_ kind: StemKind) -> some View {
        let state = model.stemMixer[kind]
        let isAvailable = model.stemFiles?[kind] != nil
        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                VerticalFader(
                    value: Binding(
                        get: { Double(model.stemMixer[kind].gain) },
                        set: { model.setStemGain(Float($0), for: kind) }
                    ),
                    range: 0...Double(StemMixState.maximumGain),
                    thumbWidth: 14,
                    controlWidth: 15
                )
                SegmentedLevelMeter(
                    level: stemPlayback.stemLevels[kind] ?? 0, meterWidth: 7)
            }
            .frame(maxHeight: .infinity)
            .help("\(kind.rawValue.capitalized): \(Int((state.gain * 100).rounded()))%")

            VStack(spacing: 2) {
                miniToggle("M", isOn: state.isMuted, tint: Color.swCoral) {
                    model.setStemMuted($0, for: kind)
                }
                miniToggle("S", isOn: state.isSoloed, tint: Color.swAccent) {
                    model.setStemSoloed($0, for: kind)
                }
            }

            ScribbleStrip(text: shortName(kind))
        }
        .frame(maxWidth: 30)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
    }

    private var slimClickStrip: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                VerticalFader(
                    value: Binding(
                        get: { Double(stemPlayback.clickGain) },
                        set: { stemPlayback.clickGain = Float($0) }
                    ),
                    range: 0...Double(StemMixState.maximumGain),
                    thumbWidth: 14,
                    controlWidth: 15
                )
                // Width stand-in for the meter so the fader aligns with the stem strips.
                Color.clear.frame(width: 11)
            }
            .frame(maxHeight: .infinity)
            .help("Metronome click on each detected beat; 0% is off")

            // Stand-in for the M/S buttons so the scribble strips align.
            Color.clear.frame(height: 14 * 2 + 2)

            ScribbleStrip(text: "Clk")
        }
        .frame(maxWidth: 30)
    }

    private func shortName(_ kind: StemKind) -> String {
        String(kind.rawValue.prefix(3)).capitalized
    }

    private func miniToggle(
        _ label: String, isOn: Bool, tint: Color, set: @escaping (Bool) -> Void
    ) -> some View {
        Button {
            set(!isOn)
        } label: {
            Text(label)
                .font(.swMono(9, weight: .bold))
                .frame(width: 18, height: 14)
                .foregroundStyle(isOn ? Color.black : Color.swTextSecondary)
                .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? tint : Color.swSurface))
        }
        .buttonStyle(.plain)
        .help(label == "M" ? "Mute" : "Solo")
    }
}

/// A vertical fader (lowest value at the bottom) driven by a drag gesture.
private struct VerticalFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Thumb/control widths are parametrized so the slim right-rail strips can reuse the
    /// exact fader at a narrower footprint (defaults match the Stems editor).
    var thumbWidth: CGFloat = 26
    var controlWidth: CGFloat = 30
    private let thumbHeight: CGFloat = 14
    private let trackWidth: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
            let travel = max(height - thumbHeight, 1)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.32)).frame(width: trackWidth)
                Capsule()
                    .fill(Color.swAccent.opacity(0.75))
                    .frame(width: trackWidth, height: thumbHeight / 2 + fraction * travel)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.swTextPrimary)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(y: -fraction * travel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let clampedY = min(max(drag.location.y, 0), height)
                    let upward = 1 - Double(clampedY / height)
                    value = range.lowerBound + min(max(upward, 0), 1) * span
                }
            )
        }
        .frame(width: controlWidth)
    }
}

/// A vertical segmented VU meter: segments light from the bottom up (green → amber → red).
private struct SegmentedLevelMeter: View {
    let level: Float
    /// Parametrized so the slim right-rail strips can render the same meter narrower.
    var meterWidth: CGFloat = 14
    private let segmentCount = 16

    var body: some View {
        let clamped = min(max(level, 0), 1)
        return VStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { row in
                let fromBottom = segmentCount - 1 - row
                let threshold = Float(fromBottom) / Float(segmentCount)
                RoundedRectangle(cornerRadius: 1)
                    .fill(clamped > threshold ? color(fromBottom) : Color.white.opacity(0.06))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: meterWidth)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.3)))
        .animation(.linear(duration: 0.08), value: clamped)
    }

    private func color(_ fromBottom: Int) -> Color {
        let fraction = Float(fromBottom) / Float(segmentCount)
        if fraction > 0.85 { return .swCoral }
        if fraction > 0.6 { return .yellow }
        return .swMint
    }
}

/// A console "scribble strip" label — channel name on a strip of cream tape.
private struct ScribbleStrip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.94, green: 0.92, blue: 0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.2), lineWidth: 0.5)
            )
    }
}
