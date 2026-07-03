# Chord event-timing rigor audit (backlog item #10)

Follow-up to the 2026-07-02 evening ad-hoc check on "There's a party goin on"
(guitar stem), which used a crude flux-based onset detector and explicitly
flagged its own weakness:

> with 941 onsets the nearest-onset metric is weak — a rigorous event audit
> needs chroma-flux change-point comparison (A-phase work).

This note builds that rigorous comparison and reports what can and cannot be
verified inside this sandbox (no Swift toolchain, no bundled real-audio
fixture).

## What "crude" meant, precisely

The prior audit's onset source was `InstrumentOnsetDetector`
(`Sources/SongWorkbench/AudioFileAnalysisService.swift`): a broadband
energy-flux peak-picker (positive first-difference of per-hop RMS, threshold
= noise-floor-relative + peak-fraction, local-maxima peak-picking, minimum
spacing debounce). It is also what `ChordOnsetAligner` uses in production to
snap chord-event times to "the instrumental actually changed" during
`AnalysisStage`. It is a genuinely useful detector for *note attacks*, but it
cannot distinguish "the same chord got strummed again" from "the chord
changed" — both look like a rise in RMS. That conflation is exactly why the
prior audit's authors called their own 63%-within-150ms number weak evidence.

## What was built

`Sources/SongWorkbench/ChromaChangePointDetector.swift`, two new pure,
deterministic, unit-tested types:

- **`ChromaChangePointDetector`** — given a sequence of `ChromaVector` (the
  same 12-bin pitch-class-energy representation `ChromaAnalyzer`/
  `ChordClassifier` already produce per-frame), computes frame-to-frame
  **cosine distance** (loudness-insensitive, since chroma is normalized to
  sum to 1 already) and adaptive-threshold peak-picks it (median + 6×scaled-
  MAD, same robust-statistics shape as `InstrumentOnsetDetector`'s flux
  threshold, but operating on harmonic content instead of broadband energy).
  This is a genuine, different signal from onset/flux: a chord change moves
  the chroma vector even when the pick attack is soft (or absent — e.g. a
  sustained pad or feedback swell), and a repeated strum of the *same* chord
  barely moves it at all, regardless of how loud the attack is.
- **`ChordChangePointAudit`** — compares persisted chord-event times against
  detected change-points: signed median error, median absolute error, and
  hit-rate within a tolerance window. Same shape of metric as the prior
  crude audit (so the two numbers are comparable), but now measuring
  "is there a real harmonic change near this chord event" instead of
  "is there *any* instrumental attack near this chord event."

### A real bug the synthetic tests caught

The first draft used median + k·MAD with a smoothing pre-pass and an
under-scaled MAD. Hand-tracing it in Python (since nothing here can compile
Swift) found two real defects before they reached a test file:

1. **Threshold collapse on clean/near-silent data.** When the chroma stream
   holds one chord for a long stretch (many identical frames, distance
   curve ≈ 0 almost everywhere), both the median and the raw MAD are exactly
   0, so `median + k·MAD` degenerated to a threshold of literally 0 — and
   *every* frame with a nonzero (even floating-point-noise) distance then
   registered as a "local maximum ≥ threshold," firing dozens of spurious
   change-points inside a single sustained chord. Fixed with an explicit
   `minimumThresholdFloor` and a peak-relative fallback spread when both
   median and MAD are zero.
2. **Under-scaled MAD let jitter noise through.** Raw (unscaled) MAD
   under-estimates a Gaussian-like noise spread by ~1.5x, so realistic
   per-frame jitter (±0.01 on already-small chroma values, simulating a
   slightly noisy analysis) pushed several noisy points above threshold.
   Scaling MAD by the standard consistency constant 1.4826 (so it
   approximates a true standard deviation) fixed this with no compiler
   available to catch it — caught only by literally re-implementing the
   same algorithm in Python and running it against >30 independent jitter
   seeds plus a 16-bar/15-change synthetic chord progression before trusting
   the Swift file.
