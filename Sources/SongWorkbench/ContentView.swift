import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SongSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            Group {
                if let song = model.selectedSong {
                    PlayerView(song: song, model: model)
                } else {
                    ContentUnavailableView(
                        "No Song Selected",
                        systemImage: "music.note.list",
                        description: Text("Import an audio file to begin.")
                    )
                }
            }
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
    }
}

private struct SongSidebar: View {
    @ObservedObject var model: AppModel

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
        .navigationTitle("Songs")
        .toolbar {
            Button("Remove Selected Song", systemImage: "trash") {
                if let song = model.selectedSong {
                    model.removeSong(song)
                }
            }
            .disabled(model.selectedSong == nil)

            Button("Import Songs", systemImage: "plus") {
                model.isImporterPresented = true
            }
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

private struct PlayerView: View {
    let song: Song
    @ObservedObject var model: AppModel
    @ObservedObject private var playback: AudioPlaybackService
    @ObservedObject private var stemPlayback: StemPlaybackService
    @State private var waveformZoom = 1.0
    @State private var selectedEditor: EditorTab = .lyrics

    init(song: Song, model: AppModel) {
        self.song = song
        self.model = model
        playback = model.playback
        stemPlayback = model.stemPlayback
    }

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
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

            Picker("Editor", selection: $selectedEditor) {
                ForEach(EditorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 680)

            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(spacing: 18) {
                        waveformContent
                        PlaybackTransportCard(model: model)
                        PitchSpeedCard(model: model)
                        AnalysisWorkspaceView(model: model)
                    }
                    .padding(.trailing, 4)
                }
                .frame(minWidth: 380, idealWidth: 400, maxWidth: 440)

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
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    ScrollView(.horizontal) {
                        WaveformView(
                            envelope: waveform,
                            currentTime: model.activePlaybackTime,
                            loopRegion: $model.loopRegion
                        )
                        // Fill the card at 1x; widen (and scroll) as zoom increases.
                        .frame(
                            width: max(geo.size.width, geo.size.width * waveformZoom), height: 100)
                    }
                    .scrollIndicators(.visible)
                }
                .frame(height: 100)
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

}
