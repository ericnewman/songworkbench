# SongWorkbench Backlog — prioritized, numbered

Goal: clear this list to zero. Source-of-truth for status; `tasks/todo.md` remains the
historical work log (each item below cites where it came from).

Items are grouped into **batches by file/subsystem overlap**, not just topic. Items in the
same batch touch the same code and must be done sequentially (one PR at a time). Items in
different batches touch disjoint code and can run in parallel, each in its own
`git worktree` — this project has already been burned once by two agents editing the same
checkout at the same time (see `songworkbench-store-split-handoff.md`), so parallel batches
are never allowed to share a working tree. Each batch merges back to `main` on its own,
sequentially, once green.

---

## Batch A — Ball/highlight/clock cleanup (sequential within batch)
Touches: WorkspaceEditorsView.swift, AudioPlaybackService/StemPlaybackService, SongTimeline-adjacent code.

1. [x] **Delete legacy ball-heuristic code** (f9aaed4) — audited; nothing safe to delete,
   the fallback is still load-bearing for user-edited charts. (todo.md: SongTimeline Review
   2026-07-01, reconfirmed 2026-07-02 evening "Still open")
2. [x] **PlaybackClock protocol unification (3d)** (589f31e) — `PlaybackClock` protocol +
   `AppModel.activeClock`; view no longer picks between the two playback services directly.
   (todo.md: SongTimeline plan, Phase 3d)
3. [x] **Word-highlight lead: make rate-aware** — MOOT, no code change: commit 91e700c
   (2026-07-03, predates this batch) already retired the fixed lead entirely
   (`highlightLeadSeconds` 0.45 → 0) once word timings were pinned to real vocal-stem
   energy, which is what made the old lead necessary. Scaling a lead that's now always 0
   by `1/tempoRate` is still 0 — nothing left to do. Checked before implementing rather
   than adding dead rate-scaling code. (todo.md: 2026-06-27 Phase 1 item D)
4. **Q2: per-word onset snapping** — snap word.start to the nearest true vocal onset via a
   new `VocalWordOnsetAligner`. Builds on #3. (todo.md: 2026-07-01 "Vocal-energy alignment")
