import SwiftUI

/// The spec-exact ChordPro renderer: chords positioned above lyric text, plus directives, and
/// nothing else — the chart as a `.cho` file actually reads. This is what the ChordPro TAB shows.
/// The Review tab uses `ChordProAppPreview` instead, which layers the playback and review chrome
/// (ball, beat dots, waveform, bass row, confidence shading, accept/edit) over the same chart.
/// One source of truth for the chart's text sizes, shared by the two ChordPro surfaces.
///
/// The Review chart (`ChordProAppPreview`) and the plain ChordPro tab (`ChordProReadOnlyView`)
/// deliberately have SEPARATE bodies — one is defined by the overlays it draws, the other by the
/// ones it doesn't — so the "single renderer" guarantee that used to keep their typography
/// identical no longer applies. These constants are what replaces it. Change a size here, not at a
/// call site.
enum ChordProChartTypography {
    /// Lyric text on both surfaces, at the chart's MINIMUM (1×) size.
    static let lyricSize: CGFloat = 15
    /// Chord labels on the Review chart, which positions each label ABSOLUTELY and so is free to
    /// use a smaller size than the lyric line under it. Also the 1× size.
    static let chordSize: CGFloat = 13

    static let lyric = Font.system(size: lyricSize, design: .monospaced)

    static func lyric(weight: Font.Weight) -> Font {
        .system(size: lyricSize, weight: weight, design: .monospaced)
    }

    static func lyric(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func chord(weight: Font.Weight = .semibold) -> Font {
        .system(size: chordSize, weight: weight, design: .monospaced)
    }

    static func chord(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Chord row for COLUMN-ALIGNED rendering (`ChordProReadOnlyView`), where the chord row is a
    /// space-padded string sitting above the lyric row. It must use `lyricSize`, not `chordSize`:
    /// the alignment is character advances, so a smaller chord row would slide out of register
    /// with the words it names. Weight is safe to vary — a monospaced face keeps one advance
    /// width across weights.
    static let columnAlignedChord = Font.system(
        size: lyricSize, weight: .semibold, design: .monospaced)

    static func columnAlignedChord(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// The chart's ONE zoom factor, shared by both ChordPro surfaces (the plain ChordPro tab and the
/// Review chart). The user picks a body font size; everything else in the chart — chord and bass
/// glyph sizes, the horizontal time axis, the ball/beat-dot/bass reserves, row heights — is that
/// size divided by the 1× body size.
///
/// Scaling the font WITHOUT the horizontal axis would be a bug, not a smaller feature: the Review
/// chart lays words out at their measured time and then nudges a colliding word right by whole
/// character widths. Bigger glyphs on an unchanged axis collide more, so the nudge would push
/// words off the beat columns they are supposed to prove alignment with. `factor` therefore
/// multiplies `pixelsPerSecond` and `characterWidth` together, which leaves every ratio in the
/// layout — and so every beat column — exactly where it was.
struct ChordProChartScale: Equatable, Sendable {
    /// The chart's current size IS the minimum; the slider only ever grows it.
    static let minimumFontSize: CGFloat = ChordProChartTypography.lyricSize
    /// Double, per Eric — far enough to read from a music stand.
    static let maximumFontSize: CGFloat = minimumFontSize * 2
    /// Whole points: the slider's step, and what the readout shows.
    static let step: CGFloat = 1

    /// Body (lyric) font size in points, clamped into `minimumFontSize...maximumFontSize`.
    let fontSize: CGFloat

    init(fontSize: CGFloat) {
        self.fontSize = min(max(fontSize, Self.minimumFontSize), Self.maximumFontSize)
    }

    /// The unscaled chart — what every call site renders when no size has been chosen.
    static let base = ChordProChartScale(fontSize: minimumFontSize)

    /// Multiplier for EVERY length in the chart. 1.0 at the minimum size, 2.0 at the maximum.
    var factor: CGFloat { fontSize / Self.minimumFontSize }

    /// A 1×-authored length at the current size.
    func scaled(_ length: CGFloat) -> CGFloat { length * factor }

    /// Lyric/word glyph size — identical to `fontSize`, named for symmetry with `chordSize`.
    var lyricSize: CGFloat { scaled(ChordProChartTypography.lyricSize) }
    /// Chord (and bass-note) glyph size, holding the 13:15 ratio against the lyrics.
    var chordSize: CGFloat { scaled(ChordProChartTypography.chordSize) }
}

struct ChordProReadOnlyView: View {
    let source: String
    var transpose: Int = 0
    /// Proportional chart zoom (see `ChordProChartScale`). Column-aligned rendering needs nothing
    /// but the font size: the chord row is a space-padded string, so its register with the lyric
    /// row is character advances, which scale with the point size on their own.
    var scale: ChordProChartScale = .base

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
                    .font(ChordProChartTypography.columnAlignedChord(size: scale.lyricSize))
                    .foregroundStyle(Color.swAccent)
            }
            Text(rows.lyricRow)
                .font(ChordProChartTypography.lyric(size: scale.lyricSize))
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
