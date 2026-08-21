# 08 — Track A: vocal note events on the chart

Status: needs-triage

## Why this is its own issue

Note detection and playable stems diverge after the shared front half of the chain, and
they fail differently (PRD §2b, `FINDINGS-timbral-spike.md` follow-up 3). This track:

- needs **no inverse STFT and no mask synthesis** — the largest piece of new DSP in the PRD
  is not on its critical path;
- is **immune to the unison-double case** that is fatal for stems — two singers in unison
  are one note on the page, and at a 0.10 confidence gate the double-bearing fixture scores
  identically to the clean one;
- already has a three-voice operating point where **every note reported is correct**
  (precision 1.000 at recall 0.667, confidence gate 0.20).

## Work

- Port the note-event layer: f0 tracks → `(onset, offset, midi, pitch, confidence, part)`,
  segmenting a track wherever its running-median pitch settles a new step away (a legato
  slide is two notes inside one track; a per-frame threshold would instead trip on vibrato).
- Follow `BassNoteObservation` (`BassNote.swift`): keep the fractional pitch the rounding
  came from so a later pass can re-arbitrate a borderline rounding against the chord.
- Confidence from f0 strength × pitch steadiness, and a user-facing gate. Default the gate
  where precision is 1.0 rather than where F1 peaks: this is a draft the user edits, and a
  wrong note on the page costs more trust than a missing one.
- Surface on the chart next to the existing bass row.

## Acceptance

- [ ] Note precision ≥ 0.95 at the shipped gate on the corpus, recall reported honestly
      alongside it.
- [ ] Median pitch error ≤ 25 cents; median onset error ≤ 50 ms (spike measured 4.6-8.5
      cents and ~27 ms on synthetic input — treat those as an upper bound).
- [ ] A note the user edits stays edited across re-analysis (same contract as timed lyrics).
- [ ] Four-voice input degrades to fewer notes, never to wrong ones.

## Known gap

At four voices confidence stops discriminating (precision never exceeds 0.70 at any gate).
Track A has its own four-voice problem and it is NOT the same one as Track B's — Track B's
is partial collision in the mask, Track A's is spurious/missing note events. Do not assume a
fix for one helps the other.
