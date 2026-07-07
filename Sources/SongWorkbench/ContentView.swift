import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            PlayerView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.swCanvas)
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            model.handleSongImportResult(result)
        }
        .sheet(isPresented: $model.isMusicLibraryPickerPresented) {
            MusicLibraryPickerView(model: model)
        }
    }
}

private struct SongSidebar: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false
    @FocusState private var listFocused: Bool
    /// Collapsed/expanded state of the whole song list, persisted across launches. Shares its
    /// UserDefaults key with `PlayerView.mainColumns` (multiple `@AppStorage` readers/writers of
    /// the same key stay in sync) so the outer frame can shrink to match. Added 2026-07-06: on
    /// iPad the list ate a lot of vertical space even with one song selected — collapsing to a
    /// single current-song row frees that space for the analysis tool cards below.
    @AppStorage("songSidebarExpanded") private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                songList
            } else {
                collapsedRow
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importSongs(from: urls)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.swAccent, lineWidth: 2)
                    .background(Color.swAccent.opacity(0.08))
                    .overlay {
                        Label(
                            "Drop audio files or folders to add",
                            systemImage: "square.and.arrow.down"
                        )
                        .font(.swDisplay(13, weight: .medium))
                        .foregroundStyle(Color.swAccent)
                    }
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Songs")
        .hideSystemNavigationBarCompat()
        .focused($listFocused)
        .task { listFocused = true }
        // Selecting a song programmatically (type-to-select) can move first-responder to the new
        // row; re-assert list focus so the next typed character keeps refining the same prefix.
        .onChange(of: model.selectedSongID) { listFocused = true }
        // Type-to-select: alphanumeric/space/punctuation keys jump to the first matching song title;
        // arrows/Return fall through to the List's own selection navigation.
        .onKeyPress(
            characters: CharacterSet.alphanumerics.union(.whitespaces).union(.punctuationCharacters)
        ) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
                return .ignored
            }
            return model.typeToSelect(press.characters) ? .handled : .ignored
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.swTextSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Songs")
                        .font(.swDisplay(12, weight: .semibold))
                        .foregroundStyle(Color.swTextSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse song list" : "Expand song list")
            // Moved up from a dedicated footer bar at the bottom of the window (2026-07-06,
            // Eric: "move the Ready indicator into the top of the screen and delete the
            // footer bar to save space") — this header row is visible in every state
            // (expanded or collapsed), so it's always on screen without its own chrome.
            BackgroundStatusBar(model: model)
            Spacer()
            // Library actions live with the library list.
            Button("Import Songs", systemImage: "plus") {
                model.isImporterPresented = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Import audio files")
            Button("Open from Music", systemImage: "music.note") {
                model.isMusicLibraryPickerPresented = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Open a track from your Music library")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, isExpanded ? 4 : 8)
    }

    private var songList: some View {
        List(selection: selection) {
            ForEach(model.songs) { song in
                HStack(spacing: 8) {
                    // File format (MP3/M4A) used to show as a caption under the title —
                    // dropped (2026-07-06) to tighten row height in the iPad song list,
                    // where the extra line made titles feel far apart. Title-only rows
                    // pack closer together on both platforms.
                    Text(song.title)
                        .lineLimit(1)
                    Spacer()
                    Button("Remove Song", systemImage: "trash") {
                        model.removeSong(song)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.swCoral)
                }
                .contextMenu {
                    Button("Remove Song", systemImage: "trash", role: .destructive) {
                        model.removeSong(song)
                    }
                }
                .tag(song.id)
            }
        }
    }

    /// Shown when collapsed: just the current song, tappable to expand back to the full list.
    private var collapsedRow: some View {
        Button {
            withAnimation(.snappy) { isExpanded = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.swTextSecondary)
                Text(model.selectedSong?.title ?? "No song selected")
                    .font(.swDisplay(13))
                    .foregroundStyle(Color.swTextPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .help("Expand song list")
    }

    private var selection: Binding<Song.ID?> {
        Binding(
            get: { model.selectedSongID },
            set: { newID in
                guard
                    let newID,
                    newID != model.selectedSongID,
                    let song = model.songs.first(where: { $0.id == newID })
                else { return }
                model.select(song)
            }
        )
    }
}

/// Compact inline status indicator — shows whatever the app is doing in the background
/// (importing/copying a song, analyzing, exporting, downloading a model, loading a waveform)
/// so long-running work is never invisible. Lives in `SongSidebar`'s header row at the top of
/// the window; used to be its own full-width footer bar at the bottom, which cost a whole row
/// of vertical space for one line of text (2026-07-06, Eric: move it up, drop the footer).
private struct BackgroundStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if let status = model.backgroundActivityStatus {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text(status)
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Circle()
                    .fill(Color.swMint.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text("Ready")
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextSecondary)
            }
        }
        .layoutPriority(-1)
    }
}

