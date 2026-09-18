# Results — forced alignment measured on our own library (2026-09-18)

Status: measured · 19 songs · paired per word · harness in `tools/lyrics_align_spike/`

Tests the recommendation in [FINDINGS-forced-alignment.md](FINDINGS-forced-alignment.md):
replace ASR-derived word times with **forced alignment** using
[`jhuang448/LyricsAlignment-MTL`](https://github.com/jhuang448/LyricsAlignment-MTL) (MIT,
singing-trained, trained on source-separated vocals, 34.8 ms frames).

## Verdict

**It wins, on every song, on the metrics that matter, by margins that are not close.** And the
Core ML conversion — the spike's biggest open engineering question — works.

## Design

Paired A/B. For each song the two arms produce times for the **same word list** from the **same**
vocal stem, so every comparison is per word, and per song for inference.

- **current** — the word times in the app's stored document.
- **MTL** — LyricsAlignment-MTL over the same Demucs vocal stem, given the same words.
- **random** — uniformly random times, the control. With a few hundred onsets in a song, "near
  some onset" can be luck; without this you cannot tell whether the metric resolves anything.

Scored against **measured** onsets from the vocal stem (librosa, backtracked), so no human
annotation is involved. That is what made 19 songs possible when only 2 are human-reviewed.

## Aggregate

| metric | current | **MTL** | random | MTL wins | sign test |
| --- | --- | --- | --- | --- | --- |
| median \|Δ\| to nearest onset | 90.3 ms | **47.4 ms** | 328.3 ms | **19/19** | **p = 3.8e-06** |
| within 100 ms | 57.5 % | **76.3 %** | 32.3 % | **19/19** | **p = 3.8e-06** |
| derailment (>1 s) | 3.4 % | **0.4 %** | 24.5 % | 11/11 differing | **p = 0.00098** |
| words on silent stem | 6.4 % | **2.1 %** | 40.9 % | 12/18 differing | p = 0.24 — **not significant** |

Speed: **13.1× realtime**, CPU, unoptimised Python, whole song at once.

**Read the last row honestly.** The mean improves nearly threefold, but that is carried by a few
catastrophic songs; per song the win rate is 12 of 18, which a sign test cannot separate from
chance. The claim supported by the data is "it fixes the songs that were badly broken", not "it
places fewer words in silence on a typical song".

The first two rows are as strong as this design can produce: every song, both metrics.

## Where the current pipeline was actually broken

| song | words in silence | derailment |
| --- | --- | --- |
| There's a party goin on | **45.0 % → 2.7 %** | **29.1 % → 0.0 %** |
| The Winery Dogs — Fooled Around And Fell In Love | 22.8 % → 0.6 % | 14.6 % → 3.5 % |
| Good friends and a beer or two | 15.5 % → 1.3 % | 0.0 % → 0.0 % |
| Beach Weather — High In Low Places | 7.6 % → 2.4 % | 4.0 % → 0.4 % |

"There's a party goin on" had **45 % of its words sitting where the vocal stem is silent** and
**29 % more than a second from any onset**. That is not a tuning problem.

## Beach Weather, the song that started this

The reported bug: the playhead ran ahead of the audio, the first musical onset landed three
quarters of the way into the opening line, and highlighting fired before anything was sung.

| | current | MTL |
| --- | --- | --- |
| first word | **0.00 s** | **16.75 s** |
| nearest measured stem onset | — | **16.76 s** (10 ms away) |

The old pipeline placed nine words evenly 1.21 s apart from 0.00 against singing that began around
18.8 s. The aligner puts the first word on a measured onset.

## Core ML conversion

`tools/lyrics_align_spike/convert_coreml.py`. The findings document flagged the three bidirectional
LSTMs as the one real risk and noted no conversion had been published.

| | |
| --- | --- |
| converts | **yes**, `mlprogram`, macOS 14 target |
| size | **24.4 MB** fp32 |
| max abs diff vs PyTorch | **3.4e-05** |
| **argmax agreement** | **100.00 %** |

Argmax agreement is the one that matters: alignment depends on the winning class per frame, not on
exact logits.

Two things were needed beyond a naive trace, both documented in the script:

1. The stock `forward` calls `x.view(sizes[0], sizes[1] * sizes[2], sizes[3])` with sizes read off a
   traced tensor. coremltools cannot scalarize those — *"only 0-dimensional arrays can be converted
   to Python scalars"*. Converting at a fixed frame count makes the shapes static literals.
2. The pitch-head sum and `log_softmax` that `wrapper.py` applies after the model are folded in, so
   Core ML emits the `[T, 41]` posteriorgram forced alignment consumes rather than raw logits.

Converted at 2049 mel frames → 683 output frames ≈ 23.8 s per window.

## What this does NOT establish

- **The metric measures plausibility, not correctness.** It asks whether a word sits on a vocal
  onset, not whether it is the *right* word for that onset. A system could score well placing wrong
  words on real onsets. It catches words-in-silence and derailment — which were the visible
  symptoms — and nothing more.
- **No human-verified onset error.** Every number is against an automatic onset detector, itself
  imperfect on singing (published singing-onset F-measures are around 78 % at 50 ms). The two-tier
  annotation plan in the findings document is still the way to a real accuracy figure.
- **Word identity is still the ASR's.** Forced alignment fixes *when*, not *what*. Songs whose
  transcript is wrong stay wrong, and the blend's overlapping-row duplication is untouched.
- **Speed is Python on CPU.** 13.1× realtime is encouraging and is not a Core ML measurement.
- **BDR untested.** The boundary-detection variant, the published version of the onset-anchoring
  thesis, has not been run. Neither has onset snapping.
- **19 songs, one library, one genre cluster.** These are our songs, not a public benchmark.

## Next

1. Run BDR on/off, and onset snapping with a detuned-detector control.
2. Mel front end in Swift, then wire the Core ML model to `CTCForcedAlignment`.
3. Windowing: the model converts at a fixed length, so a song needs chunking with overlap, or
   enumerated shapes.
4. G2P — upstream uses `g2p_en` (CMU ARPABET). For known reference lyrics this can be precomputed
   or served by a CMUdict lookup rather than ported.
