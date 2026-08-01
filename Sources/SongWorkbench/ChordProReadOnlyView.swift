import SwiftUI

/// The spec-exact ChordPro renderer: chords positioned above lyric text, plus directives, and
/// nothing else — the chart as a `.cho` file actually reads. This is what the ChordPro TAB shows.
/// The Review tab uses `ChordProAppPreview` instead, which layers the playback and review chrome
/// (ball, beat dots, waveform, bass row, confidence shading, accept/edit) over the same chart.
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
        .background(Color.swTextBackground)
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
        let rows = ChordProReadOnlyLineRenderer.rows(for: line)
        return VStack(alignment: .leading, spacing: 0) {
            if let chordRow = rows.chordRow {
                Text(chordRow)
                    .font(Self.font)
                    .foregroundStyle(Color.swAccent)
            }
            Text(rows.lyricRow)
                .font(Self.font)
                .foregroundStyle(Color.swTextPrimary)
        }
    }
}

struct ChordProReadOnlyLineRows: Equatable, Sendable {
    var chordRow: String?
    var lyricRow: String
}

/// Display rows for the true ChordPro tab. Normal lyric lines stay column-exact. Generated
/// chord-only bar-grid rows get their columns expanded because `| . . |` punctuation is much more
/// compact than lyric text for the same musical span.
enum ChordProReadOnlyLineRenderer {
    static let instrumentalColumnScale = 2.0

    static func rows(for line: ChordProPreviewLine) -> ChordProReadOnlyLineRows {
        if isExpandableChordOnlyBarGrid(line) {
            let chords = line.chords.map {
                ChordProPreviewChord(name: $0.name, column: scaledColumn($0.column))
            }
            return ChordProReadOnlyLineRows(
                chordRow: chords.isEmpty ? nil : ChordRowStringBuilder.build(chords: chords),
                lyricRow: expandedBarGrid(line.lyric)
            )
        }
        return ChordProReadOnlyLineRows(
            chordRow: line.chords.isEmpty ? nil : ChordRowStringBuilder.build(chords: line.chords),
            lyricRow: line.lyric.isEmpty ? " " : line.lyric
        )
    }

    private static func isExpandableChordOnlyBarGrid(_ line: ChordProPreviewLine) -> Bool {
        guard !line.chords.isEmpty, !line.hasSungText else { return false }
        let trimmed = line.lyric.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && trimmed.allSatisfy { "| .".contains($0) }
    }

    private static func scaledColumn(_ column: Int) -> Int {
        Int((Double(column) * instrumentalColumnScale).rounded())
    }

    private static func expandedBarGrid(_ text: String) -> String {
        var characters: [Character] = []
        for (column, character) in text.enumerated() {
            let scaled = scaledColumn(column)
            if characters.count < scaled {
                characters.append(contentsOf: repeatElement(" ", count: scaled - characters.count))
            }
            characters.append(character)
        }
        return String(characters)
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

/// A bass note prepared for rendering on a lyric row: its onset time (drives the time→x
/// mapping in rhythmic mode, the same axis the chords use) and its display name.
struct TimedBassNoteLabel: Equatable, Sendable {
    let time: TimeInterval
    let name: String
}

/// Formats detected bass notes for the Review tab's optional bass-note row (backlog: Bass Note
/// display). A standalone (non-view) type so the windowing/formatting logic is unit-testable
/// without SwiftUI, mirroring `ChordRowStringBuilder`.
enum BassNoteRowFormatter {
    /// Notes below this detector clarity are not worth charting: near-zero-confidence
    /// observations were rendering alongside solid ones and reading as wrong notes against
    /// the chords (measured: they account for a large share of bass-vs-chord clashes).
    static let minimumDisplayConfidence: Float = 0.5

    /// Bass notes within `window`, pitch-named, in onset order, with their onset times — used
    /// by rhythmic mode to place each note at its real x instead of clustering the names
    /// flush-left (reported: "bass notes seem clustered against the start of the lines").
    /// `transposedBy` MUST match the chart's chord transpose, or the bass row reads a
    /// constant offset from the chords above it.
    static func timedLabels(
        for bassNotes: [BassNoteObservation],
        inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0
    ) -> [TimedBassNoteLabel] {
        bassNotes
            .filter {
                window.contains($0.timestamp) && $0.confidence >= minimumDisplayConfidence
            }
            .sorted { $0.timestamp < $1.timestamp }
            .map {
                // Pitch only. A recommended string used to be appended here ("A (G string)"),
                // but pitch alone cannot identify the string actually played, so it was
                // guidance dressed as transcription — and it tripled the width of every label
                // on a row that has to share its x-axis with the chords above it.
                TimedBassNoteLabel(
                    time: $0.timestamp,
                    name: BassNoteNaming.name(forMidiNote: $0.midiNote + semitones)
                )
            }
    }

    /// Bass notes within `window`, pitch-named and joined in onset order — for example,
    /// "E · A · D".
    /// `nil` when nothing falls in the window, so callers can skip rendering the row entirely.
    /// Monospace-mode fallback; rhythmic mode uses `timedLabels` for positioned rendering.
    static func label(
        for bassNotes: [BassNoteObservation],
        inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0
    ) -> String? {
        let notes = timedLabels(for: bassNotes, inWindow: window, transposedBy: semitones)
        guard !notes.isEmpty else { return nil }
        return notes.map(\.name).joined(separator: " · ")
    }
}

/// The ChordPro tab: the shared toolbar (transpose, export, JustChords) over a plain
/// `ChordProReadOnlyView` body. `ChordProTabConfig.chordProPlayback` sets
/// `showsPlaybackChrome = false`, which both selects that body and hides the toolbar controls
/// that only act on chrome this tab does not draw.
struct ChordProTrueView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ChordProTabEditor(model: model, config: .chordProPlayback)
    }
}

/// Confidence tiers shared by the Review tab's lyric-line and chord-event rows (backlog #15).
/// Not `private`: reused directly by the interactive Review chart's tint (`WorkspaceEditorsView`
/// — `ChordProPreviewLineView`/`ChordProPreviewBlockView`, backlog #15 Phase 2 remainder).
enum ReviewConfidenceTier {
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
// WorkspaceEditorsView.swift). Its confidence-tint/accept/correct UX now lives directly in the
// interactive Review chart (`ChordProAppPreview`/`ChordProPreviewBlockView`/
// `ChordProPreviewLineView`, backlog #15 Phase 2 remainder), which reuses `ReviewConfidenceTier`
// above.