3. Centered smoothing (the initial design's default) turned out to be
   counter-productive once the threshold above was fixed: it reproducibly
   biased a *clean* step function's reported change-point time by
   `~half the smoothing window × hop` (confirmed at ~50ms with a 3-frame/
   50ms-hop window) while buying no extra robustness against jitter. Default
   `smoothingWindow` is now `1` (off); it stays configurable in case a real
   noisy recording later needs it.

None of this would have been caught without independently re-deriving the
algorithm outside Swift and stress-testing it numerically — a reminder that
"looks right by eye" is not enough for a numeric/statistical routine when
there's no compiler or test runner in the loop.

## What the synthetic tests prove

`Tests/SongWorkbenchTests/ChromaChangePointDetectorTests.swift`, 14 tests,
validated by hand-tracing an equivalent Python implementation of the exact
same algorithm against many scenarios before transcribing to Swift:

- Exact detection (± 1μs) of every change-point in a clean, noiseless 3-chord
  step function — no smoothing-induced lag.
- Zero false positives from repeated strums of the *same* chord (chroma is
  pitch content, not onset energy) — the core claim this whole exercise is
  about.
- Correct detection despite ±0.01 per-pitch-class jitter, both for one fixed
  seed and across 30 independent seeded trials (deterministic xorshift32
  PRNG local to the test file, not `SystemRandomNumberGenerator`, so the
  test is reproducible rather than occasionally flaky).
- Exact detection of all 15 change-points in a realistic 16-bar I–V–vi–IV
  progression with independent per-frame jitter on every frame — the
  closest synthetic analogue to a real analyzed guitar stem.
- Correctly detects a chord change even when the two chords share notes
  (C major → A minor share C and E) — something a broadband onset/flux
  detector structurally cannot do, since shared-note chord changes barely
  move total energy.
- Degenerate-input correctness: empty input, single frame, all-silence
  input, unordered input (sorted internally) all behave as documented.
- `ChordChangePointAudit`: perfect alignment → zero error / 100% hit rate;
  a synthetic systematic lag is captured correctly as a signed error with
  correct sign convention; hit-rate correctly reflects the tolerance window;
  unsorted change-point input is handled correctly (binary-search nearest).

These are strong correctness guarantees for the *algorithm*, entirely
independent of any real audio file.

## What still needs a human with a real Mac

This sandbox has no Swift toolchain and cannot build/run the app, and
`Tests/SongWorkbenchTests/` has no bundled real-audio fixture or
pre-computed chroma dump for "There's a party goin on" (confirmed by
search — the song title only appears as lyric-text strings in unrelated
grouping/transcription tests, never as audio or chroma data). So:

- **No new real numbers are reported here for that song.** Reporting a
  specific new signed-median/median-absolute-error/hit-rate for the real
  guitar stem would be fabrication; that requires a human running this
  detector in Xcode against the real analyzed song.
- To get that number: run `ChromaChangePointDetector.changePoints(frames:)`
  over the per-frame `ChromaVector` stream already computed during harmony
  analysis for that song (currently computed and discarded inside
  `ChordClassifier`/`ChordTimelineDecoder` — would need a small plumbing
  change, or a debug/CLI hook, to persist or intercept that stream for one
  song), then call `ChordChangePointAudit.audit(chordEventTimes:changePoints:)`
  with the song's persisted `EditableChordEvent` times.
- The Swift file itself has never been compiled — it was written to match
  existing patterns (`vDSP.dot`/`vDSP.sumOfSquares` usage identical to
  `ChordClassification.swift`'s `cosineSimilarity`, same binary-search
  nearest-neighbour shape as `BeatTracking.swift`'s `nearestOnset`) and
  independently re-verified line-by-line against a hand-written Python
  transliteration, but a human should still build it in Xcode before
  trusting it beyond what the synthetic tests already prove.

## Does this change the earlier "no systematic bias, ~100ms median error" read?

Methodologically, yes — enough to downgrade confidence in that number,
even without new real-song data:

- The earlier metric ("is there *any* onset within X ms") cannot fail to
  find something plausible-looking on a real guitar track: with 941 onsets
  on one song, onsets are dense enough that *most* chord events will land
  near *some* onset whether or not that onset was the actual chord change.
  A high hit-rate under that metric is only weak evidence the chord grid is
  right; it's not strong evidence it's wrong either — it just doesn't
  discriminate well in either direction. The prior note's own "weak
  evidence" caveat was correct.
- The rigorous version asks a stricter, more falsifiable question: is there
  a genuine *harmonic* transition near this chord event, as opposed to any
  strum? A crude flux onset 100ms from a chord-change label could be (a) the
  real chord change, correctly detected late, or (b) a strum of the
  *previous* chord that happens to be within the window — the old metric
  cannot tell these apart, and case (b) would make the old ~100ms number
  look better than it should. The new metric is specifically designed to
  not credit case (b).
- So: the earlier "+10ms signed / 100ms median absolute / 63% within 150ms"
  numbers should be read as an upper bound on accuracy, not a confirmed
  measurement — the true chroma-change-point comparison could show either a
  similar number (if most of the guitar stem's onsets really do coincide
  with chord changes, e.g. a simply-strummed part with few passing notes)
  or a meaningfully worse one (if the guitar part has intra-chord
  strumming/fills, which "goin' on"-style pop-rock rhythm guitar often
  does). Nothing here lets us pick between those two possibilities — that
  determination needs the real numbers from a human running this tool in
  Xcode. What changed is confidence in the measurement's meaning, not a new
  point estimate for the song.

## Files touched

- `Sources/SongWorkbench/ChromaChangePointDetector.swift` (new) —
  `ChromaChangePointDetector`, `ChordChangePointAudit`.
- `Tests/SongWorkbenchTests/ChromaChangePointDetectorTests.swift` (new) —
  14 unit tests, synthetic data only.
- `.scratch/chord-event-timing-audit.md` (this file).
