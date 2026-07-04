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
                        LyricBlendRowView(
                            row: row,
                            onSelect: { mode in
                                model.applyLyricBlendSelection(rowID: row.id, mode: mode)
                            },
                            onOverrideChange: { text in
                                model.applyLyricBlendOverride(rowID: row.id, text: text)
                            }
                        )
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
                "Pick the best line per row from every transcription mode, or type your own "
                    + "correction — an override always wins and survives re-analysis."
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
    let onOverrideChange: (String) -> Void

    /// Local editing draft. Seeded from `row.overrideText` on first appearance; kept in sync with
    /// external changes (e.g. a re-analysis reconciling this row's override) via `onChange` below,
    /// since a `@State` initial value is only applied once for a given view identity.
    @State private var overrideDraft: String

    init(
        row: LyricBlendRow, onSelect: @escaping (TranscriptionMode) -> Void,
        onOverrideChange: @escaping (String) -> Void
    ) {
        self.row = row
        self.onSelect = onSelect
        self.onOverrideChange = onOverrideChange
        _overrideDraft = State(initialValue: row.overrideText ?? "")
    }

    /// An active, non-empty override always wins — no ASR candidate is "the effective one" while
    /// it's set, so none of the three candidate buttons show a checkmark.
    private var hasActiveOverride: Bool {
        !(row.overrideText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveMode: TranscriptionMode? {
        hasActiveOverride ? nil : row.effectiveCandidate()?.mode
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
                overrideField
            }
        }
        .onChange(of: row.overrideText) { _, newValue in
            let newText = newValue ?? ""
            if newText != overrideDraft { overrideDraft = newText }
        }
    }

    /// The "4th candidate": a free-text field for a correction that isn't tied to any
    /// transcription mode. Typing here takes effect immediately (same direct-binding pattern the
    /// Review tab's lyric/chord text fields already use) and takes precedence over every ASR
    /// candidate above, surviving re-analysis (`LyricBlendRowBuilder.reconciled`).
    private var overrideField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.swMint).frame(width: 8, height: 8)
            TextField("Type a correction...", text: $overrideDraft)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(Color.swMint)
                .onChange(of: overrideDraft) { _, newValue in
                    onOverrideChange(newValue)
                }
            if hasActiveOverride {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.swMint)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hasActiveOverride ? Color.swMint.opacity(0.14) : Color.clear)
        )
        .swAccentHoverBorder(cornerRadius: 8)
        .shadow(
            color: hasActiveOverride ? Color.swMint.opacity(0.5) : .clear,
            radius: hasActiveOverride ? 8 : 0)
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
