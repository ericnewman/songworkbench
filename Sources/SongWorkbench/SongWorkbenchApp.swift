import SwiftUI

@main
struct SongWorkbenchApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // The floor must be ≥ the layout's true minimum or SwiftUI CLIPS the outer
                // columns instead of stopping the resize (field-confirmed: the control row's
                // old fixed widths pushed the content minimum past the 1,540 default and the
                // window opened with the song sidebar and stem rail cut off). After moving
                // the editor tab picker into the middle pane and making the scrubber and
                // pitch/speed sliders compressible, the content minimum is ~1,330; 1,380
                // keeps a safety margin.
                .frame(minWidth: 1_380, minHeight: 650)
                .background(Color.swCanvas.ignoresSafeArea())
                .foregroundStyle(Color.swTextPrimary)
                .tint(Color.swAccent)
                .preferredColorScheme(.dark)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification)
                ) { _ in
                    model.flushPendingSave()
                }
        }
        // Explicit initial size so the window opens wide enough, on first launch, to show all 3
        // main sections of `PlayerView.mainColumns` at once (fixed-width song sidebar + the
        // flexible editor column + the stem-mix rail) without the user having to drag it wider —
        // the old `minWidth: 1_100` floor left the flexible editor column only ~410pt once the
        // ~690pt of fixed columns/spacing/padding around it were subtracted.
        .defaultSize(width: 1_540, height: 900)
        Window("About \(AboutInfo.appName)", id: "about") {
            AboutView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        Window("Lyric Blend", id: "lyricBlend") {
            LyricBlendView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 720, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommandButton()
            }
            CommandGroup(replacing: .newItem) {
                Button("Import Songs...") {
                    model.isImporterPresented = true
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Playback") {
                Button(model.isActivePlaybackPlaying ? "Pause" : "Play") {
                    model.toggleActivePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedSong == nil)

                Button("Back 10 Seconds") {
                    model.skipActivePlayback(by: -10)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(model.selectedSong == nil)

                Button("Forward 10 Seconds") {
                    model.skipActivePlayback(by: 10)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(model.selectedSong == nil)

                Divider()

                Button("Original Pitch and Tempo") {
                    model.pitchSemitones = 0
                    model.tempoRate = 1
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            CommandMenu("Analysis") {
                Button("Analyze Selected Song") {
                    model.analyzeSelectedSong(replaceExistingChordPro: true)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isSongAnalysisRunning || model.selectedSong == nil)

                Button("Re-analyze All Songs") {
                    model.reanalyzeAllSongs()
                }
                .disabled(model.isSongAnalysisRunning || model.songs.isEmpty)
            }

            CommandMenu("Recent Songs") {
                if model.songs.isEmpty {
                    Text("No Recent Songs")
                } else {
                    ForEach(model.recentSongs.prefix(10)) { song in
                        Button(song.title) { model.select(song) }
                    }
                }
            }
        }
    }
}

private struct AboutCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About \(AboutInfo.appName)") {
            openWindow(id: "about")
        }
    }
}

// The Lyric Blend window is no longer auto-opened when results are ready (Eric: "don't pop
// open the Lyric Blend window — have an icon light up instead"). `model.lyricBlendReadySongID`
// now drives the glowing indicator on `SongActionsCard`'s Lyric Blend button, and is cleared
// when the user opens the window from there.