15. **Split the ChordPro tab: restore a true ChordPro view + a new Review/Annotate tab.**
    Not previously tracked anywhere (todo.md, memory.md, EditorTab enum all checked — this
    was a verbal/undiscovered requirement until 2026-07-03 chat). Numbered 15 (not
    inserted as "5" etc.) to avoid renumbering already-referenced items; placed in Batch A
    because it touches the same file (`WorkspaceEditorsView.swift`) as items 1-4, so it's
    sequenced after #4.

    Eric's own framing (2026-07-03), verbatim intent — read this before designing anything:
    > Because these are original recordings, there is no definitive reference set of lyrics
    > or chords. We should anticipate small incremental corrections rather than pointing at
    > a larger reference file. We should consider color coding low score chords and lyrics
    > and give the user the option to accept or correct as they go. Since we have overlaid
    > so much functionality onto the ChordPro views, I think we should make a new workspace
    > view tab that allows all this editing, validation, and corrections based on the
    > current ChordPro view, then strip back the ChordPro view to truly be only the
    > elements that a true ChordPro file can contain.

    Key implication: this is NOT the existing "Reference Lyrics" paste-a-known-lyrics
    workflow (`AppModel.referenceLyrics`/`applyReferenceLyrics()`, for covers with a known
    text) — most of this catalog is original songs with no ground truth, so the model is
    **incremental self-correction of our own ASR/chord output**, not alignment against an
    external reference. Keep both features distinct; don't conflate or replace one with
    the other. (C1 / item #8, "reference-lyrics-first workflow," is specifically about
    the cases where a reference DOES exist — still a separate, narrower case.)

    Design points:
    - `chordPro` tab (`EditorTab.chordPro`) → **true ChordPro view**: read-only,
      spec-exact rendering of exactly what's in the `.cho` source — no waveform, no beat
      dots, no interactive overlay chrome.
    - New tab gets everything currently overlaid on the ChordPro preview (waveform, beat
      dots, bouncing ball, word/chord highlight) — same view essentially, but as the
      editing/validation/correction surface instead of bolted onto the spec-exact one.
    - **Color code low-confidence chords and lyrics** at whatever granularity their
      confidence data already exists at — chords are already discrete per-event
      confidence-scored (memory.md: "Chord events are confidence-filtered... per-song
      persisted threshold"), so color per chord event; check `TimedLyricSegment`/
      `TranscriptionResult` for existing per-word or per-segment confidence before
      inventing a new field.
    - **Accept-or-correct as they go** — an incremental, in-place workflow (user reads
      through and fixes flagged spots one at a time), not a big batch review-all screen.
      Accept/correct action is per-line for lyrics (matches Eric's 2026-07-03 confirmation)
      and naturally per-chord-event for chords, since chords are already discrete units.
    - Likely touches: `EditorTab` enum, `WorkspaceEditorsView.swift` (new tab case + view),
      `ChordProPreviewDocument`/its renderer (split into "print-exact" vs. today's enhanced
      mode).

## Batch B — ChordPro chart-quality (sequential within batch)
Touches: ChordProDraftBuilder.swift, ChordProTextRenderer.swift, and chart-export code.

5. **B2: Bar-aligned chord-only rows** — real barlines (`| C# | F# . | Ab | C# |`) instead
   of the current loose spacing. (todo.md: 2026-07-02 evening "Still open")
6. **B4: Section directives** — `{start_of_verse N}` / `{start_of_chorus}` etc., plus keep
   existing repeat marking. (same)
7. **B5: `x_` round-trip custom directives** — carrier for timing data the ChordPro spec
   can't natively hold. (same)
8. **C1: Reference-lyrics-first workflow** — surface pasting real lyrics as the primary path
   for original songs, not a secondary sheet. (same)

## Batch C — Independent features (parallelizable with A and B, and with each other via separate worktrees)

9. **Phrase-structure lyric grouper** — rhyme/syllable/bar-period aware line grouping
   (`LyricPhraseGrouper`), replacing purely ASR-timing-driven grouping. New subsystem, no
   Review section exists yet — fully unstarted. (todo.md: 2026-07-01)
10. **Chord event-timing rigor audit** — current nearest-onset accuracy metric is
    self-flagged "weak" (941-onset guitar-stem test); needs a real chroma-flux
    change-point comparison. Investigation + maybe a scoring script, likely no product code
    change. (todo.md: 2026-07-02 evening)
11. **Lyric Blending feature** — drop the Fast/Balanced/Accuracy picker, always run all 3
    models, open a per-song "Lyric Blend" window, stack 3 candidates per time window in 3
    colors, user picks best per row, blended selection persists as official lyrics. Biggest
    standalone item in this batch. (todo.md: 2026-06-27 Phase 2, reconfirmed open
    2026-07-02 evening)

## Batch D — Live Capture (own worktree; gated on real hardware, see note)
Touches: AudioCaptureSources.swift and new capture-only files.

12. **Live Capture Phase 1 — real-time chords.** Phase 0 (feasibility spike) is done and
    already merged. Needs, in order: (a) on-device validation of
    `AVAudioEngineCaptureSource` via loopback device + mic, and of the system-audio path
    (ScreenCaptureKit audio first, Core Audio process-tap fallback) under the sandbox — **this
    validation step needs a real Mac with real audio hardware/devices in front of a human; a
    coding subagent cannot do it**; (b) once validated, build `TransientCaptureBuffer` +
    `LiveHarmonyAnfalyzer` (reusing the existing vDSP chord path) + `CaptureMuteMonitor`
    wiring + `AnalysisSourceKind.liveCapture` + additive schema bump. (PRD:
    `.scratch/PRD-live-capture-analysis.md` §7; findings:
    `.scratch/PHASE0-capture-spike-findings.md`)
13. **Live Capture Phase 2 — live lyrics.** Transient-scratch-and-shred transcription path
    (option A in the PRD) or streaming ASR (option B, zero-bytes-on-disk but bigger lift).
    Blocked on #12.
14. **Live Capture Phase 3 — polish.** Loopback-device setup guide in-app, accessibility
    labels (UI-010), evaluate streaming ASR for lyrics. Blocked on #12/#13.

## Deferred / open question, not yet numbered
- **M7: default transcription mode → Accuracy** — explicitly skipped as "not requested" in
  the 2026-06-29 review. Only add to the numbered list if you actually want it.

---

## Working agreement while clearing this list
- One batch's worktree merges to `main` (build + full test suite green, `swift format lint
  --strict` clean) before its items are marked done here.
- Batches A/B/C may run concurrently in separate worktrees; Batch D waits for a session with
  Eric at the Mac to do on-device validation before any code lands.
- When an item is done: mark `[x]` here with the commit hash, and add one line to
  `tasks/todo.md` under a new dated section (keeps the historical log intact).
