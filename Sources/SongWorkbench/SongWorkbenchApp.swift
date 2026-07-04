import SwiftUI

@main
struct SongWorkbenchApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1_100, minHeight: 650)
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
                .modifier(LyricBlendAutoOpen(model: model))
        }
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

/// Auto-opens the "Lyric Blend" window once `model.lyricBlendReadySongID` is set (backlog #11:
/// "on analysis complete, open a new Lyric Blend window for the selected song"). Resets the
/// signal immediately after opening so it doesn't re-fire if the same song is re-selected later.
private struct LyricBlendAutoOpen: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: model.lyricBlendReadySongID) { _, newValue in
            guard newValue != nil else { return }
            openWindow(id: "lyricBlend")
            model.lyricBlendReadySongID = nil
        }
    }
}
