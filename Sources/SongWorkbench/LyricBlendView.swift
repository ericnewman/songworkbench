import SwiftUI

/// The "Lyric Blend" window (backlog #11): shows every time window across the currently selected
/// song where at least one transcription mode produced a line, stacking each mode's candidate in
/// its own color so the user can pick the best line per row. Tracks the SELECTED song's live,
/// reactive state (`model.lyricBlendRows`/`lyricSegments`) rather than being pinned to whichever
/// song it was opened for — see `AppModel.applyLyricBlendSelection`.
struct LyricBlendView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.lyricBlendRows.isEmpty {
                    emptyState
                } else {
                    ForEach(model.lyricBlendRows) { row in
                        LyricBlendRowView(row: row) { mode in
                            model.applyLyricBlendSelection(rowID: row.id, mode: mode)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.swCanvas.ignoresSafeArea())
        .foregroundStyle(Color.swTextPrimary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.selectedSong?.title ?? "Lyric Blend")
                .font(.swDisplay(20, weight: .semibold))
                .lineLimit(1)
            Text(
                "Pick the best line per row from every transcription mode. Your choice becomes "
                    + "the official lyrics."
            )
            .font(.callout)
            .foregroundStyle(Color.swTextSecondary)
        }
    }

    private var emptyState: some View {
        Text(
            "No blend candidates yet — analyze a song with more than one transcription model "
                + "installed to compare lines here."
        )
        .font(.callout)
        .foregroundStyle(Color.swTextSecondary)
        .padding(.top, 40)
    }
}

private struct LyricBlendRowView: View {
    let row: LyricBlendRow
    let onSelect: (TranscriptionMode) -> Void

    private var effectiveMode: TranscriptionMode? {
        row.effectiveCandidate()?.mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.swTextSecondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(row.candidates) { candidate in
                    candidateButton(candidate)
                }
            }
        }
    }

    private var timeLabel: String {
        let totalSeconds = max(Int(row.start.rounded()), 0)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func candidateButton(_ candidate: LyricBlendCandidate) -> some View {
        let isSelected = candidate.mode == effectiveMode
        let tint = color(for: candidate.mode)
        return Button {
            onSelect(candidate.mode)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(candidate.text)
                    .font(.body)
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .swAccentHoverBorder(cornerRadius: 8)
        .shadow(color: isSelected ? tint.opacity(0.5) : .clear, radius: isSelected ? 8 : 0)
    }

    private func color(for mode: TranscriptionMode) -> Color {
        switch mode {
        case .accuracy: .swAccent
        case .balancedDraft: .swViolet
        case .fastDraft: .swAmber
        }
    }
}
