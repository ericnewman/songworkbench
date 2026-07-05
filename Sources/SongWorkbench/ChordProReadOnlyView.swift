import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A true, spec-exact ChordPro renderer for the `chordPro` tab (backlog #15): chords positioned
/// above lyric text at their recorded column, nothing else. No waveform, no bouncing ball, no
/// beat dots, no playback highlight — that overlay chrome lives entirely in the Review tab
/// (`ChordProReviewTab` → `ChordProTabEditor` → `ChordProAppPreview`), which is left untouched.
/// This view exists so `EditorTab.chordPro` shows only what a real .cho file can express.
struct ChordProReadOnlyView: View {
    let source: String
    var transpose: Int = 0

    private static let font = Font.system(.body, design: .monospaced)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("chordpro-readonly-view")
    }

    @ViewBuilder
    private var content: some View {
        switch previewResult {
        case .success(let document):
            if document.blocks.isEmpty {
                ContentUnavailableView(
                    "No ChordPro Yet",
                    systemImage: "doc.plaintext",
                    description: Text("Run Tempo & Chords and Transcribe to generate a chart.")
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(for: block)
                    }
                }
            }
        case .failure(let error):
            ContentUnavailableView(
                "ChordPro Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription)
            )
        }
    }

    private var previewResult: Result<ChordProPreviewDocument, Error> {
        Result {
            let document = try ChordProDocument(parsing: source)
            return ChordProPreviewDocument(document: document.transposed(by: transpose))
        }
    }

    @ViewBuilder
    private func blockView(for block: ChordProPreviewBlock) -> some View {
        switch block {
        case .title(let title):
            Text(title)
                .font(.title2.bold())
                .padding(.bottom, 2)
        case .metadata(let label, let value):
            HStack(spacing: 5) {
                Text(label + ":").foregroundStyle(.secondary)
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
            lyricLineView(line)
        case .directive(let directiveSource):
            Text(directiveSource)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    private func lyricLineView(_ line: ChordProPreviewLine) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !line.chords.isEmpty {
                Text(ChordRowStringBuilder.build(chords: line.chords))
                    .font(Self.font)
                    .foregroundStyle(Color.swAccent)
            }
            Text(line.lyric.isEmpty ? " " : line.lyric)
                .font(Self.font)
                .foregroundStyle(Color.swTextPrimary)
        }
    }
}

/// Builds a ChordPro line's chord row as a plain string with each chord placed at its recorded
/// character column, padding with spaces — the standard "chords over lyrics" convention. A
/// standalone (non-view) type so the column-placement logic is unit-testable without SwiftUI.
enum ChordRowStringBuilder {
    /// Chords are visited in column order; if a chord's own column would land inside the
    /// PREVIOUS chord's name, it's pushed one space past it instead of overlapping, since two
    /// chords can't literally occupy the same characters in a monospaced render.
    static func build(chords: [ChordProPreviewChord]) -> String {
        var characters: [Character] = []
        var cursor = 0
        for chord in chords.sorted(by: { $0.column < $1.column }) {
            let column = max(chord.column, cursor)
            if characters.count < column {
                characters.append(contentsOf: repeatElement(" ", count: column - characters.count))
            }
            characters.append(contentsOf: chord.name)
            cursor = characters.count + 1
        }
        return String(characters)
    }
}

/// Formats detected bass notes for the Review tab's optional bass-note row (backlog: Bass Note
/// display). A standalone (non-view) type so the windowing/formatting logic is unit-testable
/// without SwiftUI, mirroring `ChordRowStringBuilder`.
enum BassNoteRowFormatter {
    /// Bass notes within `window`, pitch-named and joined in onset order — e.g. "E · A · D".
    /// `nil` when nothing falls in the window, so callers can skip rendering the row entirely.
    static func label(
        for bassNotes: [BassNoteObservation], inWindow window: ClosedRange<TimeInterval>
    ) -> String? {
        let notes =
            bassNotes
            .filter { window.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !notes.isEmpty else { return nil }
        return notes.map { BassNoteNaming.name(forMidiNote: $0.midiNote) }.joined(separator: " · ")
    }
}

/// The `chordPro` tab's chrome: just a title, transpose (a real ChordPro concept — transposing
/// changes what chords the .cho file itself displays) and export, wrapping the read-only render.
/// Deliberately has none of `ChordProTabEditor`'s Edit/Source toggle, Import, JustChords, or Mark
/// Reviewed controls — those belong to editing/validating the chart, which now lives in Review.
struct ChordProTrueView: View {
    @ObservedObject var model: AppModel
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ChordPro")
                    .font(.swDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.swTextPrimary)
                Text("Spec-exact")
                    .font(.swDisplay(11))
                    .foregroundStyle(Color.swTextSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.swSurface, in: Capsule())
                Spacer()
                Stepper(
                    "Transpose \(model.chordProTranspose)",
                    value: $model.chordProTranspose, in: -12...12
                )
                .fixedSize()
                Button("Export...", systemImage: "square.and.arrow.up") {
                    exportDocument()
                }
                .labelStyle(.iconOnly)
                .help("Export the chart to a ChordPro file")
                .disabled(model.chordProSource.isEmpty)
            }
            ChordProReadOnlyView(source: model.chordProSource, transpose: model.chordProTranspose)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.swCoral)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func exportDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cho") ?? .plainText]
        panel.nameFieldStringValue = "Song.cho"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportChordPro(to: url, transposedBy: model.chordProTranspose)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Confidence tiers shared by the Review tab's lyric-line and chord-event rows (backlog #15).
private enum ReviewConfidenceTier {
    case unknown
    case low
    case medium
    case high

    init(_ confidence: Float?) {
        guard let confidence else {
            self = .unknown
            return
        }
        switch confidence {
        case ..<0.4: self = .low
        case ..<0.7: self = .medium
        default: self = .high
        }
    }

    var tint: Color {
        switch self {
        case .unknown: .clear
        case .low: .swCoral
        case .medium: .swAmber
        case .high: .clear
        }
    }

    var label: String? {
        switch self {
        case .unknown: nil
        case .low: "Low confidence"
        case .medium: "Uncertain"
        case .high: nil
        }
    }
}

// The old "Review & Annotate" bottom panel (backlog #15 Phase 1) is gone (Phase 2
// consolidation, per Eric: "the bottom panel isn't necessary... combined with the top panel").
// Its bass-note row lives in ChordProAppPreview now (View menu's "Show Bass Notes" toggle,
// WorkspaceEditorsView.swift). Its confidence-tint/accept/correct UX is still pending as the
// next chart addition (task: drag/tint/accept/word-edit) — ReviewConfidenceTier below is kept
// since that follow-up will reuse it directly.
