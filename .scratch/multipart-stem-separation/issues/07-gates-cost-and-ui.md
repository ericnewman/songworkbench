# 07 — Quality gates, cost budget, and presentation

Status: needs-triage

## Work

- Offline harness (env-gated under the test target, as
  `ChordDecoderOfflineValidationTests` already does) computing the PRD §4 metrics per song and
  writing results incrementally to a file (`tasks/lessons.md`: never rely on stdout for a
  long-running harness).
- Record peak RSS and realtime factor per refiner stage; compare against the 8.74 GB / 0.88x
  karaoke precedent and state the macOS/iPad verdict explicitly.
- Storage: a per-instrument, per-algorithm stem set with no eviction policy multiplies disk use.
  Decide the policy before shipping more parts.
- UI: the waveform pane groups a refined family behind one disclosure triangle, so 5 vocal + 5
  drum lanes stay readable; verify with a real 10-lane stem set and check the mixer rail too.

## Acceptance

- [ ] Metrics table committed for the corpus, not a single song.
- [ ] Memory/runtime numbers recorded in `Benchmarks/STEM_SEPARATION.md`.
- [ ] Mixer channels and waveform lanes verified end to end with the full part set.
