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
        }
        .commands {
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
