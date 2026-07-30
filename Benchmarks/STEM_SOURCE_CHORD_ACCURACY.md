# Stem Source vs Chord Detection

Two runs, 2026-07-29. Run A measures SENSITIVITY (no labels). Run B measures ACCURACY against
independent charts. Together they answer: does the stem fed to chord detection change the
result, and does it change it for the better?

**Answer: it changes the result a lot, and makes it better almost not at all.**

## Harness

`Tests/SongWorkbenchTests/StemSourceChordAccuracyTests.swift` (additive; no shipping code
changed). Arms: the **guitar** stem (what `HarmonyAudioSourceSelector` prefers today), the
**accompaniment** stem (guitar+piano+other summed at separation time), and the original **full
mix** (no-separation baseline).

Beat grid, bass notes, and bar meter are computed ONCE per song and injected identically into
every arm, so only the chroma source varies; grid identity is asserted per song. The harness
mirrors stage 1-8 of `AnalysisStage.swift:740-839` rather than calling `HarmonyStage.run`, which
needs a full `AnalysisStageContext`.

## Run A — sensitivity (25 songs, no ground truth)

25 already-separated songs, 5,527.9 s. 742.6 s wall.

| pair | songs | agree % | root div % | quality div % | median agree % |
| --- | ---: | ---: | ---: | ---: | ---: |
| guitar vs accompaniment | 25 | 79.8 | 15.1 | 5.0 | 82.1 |
| guitar vs fullmix | 5 | 49.8 | 36.7 | 13.5 | 48.5 |
| accompaniment vs fullmix | 5 | 53.1 | 34.7 | 12.2 | 53.3 |

Chord output is highly sensitive to source: a fifth of a song changes between guitar and
accompaniment, most of it at ROOT level — despite accompaniment being a strict superset of the
guitar stem's content.

Effective N is ~21: four directories are re-analyses producing byte-identical rows
(`0b6422c8`/`27500f39`; `9f6bd108`/`9fa15b34`/`f1145c16`; `9ff8e5ba`/`db1c78e3`). `8b4da4a8` is
a 25 s clip with one chord event scoring a degenerate 100 %.

### Emitted quality

| arm | major % | minor % | maj7 % | m7 % | dom7 % |
| --- | ---: | ---: | ---: | ---: | ---: |
| guitar | 71.8 | 20.8 | 6.8 | 0.0 | 0.6 |
| accompaniment | 72.7 | 20.4 | 6.3 | 0.0 | 0.6 |
| fullmix | 66.4 | 23.0 | 9.6 | 0.1 | 0.9 |

## Run B — accuracy against independent charts (3 songs)

