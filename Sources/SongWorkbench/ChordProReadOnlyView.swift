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

/// The Review tab's accept/correct surface (backlog #15): every lyric line and chord event,
/// tinted by ASR/detection confidence, with an inline text field to correct it and an Accept
/// toggle to mark it looked-at. Purely additive — accepting a line/chord here does not touch the
/// existing whole-song `lyricReviewState`/`chordReviewState` "Mark Reviewed" gating above, per
/// Eric's confirmed decision to keep them independent for this first pass.
struct ChordProReviewAnnotationsPanel: View {
    @ObservedObject var model: AppModel

    private var sortedLyricIndices: [Int] {
        model.lyricSegments.indices.sorted {
            model.lyricSegments[$0].start < model.lyricSegments[$1].start
        }
    }

    private var sortedChordIndices: [Int] {
        model.chordEvents.indices.sorted {
            model.chordEvents[$0].time < model.chordEvents[$1].time
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review & Annotate")
                .font(.swDisplay(15, weight: .semibold))
                .foregroundStyle(Color.swTextPrimary)
            Text(
                "Original recordings have no reference chart, so lines and chords below are "
                    + "color-coded by how confident the analysis was — tinted rows are worth a "
                    + "look. Correct the text/chord inline and check Accept as you go."
            )
            .font(.swDisplay(11))
            .foregroundStyle(Color.swTextSecondary)

            if model.lyricSegments.isEmpty && model.chordEvents.isEmpty {
                ContentUnavailableView(
                    "Nothing to Review",
                    systemImage: "checkmark.seal",
                    description: Text("Run Transcribe and Tempo & Chords first.")
                )
            } else {
                lyricSection
                chordSection
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var lyricSection: some View {
        if !model.lyricSegments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lyric Lines").font(.swDisplay(12, weight: .semibold))
                    .foregroundStyle(Color.swTextSecondary)
                ForEach(sortedLyricIndices, id: \.self) { index in
                    lyricRow(index: index)
                }
            }
        }
    }

    @ViewBuilder
    private var chordSection: some View {
        if !model.chordEvents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chord Events").font(.swDisplay(12, weight: .semibold))
                    .foregroundStyle(Color.swTextSecondary)
                ForEach(sortedChordIndices, id: \.self) { index in
                    chordRow(index: index)
                }
            }
        }
    }

    private func lyricRow(index: Int) -> some View {
        let tier = ReviewConfidenceTier(model.lyricSegments[index].confidence)
        return HStack(spacing: 8) {
            Text(timeLabel(model.lyricSegments[index].start))
                .font(.swMono(10))
                .foregroundStyle(Color.swTextSecondary)
                .frame(width: 44, alignment: .trailing)
            if let label = tier.label {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(tier.tint)
                    .help(label)
            }
            TextField("Lyric", text: $model.lyricSegments[index].text)
            Toggle("Accept", isOn: $model.lyricSegments[index].accepted)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Mark this line accepted")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tier.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func chordRow(index: Int) -> some View {
        let tier = ReviewConfidenceTier(model.chordEvents[index].confidence)
        return HStack(spacing: 8) {
            Text(timeLabel(model.chordEvents[index].time))
                .font(.swMono(10))
                .foregroundStyle(Color.swTextSecondary)
                .frame(width: 44, alignment: .trailing)
            if let label = tier.label {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(tier.tint)
                    .help(label)
            }
            TextField("Chord", text: $model.chordEvents[index].chord)
                .frame(width: 90)
            Spacer()
            Toggle("Accept", isOn: $model.chordEvents[index].accepted)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Mark this chord accepted")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tier.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
