import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(model.songs) { song in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title)
                                .lineLimit(1)
                            Text(song.fileExtension)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            } header: {
                Text("Songs")
                    .font(.swDisplay(12, weight: .semibold))
                    .foregroundStyle(Color.swTextSecondary)
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

/// Header card with the library/analysis actions as full labeled buttons — the same
/// actions that used to be tiny icon-only items in the window toolbar.
private struct SongActionsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.swDisplay(11))
                .foregroundStyle(Color.swTextSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.swSurface, in: Capsule())

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button("Import Songs", systemImage: "plus") {
                        model.isImporterPresented = true
                    }
                    Button("Open from Music", systemImage: "music.note") {
                        model.isMusicLibraryPickerPresented = true
                    }
                }
                GridRow {
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
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
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

    init(model: AppModel) {
        self.model = model
        playback = model.playback
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left column: the song list on top, the tool cards below it (resizable divider), so
            // the editor gets the whole rest of the window.
            VSplitView {
                SongSidebar(model: model)
                    .frame(minHeight: 150, idealHeight: 300)
                ScrollView {
                    VStack(spacing: 18) {
                        waveformContent
                        AnalysisWorkspaceView(model: model)
                    }
                    .padding(12)
                }
                .frame(minHeight: 220)
            }
            .frame(width: 380)

            // Main column: the segment/editor view, maximized. The playback transport sits in
            // the upper-left corner of this column so play/pause/rewind stays available across
            // ALL editor views (Lyrics, Stems, ChordPro), not just when the sidebar shows it.
            VStack(alignment: .center, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    PlaybackTransportCard(model: model)
                        .frame(width: 320)
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
                        .padding(.top, 8)
                    } else {
                        Spacer()
                    }
                    // Library/analysis actions as real labeled buttons (formerly tiny
                    // window-toolbar icons), in a header card matching the transport.
                    SongActionsCard(model: model)
                }

                Picker("Editor", selection: $selectedEditor) {
                    ForEach(EditorTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 680)
                .background {
                    // ⌘1…⌘5 switch editor tabs (also enables hands-free navigation).
                    ForEach(Array(EditorTab.allCases.enumerated()), id: \.element) { index, tab in
                        Button("Show \(tab.title)") { selectedEditor = tab }
                            .keyboardShortcut(
                                KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    }
                    .opacity(0)
                    .accessibilityHidden(true)
                }

                if model.selectedSong != nil {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
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
                        // collapsible so the editor can reclaim the width.
                        StemMixSidebar(model: model)
                            .frame(width: stemRailExpanded ? 250 : 44)
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
