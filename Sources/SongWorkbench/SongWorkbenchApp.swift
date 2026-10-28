import SwiftUI

// @main lives on `SongWorkbenchMain`, which dispatches to the headless CLI for known
// subcommands and to this App otherwise.
struct SongWorkbenchApp: App {
    @StateObject private var model = AppModel()

    init() {
        // iPadOS requires an AVAudioSession category before any AVAudioEngine render/IO
        // starts (silent output otherwise); this is a no-op on macOS.
        PlatformAudioSession.configureForPlayback()
        EndogenFonts.registerBundled()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // The floor must be ≥ the layout's true minimum or SwiftUI CLIPS the outer
                // columns instead of stopping the resize (field-confirmed: the control row's
                // old fixed widths pushed the content minimum past the 1,540 default and the
                // window opened with the song sidebar and stem rail cut off). After moving
                // the editor tab picker into the middle pane and making the scrubber and
                // pitch/speed sliders compressible, the content minimum is ~1,330 with the
                // 360 pt stem rail open. Below `PlayerView.compactWidthThreshold` (1,380) the
                // rail collapses to its 44 pt strip and opens as a popover, which takes ~316 pt
                // off that minimum; 1,080 keeps a margin and fits a 1,280 pt display.
                .frame(minWidth: 1_080, minHeight: 650)
                .modifier(SplashOverlay(isReady: model.hasRestoredProjects))
                .background(Color.swCanvas.ignoresSafeArea())
                .foregroundStyle(Color.swTextPrimary)
                .tint(Color.swAccent)
                // a11y-exception: dark-only by design (the Endogen Night/phosphor brand; a
                // scope-style tool used on stage and in dim rooms). Compensation: every text and
                // UI color is checked against the dark grounds only (`ThemeContrastTests`),
                // and Increase Contrast swaps Mist for Text and drops opacity dimming
                // (`Color.swHighContrastAware`, `Color.swDimmed`).
                .preferredColorScheme(.dark)
                .font(.swDisplay(13))
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: PlatformLifecycle.willTerminateNotification)
                ) { _ in
                    model.flushPendingSave()
                }
        }
        #if os(macOS)
            // Explicit initial size so the window opens wide enough, on first launch, to show
            // all 3 main sections of `PlayerView.mainColumns` at once (fixed-width song sidebar
            // + the flexible editor column + the stem-mix rail) without the user having to drag
            // it wider — the old `minWidth: 1_100` floor left the flexible editor column only
            // ~410pt once the ~690pt of fixed columns/spacing/padding around it were subtracted.
            .defaultSize(width: 1_540, height: 900)
        #endif
        #if os(macOS)
            Window("About \(AboutInfo.appName)", id: "about") {
                AboutView()
                    .preferredColorScheme(.dark)
                    .font(.swDisplay(13))
            }
            .windowResizability(.contentSize)
            Settings {
                TabView {
                    AnalysisWorkspaceView(model: model)
                        .tabItem {
                            Label("Analysis", systemImage: "waveform.badge.magnifyingglass")
                        }
                    MIDIInstrumentSettingsView(model: model)
                        .tabItem { Label("MIDI Instruments", systemImage: "pianokeys") }
                    TextSizeSettingsView()
                        .tabItem { Label("Text", systemImage: "textformat.size") }
                }
                .preferredColorScheme(.dark)
                .font(.swDisplay(13))
            }
            Window("Lyric Blend", id: "lyricBlend") {
                LyricBlendView(model: model)
                    .preferredColorScheme(.dark)
                    .font(.swDisplay(13))
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
                CommandGroup(before: .toolbar) {
                    TextSizeCommands()
                    Divider()
                }

                CommandMenu("Playback") {
                    // No `.keyboardShortcut(.space, ...)` here: AppKit checks the main menu's
                    // key equivalents BEFORE the responder chain, even for unmodified keys, so
                    // an unconditional space shortcut steals space out of every TextField/
                    // TextEditor in the app before it can self-insert. Space-to-toggle is instead
                    // handled by a first-responder-aware NSEvent monitor (`ContentView`'s
                    // `installSpaceBarPlaybackToggle`), which only fires when nothing is being
                    // actively edited. This menu item remains for click/discoverability.
                    Button(model.isActivePlaybackPlaying ? "Pause" : "Play") {
                        model.toggleActivePlayback()
                    }
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

                    Divider()

                    Button("Move Models and Stems…") {
                        chooseBulkStorageLocation(model)
                    }
                    .disabled(!model.canMoveBulkStorage)
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
        #endif
    }
}

#if os(macOS)
    /// Asks for a folder, confirms, and hands it to `AppModel.moveBulkStorage(to:)`.
    @MainActor private func chooseBulkStorageLocation(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for SongWorkbench's models and stems."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let size = ByteCountFormatter.string(
            fromByteCount: BulkStorageLocation.movableSize(), countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Move models and stems to “\(folder.lastPathComponent)”?"
        alert.informativeText = """
            \(size) moves to \(folder.path). SongWorkbench quits when the move finishes; open \
            it again to continue. Keep this drive connected whenever you use SongWorkbench.
            """
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.moveBulkStorage(to: folder)
    }
#endif

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

/// View › Bigger Text / Smaller Text / Actual Text Size. macOS has no system Dynamic Type for
/// SwiftUI, so the app scales its own text (`SWTextScale`).
private struct TextSizeCommands: View {
    private var textScale = SWTextScale.shared

    var body: some View {
        Button("Bigger Text") { textScale.increase() }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!textScale.canIncrease)
        Button("Smaller Text") { textScale.decrease() }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!textScale.canDecrease)
        // ⌥⌘0, not ⌘0: ⌘0 is Playback › Original Pitch and Tempo.
        Button("Actual Text Size") { textScale.reset() }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(textScale.factor == 1)
    }
}

/// Settings › Text: the app-wide text size.
struct TextSizeSettingsView: View {
    private var textScale = SWTextScale.shared

    var body: some View {
        Form {
            Picker(
                "Text size",
                selection: Binding(
                    get: { textScale.factor },
                    set: { textScale.factor = $0 }
                )
            ) {
                ForEach(SWTextScale.steps, id: \.self) { step in
                    Text(step, format: .percent.precision(.fractionLength(0))).tag(step)
                }
            }
            Text(
                "Scales the text throughout SongWorkbench, including the chord chart. Use View › Bigger Text (⌘+) and Smaller Text (⌘−) to change it from anywhere."
            )
            .font(.swDisplay(11))
            .foregroundStyle(Color.swTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Sample: Verse 1 · G  D/F#  Em  C")
                .font(.swDisplay(13))
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
