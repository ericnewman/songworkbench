import SwiftUI

/// The reference-vs-generated chart report: systemic findings on top (transposition, density,
/// quality collapse — the patterns a single wrong chord can't show), then the per-line diff so
/// individual disagreements can be inspected. "Adopt Reference" is the explicit, only path by
/// which an uploaded reference ever replaces the generated chart.
struct ReferenceComparisonReportView: View {
    let comparison: ReferenceChartComparison
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