Ground truth: hand/independently-authored ChordPro from `~/Documents/CCS Files 2`. These are
UNTIMED (inline `[C]` markup, no `x_chord_times`), so scoring is **LCS over collapsed chord
sequences**, not time-weighted. Charts are written in capo shapes and are transposed to concert
pitch (`concert = written + capo`) before comparison — verified on `Summertime's here with you`
(`{key: G}`, `{capo: 1}`, comment "Concert key: Ab" → written G maps to concert G#/Ab).

Excluded as circular: `Desktop/Settle Down.cho`, a SongWorkbench export carrying
`{comment: Generated analysis draft - review required}` and `x_chord_times`.

| song | provenance tier | capo | truth | arm | det | root seq % | full seq % |
| --- | --- | ---: | ---: | --- | ---: | ---: | ---: |
| 1c2f744d326b Summertime's | **Reviewed performance chart** | 1 | 75 | guitar | 84 | 37.3 | 33.3 |
| | | | | accompaniment | 82 | 37.3 | 32.0 |
| | | | | fullmix | 81 | 38.7 | 28.0 |
| 3ba46cbaba9c Key West Bar | Transcribed from recording | 1 | 84 | guitar | 124 | 94.0 | 90.5 |
| | | | | accompaniment | 121 | 94.0 | 90.5 |
| | | | | fullmix | 143 | 90.5 | 79.8 |
| f1145c16433f Flip Flops | Automated best-effort | 1 | 34 | guitar | 123 | 100.0 | 94.1 |
| | | | | accompaniment | 125 | 100.0 | 97.1 |
| | | | | fullmix | 170 | 100.0 | 88.2 |

### Aggregate

| arm | songs | mean root % | median root % | mean full % | median full % |
| --- | ---: | ---: | ---: | ---: | ---: |
| guitar | 3 | 77.1 | 94.0 | 72.6 | 90.5 |
| accompaniment | 3 | **77.1** | 94.0 | **73.2** | 90.5 |
| fullmix | 3 | 76.4 | 90.5 | 65.3 | 79.8 |

**Guitar and accompaniment are tied on root accuracy to the decimal, and accompaniment is
marginally ahead on full quality.** The 15.1 % root divergence from Run A produces no accuracy
advantage for either.

## Run C — expanded set with a precision-corrected scorer (6 pairs, 5 songs)

Run B's LCS metric was recall-only. Run C adds precision and F1, plus an explicit
`over_seg_ratio` column, and widens the set. Two songs were recovered without any separation by
duration-matching orphaned stem directories to named audio (`There's a party goin on` 169.9 s →
`0b6422c8`; `Good friends and a beer or two` 225.7 s → `9ff8e5ba`). 185.9 s wall.

| arm | root F1 | root prec | root rec | full F1 | full prec | full rec | over-seg |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| guitar | **50.6** | 40.2 | 77.6 | **45.9** | 35.7 | 72.7 | 2.24x |
| accompaniment | **50.6** | 40.5 | 77.5 | 45.1 | 35.4 | 71.2 | 2.27x |
| fullmix | 45.9 | 36.1 | 78.0 | 39.0 | 30.0 | 68.6 | 2.73x |

The fix mattered: `Flip Flops` fell from a meaningless 100.0 % to 43.3 % F1 once its 3.62x
over-detection was penalised.

### Per song

| song | tier | truth | arm | det | over-seg | root F1 | full F1 |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: |
| 1c2f744d Summertime's | reviewed | 75 | guitar | 84 | 1.12 | 35.2 | 30.5 |
| | | | accompaniment | 82 | 1.09 | 35.7 | 29.4 |
| | | | fullmix | 81 | 1.08 | 37.2 | 26.6 |
| 1c2f744d Summertime's | automated-dup | 69 | guitar | 84 | 1.22 | 70.6 | 60.8 |
| | | | accompaniment | 82 | 1.19 | 72.8 | 63.7 |
| | | | fullmix | 81 | 1.17 | 68.0 | 55.3 |
| 3ba46cba Key West Bar | transcribed | 84 | guitar | 124 | 1.48 | 76.0 | 70.7 |
| | | | accompaniment | 121 | 1.44 | 77.1 | 72.7 |
| | | | fullmix | 143 | 1.70 | 67.0 | 57.8 |
| f1145c16 Flip Flops | automated | 34 | guitar | 123 | 3.62 | 43.3 | 39.5 |
| | | | accompaniment | 125 | 3.68 | 42.8 | 40.0 |
| | | | fullmix | 170 | 5.00 | 33.3 | 29.0 |
| 0b6422c8 There's a party | automated | 27 | guitar | 82 | 3.04 | 33.0 | 29.1 |
| | | | accompaniment | 83 | 3.07 | 29.1 | 23.2 |
| | | | fullmix | 100 | 3.70 | 29.9 | 29.7 |
| 9ff8e5ba Good friends | automated | 38 | guitar | 112 | 2.95 | 45.3 | 45.0 |
| | | | accompaniment | 119 | 3.13 | 45.9 | 41.5 |
| | | | fullmix | 141 | 3.71 | 40.2 | 35.6 |

### By tier

| tier | songs | guitar root F1 | accompaniment root F1 | fullmix root F1 | over-seg |
| --- | ---: | ---: | ---: | ---: | ---: |
| reviewed | 1 | 35.2 | 35.7 | 37.2 | 1.1x |
| automated-dup | 1 | 70.6 | 72.8 | 68.0 | 1.2x |
| transcribed | 1 | 76.0 | 77.1 | 67.0 | 1.5x |
| automated | 3 | 40.6 | 39.2 | 34.5 | 3.2x |

### The duplicate-chart control — ground truth dominates the measurement

The same audio and the same detector output, scored against two different charts for that song:

| chart | guitar root F1 |
| --- | ---: |
| Reviewed performance chart | 35.2 |
| Best-effort transcription | **70.6** |

**The score doubles depending on which chart is called truth.** The two charts also declare
different keys for the same song (written G / concert G# vs written C / concert C#, a fourth
apart), so at least one is wrong about key. Chart quality currently swamps every stem effect
measured here; treat any single-chart accuracy figure accordingly.

## Vocabulary ceiling — measured, and it is NOT the limit

37 independent charts, 2,361 chord tokens:

| suffix | count | share | representable? |
| --- | ---: | ---: | --- |
| (major) | 1781 | 75.4 % | yes |
| m | 478 | 20.2 % | yes |
| m7 | 66 | 2.8 % | yes |
| add9 | 18 | 0.8 % | no |
| maj9 | 10 | 0.4 % | no |
| 6 | 2 | 0.1 % | no |
| 7 | 2 | 0.1 % | yes |
| add11, madd9, m7add11, 7sus4 | 4 | 0.2 % | no |

**Out-of-vocabulary: 1.4 %.** The 5-quality vocabulary covers 98.6 % of this repertoire, and all
three scored songs had 0.0 % OOV. The earlier hypothesis that vocabulary caps accuracy is
**refuted**.

The classifier, however, is miscalibrated on sevenths in both directions:

| quality | ground truth | detector (guitar arm) |
| --- | ---: | ---: |
| maj7 | **0 tokens (0.0 %)** | 6.8 % |
| m7 | 66 tokens (2.8 %) | **0.0 %** |

It emits `maj7` 6.8 % of the time in a repertoire containing zero maj7 chords, and never emits
the `m7` that occurs 66 times.

**Narrowed to the 6 scored charts specifically** (370 chord tokens): 84.3 % major, 15.7 % minor,
and **zero** maj7, m7, and dom7 — those songs are pure triads, OOV 0.0 %. So on the scored set
the maj7 false-positive stands (detector 6.8 % vs truth 0 %), while the m7 miss cannot be
assessed there — its evidence comes from the wider 37-chart corpus, where m7 appears 66 times.
The two halves of the miscalibration finding therefore rest on different samples; say so rather
than quoting them as one number.

## Limitations

- **N=3, of which only ONE is a Reviewed chart.** The other two are self-described automated
  transcriptions from another tool — independent of this decoder, so not circular, but of
  unknown accuracy. Conclusions at the strong tier rest on one song.
- **LCS/truth-length is recall-only — no precision penalty.** A detector emitting many chords
  scores high: `Flip Flops` detects 123 events against 34 truth chords (3.6×) and scores a
  meaningless 100 %. Absolute levels are inflated. The guitar-vs-accompaniment COMPARISON is
  unaffected — their sequence lengths are near-identical (84/82, 124/121, 123/125) — but
  fullmix over-detects more (81/143/170), so separation's advantage is if anything understated.
- The one song with balanced sequence lengths AND a Reviewed chart scores worst (37.3 % root),
  which is consistent with the metric rewarding over-segmentation elsewhere.
- Run A's root divergence is a ~1-2 point over-estimate (song lead-in before the first event is
  uncovered in both arms and scored as divergence).
