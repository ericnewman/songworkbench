# Transcription Benchmark

## Corpus And Scoring

- Recording: reviewed alternate `Summertime's here with you`, 233.50 seconds.
- Content: lead singing over a full band, instrumental sections, and repeated
  choruses.
- Reference: the reviewed lyrics-only catalog export, 194 normalized words.
- Metric: case/punctuation-insensitive Levenshtein word error rate using
  `Tools/compare_transcriptions.py`.

The reference still contains a few artistically ambiguous phrases, so absolute
WER is directional. Relative results are useful because every engine is scored
against the same complete arrangement and reference.

## Results

| Engine/configuration | Total time | Max resident | S / D / I | WER |
| --- | ---: | ---: | ---: | ---: |
| FluidAudio Parakeet TDT v3 | 29.03 s | 527 MB | 42 / 16 / 4 | 31.96% |
| Whisper Large V3 MLX, default conditioning | 325.20 s | 1.27 GB | 61 / 2 / 282 | 177.84% |
| Whisper Large V3 MLX, previous-text conditioning off | 95.65 s | 3.13 GB | 9 / 0 / 2 | 5.67% |

FluidAudio used current source at commit
`ffefeec2147ee05ee2ea42e788960bf38ac107b5`. Its optimized CLI was 10.6 MB.
The complete downloaded model repository occupied 2.8 GB because it includes
legacy and alternate model variants; the v3 INT8 runtime subset is about
461 MB.

The cached MLX Whisper Large V3 model occupied 2.9 GB. The successful
anti-repetition pass decoded the song in about 10.5 seconds after model/import
startup, but its end-to-end time and memory were still substantially higher
than FluidAudio.

## Failure Modes

- FluidAudio was fast and bounded but made many phonetic substitutions on sung
  words and omitted some repeated material.
- Default Whisper conditioning entered a long repeated-phrase loop during an
  instrumental section. This is unacceptable without configuration safeguards.
- Disabling previous-text conditioning removed the loop and preserved all
  reviewed sections with only a small number of substitutions/insertions.
- A word-timestamp hallucination-filter pass was abandoned after 479 seconds
  because this local environment stalled while importing SciPy and never
  reached inference. That configuration is not viable for the app.

## Runtime Scope

The Whisper measurement used the locally available MLX runtime, not
SwiftWhisper. It measures the Large V3 model's CCS lyric accuracy and failure
modes, but not whisper.cpp/SwiftWhisper binary size or speed. Swift integration
should use direct whisper.cpp or a maintained wrapper and must repeat a smaller
runtime benchmark with its chosen quantized model before release.

## Decision

- Use FluidAudio/Parakeet for an optional **fast draft** mode and responsive
  first-pass timestamps.
- Use Whisper with previous-text conditioning disabled for **accuracy mode** on
  songs and for low-confidence FluidAudio sections.
- Keep the implementation behind `TranscriptionEngine`; models are downloaded
  on demand and neither runtime is bundled in the base app.
- Do not label raw ASR output as reviewed lyrics. Both engines require an
  editable timeline and confidence-aware human review.

For the current app, accuracy mode is the recommended default for lyric work.
FluidAudio is the recommended default only when turnaround and memory are more
important than transcription fidelity.
