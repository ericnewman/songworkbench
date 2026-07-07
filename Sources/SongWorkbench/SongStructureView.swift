import SwiftUI

/// Read-only Structure tab (`EditorTab.structure`): separates the song's structure from its
/// content — Form (section order), Harmony (chords as scale degrees), Meter (syllables per
/// line), Rhyme (end-rhyme scheme), and an approximate Melody phrase pattern — per Eric's
/// 2026-07-06 framing. Mirrors `ChordProReadOnlyView`'s shape (a plain scrolling render with
/// no editing chrome) but over `SongStructureOverview` instead of the ChordPro text.
struct SongStructureView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.swTextBackground)
        .accessibilityIdentifier("song-structure-view")
    }

    @ViewBuilder
    private var content: some View {
        if let overview = model.songStructureOverview() {
            VStack(alignment: .leading, spacing: 16) {
                header
                formSection(overview)
                ForEach(overview.templates, id: \.kind) { template in
                    templateCard(template)
                }
                ForEach(overview.instrumentalSummaries, id: \.kind) { summary in
                    instrumentalCard(summary)
                }
            }
        } else {
            ContentUnavailableView(
                "No Structure Yet",
                systemImage: "square.stack.3d.up",
                description: Text("Run Tempo & Chords and Transcribe to see the song's form.")
            )
        }
    }

    // `overview.title` used to repeat here as its own heading, right under the shared per-song
    // title PlayerView already shows above the tab bar — pure duplication, and on iPad's tighter
    // vertical layout it read as wasted space at the top of the tab (2026-07-06). Only the
    // "Approximate" badge earns its own row now.
    private var header: some View {
        HStack {
            Spacer()
            Text("Approximate")
                .font(.swDisplay(11))
                .foregroundStyle(Color.swTextSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.swSurface, in: Capsule())
                .help(
                    "Bridge/Solo classification and the Melody phrase pattern are heuristic "
                        + "approximations, not measured from real pitch/melody analysis."
                )
        }
    }

    private func formSection(_ overview: SongStructureOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FORM")
                .font(.swDisplay(11, weight: .semibold))
                .foregroundStyle(Color.swTextSecondary)
            ForEach(Array(overview.form.enumerated()), id: \.offset) { _, section in
                HStack(spacing: 8) {
                    Text(section.label)
                        .font(.swDisplay(13))
                        .foregroundStyle(Color.swTextPrimary)
                        .frame(width: 90, alignment: .leading)
                    Text(timeRange(section.start, section.end))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.swTextSecondary)
                }
            }
        }
    }

    private func templateCard(_ template: SongStructureOverview.PhraseTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(templateTitle(template.kind)) TEMPLATE")
                .font(.swDisplay(11, weight: .semibold))
                .foregroundStyle(Color.swTextSecondary)
            templateRow("Length", "\(template.lineCount) lines")
            templateRow("Phrase Pattern", template.phrasePattern.joined(separator: " "))
            templateRow(
                "Chord Pattern",
                template.chordPattern.isEmpty
                    ? "—" : "| " + template.chordPattern.joined(separator: " | ") + " |")
            templateRow(
                "Lyric Meter",
                template.meterPattern.map(String.init).joined(separator: " / "))
            templateRow("Rhyme", template.rhymeScheme.joined(separator: " "))
        }
        .padding(10)
        .background(Color.swSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Counterpart to `templateCard` for wordless kinds (Intro/Instrumental/Solo/Outro) —
    /// no lyric lines to show a phrase/meter/rhyme breakdown for, so just occurrence count,
    /// total time, and the representative chord pattern (Eric, 2026-07-06).
    private func instrumentalCard(_ summary: SongStructureOverview.InstrumentalSummary)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(templateTitle(summary.kind)) SECTIONS")
                .font(.swDisplay(11, weight: .semibold))
                .foregroundStyle(Color.swTextSecondary)
            templateRow("Occurrences", "\(summary.occurrenceCount)")
            templateRow("Total Time", formatted(summary.totalDuration))
            templateRow(
                "Chord Pattern",
                summary.chordPattern.isEmpty
                    ? "—" : "| " + summary.chordPattern.joined(separator: " | ") + " |")
        }
        .padding(10)
        .background(Color.swSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func templateRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.swTextSecondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.swTextPrimary)
        }
    }

    private func templateTitle(_ kind: SongStructureOverview.Section.Kind) -> String {
        kind.rawValue.uppercased()
    }

    private func timeRange(_ start: TimeInterval, _ end: TimeInterval) -> String {
        "\(formatted(start))–\(formatted(end))"
    }

    private func formatted(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