- `instrumentOnsets` varies per arm by design, mirroring production; the comparison isolates
  audio source, not chroma alone.

## Decision

**Phase 1 (BS-RoFormer guitar stem): NO-GO on current evidence.**

The premise was that a better guitar stem improves chords because chord detection reads the
guitar stem. Run B tests that premise directly and it does not hold: swapping between two
genuinely different separations changes 15 % of roots while leaving accuracy identical
(77.1 / 77.1). Output moves; quality does not. A better guitar stem has no demonstrated path to
better chords.

Separation as such still earns its place — guitar beats full mix by 7.3 points on full-quality
accuracy — but that is the already-shipped benefit, not an argument for a second model.

**The bigger lever is the classifier and event segmentation, not the stem:**
1. Seventh confusion — `maj7` emitted at 6.8 % where truth has 0 %; `m7` never emitted where
   truth has 2.8 %.
2. Over-segmentation — 1.1× to 3.6× more chord events than the charts carry.
Both are stem-independent and cheaper to attack than integrating a new separation model.

**Before any further stem work:** get more Reviewed charts (N=1 cannot carry this), and add a
precision term to the scorer so over-segmentation is penalised rather than rewarded.

## Reproduce

```sh
# Run A — sensitivity, no labels
SW_STEM_BATCH=1 SW_STEM_BATCH_ROOT="<container>/Analysis/Stems" \
SW_STEM_BATCH_MIXMAP=mixmap.tsv \
  swift test --jobs 1 --filter testBatchAgreementAcrossSeparatedSongs

# Run B — accuracy vs charts
SW_STEM_GT=1 SW_STEM_GT_MANIFEST=gt_manifest.tsv SW_STEM_GT_OUT=gt_results.txt \
  swift test --jobs 1 --filter testGroundTruthSequenceAccuracy
```

`gt_manifest.tsv`: `<stemDirName>\t<stems dir>\t<mix path or empty>\t<chart .cho path>`.
Run B flushes per song to `SW_STEM_GT_OUT`; Run A buffers stdout until exit (~12 min for 25
songs).
