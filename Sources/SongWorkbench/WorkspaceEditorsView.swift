import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

/// The workspace editor tabs, selected by a segmented control at the top of the
/// window so the editor content fills the right column.
enum EditorTab: String, CaseIterable, Identifiable {
    case structure
    case lyrics
    case chords
    case chordPro
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structure: "Structure"
        case .lyrics: "Lyrics"
        case .chords: "Chords"
        case .chordPro: "ChordPro"
        case .review: "Review"
        }
    }

    var systemImage: String {
        switch self {
        case .structure: "square.stack.3d.up"
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
            case .structure: SongStructureView(model: model)
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
    // Observed directly (not just read through `model.isActivePlaybackPlaying`) so the single
    // play/pause button below reacts immediately to state changes on WHICHEVER service is
    // active — `model` itself doesn't republish its children's `@Published` changes, and
    // `activePlaybackSource` alone only flips when the source switches, not on every
    // play/pause toggle.
    @ObservedObject private var playback: AudioPlaybackService
    @ObservedObject private var stemPlayback: StemPlaybackService

    init(model: AppModel) {
        self.model = model
        playback = model.playback
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

                // One button, acting on whichever source is active (`activePlaybackSource`) —
                // the Stem Mix pane's Original/Stems switch (`StemMixSidebar.sourcePicker`) is
                // now what picks the source; this button just plays/pauses it. The small
                // trailing badge (added by `compactPlayButton`) still signals which source is
                // live so the transport bar doesn't lose that at-a-glance info.
                compactPlayButton(
                    title: model.isActivePlaybackPlaying ? "Pause" : "Play",
                    disabled: model.selectedSong == nil
                        || (model.activePlaybackSource == .stemMix && !stemPlayback.isLoaded),
                    isPlaying: model.isActivePlaybackPlaying,
                    symbolVariant: model.activePlaybackSource == .stemMix ? "square.stack" : nil,
                    help: model.activePlaybackSource == .stemMix
                        ? "Play or pause the separated stem mix"
                        : "Play or pause the original recording"
                ) {
                    model.toggleActivePlayback()
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

            // Compact scrubber (~3in ideal) — enough travel for seeking without dominating the
            // bar, but COMPRESSIBLE: a fixed 220 made the whole control row's minimum wider
            // than the default window's middle column, so the layout clipped the outer panes.
            PlaybackProgressSlider(model: model)
                .frame(minWidth: 100, idealWidth: 220, maxWidth: 260)

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
                .frame(minWidth: 84, idealWidth: 108, maxWidth: 108)
                .help("Pitch shift (semitones); playback speed is unaffected")
                VStack(spacing: 1) {
                    Slider(value: $model.tempoRate, in: 0.5...1.5, step: 0.05)
                        .controlSize(.mini)
                    Text("Speed \(Int((model.tempoRate * 100).rounded()))%")
                        .font(.swDisplay(9))
                        .foregroundStyle(Color.swTextSecondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 84, idealWidth: 108, maxWidth: 108)
                .help("Playback speed (pitch preserved)")
                Button("Reset Pitch and Speed", systemImage: "arrow.counterclockwise") {
                    model.pitchSemitones = 0
                    model.tempoRate = 1
                }
                .labelStyle(.iconOnly)
                .disabled(model.pitchSemitones == 0 && model.tempoRate == 1)
                .help("Reset pitch and speed")
            }
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
            sourceDuration: model.sourceDuration,
            untranscribedVocalRegions: model.untranscribedVocalRegions)
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

    /// Lyric lines that look like mis-splits, keyed by id → reason. Shown as a review flag; use
    /// Merge/Split to correct. Combines two independent signals: duration relative to the song's
    /// probable beats-per-line and structural meter/rhyme/chord-count deviation from the section's
    /// established `PhraseTemplate` (see `StructureAlignmentDiagnostics`) — a line flagged by both
    /// gets both reasons concatenated.
    private var suspectReasons: [TimedLyricSegment.ID: String] {
        guard showSuspectFlags else { return [:] }
        var reasons = LyricLineDiagnostics.suspectReasons(
            model.lyricSegments, tempo: model.estimatedBPM)
        if let overview = model.songStructureOverview() {
            for (id, reason) in StructureAlignmentDiagnostics.anomalies(in: overview) {
                reasons[id] = reasons[id].map { $0 + " " + reason } ?? reason
            }
        }
        return reasons
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
                        + "typical line, or inconsistent with a repeated section). Off by default.")
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
        let segments = model.displayLyricSegments
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
                .swProminentButtonStyle()
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
        case .untranscribedVocal: "waveform"
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
struct ChordProTabConfig: Sendable {
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
    /// Whether the App Preview/Edit-or-Source segmented picker is visible.
    /// Playback-only surfaces keep the shared preview renderer fixed onscreen.
    let showsSecondaryMode: Bool
    /// Footer caption shown beneath the body, if any.
    let footerNote: String?
    /// Whether this surface shows the playback/review chrome layered OVER the chart: the bouncing
    /// ball, beat dots, barlines, waveform, bass-note row, chord time labels, confidence shading,
    /// and the per-line accept/edit affordances. `false` renders the chart the way a ChordPro file
    /// actually reads — chords positioned above lyric text, plus directives — and nothing else.
    var showsPlaybackChrome = true

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
        showsSecondaryMode: true,
        footerNote: nil
    )

    static let chordProPlayback = ChordProTabConfig(
        kind: .chordPro,
        title: "ChordPro",
        pickerAccessibilityLabel: "ChordPro view",
        secondaryModeLabel: "Source",
        secondaryMode: .source,
        highlightStyle: .chord,
        exportFileName: "Song.cho",
        supportsTranspose: true,
        supportsImport: false,
        supportsMarkReviewed: false,
        showsSecondaryMode: false,
        footerNote: nil,
        showsPlaybackChrome: false
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
        showsSecondaryMode: true,
        footerNote:
            "Bass notes are detected from the separated bass stem when available; "
            + "otherwise they fall back to chord roots (slash-bass first, else the chord root)."
    )
}

struct ChordProTabEditor: View {
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
    /// Always on (Eric: rhythmic spacing should never be turned off) — no longer a user toggle.
    /// Kept as a `let` rather than deleting every `rhythmicSpacing` reference throughout this file.
    private let rhythmicSpacing = true
    @AppStorage("chordProShowWaveform") private var showWaveform = false
    /// Shows a bass-note row above each lyric line in the chart (backlog #15 Phase 2
    /// consolidation) — replaces the removed standalone Bass Notes tab and the old
    /// Review-tab bottom panel's bass toggle. Off by default: most songs won't have bass
    /// detected yet, and the extra row adds visual noise once they do.
    @AppStorage("reviewShowBassNotes") private var showBassNotes = false
    /// Shows the raw `{x_chord_times: ...}` round-trip directive `ChordProDraftBuilder` emits
    /// before every chord-only row (backlog B5) — a debug/inspection aid, not something most
    /// people reading the chart want to see. Off by default (Eric: make these labels optional,
    /// default off).
    @AppStorage("reviewShowChordTimeLabels") private var showChordTimeLabels = false
    /// Ball taps CHORD onsets instead of word onsets on sung lines. Eric's default ball model taps
    /// words (2026-07-02) because that is what a singer follows — but when the question is where
    /// the chords sit, a ball tracking words is measuring the wrong thing. Off by default.
    @AppStorage("reviewBallTracksChords") private var ballTracksChords = false
    /// Drives the small chord-confidence-shading legend popover in the toolbar (backlog #15).
    @State private var showConfidenceLegend = false

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
            // The full toolbar (title, Import, mode picker, timing offset, View menu, Mark
            // Reviewed, Transpose, Export, JustChords) sums to more ideal width than the
            // middle column ever has, especially on iPad — an unconstrained HStack here
            // forced the whole pane wider and pushed the song list/stem mixer off-screen
            // (Eric: "Review pane is too wide and forces left and right panels off screen").
            // A horizontal ScrollView caps the row's contribution to the parent's layout at
            // whatever width is actually available; the row itself just scrolls instead.
            ScrollView(.horizontal, showsIndicators: false) {
                toolbar
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
                    case .preview where !config.showsPlaybackChrome:
                        // Plain ChordPro: the chart as a .cho file reads it. Deliberately NOT
                        // `ChordProAppPreview` with everything switched off — that view's overlays
                        // and accept/edit affordances are the Review tab's job, and threading
                        // "hide it all" flags through it would leave the two surfaces free to
                        // drift back together.
                        ChordProReadOnlyView(
                            source: previewSource, transpose: model.chordProTranspose)
                    case .preview:
                        ChordProAppPreview(
                            source: previewSource,
                            transpose: config.supportsTranspose ? model.chordProTranspose : 0,
                            auditionedPlacement: model.auditionedPlacement,
                            placementPicks: model.chordPlacementPicks,
                            highlightContext: highlightContext(style: config.highlightStyle),
                            beatBall: beatBallInput,
                            beatDots: beatDotContext,
                            showBarlines: barlinesEnabled,
                            rhythmicSpacing: rhythmicSpacing,
                            lyricLineWords: sortedLyricLineWords,
                            showWaveform: showWaveform,
                            audioEnvelope: model.vocalWaveform ?? model.waveform,
                            audioEnvelopeIsVocals: model.vocalWaveform != nil,
                            guitarEnvelope: model.stemWaveformEnvelope(for: .guitar),
                            pianoEnvelope: model.stemWaveformEnvelope(for: .piano),
                            drumsEnvelope: model.stemWaveformEnvelope(for: .drums),
                            bassEnvelope: model.stemWaveformEnvelope(for: .bass),
                            lyricLineWindows: sortedLyricLineWindows,
                            songDuration: model.timelineDuration,
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
                                    .map { ($0.number, $0.chordTimes) }),
                            bassNotes: model.bassNotes,
                            showBassNotes: showBassNotes,
                            showChordTimeLabels: showChordTimeLabels,
                            lyricSegments: sortedLyricSegments,
                            chordEvents: model.chordEvents,
                            onToggleLyricAccepted: { id in model.toggleLyricAccepted(id: id) },
                            onCommitLyricOverride: { id, text in
                                model.setLyricOverrideText(id: id, text: text)
                            },
                            onToggleChordAccepted: { id in model.toggleChordAccepted(id: id) },
                            onSetChordManualTime: { id, time in
                                model.setChordManualTime(id: id, manualTime: time)
                            }
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

    private var toolbar: some View {
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
            if config.showsSecondaryMode {
                Picker(config.pickerAccessibilityLabel, selection: $mode) {
                    Text("App Preview").tag(Mode.preview)
                    Text(config.secondaryModeLabel).tag(Mode.secondary)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            // Timing offset, the display toggles and the shading legend all act on chrome the
            // plain ChordPro tab does not draw, so they are hidden there rather than left as
            // controls that appear to do nothing.
            if config.showsPlaybackChrome {
                timingOffsetControl
                // The display toggles live in one compact "View" menu so their labels can't
                // wrap and crowd the toolbar.
                Menu {
                    Toggle("Bouncing ball", isOn: $bouncingBallEnabled)
                    Toggle("Beat dots", isOn: $beatDotsEnabled)
                    Toggle("Barlines", isOn: $barlinesEnabled)
                    Toggle("Waveform", isOn: $showWaveform)
                    Toggle("Show Bass Notes", isOn: $showBassNotes)
                        .disabled(model.bassNotes.isEmpty)
                    Toggle("Chord Time Labels", isOn: $showChordTimeLabels)
                    Toggle("Ball Taps Chord Onsets", isOn: $ballTracksChords)
                } label: {
                    Label("View", systemImage: "eye")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(
                    "Show/hide the bouncing ball, beat dots, measure barlines, "
                        + "the per-line waveform, the detected bass note row, "
                        + "and each chord's raw detected timestamp")
                // Chord-placement A/B. A chord change is an inference, but WHERE it sits is a
                // separate question with more than one defensible answer, and the pipeline is its
                // own only witness — the `.cho` charts are untimed and were generated by earlier
                // versions of it. So the alternatives are exposed and judged against the
                // recording by ear. Purely transient: see `AppModel.auditionedPlacement`.
                Picker("Chord Placement", selection: $model.auditionedPlacement) {
                    Text("As saved").tag(ChordPlacementVariant?.none)
                    ForEach(ChordPlacementVariant.allCases, id: \.self) { variant in
                        Text(variant.displayName).tag(ChordPlacementVariant?.some(variant))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(
                    "Audition where chord changes are placed. Turn up the chord click fader in "
                        + "Stem Mix and switch between these while the song plays — whichever "
                        + "lands with the recording is the better anchor. Auditioning never "
                        + "edits the chart.")
                Button("Chord Shading Legend", systemImage: "questionmark.circle") {
                    showConfidenceLegend = true
                }
                .labelStyle(.iconOnly)
                .help("What the shaded backgrounds behind chord names mean")
                .popover(isPresented: $showConfidenceLegend, arrowEdge: .bottom) {
                    confidenceLegendContent
                }
            }
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
        .fixedSize()
    }

    /// Small popover explaining the shaded backgrounds behind chord names: reuses
    /// `ReviewConfidenceTier`'s existing tint/label mapping directly rather than duplicating it,
    /// so this legend can't drift out of sync with what `chordTint(at:)` actually renders.
    private var confidenceLegendContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chord Shading")
                .font(.swDisplay(12, weight: .semibold))
                .foregroundStyle(Color.swTextPrimary)
            legendRow(color: .swCoral, label: "Low confidence")
            legendRow(color: .swAmber, label: "Uncertain")
            legendRow(color: .clear, label: "Reviewed / high confidence", outlined: true)
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
    }

    private func legendRow(color: Color, label: String, outlined: Bool = false) -> some View {
        HStack(spacing: 8) {
            // Swatches mirror the preview's outline-only confidence marker (see
            // `chordConfidenceOutline(at:)`): tier color as a thin box, no fill.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    outlined ? Color.swTextSecondary.opacity(0.4) : color.opacity(0.9),
                    lineWidth: 1
                )
                .frame(width: 20, height: 14)
            Text(label)
                .font(.swDisplay(12))
                .foregroundStyle(Color.swTextPrimary)
        }
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
            .background(Color.swTextBackground)
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
        #if os(macOS)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [
                UTType(filenameExtension: "cho") ?? .plainText, .plainText,
            ]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try model.importChordPro(from: url)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        #else
            errorMessage = "Importing isn\u{2019}t available on iPad yet."
        #endif
    }

    private func exportDocument() {
        #if os(macOS)
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
        #else
            errorMessage = "Exporting isn\u{2019}t available on iPad yet."
        #endif
    }

    /// Writes the current (transposed) ChordPro to a temp file and opens it in the JustChords app.
    private func openInJustChords() {
        #if os(macOS)
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
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: openConfig)
            {
                _, error in
                if let error {
                    DispatchQueue.main.async {
                        errorMessage = "Could not open JustChords: \(error.localizedDescription)"
                    }
                }
            }
        #else
            errorMessage = "Opening in JustChords isn\u{2019}t available on iPad."
        #endif
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
                // Chord-tracking mode reads the PLACED times, not `row.chordTimes` — the timeline
                // row carries the stored placement, and during an A/B the ball has to agree with
                // what the chord click is playing or the two cues contradict each other.
                let placed =
                    ballTracksChords
                    ? model.placedChordTimes.filter { $0 >= row.start && $0 < row.end } : []
                return BeatBallInput(
                    currentTime: now,
                    ordinal: ordinal,
                    windowStart: row.start,
                    windowEnd: row.end,
                    words: segment?.words ?? [],
                    bpm: bpm,
                    beatTimes: beatTimes,
                    isWaiting: false,
                    chordTimes: placed,
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
/// low-confidence lyric lines and chord events one at a time. The `chordPro` tab shows the same
/// toolbar but renders through `ChordProReadOnlyView` — a spec-exact chords-above-lyrics render
/// with none of this chrome (`ChordProTabConfig.showsPlaybackChrome == false`).
struct ChordProReviewTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // backlog #15 Phase 2 consolidation: the bottom "Review & Annotate" list panel is gone —
        // bass notes, confidence tinting, and accept/correct now live directly in the chart
        // itself (bass row: the View menu's "Show Bass Notes" toggle; tint/accept/drag/edit: see
        // ChordProPreviewLineView). This tab is now just the interactive chart, full height.
        ChordProTabEditor(model: model, config: .chordPro)
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
    /// Playback auto-scroll animation: a slow symmetric ease so each line advance glides the
    /// chart toward center instead of the default quick spring's "jump scroll". Duration is a
    /// large fraction of a typical inter-line gap so the chart reads as continuously moving.
    static let autoScrollGlide: Animation = .easeInOut(duration: 1.1)

    let source: String
    var transpose: Int = 0
    /// Placement variant being auditioned in the chord-placement A/B, or nil for stored times.
    var auditionedPlacement: ChordPlacementVariant?
    /// Recorded placement verdicts, applied when no audition is in progress.
    var placementPicks: [ChordPlacementPick] = []
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
    /// Known full-song duration from the analysis timeline, used as the authoritative trailing
    /// bound for outro chord-only rows even when waveforms/beat dots are not loaded.
    var songDuration: TimeInterval = 0
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
    /// Detected bass notes (backlog: Bass Note display consolidation) — shown as an optional row
    /// above each lyric line when `showBassNotes` is on, replacing the standalone Bass Notes tab.
    var bassNotes: [BassNoteObservation] = []
    var showBassNotes = false
    /// Shows the raw `{x_chord_times: ...}` directive text (View menu's "Chord Time Labels"
    /// toggle) instead of hiding it — off by default.
    var showChordTimeLabels = false
    /// Lyric segments in the SAME sorted order `lyricOrdinal` indexes into (backlog #15 Phase 2
    /// remainder — chart interactivity), so a rendered line's confidence/accepted/overrideText
    /// can be read (and edited) directly, without a separate lookup mechanism.
    var lyricSegments: [TimedLyricSegment] = []
    /// The live chord events (backlog #15 Phase 2 remainder), matched to each rendered chord via
    /// its row's authoritative onset time (`EditableChordEvent.matching(rowTime:in:)`) so the
    /// chart can show confidence tint, accept state, and drag-to-reposition.
    var chordEvents: [EditableChordEvent] = []
    var onToggleLyricAccepted: (TimedLyricSegment.ID) -> Void = { _ in }
    var onCommitLyricOverride: (TimedLyricSegment.ID, String) -> Void = { _, _ in }
    var onToggleChordAccepted: (EditableChordEvent.ID) -> Void = { _ in }
    var onSetChordManualTime: (EditableChordEvent.ID, TimeInterval?) -> Void = { _, _ in }

    /// The live segment behind a rendered lyric line, by ordinal (nil for chord-only rows or an
    /// out-of-range ordinal — matches the existing `bassLabel(forLyricOrdinal:)` convention).
    private func lyricSegment(forOrdinal ordinal: Int?) -> TimedLyricSegment? {
        guard let ordinal, lyricSegments.indices.contains(ordinal) else { return nil }
        return lyricSegments[ordinal]
    }

    /// Per-row chord matching, bundled into one call (backlog #15 Phase 2 remainder) so the body's
    /// `ForEach` only needs one `let` for both results — Swift's expression type-checker times out
    /// on this view's already-large per-item closure if that computation is inlined as two
    /// separate statements plus an inline call inside the `ChordProPreviewBlockView(...)`
    /// initializer.
    private struct ChordRowData {
        /// Real chord event behind each rendered chord, index-aligned with `line.chords`.
        let events: [EditableChordEvent?]
        /// Authoritative onset times with any manually-dragged chord's time substituted, so a
        /// drag moves the chord without any other change to the existing time→x coordinate math
        /// (`ChordProPreviewLineView` consumes this array as its authoritative source).
        let effectiveTimes: [TimeInterval]
    }

    private func chordRowData(for item: ChordProPreviewIndexedBlock) -> ChordRowData {
        let rawTimes: [TimeInterval] =
            item.displayLineNumber.flatMap { timelineChordTimesByLine[$0] } ?? []
        let events = rawTimes.map { EditableChordEvent.matching(rowTime: $0, in: chordEvents) }
        let effectiveTimes = zip(rawTimes, events).map { rowTime, event in
            // Resolved through the model so a drag, an in-progress A/B audition, and a recorded
            // placement pick all move the glyph the same way — see `AppModel.placementTime(for:)`.
            event?.placementTime(auditioning: auditionedPlacement, picks: placementPicks)
                ?? rowTime
        }
        return ChordRowData(events: events, effectiveTimes: effectiveTimes)
    }

    /// The detected bass note(s) sounding during a lyric line's time window, formatted for
    /// display (e.g. "E (D string) · A (G string)") — `nil` when the toggle is off, there's no
    /// nothing falls in the window (mirrors the removed `ChordProReviewAnnotationsPanel`'s
    /// `bassNoteLabel(forLyricIndex:)`, now computed per rendered row instead of a flat list).
    private func bassLabel(forLyricOrdinal ordinal: Int?) -> String? {
        guard showBassNotes, !bassNotes.isEmpty, let ordinal,
            lyricLineWindows.indices.contains(ordinal)
        else { return nil }
        // Transposed by the SAME amount as the chart's chords — the bass row previously
        // showed raw detected pitches, reading a consistent half-step off whenever the
        // Transpose stepper was non-zero (Eric: "half a step low, or perhaps not
        // transposed" — it was the latter).
        return BassNoteRowFormatter.label(
            for: bassNotes, inWindow: lyricLineWindows[ordinal], transposedBy: transpose)
    }

    /// The same window's bass notes with onset times, for rhythmic mode's positioned row (each
    /// note at its real x on the row's time axis instead of one flush-left label).
    private func timedBassNotes(forLyricOrdinal ordinal: Int?) -> [TimedBassNoteLabel] {
        guard showBassNotes, !bassNotes.isEmpty, let ordinal,
            lyricLineWindows.indices.contains(ordinal)
        else { return [] }
        return BassNoteRowFormatter.timedLabels(
            for: bassNotes, inWindow: lyricLineWindows[ordinal], transposedBy: transpose)
    }

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
    ) -> (peaks: [Float], duration: TimeInterval, start: TimeInterval, color: Color) {
        // Lyric lines use the vocals lane color (matches the waveform panel); a full-mix fallback is
        // neutral so it isn't mislabeled as the isolated vocal.
        let lyricColor: Color = audioEnvelopeIsVocals ? StemKind.vocals.laneColor : .swTextSecondary
        if let ordinal = item.lyricOrdinal {
            let start: TimeInterval =
                lyricLineWindows.indices.contains(ordinal)
                ? lyricLineWindows[ordinal].lowerBound : 0
            return (
                vocalPeaks(forLyricOrdinal: ordinal),
                lineDuration(forLyricOrdinal: ordinal), start, lyricColor
            )
        }
        // The row's real time window (hence its rhythmic-mode WIDTH, and where each of its chords
        // falls within that width) must not depend on whether there's a guitar/piano envelope to
        // draw as a waveform strip underneath it — those are separate concerns. Gating `duration`
        // behind `instrumentalLane` meant a song with no guitar/piano stem (or one not yet loaded
        // at this call site) silently reported duration 0 for every instrumental row, which fell
        // through `instrumentalTimeWidth`'s `lineDuration > 0` guard straight to the old
        // character-count sizing — no amount of fixing that width formula could show through when
        // this returned 0 first. Resolve the window unconditionally; only the drawn peaks (and
        // their color) depend on a lane actually being available. `start` lets each chord glyph
        // find its real time-proportional x within the row (see `monospaceChordX`) instead of a
        // fraction of the bar-grid TEXT's own character count.
        guard case .lyric(let line) = item.block, !line.chords.isEmpty, !line.hasSungText,
            let window = chordOnlyLineWindow(for: item, in: document)
        else { return ([], 0, 0, .swTextSecondary) }
        let duration = max(0, window.end - window.start)
        guard let lane = instrumentalLane else {
            return ([], duration, window.start, .swTextSecondary)
        }
        return (peaks(in: window, from: lane.envelope), duration, window.start, lane.color)
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
                                        blockRow(for: item, in: document)
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
                            .background(Color.swTextBackground)
                            .border(.separator)
                            .onChange(of: highlightContext?.currentLyricOrdinal) { _, ordinal in
                                guard
                                    let ordinal,
                                    let offset = blockOffset(
                                        forLyricOrdinal: ordinal, in: document
                                    )
                                else { return }
                                // Teleprompter glide, not a jump: a slow ease toward the next
                                // line's centered position reads as one continuous scroll when
                                // lines advance every few seconds (Eric: "smooth incremental
                                // scroll ... keep the active line centered"). Centering is
                                // clamped by the ScrollView itself, so the chart naturally
                                // stays put until enough lines have played for the active one
                                // to reach the middle of the viewport.
                                withAnimation(Self.autoScrollGlide) {
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
                                withAnimation(Self.autoScrollGlide) {
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

    /// One rendered chart row (title/metadata/section/lyric/chord-only line), fully configured.
    /// Pulled out of the `ForEach` above as its OWN function (backlog #15 Phase 2 remainder,
    /// chart interactivity): the closure was already large before this task added several more
    /// `ChordProPreviewBlockView` parameters, and Swift's type-checker times out solving a
    /// `ForEach` result-builder closure with this many statements as one unit — an ordinary
    /// function's statements are checked individually, so this has no such limit.
    @ViewBuilder
    private func blockRow(
        for item: ChordProPreviewIndexedBlock, in document: ChordProPreviewDocument
    ) -> some View {
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
        let chordRow = chordRowData(for: item)
        // Every argument below is pre-computed into its own `let`
        // (rather than inlined as an expression in the call) —
        // this view's `ChordProPreviewBlockView(...)` call has
        // enough arguments that the Swift type-checker times out
        // solving them jointly with any nested expression inside
        // the call itself; simple identifiers avoid that.
        let itemLyricSegment = lyricSegment(
            forOrdinal: item.lyricOrdinal)
        let itemHighlight = highlightContext?.highlight(
            forLyricOrdinal: item.lyricOrdinal)
        let itemBeatBall = beatBallValue(for: item, in: document)
        let itemBeatDots = beatDotValue(for: item, in: document)
        let itemShowBarlines = showBarlines && vocalsFollowBeatGrid
        let itemTrailingRest = trailingRestSeconds(
            lastWordEnd: lineWords.last?.end,
            nextLineStart: nextLineStart)
        let itemHasUntranscribed: Bool =
            item.displayLineNumber
            .map(untranscribedLineNumbers.contains) ?? false
        let itemBassLabel = bassLabel(
            forLyricOrdinal: item.lyricOrdinal)
        let itemRowBassNotes = timedBassNotes(
            forLyricOrdinal: item.lyricOrdinal)
        ChordProPreviewBlockView(
            block: item.block,
            highlight: itemHighlight,
            beatBall: itemBeatBall,
            beatDots: itemBeatDots,
            rhythmicSpacing: rhythmicSpacing,
            rhythmicWordTimings: lineWords,
            vocalPeaks: strip.peaks,
            lineDuration: strip.duration,
            rowStartTime: strip.start,
            stripColor: strip.color,
            rowDownbeatSeconds: rowDownbeat,
            gutterSeconds: gutterSeconds,
            beatLengthSeconds: beatLengthSeconds,
            beatsPerBar: beatsPerBar,
            showBarlines: itemShowBarlines,
            chordOnsetTimes: chordOnsetTimes,
            leadingMelodyPeaks: leadingMelody.peaks,
            melodyColor: leadingMelody.color,
            leadingMelodySeconds: leadingMelody.seconds,
            trailingMelodyPeaks: trailingMelody.peaks,
            trailingMelodySeconds: trailingMelody.seconds,
            lineNumber: item.displayLineNumber,
            trailingRestSeconds: itemTrailingRest,
            hasUntranscribedVocals: itemHasUntranscribed,
            rowChordTimes: chordRow.effectiveTimes,
            bassLabel: itemBassLabel,
            rowBassNotes: itemRowBassNotes,
            showChordTimeLabels: showChordTimeLabels,
            lyricSegment: itemLyricSegment,
            onToggleLyricAccepted: onToggleLyricAccepted,
            onCommitLyricOverride: onCommitLyricOverride,
            rowChordEvents: chordRow.events,
            onToggleChordAccepted: onToggleChordAccepted,
            onSetChordManualTime: onSetChordManualTime
        )
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
        // Shared with the Lyric Blend window so both surfaces agree on line numbers.
        ChordProPreviewIndexing.indexedBlocks(for: document)
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
                    return line.hasSungText
                }
                return false
            })
        else { return nil }
        for index in (lastLyricIndex + 1)..<items.count {
            if case .lyric(let line) = items[index].block, !line.chords.isEmpty,
                !line.hasSungText
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
            let hasText = line.hasSungText
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
            // Chord-tracking mode: a sung row's ball taps the chords rather than the words. The
            // instrumental path already bounces on `chordTimes`; this reuses it rather than
            // adding a second way to express the same thing.
            if !beatBall.chordTimes.isEmpty {
                return LineBeatBall(
                    currentTime: beatBall.currentTime,
                    segmentStart: beatBall.windowStart,
                    segmentEnd: beatBall.windowEnd,
                    bpm: beatBall.bpm,
                    beatTimes: beatBall.beatTimes,
                    chordTimes: beatBall.chordTimes
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
            !line.hasSungText,
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
        let envelopeDurations = [audioEnvelope, guitarEnvelope, pianoEnvelope].compactMap {
            $0?.duration
        }
        return ChordProPreviewLineWindowResolver.chordOnlyLineWindow(
            items: items,
            index: index,
            lyricLineWindows: lyricLineWindows,
            explicitStart: start,
            explicitEnd: end,
            songDuration: songDuration,
            envelopeDurations: envelopeDurations,
            beatTimes: beatTimes,
            beatLengthSeconds: beatLengthSeconds,
            chordOnsetTimes: chordOnsetTimes
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

struct ChordProPreviewIndexedBlock {
    let offset: Int
    let block: ChordProPreviewBlock
    let lyricOrdinal: Int?
    /// 1-based running number across all musical lines (lyric + chord-only instrumental), or nil
    /// for non-musical blocks (titles, section headers, metadata, directives).
    var displayLineNumber: Int?
}

/// Shared chart-line numbering, used by the Review pane's gutter AND the Lyric Blend window,
/// so a row referenced as "line 9" means the same line in both places.
enum ChordProPreviewIndexing {
    static func indexedBlocks(
        for document: ChordProPreviewDocument
    ) -> [ChordProPreviewIndexedBlock] {
        var lyricOrdinal = 0
        var displayLine = 0
        return document.blocks.enumerated().map { offset, block in
            let ordinal: Int?
            // Only lines with real (non-whitespace) lyric text are lyric lines; chord-only
            // lines (intro/instrumental/outro) carry whitespace lyric and must not consume
            // an ordinal, or highlight/ball alignment shifts off the real lyrics.
            if case .lyric(let line) = block, line.hasSungText {
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
                line.hasSungText || !line.chords.isEmpty
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

    /// True when `items[i]` is itself a chord-only (instrumental) row: has chords, no sung text.
    static func isChordOnlyRow(_ items: [ChordProPreviewIndexedBlock], _ i: Int) -> Bool {
        guard items.indices.contains(i), items[i].lyricOrdinal == nil,
            case .lyric(let line) = items[i].block
        else { return false }
        return !line.chords.isEmpty && !line.hasSungText
    }

    /// This row's position within its run of consecutive chord-only rows, and the run's total
    /// length — used to give a multi-row intro/instrumental/outro span an equal `1/rowCount`
    /// slice of its time gap per row.
    ///
    /// A real sung lyric line ends the run; anything else in between — the
    /// `{x_chord_times: ...}` directive `ChordProDraftBuilder` emits before EVERY chord-only
    /// row, section/comment directives, blank lines — is not itself a row and must be stepped
    /// over, not treated as a run-ending gap. A naive adjacent-index check
    /// (`isChordOnlyRow(index - 1)`/`(index + 1)`) hits that directive immediately
    /// preceding/following each row and stops there, collapsing every multi-row intro/outro to
    /// `rowCount == 1` — so each row claimed the ENTIRE gap instead of its slice (reported:
    /// "Intro and outro bars are now twice as wide as they should be").
    static func chordOnlyRunPosition(
        in items: [ChordProPreviewIndexedBlock], at index: Int
    ) -> (rowCount: Int, position: Int) {
        func isRunBoundary(_ i: Int) -> Bool {
            guard items.indices.contains(i) else { return true }
            if items[i].lyricOrdinal != nil { return true }
            if case .lyric(let line) = items[i].block, line.hasSungText { return true }
            return false
        }
        func adjacentChordOnlyRow(from i: Int, step: Int) -> Int? {
            var probe = i + step
            while items.indices.contains(probe) {
                if isChordOnlyRow(items, probe) { return probe }
                if isRunBoundary(probe) { return nil }
                probe += step
            }
            return nil
        }
        var rowOffsets = [index]
        var probeStart = index
        while let prev = adjacentChordOnlyRow(from: probeStart, step: -1) {
            rowOffsets.insert(prev, at: 0)
            probeStart = prev
        }
        var probeEnd = index
        while let next = adjacentChordOnlyRow(from: probeEnd, step: 1) {
            rowOffsets.append(next)
            probeEnd = next
        }
        return (max(1, rowOffsets.count), rowOffsets.firstIndex(of: index) ?? 0)
    }

    /// Every row index in this row's run of consecutive chord-only rows, in order. Same walk as
    /// `chordOnlyRunPosition`, which is expressed in terms of it.
    static func chordOnlyRunRows(
        in items: [ChordProPreviewIndexedBlock], at index: Int
    ) -> [Int] {
        func isRunBoundary(_ i: Int) -> Bool {
            guard items.indices.contains(i) else { return true }
            if items[i].lyricOrdinal != nil { return true }
            if case .lyric(let line) = items[i].block, line.hasSungText { return true }
            return false
        }
        func adjacentChordOnlyRow(from i: Int, step: Int) -> Int? {
            var probe = i + step
            while items.indices.contains(probe) {
                if isChordOnlyRow(items, probe) { return probe }
                if isRunBoundary(probe) { return nil }
                probe += step
            }
            return nil
        }
        var rowOffsets = [index]
        var probeStart = index
        while let prev = adjacentChordOnlyRow(from: probeStart, step: -1) {
            rowOffsets.insert(prev, at: 0)
            probeStart = prev
        }
        var probeEnd = index
        while let next = adjacentChordOnlyRow(from: probeEnd, step: 1) {
            rowOffsets.append(next)
            probeEnd = next
        }
        return rowOffsets
    }

    /// Review-pane display line number for each SUNG-lyric ordinal in `source` — the mapping
    /// the Lyric Blend window uses to label its rows with the chart's own numbers.
    static func displayNumbersByLyricOrdinal(source: String) -> [Int: Int] {
        guard let document = try? ChordProDocument(parsing: source) else { return [:] }
        var mapping: [Int: Int] = [:]
        for item in indexedBlocks(for: ChordProPreviewDocument(document: document)) {
            if let ordinal = item.lyricOrdinal, let number = item.displayLineNumber {
                mapping[ordinal] = number
            }
        }
        return mapping
    }
}

enum ChordProPreviewLineWindowResolver {
    static func chordOnlyLineWindow(
        items: [ChordProPreviewIndexedBlock],
        index: Int,
        lyricLineWindows: [ClosedRange<TimeInterval>],
        explicitStart: TimeInterval? = nil,
        explicitEnd: TimeInterval? = nil,
        songDuration: TimeInterval,
        envelopeDurations: [TimeInterval],
        beatTimes: [TimeInterval],
        beatLengthSeconds: TimeInterval,
        chordOnsetTimes: [TimeInterval]
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard items.indices.contains(index), ChordProPreviewIndexing.isChordOnlyRow(items, index)
        else { return nil }

        func window(at i: Int) -> ClosedRange<TimeInterval>? {
            guard let ordinal = items[i].lyricOrdinal,
                lyricLineWindows.indices.contains(ordinal)
            else { return nil }
            return lyricLineWindows[ordinal]
        }

        var start = explicitStart
        if start == nil {
            var before = index - 1
            while before >= 0 {
                if let segment = window(at: before) {
                    start = segment.upperBound
                    break
                }
                before -= 1
            }
        }

        var end = explicitEnd
        if end == nil {
            var after = index + 1
            while after < items.count {
                if let segment = window(at: after) {
                    end = segment.lowerBound
                    break
                }
                after += 1
            }
        }

        let resolvedStart = start ?? 0
        let resolvedEnd =
            end
            ?? trailingEndBound(
                after: resolvedStart,
                songDuration: songDuration,
                envelopeDurations: envelopeDurations,
                beatTimes: beatTimes,
                beatLengthSeconds: beatLengthSeconds,
                chordOnsetTimes: chordOnsetTimes
            )
        guard let resolvedEnd, resolvedEnd > resolvedStart else { return nil }

        let (rowCount, position) = ChordProPreviewIndexing.chordOnlyRunPosition(
            in: items, at: index)

        // Prefer each row's REAL time window, taken from the chord onsets it actually holds.
        // Equal `1/rowCount` slices make every row of a run the same width no matter how much
        // song time it covers — an intro of 5.12 / 5.25 / 5.05 / 4.04 s rendered as four
        // identical 4.9 s rows — which breaks the constant pixels-per-second axis the rest of the
        // chart is drawn on (Eric: "instrumental lines still much shorter than lyric lines").
        if let boundaries = runRowBoundaries(
            items: items,
            index: index,
            rowCount: rowCount,
            resolvedStart: resolvedStart,
            resolvedEnd: resolvedEnd,
            chordOnsetTimes: chordOnsetTimes
        ) {
            return (boundaries[position], boundaries[position + 1])
        }

        let span = resolvedEnd - resolvedStart
        let sliceStart = resolvedStart + span * Double(position) / Double(rowCount)
        let sliceEnd = resolvedStart + span * Double(position + 1) / Double(rowCount)
        return (sliceStart, sliceEnd)
    }

    /// `rowCount + 1` time boundaries for a run of chord-only rows: each row starts at its own
    /// first chord onset. `nil` when the onsets can't account for every row's chords, so the
    /// caller falls back to equal slices rather than inventing a boundary.
    private static func runRowBoundaries(
        items: [ChordProPreviewIndexedBlock],
        index: Int,
        rowCount: Int,
        resolvedStart: TimeInterval,
        resolvedEnd: TimeInterval,
        chordOnsetTimes: [TimeInterval]
    ) -> [TimeInterval]? {
        guard rowCount > 1 else { return nil }
        let rows = ChordProPreviewIndexing.chordOnlyRunRows(in: items, at: index)
        guard rows.count == rowCount else { return nil }
        let chordCounts: [Int] = rows.map { row in
            guard case .lyric(let line) = items[row].block else { return 0 }
            return line.chords.count
        }
        guard chordCounts.allSatisfy({ $0 > 0 }) else { return nil }

        let epsilon = 1e-6
        let onsets =
            chordOnsetTimes
            .filter { $0 >= resolvedStart - epsilon && $0 < resolvedEnd + epsilon }
            .sorted()
        guard onsets.count >= chordCounts.reduce(0, +) else { return nil }

        var boundaries: [TimeInterval] = [resolvedStart]
        var consumed = 0
        for count in chordCounts.dropLast() {
            consumed += count
            // The next row opens at its own first chord.
            let boundary = onsets[consumed]
            guard boundary > (boundaries.last ?? resolvedStart) + epsilon,
                boundary < resolvedEnd - epsilon
            else { return nil }
            boundaries.append(boundary)
        }
        boundaries.append(resolvedEnd)
        return boundaries
    }

    private static func trailingEndBound(
        after start: TimeInterval,
        songDuration: TimeInterval,
        envelopeDurations: [TimeInterval],
        beatTimes: [TimeInterval],
        beatLengthSeconds: TimeInterval,
        chordOnsetTimes: [TimeInterval]
    ) -> TimeInterval? {
        let beatLength = beatLengthSeconds > 0 ? beatLengthSeconds : 0.5
        let oneBar = 4 * beatLength
        let candidates: [TimeInterval] = [
            songDuration,
            envelopeDurations.max() ?? 0,
            beatTimes.last.map { $0 + oneBar } ?? 0,
            chordOnsetTimes.filter { $0 >= start }.max().map { $0 + oneBar } ?? 0,
        ]
        let end = candidates.max() ?? 0
        return end > start ? end : nil
    }
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
    /// This row's own real start time (its `chordOnlyLineWindow`/lyric-window lower bound) — the
    /// origin `rowChordTimes` are measured from when placing a chord glyph time-proportionally
    /// across `instrumentalTimeWidth` (see `ChordProPreviewLineView.monospaceChordX`).
    var rowStartTime: TimeInterval = 0
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
    /// Detected bass note(s) sounding during this row's window (e.g. "E · A · D"), shown above
    /// the chord/lyric content when the View menu's "Show Bass Notes" toggle is on. `nil` for
    /// non-lyric blocks or when there's nothing to show. Used only as the flush-left fallback
    /// when the rhythmic (positioned) bass row can't render — monospace mode or an overridden
    /// line, where there's no per-time x axis.
    var bassLabel: String?
    /// The same bass notes with onset times, for rhythmic mode's positioned per-note row.
    var rowBassNotes: [TimedBassNoteLabel] = []
    /// Shows raw `{...}` directive lines (e.g. the `x_chord_times` round-trip carrier) instead
    /// of hiding them — View menu's "Chord Time Labels" toggle, off by default.
    var showChordTimeLabels = false
    /// The live segment behind this rendered lyric line (backlog #15 Phase 2 remainder — chart
    /// interactivity); `nil` for chord-only/non-lyric blocks. Drives the accept toggle, the
    /// confidence tint, and the edited-line text when set.
    var lyricSegment: TimedLyricSegment?
    var onToggleLyricAccepted: (TimedLyricSegment.ID) -> Void = { _ in }
    var onCommitLyricOverride: (TimedLyricSegment.ID, String) -> Void = { _, _ in }
    /// Real chord events behind this row's rendered chords, index-aligned with the block's
    /// `ChordProPreviewLine.chords` (backlog #15 Phase 2 remainder).
    var rowChordEvents: [EditableChordEvent?] = []
    var onToggleChordAccepted: (EditableChordEvent.ID) -> Void = { _ in }
    var onSetChordManualTime: (EditableChordEvent.ID, TimeInterval?) -> Void = { _, _ in }

    @State private var isEditingLyric = false
    @State private var draftLyricText = ""

    /// True when the nested `ChordProPreviewLineView` will render the bass notes positioned on
    /// its rhythmic time axis — mirrors that view's own mode selection (rhythmic words present,
    /// no override) so the flush-left fallback label never doubles up with the positioned row.
    private var rendersPositionedBassNotes: Bool {
        guard case .lyric(let line) = block else { return false }
        guard rhythmicSpacing, !rhythmicWordTimings.isEmpty, !rowBassNotes.isEmpty else {
            return false
        }
        let overrideActive =
            line.hasSungText
            && lyricSegment?.overrideText?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return !overrideActive
    }

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
                if let bassLabel, !rendersPositionedBassNotes {
                    // Flush-left fallback (monospace mode / overridden lines). Same size as the
                    // chord glyphs (13pt monospaced) and a bright green — Eric: "Bass note names
                    // should be the same size as chords, and be in bright green" — rather than
                    // the smaller 10pt `StemKind.bass.laneColor` (blue) used elsewhere, which
                    // read as secondary metadata next to the chart's chords.
                    Text(bassLabel)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.swMint)
                }
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
            VStack(alignment: .leading, spacing: 2) {
                if isEditingLyric {
                    editingLyricField
                } else {
                    ChordProPreviewLineView(
                        line: line, highlight: highlight, beatBall: beatBall, beatDots: beatDots,
                        rhythmicSpacing: rhythmicSpacing, rhythmicWordTimings: rhythmicWordTimings,
                        vocalPeaks: vocalPeaks, lineDuration: lineDuration,
                        rowStartTime: rowStartTime, stripColor: stripColor,
                        rowDownbeatSeconds: rowDownbeatSeconds, gutterSeconds: gutterSeconds,
                        beatLengthSeconds: beatLengthSeconds, beatsPerBar: beatsPerBar,
                        showBarlines: showBarlines,
                        chordOnsetTimes: chordOnsetTimes,
                        leadingMelodyPeaks: leadingMelodyPeaks, melodyColor: melodyColor,
                        leadingMelodySeconds: leadingMelodySeconds,
                        trailingMelodyPeaks: trailingMelodyPeaks,
                        trailingMelodySeconds: trailingMelodySeconds,
                        trailingRestSeconds: trailingRestSeconds,
                        rowChordTimes: rowChordTimes,
                        rowChordEvents: rowChordEvents,
                        onToggleChordAccepted: onToggleChordAccepted,
                        onSetChordManualTime: onSetChordManualTime,
                        overrideText: lyricSegment?.overrideText,
                        rowBassNotes: rowBassNotes)
                }
                if line.hasSungText, let lyricSegment {
                    lyricControls(for: lyricSegment)
                }
            }
        case .directive(let source):
            if showChordTimeLabels {
                Text(source)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Small accept/edit affordance row beneath a lyric line (backlog #15 Phase 2 remainder).
    /// Deliberately NOT inside `ChordProPreviewLineView` — accepting/editing a whole line is a
    /// simple, coordinate-independent action, unlike chord tint/drag which lives right on the
    /// chord glyph because it IS coordinate-dependent.
    private func lyricControls(for segment: TimedLyricSegment) -> some View {
        let tier = ReviewConfidenceTier(segment.confidence)
        return HStack(spacing: 6) {
            Button {
                onToggleLyricAccepted(segment.id)
            } label: {
                Image(systemName: segment.accepted ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(segment.accepted ? Color.swMint : Color.swTextSecondary)
            .help(segment.accepted ? "Accepted — click to un-accept" : "Accept this line")

            Button {
                draftLyricText = segment.effectiveText
                isEditingLyric = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.swTextSecondary)
            .help("Correct this line's text")

            if !segment.accepted, let label = tier.label {
                Text(label)
                    .font(.swDisplay(9))
                    .foregroundStyle(tier.tint)
            }
            if segment.overrideText != nil {
                Text("Edited")
                    .font(.swDisplay(9))
                    .foregroundStyle(Color.swTextSecondary)
            }
        }
    }

    /// Inline correction field, seeded with the line's currently effective text. Return commits;
    /// Escape (via `onExitCommand`) discards. Writes `TimedLyricSegment.overrideText` on commit —
    /// the schema is per-line, so this is the finest-grained "word edit" the model supports.
    @ViewBuilder private var editingLyricField: some View {
        if let lyricSegment {
            TextField(
                "Line text", text: $draftLyricText,
                onCommit: {
                    onCommitLyricOverride(lyricSegment.id, draftLyricText)
                    isEditingLyric = false
                }
            )
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .onExitCommandCompat { isEditingLyric = false }
        }
    }
}

enum ChordProPreviewLineLayout {
    /// 1.0 — chord-only rows share the SAME pixels-per-second as sung rows.
    ///
    /// This was 1.35, which meant a second of music occupied 135 px on an instrumental row and
    /// 100 px on a lyric row: two different horizontal scales in one chart, so a listener could
    /// not read a gap's width as a duration. The readability concern it was solving is already
    /// handled by the `max(chordExtentWidth, …)` floor below — exactly the same way lyric rows
    /// are allowed to grow past raw time width when their word text would collide. Keeping the
    /// constant (rather than deleting it) leaves one named place to change if chord-only rows
    /// ever need their own scale again.
    static let instrumentalReadableScale: CGFloat = 1.0

    /// THE time scale for the chart: one second of song is this many points, on every row and
    /// every row kind. Everything positional derives from it — word x, chord x, row width, the
    /// beat/bar grid, the waveform strip, and the drag-to-retime gesture — so the chart is one
    /// time-based reference rather than a set of independently-sized rows.
    ///
    /// 150, not 100: at 100, measured over every persisted song, 51 % of adjacent word pairs
    /// overlapped at their true time positions and had to be nudged apart; 150 halves that to
    /// 23 %. The tail can't be bought out (p98 needs ~1000 px/s for melismatic and fast-sung
    /// pairs), so crowding is answered here, by widening the scale — never by letting a row grow
    /// past the time it covers.
    ///
    /// Raised again to 200 once row width became time-only: with the text floors gone, a scale
    /// that is too tight no longer shows up as a wider row, it shows up as glyphs crowding each
    /// other, so the scale is the ONLY remaining lever (Eric: "if there is a risk caused by too
    /// low of a pixels per second we should increase it").
    ///
    ///     px/s          150    175    200    225    250    300
    ///     words nudged  26.3%  20.0%  16.9%  14.4%  12.0%   9.8%
    ///     widest row    1505   1755   2006   2257   2508   3009  px
    ///
    /// 200 is where the curve flattens — past it each further 50 px/s buys ~2 points of nudging
    /// for another ~250 px of scroll. Chord labels are not the constraint at any of these values
    /// (0 % overlap from 150 up): they are 1-3 characters and change no faster than a beat.
    static let pixelsPerSecond: CGFloat = 200

    /// Both row kinds follow one rule: width is real duration at `pixelsPerSecond`, widened only
    /// when the row's own text would otherwise collide. For a lyric row that floor comes from the
    /// words; for a chord-only row it comes from the chord columns.
    static func instrumentalWidth(
        rhythmicSpacing: Bool,
        lineDuration: TimeInterval,
        chordColumnExtent: CGFloat,
        characterWidth: CGFloat,
        pixelsPerSecond: CGFloat
    ) -> CGFloat {
        let chordExtentWidth = chordColumnExtent * characterWidth
        // Off the rhythmic axis (or with no duration) there is no time to size by, so the chord
        // columns are all that's left.
        guard rhythmicSpacing, lineDuration > 0 else { return chordExtentWidth }
        // On it, time is the only input — symmetrical with the sung row above. Taking
        // `max(chordExtentWidth, …)` let a row holding many chord columns draw wider than its
        // duration, so instrumental rows drifted off the same axis for the same reason.
        return CGFloat(lineDuration) * pixelsPerSecond * instrumentalReadableScale
    }
}

private struct ChordProPreviewLineView: View {
    private static let lyricFont = PlatformFont.monospacedSystemFont(ofSize: 15, weight: .regular)
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

    /// The chart's one time scale — see `ChordProPreviewLineLayout.pixelsPerSecond`.
    private static let pixelsPerSecond: CGFloat = ChordProPreviewLineLayout.pixelsPerSecond

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
    /// This row's own real start time — the origin `rowChordTimes` are measured from, used to
    /// place each chord glyph time-proportionally on an instrumental (chord-only) row instead of
    /// by its fractional position in the bar-grid TEXT (see `monospaceChordX`).
    var rowStartTime: TimeInterval = 0
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
    /// Authoritative chord onset times for this row (chart order, from `SongTimeline`), with any
    /// manually-dragged chord's time already substituted (backlog #15 Phase 2 remainder — see
    /// `ChordProAppPreview.effectiveRowChordTimes`). When it pairs 1:1 with `line.chords`, chords
    /// render at these times.
    var rowChordTimes: [TimeInterval] = []
    /// The real chord event behind each rendered chord, index-aligned with `line.chords`; `nil`
    /// where there's no live match (edited/legacy charts, or `rowChordTimes` doesn't pair 1:1).
    /// Drives confidence tint, tap-to-accept, and drag-to-reposition.
    var rowChordEvents: [EditableChordEvent?] = []
    var onToggleChordAccepted: (EditableChordEvent.ID) -> Void = { _ in }
    var onSetChordManualTime: (EditableChordEvent.ID, TimeInterval?) -> Void = { _, _ in }
    /// A user-typed correction for this line (backlog #15 Phase 2 remainder). When set, the line
    /// renders as plain corrected text instead of the per-word ASR layout — hand-typed text has
    /// no per-word ASR timings to place rhythmically or bounce the ball over.
    var overrideText: String?
    /// Detected bass notes in this row's time window (onset order). In rhythmic mode each note
    /// renders at its onset's x on the SAME time axis as the chords — previously the names were
    /// a single flush-left label, which read as "clustered against the start of the line".
    var rowBassNotes: [TimedBassNoteLabel] = []

    /// Extra row height reserved above the chords for the positioned bass notes.
    private static let bassRowReserve: CGFloat = 18

    /// Bass-note x positions in rhythmic mode: each note at its onset's x on the words' time
    /// axis (same mapping as authoritative chord times), collisions nudged right like chords.
    private var rhythmicBassXs: [CGFloat] {
        guard !rowBassNotes.isEmpty, !rhythmicWords.isEmpty else { return [] }
        var result: [CGFloat] = []
        var cursor = -CGFloat.greatestFiniteMagnitude
        for note in rowBassNotes {
            let x = max(rhythmicX(forTime: note.time), cursor)
            result.append(x)
            cursor = x + CGFloat(note.name.count + 1) * Self.characterWidth
        }
        return result
    }

    /// Live chord event behind `line.chords[index]`, or `nil` if unmatched.
    private func chordEvent(at index: Int) -> EditableChordEvent? {
        rowChordEvents.indices.contains(index) ? rowChordEvents[index] : nil
    }

    /// Tint for a chord's glyph: clear once accepted (matches `ReviewConfidenceTier.high`'s
    /// "nothing to flag" treatment), else driven by its confidence tier. Unmatched chords (no
    /// live event, e.g. an edited/legacy chart) never tint — there's nothing to accept/drag.
    private func chordTint(at index: Int) -> Color {
        guard let event = chordEvent(at: index), !event.accepted else { return .clear }
        return ReviewConfidenceTier(event.confidence).tint
    }

    /// Confidence marker drawn as a thin outline box around the chord glyph. A solid tinted
    /// background made the light chord text hard to read (amber behind light blue especially),
    /// so the tier color is now an outline only — same `chordTint(at:)` mapping, no fill.
    /// A brief glow on a chord glyph at the moment its onset passes under the playhead, decaying
    /// over the beat it triggers on. The audible chord click answers "is this placement right?"
    /// better than any static picture can, but the click alone leaves you guessing WHICH chord
    /// just fired — this ties the sound to the glyph, so ear and eye agree.
    ///
    /// Decays rather than switching off so the eye reads it as an attack (matching how the click
    /// itself is an exponentially-decaying sample), and so two chords a beat apart never both sit
    /// at full brightness.
    @ViewBuilder
    private func chordOnsetGlow(at index: Int) -> some View {
        let beat = beatLengthSeconds ?? 0.5
        if let now = highlight?.currentTime, rowChordTimes.indices.contains(index), beat > 0 {
            let elapsed = now - rowChordTimes[index]
            if elapsed >= 0, elapsed < beat {
                let intensity = 1 - (elapsed / beat)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.swAmber.opacity(0.35 * intensity))
                    .padding(-2)
                    .shadow(color: .swAmber.opacity(0.9 * intensity), radius: 5 * intensity)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func chordConfidenceOutline(at index: Int) -> some View {
        let tint = chordTint(at: index)
        if tint != .clear {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(tint.opacity(0.9), lineWidth: 1)
                .padding(-2)
        }
    }

    /// Drag-to-reposition (free timestamp, no snapping) + tap-to-accept for one chord glyph.
    /// A drag under 3pt of total travel counts as a tap (toggles `accepted`); anything past that
    /// commits a `manualTime` at the release position, converted from the drag's pixel delta
    /// using `pixelsPerSecond` (the same constant rhythmic-mode positions everything on, so a
    /// drag's visual distance always matches the time it moves the chord by).
    private func chordDragGesture(at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard let event = chordEvent(at: index) else { return }
                let distance =
                    value.translation.width * value.translation.width
                    + value.translation.height * value.translation.height
                guard distance > 9 else {
                    onToggleChordAccepted(event.id)
                    return
                }
                let deltaSeconds = Double(value.translation.width / Self.pixelsPerSecond)
                onSetChordManualTime(event.id, event.effectiveTime + deltaSeconds)
            }
    }

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

    /// Trimmed, non-empty `overrideText`, or `nil` — mirrors `TimedLyricSegment.effectiveText`'s
    /// own trim/empty check.
    private var effectiveOverrideText: String? {
        guard let overrideText else { return nil }
        let trimmed = overrideText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if line.hasSungText, effectiveOverrideText != nil {
                overriddenContent
            } else if rhythmicWords.isEmpty {
                monospaceContent
            } else {
                rhythmicContent
            }
            if !vocalPeaks.isEmpty {
                waveformStrip
            }
        }
    }

    /// A hand-corrected line's render: the chords stay exactly where they already are (still
    /// tintable/tappable), but the lyric text is the user's typed correction rendered as a single
    /// plain string — there's no ASR per-word timing for typed text, so this skips rhythmic
    /// spacing and the bouncing ball for this line only (backlog #15 Phase 2 remainder).
    @ViewBuilder private var overriddenContent: some View {
        ZStack(alignment: .topLeading) {
            Text(effectiveOverrideText ?? "")
                .font(ChordProChartTypography.lyric)
                .foregroundStyle(Color.swTextPrimary)
                .offset(y: line.chords.isEmpty ? 0 : 20)
            ForEach(Array(line.chords.enumerated()), id: \.offset) { index, chord in
                Text(chord.name)
                    .font(ChordProChartTypography.chord(weight: chordWeight(for: chord)))
                    .foregroundStyle(.tint)
                    .overlay(chordOnsetGlow(at: index))
                    .overlay(chordConfidenceOutline(at: index))
                    .offset(x: monospaceChordX(chord, at: index))
                    .onTapGesture {
                        if let event = chordEvent(at: index) {
                            onToggleChordAccepted(event.id)
                        }
                    }
            }
        }
        .frame(width: monospaceWidth, alignment: .topLeading)
    }

    /// Width of this line's rendered content. Measured from the ACTUAL lyric string (not
    /// charCount × "M"-advance), so glyph substitution and any sub-pixel advance differences are
    /// captured — otherwise the rendered text overruns the frame by a few px and the strip below
    /// (which shares this width) ends up visibly shorter than the line. Chord-only lines fall back
    /// to the chord extent. Both the content frame and the strip use this single value so they
    /// always end at exactly the same x.
    private var monospaceWidth: CGFloat {
        let lyricSample = line.hasSungText ? line.lyric : " "
        let lyricWidth = ceil(
            NSString(string: lyricSample).size(withAttributes: [.font: Self.lyricFont]).width)
        let chordExtent =
            CGFloat(line.chords.map { $0.column + $0.name.count }.max() ?? 0) * Self.characterWidth
        return max(Self.characterWidth, lyricWidth, chordExtent)
    }

    /// An instrumental (chord-only) line: chords present, no sung lyric text.
    private var isInstrumentalLine: Bool {
        !line.chords.isEmpty && !line.hasSungText
    }

    /// True once an instrumental row is actually being rendered on the real-duration time axis
    /// (`instrumentalTimeWidth`'s rhythmic branch) rather than the bar-grid text's own character
    /// extent — the condition under which the flat "| . . |" text can no longer visually track
    /// the row's width (see `monospaceContent`).
    private var isTimeScaledInstrumentalLine: Bool {
        isInstrumentalLine && rhythmicSpacing && lineDuration > 0
    }

    /// The chord row's text extent, in characters (rightmost chord column + its name length).
    private var chordColumnExtent: CGFloat {
        CGFloat(line.chords.map { $0.column + $0.name.count }.max() ?? 0)
    }

    /// Width for an instrumental line's content + strip. Rhythmic chord-only rows use their real
    /// duration plus a lyric-like readability scale; without this, lyric rows can grow wider from
    /// word collision avoidance while equal-duration instrumental rows stay on the raw time axis.
    /// Non-rhythmic and unknown-duration rows keep the old chord-text fallback.
    private var instrumentalTimeWidth: CGFloat {
        ChordProPreviewLineLayout.instrumentalWidth(
            rhythmicSpacing: rhythmicSpacing,
            lineDuration: lineDuration,
            chordColumnExtent: chordColumnExtent,
            characterWidth: Self.characterWidth,
            pixelsPerSecond: Self.pixelsPerSecond
        )
    }

    /// X of a chord on an instrumental line. In rhythmic mode (once `instrumentalTimeWidth` is
    /// keyed to real duration, not the bar-grid text's length) a chord's column-fraction position
    /// no longer means anything on that wider axis — it must use its own REAL onset time instead,
    /// same as a word does. `rowChordTimes` is index-aligned with `line.chords`; falls back to the
    /// old column-fraction-of-text positioning when times aren't available 1:1, or off the
    /// rhythmic axis entirely (monospace mode, no duration).
    private func monospaceChordX(_ chord: ChordProPreviewChord, at index: Int) -> CGFloat {
        if isInstrumentalLine, rhythmicSpacing, lineDuration > 0,
            rowChordTimes.indices.contains(index)
        {
            let fraction = (rowChordTimes[index] - rowStartTime) / lineDuration
            return instrumentalTimeWidth * CGFloat(min(max(fraction, 0), 1))
        }
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
        // A row's extent is the TIME it covers, and nothing else. `wordsWidth` — the extent of the
        // words after collision nudging — used to be part of this `max`, which let a line's TEXT
        // stretch it past its real duration. That is what let a short, word-dense line render
        // wider than a long one and knocked every row off the shared axis (Eric: "a short lyric
        // line shouldn't fool the spacing algorithm — these lines represent time — and everything
        // else needs to align to this time-based reference").
        //
        // `trailingEndX` stays in: the trailing melody is real song time beyond the last word, not
        // text. If words now crowd, the answer is `pixelsPerSecond`, not a wider row.
        let endX = rhythmicX(forTime: lineStartTime + lineDuration)
        let trailingEndX =
            trailingMelodySeconds > 0
            ? rhythmicX(forTime: (rhythmicWords.last?.end ?? lineStartTime) + trailingMelodySeconds)
            : 0
        return max(1, max(endX, trailingEndX))
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
        let bassXs = rhythmicBassXs
        let ball = rhythmicBallPosition
        // Reserve space above the content: the full ball reserve when the ball is shown, else a
        // thin row for the beat dots, else nothing (so lines without either keep their height).
        let topReserve: CGFloat =
            ball != nil
            ? Self.ballTopReserve : (dots.isEmpty ? 0 : Self.rhythmicDotTopReserve)
        // Positioned bass-note row (when present) sits between the reserve and the chords;
        // chords/words shift down by this amount so nothing overlaps.
        let bassReserve: CGFloat = bassXs.isEmpty ? 0 : Self.bassRowReserve
        let totalWidth =
            (xs.last ?? 0) + CGFloat(max(words.last?.text.count ?? 1, 1))
            * Self.characterWidth + Self.characterWidth
        let contentHeight = (line.chords.isEmpty ? 20 : 42) + topReserve + bassReserve
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
            ForEach(Array(bassXs.enumerated()), id: \.offset) { index, x in
                // Same size as the chord glyphs and bright green (Eric: "Bass note names
                // should be the same size as chords, and be in bright green").
                Text(rowBassNotes[index].name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.swMint)
                    .offset(x: x, y: topReserve)
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
                    .offset(
                        x: xs[index],
                        y: (line.chords.isEmpty ? 0 : 20) + topReserve + bassReserve)
            }
            ForEach(Array(line.chords.enumerated()), id: \.offset) { index, chord in
                Text(chord.name)
                    .font(ChordProChartTypography.chord(weight: chordWeight(for: chord)))
                    .foregroundStyle(.tint)
                    .overlay(chordOnsetGlow(at: index))
                    .overlay(chordConfidenceOutline(at: index))
                    .offset(x: chordXs[index], y: topReserve + bassReserve)
                    // Free-timestamp drag (no snapping) + tap-to-accept — rhythmic mode has a
                    // true, uniform time axis (`pixelsPerSecond`), so dragging here is exact.
                    .gesture(chordDragGesture(at: index))
            }
            // Rest marker: a short TRUE break after the last word (audit RC-4) — so the pause
            // the musician hears is visible on the chart instead of unexplained blank space.
            if trailingRestSeconds > 0, beatLengthSeconds > 0,
                let lastX = xs.last, let lastWord = words.last
            {
                let restBeats = max(Int((trailingRestSeconds / beatLengthSeconds).rounded()), 2)
                // Plain text, not the musical rest glyph 𝄽 (U+1D13D): no font shipped with
                // macOS covers it (verified via coveredCharacterSet — the system falls back
                // to LastResort), so it rendered as a "?" box (Eric: "what do these ?4
                // symbols mean?").
                Text("rest \(restBeats)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.swTextSecondary.opacity(0.75))
                    .offset(
                        x: lastX + CGFloat(max(lastWord.text.count, 1)) * Self.characterWidth + 10,
                        y: (line.chords.isEmpty ? 0 : 20) + topReserve + bassReserve
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
            height: contentHeight,
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
                // The bar-grid "| . . |" text is a flat monospace string that can't stretch to
                // match `instrumentalTimeWidth` once that's keyed to real duration instead of the
                // text's own character count (see `instrumentalTimeWidth`/`monospaceChordX`) — it
                // would render flush-left at its own short natural width while the chord glyphs
                // (now correctly time-positioned) spread out across the wider row, reading as
                // disconnected from their bar markers. The beat dots above already show the row's
                // structure on the SAME time axis the chords now use, so this row just omits the
                // text here rather than show a misleading, un-stretched copy of it.
                if !isTimeScaledInstrumentalLine {
                    lyricText
                        .offset(y: line.chords.isEmpty ? 0 : 20)
                }

                ForEach(Array(line.chords.enumerated()), id: \.offset) { index, chord in
                    Text(chord.name)
                        .font(
                            .system(
                                size: 13,
                                weight: chordWeight(for: chord),
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.tint)
                        .overlay(chordOnsetGlow(at: index))
                        .overlay(chordConfidenceOutline(at: index))
                        .offset(x: monospaceChordX(chord, at: index))
                        // Monospace mode has no uniform time axis for lyric lines (columns are
                        // typeset over words, not seconds), so only tap-to-accept is offered
                        // here — free-timestamp drag needs rhythmic mode's real time axis.
                        .onTapGesture {
                            if let event = chordEvent(at: index) {
                                onToggleChordAccepted(event.id)
                            }
                        }
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
        // Instrumental (chord-only) rows must NOT take the word-center path: their rendered
        // "lyric" is bar-grid text ("| . . |") whose pipes/dots masquerade as words, and those
        // character columns live in a much narrower space than the time-scaled row width —
        // which packed every dot near the line start. Route them to the time-spread branch
        // below (the same axis the bouncing ball uses at `ballPosition`).
        if !isInstrumentalLine, !beatDots.words.isEmpty || !wordCenters.isEmpty {
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
            return Text(" ").font(ChordProChartTypography.lyric)
        }
        let characters = Array(line.lyric)
        var output = Text("")
        for index in characters.indices {
            let isHighlighted = highlight?.wordRange?.contains(index) == true
            output =
                output
                + Text(String(characters[index]))
                .font(ChordProChartTypography.lyric(weight: isHighlighted ? .bold : .regular))
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
        #if os(macOS)
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
        #else
            errorMessage = "Loading stem folders isn\u{2019}t available on iPad yet."
        #endif
    }

    private func exportMix() {
        #if os(macOS)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = "Stem Mix.wav"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            model.exportStemMix(to: url)
        #endif
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
        // Slightly lighter than the standard `swSurface` panels around it (Eric: "a slighty
        // lighter background to the mixer") — also gives the now-3D controls below somewhere
        // visibly darker (the old `swSurface`) to sit on/cast shadows onto.
        .swSurfacePanel(cornerRadius: 12, fill: .swSurfaceRaised)
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
                .help("Reset all stem levels, mutes, solos, and the master fader")
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
            sourcePicker
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
                    ForEach(mixerChannels) { channel in
                        slimStrip(channel)
                    }
                    slimClickStrip
                    Divider().padding(.horizontal, 2)
                    slimMasterStrip
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Original-vs-Stems switch, replacing the transport bar's old separate per-source Play
    /// buttons (now one Play/Pause button that just acts on whichever source this picks).
    /// Switching preserves play/pause state — see `AppModel.setActivePlaybackSource`.
    private var sourcePicker: some View {
        Picker(
            "Playback Source",
            selection: Binding(
                get: { model.activePlaybackSource },
                set: { model.setActivePlaybackSource($0) }
            )
        ) {
            Text("Original").tag(PlaybackSource.recording)
            Text("Stems").tag(PlaybackSource.stemMix)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!stemPlayback.isLoaded)
        .help(
            stemPlayback.isLoaded
                ? "Play the original recording or the separated stem mix"
                : "Run Stems separation to enable stem mix playback"
        )
    }

    private var mixerChannels: [StemMixerChannel] {
        guard let manifest = model.stemSet ?? model.stemFiles?.stemSetManifest else { return [] }
        return StemMixerChannelProjector.channels(for: manifest)
    }

    private func slimStrip(_ channel: StemMixerChannel) -> some View {
        let state = model.stemMixer[channel.id]
        return VStack(spacing: 4) {
            // Horizontal L/R signal level at the top of the channel, like a console's
            // stereo input meter (post-fader, post-pan).
            HorizontalLRMeter(level: stemPlayback.stemStereoLevels[channel.id] ?? .zero)
                .help("\(channel.displayName) left/right signal level")

            PanKnob(
                value: Binding(
                    get: { Double(model.stemMixer[channel.id].pan) },
                    set: { model.setStemPan(Float($0), for: channel.id) }
                )
            )
            .help(panHelp(for: state.pan, name: channel.displayName))

            HStack(spacing: 2) {
                VerticalFader(
                    value: Binding(
                        get: { Double(model.stemMixer[channel.id].gain) },
                        set: { model.setStemGain(Float($0), for: channel.id) }
                    ),
                    range: 0...Double(StemMixState.maximumGain),
                    thumbWidth: 14,
                    controlWidth: 15
                )
                SegmentedLevelMeter(
                    level: stemPlayback.stemLevels[channel.id] ?? 0, meterWidth: 7)
            }
            .frame(maxHeight: .infinity)
            .help("\(channel.displayName): \(Int((state.gain * 100).rounded()))%")

            VStack(spacing: 2) {
                miniToggle("M", isOn: state.isMuted, tint: Color.swCoral) {
                    model.setStemMuted($0, for: channel.id)
                }
                miniToggle("S", isOn: state.isSoloed, tint: Color.swAccent) {
                    model.setStemSoloed($0, for: channel.id)
                }
            }

            ScribbleStrip(text: shortName(channel.displayName))
        }
        .frame(maxWidth: 38)
    }

    private func panHelp(for pan: Float, name: String) -> String {
        let position: String
        if abs(pan) < 0.01 {
            position = "center"
        } else {
            position = "\(Int((abs(pan) * 100).rounded()))% \(pan < 0 ? "left" : "right")"
        }
        return "\(name) pan: \(position) — drag to move, double-click to center"
    }

    private var slimClickStrip: some View {
        VStack(spacing: 4) {
            // Stand-ins for the L/R meter + pan knob so the click fader aligns with the
            // stem strips (the click is a mono centered reference — no pan).
            Color.clear.frame(height: HorizontalLRMeter.totalHeight)
            Color.clear.frame(height: PanKnob.defaultSize)

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

            HStack(spacing: 2) {
                VerticalFader(
                    value: Binding(
                        get: { Double(stemPlayback.chordClickGain) },
                        set: { stemPlayback.chordClickGain = Float($0) }
                    ),
                    range: 0...Double(StemMixState.maximumGain),
                    thumbWidth: 14,
                    controlWidth: 15
                )
                Color.clear.frame(width: 11)
            }
            .frame(maxHeight: .infinity)
            .help(
                "Higher click at each chord change, where the current placement puts it; 0% is off"
            )

            // Stand-in for the M/S buttons so the scribble strips align.
            Color.clear.frame(height: 14 * 2 + 2)

            ScribbleStrip(text: "Clk")
        }
        .frame(maxWidth: 38)
    }

    /// Overall Stem Mix output, downstream of every stem and the click. Unlike the per-stem
    /// strips, this is never dimmed/disabled by which stems happen to be loaded — it's always
    /// available as long as the mix itself is loaded.
    private var slimMasterStrip: some View {
        VStack(spacing: 4) {
            // Stand-ins for the L/R meter + pan knob so the master fader aligns with the
            // other strips — there's no per-stem meter or pan for the overall bus.
            Color.clear.frame(height: HorizontalLRMeter.totalHeight)
            Color.clear.frame(height: PanKnob.defaultSize)

            HStack(spacing: 2) {
                VerticalFader(
                    value: Binding(
                        get: { Double(model.stemMixer.masterGain) },
                        set: { model.setStemMasterGain(Float($0)) }
                    ),
                    range: 0...Double(StemMixerModel.maximumMasterGain),
                    thumbWidth: 14,
                    controlWidth: 15
                )
                // Width stand-in for the meter so the fader aligns with the other strips.
                Color.clear.frame(width: 11)
            }
            .frame(maxHeight: .infinity)
            .help("Master: \(Int((model.stemMixer.masterGain * 100).rounded()))%")

            // Stand-in for the M/S buttons so the scribble strips align.
            Color.clear.frame(height: 14 * 2 + 2)

            ScribbleStrip(text: "Mst")
        }
        .frame(maxWidth: 38)
    }

    private func shortName(_ displayName: String) -> String {
        switch displayName.lowercased() {
        case "kick": return "Kik"
        case "snare": return "Snr"
        case "cymbals": return "Cym"
        case "toms": return "Tom"
        case "lead": return "Ld"
        case "rhythm": return "Rhy"
        case "vocals": return "Voc"
        case "drums": return "Drm"
        case "bass": return "Bas"
        case "guitar": return "Gtr"
        case "piano": return "Pno"
        case "other": return "Oth"
        default: return String(displayName.prefix(3)).capitalized
        }
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
                .background(
                    // Off: a subtle raised-button gradient (light top edge, dark bottom) so it
                    // reads as a physical key. On: a bright top-to-bottom tint gradient plus a
                    // colored glow underneath — an LED-lit button, not just a color swap.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: isOn
                                    ? [tint, tint.opacity(0.8)]
                                    : [Color.white.opacity(0.08), Color.black.opacity(0.28)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5)
                        )
                        .shadow(color: isOn ? tint.opacity(0.65) : .clear, radius: 2)
                )
        }
        .buttonStyle(.plain)
        .help(label == "M" ? "Mute" : "Solo")
    }
}

/// A slim two-bar horizontal L/R level meter for the top of a channel strip.
private struct HorizontalLRMeter: View {
    var level: StemStereoLevel
    private static let barHeight: CGFloat = 3
    private static let barSpacing: CGFloat = 1
    static let totalHeight: CGFloat = barHeight * 2 + barSpacing

    var body: some View {
        VStack(spacing: Self.barSpacing) {
            bar(fraction: level.left)
            bar(fraction: level.right)
        }
        .frame(height: Self.totalHeight)
    }

    private func bar(fraction: Float) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // Empty track reads as a groove (darker than the panel it sits on); the lit
                // portion gets the same glossy-highlight + glow treatment as the segmented LEDs.
                Capsule().fill(Color.black.opacity(0.35))
                Capsule()
                    .fill(Color.swMint)
                    .overlay {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.5), .clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                    .shadow(color: Color.swMint.opacity(0.6), radius: 1.5)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: Self.barHeight)
    }
}

/// A traditional mixer pan pot: a small rotary knob whose indicator sweeps −135°…+135°
/// (hard left … hard right). Drag right/up to pan right, left/down to pan left;
/// double-click snaps back to center.
private struct PanKnob: View {
    @Binding var value: Double
    static let defaultSize: CGFloat = 20
    var size: CGFloat = PanKnob.defaultSize
    @State private var dragStartValue: Double?

    var body: some View {
        ZStack {
            // Raised dome: a top-lit-to-bottom-shadowed gradient instead of a flat fill, plus a
            // dark outer rim and a thin inner highlight, reads as a real knob rather than a disc.
            Circle().fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.14), Color.swSurface, Color.black.opacity(0.3)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5).padding(0.75)
            // Indicator line from the center toward the rim.
            Capsule()
                .fill(abs(value) < 0.01 ? Color.swTextSecondary : Color.swAccent)
                .frame(width: 2, height: size * 0.38)
                .offset(y: -size * 0.2)
                .rotationEffect(.degrees(value * 135))
        }
        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    if dragStartValue == nil { dragStartValue = value }
                    // Right or up increases; ~90pt of travel spans one full side.
                    let travel = gesture.translation.width - gesture.translation.height
                    let next = (dragStartValue ?? 0) + Double(travel) / 90
                    value = min(max(next, -1), 1)
                }
                .onEnded { _ in dragStartValue = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        .accessibilityLabel("Pan")
        .accessibilityValue(String(format: "%.2f", value))
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
                // Inset groove: darker at the edges than the center, like a channel routed into
                // the console face rather than a flat line drawn on top of it.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.5), Color.black.opacity(0.22),
                                Color.black.opacity(0.5),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: trackWidth)
                Capsule()
                    .fill(Color.swAccent.opacity(0.75))
                    .frame(width: trackWidth, height: thumbHeight / 2 + fraction * travel)
                // Raised cap: light-to-dark gradient + a hairline dark border reads as a real
                // fader cap catching light from above, instead of a flat-color rectangle.
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color.swTextPrimary, Color(white: 0.72)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5)
                    )
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1.5)
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
                let isLit = clamped > threshold
                // Real LED look: a solid color base, a glossy top-half highlight (a lens
                // catching light), and a soft colored glow behind it — instead of one flat
                // fill that just switches color on/off.
                RoundedRectangle(cornerRadius: 1)
                    .fill(isLit ? color(fromBottom) : Color.white.opacity(0.06))
                    .overlay {
                        if isLit {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.55), .clear],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                        }
                    }
                    .shadow(color: isLit ? color(fromBottom).opacity(0.7) : .clear, radius: 1.5)
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