/// Header card with the library/analysis actions as full labeled buttons — a single thin
/// row matching the playback bar's height.
private struct SongActionsCard: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            // Lyric Blend results no longer pop their window open on analysis completion;
            // this button's mint glow is the "ready" indicator instead (Eric's request).
            Button("Lyric Blend", systemImage: "square.stack.3d.up") {
                openWindow(id: "lyricBlend")
                model.lyricBlendReadySongID = nil
            }
            .labelStyle(.iconOnly)
            .disabled(model.lyricBlendRows.isEmpty)
            .foregroundStyle(
                model.lyricBlendReadySongID != nil ? Color.swMint : Color.swTextPrimary
            )
            .overlay(alignment: .topTrailing) {
                if model.lyricBlendReadySongID != nil {
                    Circle()
                        .fill(Color.swMint)
                        .frame(width: 7, height: 7)
                        .offset(x: 4, y: -4)
                }
            }
            .help(
                model.lyricBlendReadySongID != nil
                    ? "New Lyric Blend results are ready — click to review"
                    : "Open the Lyric Blend window")
            Button("Remove Song", systemImage: "trash") {
                if let song = model.selectedSong {
                    model.removeSong(song)
                }
            }
            .disabled(model.selectedSong == nil)
            .help("Remove the selected song from the library (the file is kept)")
            AnalyzeSongButton(model: model)
                .buttonStyle(.borderedProminent)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .swSurfacePanel(cornerRadius: 12)
        .fixedSize()
    }
}

