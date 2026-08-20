import SwiftUI

/// The reference-vs-generated chart report: systemic findings on top (transposition, density,
/// quality collapse — the patterns a single wrong chord can't show), then the per-line diff so
/// individual disagreements can be inspected. "Adopt Reference" is the explicit, only path by
/// which an uploaded reference ever replaces the generated chart.
struct ReferenceComparisonReportView: View {
    let comparison: ReferenceChartComparison
    /// How well the RECORDING backs each chart. `nil` when the song has no persisted audio
    /// evidence (analysed before it was recorded) — the section is then omitted rather than
    /// showing a verdict nothing supports.
    var audioValidation: ReferenceChartAudioValidation.Result?
    var onAdopt: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Reference Comparison", systemImage: "checklist")
                    .font(.swDisplay(15, weight: .semibold))
                Spacer()
                Text(
                    "Root agreement \(Int((comparison.rootAgreement * 100).rounded()))% · "
                        + "density \(String(format: "%.2f", comparison.densityRatio))×"
                )
                .font(.swMono(11))
                .foregroundStyle(Color.swTextSecondary)
            }

            if let audioValidation,
                let summary = ReferenceChartAudioValidation.summary(
                    for: audioValidation)
            {
                // The only section that consults the RECORDING. Everything else on this sheet
                // compares two charts against each other, which can show that they disagree but
                // never which one is right.
                VStack(alignment: .leading, spacing: 4) {
                    Label(summary, systemImage: "waveform.badge.magnifyingglass")
                        .font(.swDisplay(12))
                        .foregroundStyle(
                            audioValidation.verdict == .referenceBetter
                                ? Color.swMint : Color.swTextPrimary)
                    if !audioValidation.unsupportedFindings.isEmpty {
                        Text(
                            "\(audioValidation.unsupportedFindings.count) uploaded chord(s) have "
                                + "no attack or harmonic change in the audio: "
                                + audioValidation.unsupportedFindings.prefix(6)
                                .map {
                                    "\($0.chord) @ \(String(format: "%.1f", $0.time))s"
                                }
                                .joined(separator: ", ")
                        )
                        .font(.swMono(11))
                        .foregroundStyle(Color.swAmber)
                    }
                    if audioValidation.reference.qualityAgreementShare == nil {
                        // Frame evidence is session-only (see
                        // `SongAnalysisDocument.frameChordObservations`), so a song loaded from
                        // disk can compare placement but not quality. Say so rather than
                        // silently omitting half the comparison.
                        Text(
                            "Chord quality was not compared — re-analyse this song to compare "
                                + "thirds against the recording."
                        )
                        .font(.swDisplay(11))
                        .foregroundStyle(Color.swTextSecondary)
                    }
                    if !audioValidation.wrongQualityFindings.isEmpty {
                        // Wrong-third findings are listed separately from unsupported ones: a
                        // chord in the right place with the wrong quality is a different fix
                        // from a chord that should not be there at all.
                        Text(
                            "\(audioValidation.wrongQualityFindings.count) uploaded chord(s) "
                                + "name the wrong third: "
                                + audioValidation.wrongQualityFindings.prefix(6)
                                .map {
                                    "\($0.chord)→\($0.suggestedChord ?? "?") "
                                        + "@ \(String(format: "%.1f", $0.time))s"
                                }
                                .joined(separator: ", ")
                        )
                        .font(.swMono(11))
                        .foregroundStyle(Color.swCoral)
                    }
                    if audioValidation.untimedChordCount > 0 {
                        Text(
                            "\(audioValidation.untimedChordCount) uploaded chord(s) sit on lines "
                                + "we never transcribed, so they could not be judged."
                        )
                        .font(.swDisplay(11))
                        .foregroundStyle(Color.swTextSecondary)
                    }
                }
                .padding(8)
                .swSurfacePanel(cornerRadius: 8)
            }

            if comparison.systemicFindings.isEmpty {
                Label(
                    "No systemic issues — disagreements below are chart-granularity noise.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(Color.swMint)
                .font(.swDisplay(12))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(comparison.systemicFindings, id: \.self) { finding in
                        Label(finding, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.swAmber)
                            .font(.swDisplay(12))
                    }
                }
            }

            List {
                ForEach(comparison.lineDiffs) { diff in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diff.lyric)
                            .font(.swDisplay(12))
                            .foregroundStyle(Color.swTextSecondary)
                            .lineLimit(1)
                        HStack(spacing: 12) {
                            chordRow(label: "ref", chords: diff.referenceChords)
                            chordRow(label: "gen", chords: diff.generatedChords)
                            Spacer()
                            if diff.alignedCount > 0 {
                                Text("\(diff.rootMatches)/\(diff.alignedCount) roots")
                                    .font(.swMono(10))
                                    .foregroundStyle(
                                        diff.rootMatches == diff.alignedCount
                                            ? Color.swMint : Color.swAmber)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if !comparison.unmatchedReferenceLines.isEmpty {
                    Section("Reference lines with no generated match") {
                        ForEach(comparison.unmatchedReferenceLines, id: \.self) { lyric in
                            Text(lyric)
                                .font(.swDisplay(11))
                                .foregroundStyle(Color.swCoral)
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Button("Adopt Reference as Chart", role: .destructive) { onAdopt() }
                    .help(
                        "Replace the generated chart with the uploaded reference "
                            + "(the generated one can be rebuilt by re-analysis)")
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
    }

    @ViewBuilder
    private func chordRow(label: String, chords: [String]) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.swMono(10))
                .foregroundStyle(Color.swTextSecondary)
            Text(chords.isEmpty ? "—" : chords.joined(separator: " "))
                .font(.swMono(11))
                .foregroundStyle(Color.swTextPrimary)
                .lineLimit(1)
        }
    }
}
