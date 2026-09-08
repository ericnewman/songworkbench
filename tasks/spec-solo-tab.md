# Spec — Solo passages as guitar tab (per melodic stem)

Status: IMPLEMENTED 2026-09-08 (stages a–d, see tasks/todo.md). Decisions (Eric): "any melodic
lead line" counts as a solo; runs of ≥ 2 bars; 16th-note resolution; guitar tab is the display
for every melodic stem (guitar, guitar.lead/.rhythm, piano, other, accompaniment) — a keyboard
line as frets is still a playable transcription. NOT verified in the running .app (no GUI from
this session); unit- and diagnostic-verified only.

## Shape
- `SoloTranscriptionAnalyzer` (Sources/SongWorkbench/SoloTranscriptionAnalysis.swift):
  - Per chroma frame (same 4096/2048 front end as bucket notes): **lead-like** when at most two
    pitch classes carry ≥ 50 % of the top class's share — a plucked note keeps its fundamental
    and even harmonics in one class and its fifth partial in a second; a triad spreads three.
  - Per metronome bucket: silent (< 20 % voiced frames) / lead (≥ 60 % lead-like frames AND the
    pitch tracker names a note in ≥ 40 % of its frames AND the stem is at least as loud as the
    vocal stems in that bucket) / chordal (everything else).
  - Passages: runs of lead buckets, one-bucket gaps tolerated, kept when ≥ `beatsPerBar × 2`.
  - Transcription: each bucket of a passage is split four ways on its own span; per 16th the
    confidence-weighted mode of `VocalHarmonyAnalyzer(midiRange: 40...86).frameEstimates`
    (46 ms hop — `BassLineAnalyzer`'s 128 ms hop cannot resolve a 16th); consecutive equal notes
    merge into one with `lengthSixteenths`; a 16th with no frame at all holds the previous note.
  - `GuitarTabAssigner`: DP over hand positions (index-finger fret 0…18, span 4, open strings
    allowed) with cost = position movement + 0.5 per open string mid-run + 1 above the 15th
    fret. A C-major scale from C3 lands in one position; out-of-range notes clamp to the
    fretboard's edge rather than dropping (the rhythm survives even when the pitch is wrong).
- Persisted: `SongAnalysisDocument.soloTranscriptions: SoloTranscriptionTimeline?` with the
  `BucketGridKey` + `versionTag` ("solos-1") staleness contract of `bucketNotes`.
- `SoloTranscriptionPass.apply(to:force:)` runs right after `BucketNotePass` at both pipeline
  sites; AppModel mirrors `soloTranscriptions`, `isSoloTimelineCurrent`, `canComputeSolos`,
  `computeSolos()`.
- Review: View menu → "Solo Tab" toggle (`reviewShowSoloTab`) + "Compute/Recompute Solo Tab".
  `SoloTabRowFormatter` (ChordProReadOnlyView.swift) emits six strings (e B G D A E) of fixed
  two-character 16th columns ("5-", "12", "--"); the row view places every column at its own
  `rhythmicX(forTime:)` so the tab stays on the beat across a fitted ruler. The block sits
  below the bucket rows and above the bass-onset row (`soloReserve` = 6 × 11 pt per block).
  Tab is not transposed with the chart: frets are where the recorded player's fingers were.

## Measured (diagnostic: `SW_SOLO_DIAG=1 swift test --skip-build --filter
SoloTranscriptionDiagnosticTests`, optional `SW_SOLO_DIAG_MATCH`, `SW_SOLO_DIAG_BARS=1`)
- **Chroma sparsity does not separate lead from rhythm on the same stem.** On "Eight Miles
  High" the `guitar` stem (lead 12-string over strummed 12-string) shows 4–6 dominant pitch
  classes and a top share of 0.15–0.20 in EVERY bar, solo bars included; 12 of 403 buckets
  read as lead. The lead line was, however, found on the `other` stem, where the separator
  leaked part of it: 0:17–0:23 and 3:25–3:29 — inside the intro and outro solos and nowhere
  in the verses. So the classifier works when a stem carries a single line and not otherwise.
- **Leakage gate.** Ungated, the a cappella "It Is Well With My Soul" produced 21 passages on
  its piano/other stems (the voices, 9–18 dB down). Requiring the stem to be ≥ the vocal stems'
  RMS in the bucket (`minimumProminence = 1`) leaves 1 two-note passage (0:15–0:20, before the
  voices enter); real passages elsewhere sit 40–96 dB above their (silent) vocals and are
  untouched. At −6 dB it left 3.
- The pitch tracker's frame confidence saturates at 1.0 on real stems (score is relative to
  the frame's own peak), so `SoloNote.confidence` carries little information today.
- Per-stem cost ≈ 5 s per 3.5-minute song (chroma + pitch frames), plus the vocal stems for the
  reference level; a 3-stem song takes ~15–20 s in the pass.

## Known limits / next
- A lead played over a rhythm part on the same stem is invisible to this classifier; the fix
  is upstream (a `guitar.lead` split, which the stem graph already models) or a real
  multi-pitch salience front end, not another chroma threshold.
- A bare power chord (root + fifth) is two dominant classes and reads as lead.
- Row rendering only on rhythmic-mode lines with word timings (same gate as the bucket rows);
  instrumental lines — where solos actually live — are v2, as for bucket rows.
- Two-digit column width means a 16th column is two monospaced characters wide; at small
  zoom on a fast song adjacent columns can touch.
