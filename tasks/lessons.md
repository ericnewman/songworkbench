# Lessons

- When the user says to skip already completed items in a batch, exclude them
  from the new output folder and manifest rather than copying prior results
  into the batch deliverable.
- Do not carry a prior batch-exclusion rule into a new analysis request when the
  user broadens the scope; explicitly include all requested unique recordings.
- When packaging a workflow as a skill, confirm whether adjacent outputs belong
  inside the primary artifact. For song transcription, embed tone analysis in
  the ChordPro chart instead of treating it only as a separate report.
- When exporting one lyric file per catalog item, exclude continuous live-set
  recordings when the user wants a song list rather than a concert transcript.
- For chord-chart review, do not treat lyric lines as harmonic units. Anchor a
  beat/downbeat grid to timestamped vocals, test center-cancelled accompaniment,
  and represent sub-measure changes explicitly in chord-only sections.
- When center cancellation leaves bass roots ambiguous, separate drums, bass,
  vocals, and accompaniment. Use the drum stem for the grid, bass for roots,
  and the accompaniment stem for chord quality before editing the chart.
- After retrying one analysis stage, verify every generated downstream artifact,
  not only the direct stage output. Lyrics and Harmony changes must rebuild an
  unreviewed generated ChordPro draft while preserving reviewed/imported charts.
- When a requested stem appears merged, distinguish the model's source taxonomy
  from leakage and output-mapping defects before adding mixer tracks. A UI track
  cannot expose a source the installed model does not predict.
- Chord detection must declare and test its audio source. Prefer the separated
  accompaniment stem and beat-level aggregation; never infer source isolation
  merely because stem separation ran earlier in the pipeline.
- A two-axis SwiftUI preview must explicitly own its viewport alignment and
  initial scroll anchor. Do not rely on a lazy stack's intrinsic width to start
  at the leading edge when wide monospaced rows are present.
- Do not report a multi-stem request as handled until the separator model,
  persisted stem taxonomy, playback/export services, and mixer all expose the
  additional real audio outputs. UI work elsewhere does not satisfy it.
- For stem-separation changes, do not accept "finite WAV files were written" as
  validation. Verify reconstruction error, headroom/clipping, source mapping,
  and representative listening/metric evidence before calling the model usable.
- After moving or renaming an Xcode/Tuist workspace, validate both the
  `.xcodeproj` and `.xcworkspace` entry points. Workspace SwiftPM lockfiles may
  be symlinks with absolute paths back to the previous location.

## 2026-06-25 — Don't delete low-confidence transcribed words as "hallucinations"
**Mistake:** Treated "Grass" (conf 0.045, span 0.0–20.0) as a Whisper hallucination and made the
silence gate DROP it. It is the real first word of the song — Whisper only mis-timed it (padding
the first word after the instrumental intro across the whole 20s gap).
**Rule:** Low confidence + an implausibly long span signals a TIMING error, not a fake word.
Re-time/normalize suspicious tokens (de-pad: trim the span) rather than delete them. Only drop a
token that is genuinely isolated in silence AND short AND low-confidence. Verify against the actual
lyric before calling anything a hallucination. Deleting persisted content is destructive — the word
is then gone from storage and only re-analysis from the raw cache can restore it.
