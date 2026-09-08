# Spec — Metronome-bucket note timeline (per stem)

Status: DRAFT for Eric's review, 2026-09-08. Decisions so far (Eric): all pitched stems;
one bucket per metronome click; computed in the pipeline and persisted.

## Idea
The metronome (commit 8332afb) is a rigid grid: period `60/estimatedBPM`, phase anchored at
`beatTimes[barGrid.barPhase]`. Consecutive clicks `[c_k, c_{k+1})` define **buckets**. For every
pitched stem, detect what note (or pitch classes) sounds in each bucket and show it as one
extra row per stem under each chart line in Review, cells aligned to the beat columns.

The bucket edges are the metronome, NOT the detected beats. That is deliberate: the rows show
what each instrument does against a fixed reference, so a stem that runs ahead of/behind the
grid shows up as its notes sliding across bucket edges rather than being hidden by a grid
that follows it (cf. memory: "chord/beat lock is circular").

## Data model (SongAnalysisDocument, new optional field)
```swift
struct BucketGridKey: Codable, Equatable {      // identifies the grid the buckets were cut on
    var bpm: Double; var anchor: TimeInterval; var duration: TimeInterval
}
struct StemBucketNote: Codable, Equatable {
    var bucketIndex: Int
    var midiNote: Int?            // monophonic stems (bass, vocals*) — nil = rest
    var pitchClasses: [Int]       // polyphonic stems (guitar, piano, other) — 0..11, strongest first, ≤3
    var confidence: Float         // 0...1, detector clarity weighted by frame share
    var coverage: Float           // fraction of the bucket's frames that were voiced
}
struct StemBucketNotes: Codable, Equatable { var stemID: StemID; var notes: [StemBucketNote] }
struct BucketNoteTimeline: Codable, Equatable {
    var gridKey: BucketGridKey
    var clickTimes: [TimeInterval]   // == StemPlaybackService.metronomeGrid(...) at compute time
    var stems: [StemBucketNotes]
    static let versionTag = "buckets-1"
    var versionTag: String
}
var bucketNotes: BucketNoteTimeline?   // on SongAnalysisDocument; nil for older docs
```
Only buckets with `coverage >= 0.2` are stored (rests are implicit: missing index = rest).
Size: ~600 beats × 5 stems × ~40 B ≈ 120 KB worst case per song. Acceptable.

## Detection (new `BucketNoteAnalyzer`, pure, testable on `[Float]`)
Per stem, one pass over the stem's mono samples, then bucket aggregation:
| stem | per-frame evidence | bucket verdict |
|---|---|---|
| bass | `BassLineAnalyzer` per-frame (midi, clarity) — expose `frameEstimates(samples:sampleRate:)` (refactor: current `analyze` = frameEstimates → median → segments) | midi = clarity-weighted mode; confidence = Σclarity(mode)/Σclarity |
| vocals (+ lead/backing children when the stem set has them) | `VocalHarmonyAnalyzer` per-frame candidates (midi, conf) — expose the pre-segmentation frame list | dominant midi as above; extra candidates ignored (harmony rows already cover them) |
| guitar, piano, other | `ChromaAnalyzer` (SpectrumChroma) per frame, RMS-gated | sum chroma over the bucket, normalise; pitchClasses = classes with share ≥ 0.18, max 3, strongest first; confidence = top share |
Frames straddling a bucket edge are assigned by frame centre. Silence gate: frame RMS below the
stem's own floor (reuse `silenceThreshold`/`detectionTargetPeak` conventions) → unvoiced.
Drums: skipped (unpitched). Accompaniment (legacy 4-stem sets): treated as "other".

## Pipeline placement
New harmony-stage sub-step `stageProgress(0.95, "bucketing notes")` that runs AFTER
`AnalysisTimingPostPasses.apply` (SongAnalysisPipeline L612/L773), because the post pass can
retune bpm/beatTimes/barGrid (2:1, 3:2 …) and beat buckets cannot be derived from a coarser
level. Grid = `StemPlaybackService.metronomeGrid(beatTimes:bpm:barGrid:duration:)` — the same
function the click uses, so what you hear IS the bucket edge. Extract it to a small
`MetronomeGrid` enum so the analysis target does not depend on AVFoundation playback code.
Best-effort: any failure leaves `bucketNotes = nil`; never fails the stage.

Staleness: on load, if `bucketNotes.gridKey` ≠ key derived from the document's current
bpm/anchor/duration (e.g. a post-pass migration on an old doc), the rows are shown disabled
with "Re-analyze to refresh" — same pattern as the separation staleness record.

## Review UI
- View menu: `Toggle("Bucket Notes")` beside "Show Bass Notes", disabled when
  `model.bucketNotes == nil`; `@AppStorage("bucketNotesEnabled")`. Per-stem show/hide
  checkboxes in a submenu (default: all present stems on).
- Rendering (rhythmic mode, `rhythmicContent`): one row per enabled stem between the harmony
  rows and the bass row, `bucketRowReserve` each (same as `bassRowReserve`). For each click
  time in the row's sounding window (same window logic as `rhythmicBeatDotPositions`),
  x = `rhythmicX(forTime: clickTime)`; label = note name (`BassNoteNaming.name(forMidiNote:)`,
  transposed by the chart's transpose) or pitch-class names joined without separator
  ("CEG"); dim when confidence < 0.5; nothing drawn for rests. A left scribble label per row
  ("Bass", "Vox", "Gtr", "Pno", "Oth") in the `scale.scaled(52)` gutter the harmony rows use.
- Monospace mode: not supported in v1 (the rows only make sense positioned).
- Beat dots + bucket rows share the click x positions, so the cells visibly sit on the dots.

## Tests
- `BucketNoteAnalyzerTests`: synthetic bass tone changing pitch mid-song at known bucket edges →
  correct midi per bucket, rest buckets absent, straddle frames assigned by centre; chroma
  triad → three pitch classes strongest-first; silence → no notes.
- `MetronomeGrid` extraction keeps the existing 6 StemPlaybackService tests green (they move).
- Document round-trip: encode/decode `bucketNotes`; older JSON without the field decodes nil.
- Staleness: gridKey mismatch → `isBucketTimelineCurrent == false`.
- Review formatter (`BucketNoteRowFormatter`, non-view): window → [(x-time, label, dim)].

## Out of scope (v1)
Sub-beat buckets; polyphonic vocals; editing/accepting bucket notes into the chart; ChordPro
export of the rows; iPad layout tuning beyond "rows off by default".

## Open questions for Eric
1. Chroma share threshold 0.18 / max 3 classes for guitar+piano+other — fine as a starting point?
2. Row order under a line: harmonies → buckets (Vox, Gtr, Pno, Oth, Bass) → bass-onset row, or
   should the existing bass-onset row and the bass bucket row be adjacent?
3. Should a re-analysis be forced for the rows to appear, or add a "Compute bucket notes"
   action that runs only this sub-step on existing stems (cheaper, ~seconds)?