private struct PlayerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var playback: AudioPlaybackService
    @State private var waveformZoom = 1.0
    @State private var selectedEditor: EditorTab = .lyrics
    /// Mirrors the stem-mix rail's own expansion state so the rail's WIDTH shrinks too.
    @AppStorage(StemMixSidebar.expansionDefaultsKey) private var stemRailExpanded = true
    /// Initial height of the songs list in the left split: the persisted value from the
    /// last session, defaulting to a third of the screen. Captured ONCE at init (the split
    /// view owns the height after that; we only record the user's adjustments).
    @State private var songListIdealHeight: CGFloat
    private static let songListHeightDefaultsKey = "songListHeight"
    /// Mirrors `SongSidebar`'s own collapse state (same key) so the OUTER frame shrinks too —
    /// otherwise a collapsed one-row list would still reserve a 150pt-minimum column.
    @AppStorage("songSidebarExpanded") private var songSidebarExpanded = true
    /// Height of the collapsed single-song row: header + one compact row, no list chrome.
    private static let collapsedSongListHeight: CGFloat = 76

    init(model: AppModel) {
        self.model = model
        playback = model.playback
        let stored = UserDefaults.standard.double(forKey: Self.songListHeightDefaultsKey)
        let screenThird = PlatformScreen.visibleHeight(fallback: 900) / 3
        _songListIdealHeight = State(initialValue: stored >= 150 ? stored : screenThird)
    }

    var body: some View {
        mainColumns
    }

    /// The Structure/Lyrics/Chords/ChordPro/Review segmented control, shown centered at the
    /// top of the middle (editor) pane. ⌘1…⌘5 shortcuts ride along in a hidden background.
    private var editorTabPicker: some View {
        Picker("Editor", selection: $selectedEditor) {
            ForEach(EditorTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 280, maxWidth: 560)
        .background {
            // ⌘1…⌘4 switch editor tabs (also enables hands-free navigation).
            ForEach(
                Array(EditorTab.allCases.enumerated()), id: \.element
            ) { index, tab in
                Button("Show \(tab.title)") { selectedEditor = tab }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var mainColumns: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left column: the song list on top, the tool cards below it (resizable divider), so
            // the editor gets the whole rest of the window.
            PlatformVSplit {
                SongSidebar(model: model)
                    .frame(
                        minHeight: songSidebarExpanded ? 150 : Self.collapsedSongListHeight,
                        idealHeight: songSidebarExpanded
                            ? songListIdealHeight : Self.collapsedSongListHeight,
                        maxHeight: songSidebarExpanded ? .infinity : Self.collapsedSongListHeight
                    )
                    // Persist divider adjustments so the songs area keeps its height across
                    // sessions (default: a third of the screen). Skipped while collapsed — that
                    // height is fixed, not a user-chosen divider position.
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.height) { _, height in
                                guard songSidebarExpanded, height >= 150 else { return }
                                UserDefaults.standard.set(
                                    Double(height), forKey: Self.songListHeightDefaultsKey)
                            }
                        }
                    )
                ScrollView {
                    VStack(spacing: 18) {
                        waveformContent
                        AnalysisWorkspaceView(model: model)
                    }
                    .padding(12)
                }
                .frame(minHeight: 220)
            }
            // 360 matches the expanded stem rail exactly (Eric: same width for the first and
            // last columns, for visual symmetry).
            .frame(width: 360)

            // Main column: the segment/editor view, maximized. The playback bar spans the
            // full width up top (thin, scrubber gets the extra width) so play/pause/seek
            // stays available across ALL editor views (Lyrics, Stems, ChordPro).
            VStack(alignment: .center, spacing: 12) {
                // Title first, then one thin row: playback controls left, actions right.
                if let song = model.selectedSong {
                    VStack(spacing: 4) {
                        Text(song.title)
                            .font(.swDisplay(22, weight: .semibold))
                            .foregroundStyle(Color.swTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(song.url.lastPathComponent)
                            .font(.swMono(11))
                            .foregroundStyle(Color.swTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                }

                // ONE control row — playback · song actions. The editor tab picker lives at
                // the top of the middle pane instead (Eric: "move the segmented control into
                // the middle pane to save horizontal space in the tool bar") — with it here,
                // the row's minimum width exceeded the default window's middle column and the
                // whole layout clipped the outer panes.
                HStack(alignment: .center, spacing: 12) {
                    PlaybackTransportCard(model: model)

                    Spacer(minLength: 8)

                    // Library/analysis actions as real labeled buttons, matching the bar.
                    SongActionsCard(model: model)
                }

                if model.selectedSong != nil {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            editorTabPicker
                            WorkspaceEditorsView(model: model, selectedEditor: selectedEditor)
                            if let error = playback.errorMessage ?? model.projectErrorMessage {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.swCoral)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        // Right rail: a slim copy of the Stems console (full-height vertical
                        // faders + VU meters), persistent across ALL editor views and
                        // collapsible so the editor can reclaim the width. 360 expanded =
                        // same width as the song sidebar (visual symmetry; also gives the
                        // channel strips room for the planned L/R meters + pan pots).
                        StemMixSidebar(model: model)
                            .frame(width: stemRailExpanded ? 360 : 44)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ContentUnavailableView(
                        "No Song Selected",
                        systemImage: "music.note.list",
                        description: Text("Import an audio file to begin.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
    }

    @ViewBuilder
    private var waveformContent: some View {
        if let waveform = model.waveform {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Label("Waveform", systemImage: "waveform")
                        .font(.swDisplay(15, weight: .semibold))
                        .foregroundStyle(Color.swTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if !model.vocalActivityIntervals.isEmpty {
                        Text("· \(model.vocalActivityIntervals.count) vocal regions")
                            .font(.swDisplay(11))
                            .foregroundStyle(Color.swAmber)
                    }
                    Spacer()
                    Button {
                        if model.isLoopPlaying {
                            model.toggleActivePlayback()
                        } else {
                            model.playLoopRegion()
                        }
                    } label: {
                        Label(
                            model.isLoopPlaying ? "Stop Loop" : "Play Loop",
                            systemImage: model.isLoopPlaying ? "stop.fill" : "repeat"
                        )
                    }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
                    .disabled(!model.canPlayLoop)
                    .help(
                        model.isLoopPlaying
                            ? "Stop loop playback"
                            : "Play the selected loop region (repeats until stopped)")
                    Button {
                        model.clearLoop()
                    } label: {
                        Label("Clear Loop", systemImage: "xmark.circle")
                    }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
                    .disabled(model.loopRegion == nil)
                }

                HStack(alignment: .center, spacing: 8) {
                    Text("Zoom")
                        .font(.swDisplay(11))
                        .foregroundStyle(Color.swTextSecondary)
                        .frame(width: 38, alignment: .leading)
                    Slider(value: $waveformZoom, in: 1...8, step: 0.5)
                        .frame(maxWidth: .infinity)
                    Text("\(waveformZoom, format: .number.precision(.fractionLength(1)))x")
                        .font(.swMono(11))
                        .foregroundStyle(Color.swTextSecondary)
                        .frame(width: 32, alignment: .trailing)
                }

                GeometryReader { geo in
                    let laneWidth = max(geo.size.width, geo.size.width * waveformZoom)
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 14) {
                            WaveformView(
                                envelope: waveform,
                                currentTime: model.activePlaybackTime,
                                loopRegion: $model.loopRegion,
                                // Vocal activity is shown in its own Vocals stem lane below rather
                                // than overlaid here, so it no longer sits on top of the full mix.
                                onSeek: { model.seekActivePlayback(to: $0) }
                            )
                            // Fill the card at 1x; widen (and scroll) as zoom increases.
                            .frame(width: laneWidth, height: 64)

                            // One waveform lane per available stem, sharing the mix's time axis so
                            // each instrument's energy lines up vertically with the mix above.
                            if !model.stemWaveforms.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(model.stemWaveforms, id: \.kind) { entry in
                                        ZStack(alignment: .leading) {
                                            StemWaveformLane(
                                                envelope: entry.envelope,
                                                color: Self.stemColor(for: entry.kind),
                                                totalDuration: waveform.duration
                                            )
                                            .frame(width: laneWidth)
                                            Text(entry.kind.rawValue.capitalized)
                                                .font(.swDisplay(11))
                                                .foregroundStyle(Self.stemColor(for: entry.kind))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(
                                                    Color.swCanvas.opacity(0.55),
                                                    in: RoundedRectangle(
                                                        cornerRadius: 4, style: .continuous)
                                                )
                                                .padding(.leading, 4)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .scrollIndicators(.visible)
                }
                .frame(height: waveformPanelHeight)
                .frame(maxWidth: .infinity, alignment: .leading)

                PlaybackProgressSlider(model: model)
            }
            .padding(10)
            .swSurfacePanel(cornerRadius: 12)
        } else if model.isLoadingWaveform {
            ProgressView("Generating waveform...")
                .frame(height: 120)
        } else {
            ContentUnavailableView("Waveform Unavailable", systemImage: "waveform")
                .frame(height: 120)
        }
    }

    /// Total height of the waveform + stacked-stem-lane area. The main mix lane is 64pt; each stem
    /// lane is 26pt with 2pt spacing, plus 4pt between the mix and the stem stack.
    private var waveformPanelHeight: CGFloat {
        let topPadding: CGFloat = 6
        let mixHeight: CGFloat = 64
        let laneCount = model.stemWaveforms.count
        guard laneCount > 0 else { return topPadding + mixHeight }
        let laneHeight: CGFloat = 26
        let laneSpacing: CGFloat = 2
        let mixToStackGap: CGFloat = 14
        let stackHeight =
            CGFloat(laneCount) * laneHeight + CGFloat(max(laneCount - 1, 0)) * laneSpacing
        return topPadding + mixHeight + mixToStackGap + stackHeight
    }

    /// Distinct color per stem so each lane is visually identifiable at a glance.
    private static func stemColor(for kind: StemKind) -> Color {
        kind.laneColor
    }

}
