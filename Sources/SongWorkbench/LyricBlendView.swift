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
                    let numbers = displayNumbersByRowIndex
                    ForEach(
                        Array(model.lyricBlendRows.enumerated()), id: \.element.id
                    ) { index, row in
                        LyricBlendRowView(
                            row: row,
                            displayLineNumber: numbers[index],
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

    /// The Review pane's chart line number for each blend row, keyed by row INDEX. Blend rows
    /// emit the chart's sung lines in order, so the i-th row is the i-th sung-lyric ordinal;
    /// `ChordProPreviewIndexing` translates ordinals to the same running display numbers the
    /// Review gutter shows (which also count chord-only instrumental lines) — "line 9" here
    /// is line 9 there.
    private var displayNumbersByRowIndex: [Int: Int] {
        ChordProPreviewIndexing.displayNumbersByLyricOrdinal(source: model.chordProSource)
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
    /// The Review pane's chart line number for this row, so both surfaces speak the same
    /// "line N" language; `nil` when the chart hasn't been built yet.
    var displayLineNumber: Int?
    let onSelect: (TranscriptionMode) -> Void
    let onOverrideChange: (String) -> Void

    /// Local editing draft. Seeded from `row.overrideText` on first appearance; kept in sync with
    /// external changes (e.g. a re-analysis reconciling this row's override) via `onChange` below,
    /// since a `@State` initial value is only applied once for a given view identity.
    @State private var overrideDraft: String
    /// Whether the full candidate list + override field is showing. A row where every
    /// transcription mode agrees starts collapsed to a single line (Eric: "if all 3 lyric
    /// options are the same, they can collapse into 1") — there's nothing to compare, so
    /// showing 3 identical buttons is just noise. Starts expanded when there's disagreement to
    /// review, or an override is already active (a prior correction shouldn't hide itself).
    /// Always user-toggleable afterward via the row's disclosure control either way.
    @State private var isExpanded: Bool

    init(
        row: LyricBlendRow, displayLineNumber: Int? = nil,
        onSelect: @escaping (TranscriptionMode) -> Void,
        onOverrideChange: @escaping (String) -> Void
    ) {
        self.row = row
        self.displayLineNumber = displayLineNumber
        self.onSelect = onSelect
        self.onOverrideChange = onOverrideChange
        _overrideDraft = State(initialValue: row.overrideText ?? "")
        let hasOverride =
            !(row.overrideText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _isExpanded = State(
            initialValue: !Self.candidatesAgree(row.candidates) || hasOverride)
    }

    /// An active, non-empty override always wins — no ASR candidate is "the effective one" while
    /// it's set, so none of the three candidate buttons show a checkmark.
    private var hasActiveOverride: Bool {
        !(row.overrideText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveMode: TranscriptionMode? {
        hasActiveOverride ? nil : row.effectiveCandidate()?.mode
    }

    /// True when every candidate's text (trimmed) is identical — every transcription mode that
    /// produced a line for this window landed on the same words, so there's no real choice to
    /// make. Collapse-eligible regardless of candidate count (2 modes agreeing is just as
    /// uninteresting to review as 3).
    private static func candidatesAgree(_ candidates: [LyricBlendCandidate]) -> Bool {
        Set(candidates.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }).count <= 1
    }

    private var candidatesAgree: Bool { Self.candidatesAgree(row.candidates) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isExpanded {
                header
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(row.candidates) { candidate in
                        candidateButton(candidate)
                    }
                    overrideField
                }
            } else {
                collapsedRow
            }
        }
        .onChange(of: row.overrideText) { _, newValue in
            let newText = newValue ?? ""
            if newText != overrideDraft { overrideDraft = newText }
            // A newly-active override (e.g. carried forward by re-analysis reconciliation)
            // shouldn't be hidden behind a collapsed row.
            if !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isExpanded = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let displayLineNumber {
                Text("Line \(displayLineNumber)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.swTextPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.swSurface, in: Capsule())
            }
            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.swTextSecondary)
            if candidatesAgree {
                Spacer(minLength: 8)
                collapseButton
            }
        }
    }

    /// Lets a currently-expanded, agreeing row collapse back down — the mirror of tapping
    /// `collapsedRow` to expand it. Only offered when there's nothing to disagree about; a row
    /// with real candidate differences always stays expanded.
    private var collapseButton: some View {
        Button {
            withAnimation(.snappy) { isExpanded = false }
        } label: {
            Image(systemName: "chevron.up")
                .font(.caption2)
                .foregroundStyle(Color.swTextSecondary)
        }
        .buttonStyle(.plain)
        .help("Collapse this line")
    }

    /// One agreeing row, collapsed to a single line: line number, time, the shared text, and a
    /// disclosure chevron. Tapping it expands to the full candidate list + override field, same
    /// as any other row (Eric: "if they are clicked they could expand to show the override
    /// input field").
    private var collapsedRow: some View {
        Button {
            withAnimation(.snappy) { isExpanded = true }
        } label: {
            HStack(spacing: 8) {
                if let displayLineNumber {
                    Text("Line \(displayLineNumber)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.swTextPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.swSurface, in: Capsule())
                }
                Text(timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.swTextSecondary)
                Circle().fill(Color.swTextSecondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(row.candidates.first?.text ?? "")
                    .font(.body)
                    .foregroundStyle(Color.swTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.swTextSecondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swAccentHoverBorder(cornerRadius: 8)
        .help(
            "All \(row.candidates.count) transcription modes agree — "
                + "click to review or add a correction")
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
