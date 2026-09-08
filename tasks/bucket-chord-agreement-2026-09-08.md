# Bucket notes vs. detected chords — 2026-09-08

Question (Eric): can the per-stem metronome-bucket notes disambiguate LOW-confidence chords?
Method: `SW_BUCKET_CHORD_DIAG=1 swift test --skip-build --filter BucketChordAgreementDiagnosticTests`
cuts every analysed song's bucket timeline from the stems on disk, then for each chord span
scores (a) the share of guitar/piano/other bucket pitch-class mass that lies on the chord's tones,
(b) the share of bass buckets whose note is the chord root, and (c) the best major/minor triad by
tones + ½·bass-root + 0.1 diatonic prior; an "alternative" is flagged when it beats the detected
triad by ≥ 0.15. 14 songs, 2018 chords, ~20 s of bucket cutting per song.

## Findings

1. **The first run exposed a detector bug, not a chord insight.** Guitar filled 96/428 buckets and
   piano 38/428 on *Back To You* because the polyphonic gate was an absolute 0.18 chroma share and
   the guitar's MEDIAN top share is 0.175 (piano 0.159). Replaced with a relative gate (top class
   ≥ 1.5/12, others ≥ 60 % of top): guitar 395/428, piano 156/428, other 364/428. `buckets-2`.
2. **Agreement tracks confidence, weakly.** Mean chord-tone agreement 0.55 / 0.60 / 0.65 for
   conf <0.60 / 0.60–0.69 / ≥0.70; Pearson r = 0.13 over 1763 chords with evidence. The decoder's
   confidence is only loosely about what the stems are playing.
3. **Bass is not a root oracle.** Bass-root agreement is ~0.40 in EVERY confidence bin: the bass
   bucket note is off-root (fifths, walking lines, passing tones, octave folds) more often than on.
   Weighting bass by beat-1 of the bar is the obvious next refinement.
4. **Alternatives fire on a third of ALL chords** (39 % / 33 % / 32 % by bin), so the simple triad
   scorer disagrees with the Viterbi decoder about as often for confident chords as for shaky
   ones. Without ground truth this cannot be read as "the decoder is wrong a third of the time"
   — the untimed `Key West Bar.cho` already agrees 94 % with detection, and there is no reviewed
   chart with times in the store (all 14 songs are `draft`, 0 accepted chords).
5. **Some low-confidence flags are musically convincing** and worth Eric's ear:
   *Grass of my Home* (D major) `Bmaj7` 0.58 @116.6 → `Bm` (bass on B 80 % of the span);
   *Eight Miles High* `Bm` 0.63 @19.7 → `Em` (7 buckets; matches the Em-riff intro decoded 09-05),
   `E` 0.62 @144.7 → `D`, `Ab` 0.63 @123.0 → `C#m`; *Grass* `D` @150.2/184.8 → `A` with bass
   never on D. Per-song tables below list the 25 lowest-confidence chords each.

## What would make this decisive

- Ground truth with times: Eric accepts/corrects ~30 flagged chords in Review on 2–3 songs; the
  diagnostic then reports precision of the alternatives by confidence bin.
- Feed the evidence INTO the decoder (an emission bonus per beat window from bucket pitch-class
  mass + beat-1 bass) rather than relabelling after the fact — the memory on decoder knobs says
  post-hoc relabels only slide precision/recall, so this needs the same N=3 discipline.
- Span length: chords 1–2 beats long have ≤ 2 buckets; pooling evidence over the chord's whole
  bar (or its neighbours when the chord repeats) would cut the "inconclusive" count (31 of 131
  low-confidence chords).

---

## Summary (2018 chords, 14 songs)

| confidence | chords | mean chord-tone agreement | mean bass-root agreement | alternative suggested | inconclusive (<2 buckets) |
|---|---|---|---|---|---|
| <0.60 | 131 | 0.55 | 0.35 | 51 (39%) | 31 |
| 0.60–0.69 | 643 | 0.60 | 0.41 | 210 (33%) | 122 |
| ≥0.70 | 1244 | 0.65 | 0.40 | 398 (32%) | 162 |

Pearson r(confidence, chord-tone agreement) = 0.127 over 1763 chords

# Bucket notes vs. detected chords — 2026-09-08 12:41:37 +0000

## When the sun goes down (2)

146 chords · key Eb major · stems bass, guitar, other, piano, vocals.backing, vocals.lead · bucket pass 22.0s

Low-confidence chords (<0.65): 24

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 140.8 | Eb | 0.56 | 0.52 | 0.00 | 10 | A# (0.92 vs 0.62) |
| 13.6 | Bb | 0.56 | 0.72 | 1.00 | 7 | confirms |
| 188.4 | Eb | 0.58 | 0.56 | 0.00 | 20 | confirms |
| 41.3 | Eb | 0.58 | 0.72 | 0.00 | 3 | G# (1.43 vs 0.82) |
| 133.9 | Eb | 0.58 | 0.64 | 0.00 | 18 | confirms |
| 12.2 | Cm7 | 0.59 | 0.83 | 0.50 | 5 | confirms |
| 84.6 | Bb | 0.60 | 0.87 | 0.53 | 5 | confirms |
| 58.4 | Eb | 0.60 | 0.75 | 0.00 | 12 | G# (1.01 vs 0.85) |
| 169.6 | Eb | 0.60 | 0.47 | — | 3 | confirms |
| 10.2 | Eb | 0.61 | 0.86 | 0.00 | 13 | confirms |
| 105.4 | Eb | 0.61 | 0.84 | 0.00 | 12 | confirms |
| 25.2 | Gm | 0.61 | 0.37 | — | 1 | inconclusive |
| 30.3 | Ab | 0.62 | 0.27 | — | 6 | Gm (0.60 vs 0.37) |
| 128.5 | Ab | 0.62 | 0.49 | 1.00 | 6 | confirms |
| 37.5 | Bb | 0.63 | 0.84 | 1.00 | 6 | confirms |
| 6.7 | Bb | 0.63 | 0.00 | — | 1 | inconclusive |
| 39.0 | Gm | 0.63 | — | — | 0 | inconclusive |
| 7.5 | Ab | 0.63 | 0.24 | 0.00 | 7 | C# (0.73 vs 0.34) |
| 66.6 | Ab | 0.64 | 0.67 | 1.00 | 3 | confirms |
| 105.1 | Ab | 0.64 | — | — | 0 | inconclusive |
| 53.0 | Eb | 0.64 | 0.76 | 0.00 | 14 | confirms |
| 129.2 | Eb | 0.65 | 1.00 | 0.00 | 3 | confirms |
| 209.9 | Cm7 | 0.65 | 0.75 | 1.00 | 3 | confirms |
| 24.5 | Gm | 0.65 | 0.62 | — | 1 | inconclusive |

## Its a Party goin on

157 chords · key G major · stems bass, guitar, other, piano, vocals · bucket pass 20.3s

Low-confidence chords (<0.65): 59

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 213.7 | C | 0.56 | 0.51 | 0.00 | 6 | F (1.27 vs 0.61) |
| 177.3 | D | 0.56 | — | — | 0 | inconclusive |
| 213.1 | C# | 0.56 | 0.10 | 0.00 | 3 | F (0.75 vs 0.10) |
| 177.5 | Gm | 0.56 | 0.39 | — | 6 | C (0.58 vs 0.39) |
| 74.2 | D | 0.56 | 0.37 | 0.00 | 2 | G (1.60 vs 0.47) |
| 149.8 | D | 0.57 | 0.54 | 0.00 | 12 | G (1.35 vs 0.64) |
| 215.2 | C | 0.57 | 0.47 | 1.00 | 5 | confirms |
| 190.3 | C | 0.58 | 0.55 | 0.25 | 11 | confirms |
| 117.5 | G | 0.58 | 0.92 | 1.00 | 6 | confirms |
| 196.0 | Gm | 0.58 | 0.49 | 0.75 | 27 | G (1.02 vs 0.87) |
| 126.7 | D | 0.58 | 0.39 | 0.27 | 20 | confirms |
| 88.1 | C#m | 0.58 | 0.22 | 0.00 | 23 | G (0.67 vs 0.22) |
| 106.0 | D | 0.59 | 0.56 | 0.00 | 3 | G (1.49 vs 0.66) |
| 221.9 | C#m | 0.59 | 0.00 | 0.00 | 2 | D (1.10 vs 0.00) |
| 55.2 | C | 0.59 | 0.89 | 0.00 | 3 | Fm (1.17 vs 0.99) |
| 213.5 | D | 0.59 | — | — | 0 | inconclusive |
| 220.2 | F | 0.59 | — | 1.00 | 1 | inconclusive |
| 203.4 | C | 0.59 | 0.88 | 1.00 | 5 | confirms |
| 98.2 | G | 0.59 | 0.79 | 0.50 | 16 | confirms |
| 220.9 | C | 0.60 | 0.80 | 1.00 | 3 | confirms |
| 212.2 | G | 0.60 | 0.43 | 1.00 | 6 | confirms |
| 228.5 | C# | 0.60 | 0.15 | 0.00 | 3 | G (1.10 vs 0.15) |
| 87.6 | C# | 0.60 | 0.00 | — | 1 | inconclusive |
| 53.1 | Dm | 0.60 | 0.54 | 0.00 | 14 | G (1.23 vs 0.54) |
| 204.4 | Cm | 0.60 | 1.00 | 1.00 | 2 | confirms |

## It may be all you get

147 chords · key G major · stems bass, guitar, other, piano, vocals · bucket pass 22.9s

Low-confidence chords (<0.65): 10

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 181.2 | D | 0.59 | 0.35 | 0.00 | 5 | Em (1.00 vs 0.45) |
| 102.4 | Bm7 | 0.61 | 1.00 | 1.00 | 2 | confirms |
| 233.1 | G | 0.61 | 0.88 | 0.66 | 25 | confirms |
| 159.2 | D | 0.62 | 0.68 | 0.86 | 16 | confirms |
| 5.0 | Bb | 0.62 | 0.32 | — | 4 | G (0.67 vs 0.32) |
| 41.3 | D | 0.63 | 0.44 | 0.00 | 4 | G (0.89 vs 0.54) |
| 79.7 | Bm | 0.64 | 0.67 | 0.33 | 5 | confirms |
| 191.2 | Gmaj7 | 0.65 | 0.54 | 0.50 | 6 | confirms |
| 148.2 | G | 0.65 | 0.64 | 0.73 | 9 | confirms |
| 83.5 | Am | 0.65 | 0.40 | 0.28 | 21 | C (0.90 vs 0.64) |

## You and me in paradise (4) (1)

132 chords · key Eb major · stems bass, guitar, other, piano, vocals · bucket pass 19.6s

Low-confidence chords (<0.65): 31

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 143.6 | Bb | 0.53 | 0.65 | 0.80 | 13 | confirms |
| 125.0 | Gm | 0.54 | 0.89 | 0.50 | 4 | confirms |
| 97.7 | Gm | 0.54 | 0.50 | 0.00 | 3 | A# (1.60 vs 0.60) |
| 127.7 | Ab | 0.55 | 0.70 | 0.59 | 10 | confirms |
| 94.3 | Bb | 0.55 | 0.76 | 1.00 | 10 | confirms |
| 130.6 | Bb | 0.55 | 0.68 | 0.33 | 6 | confirms |
| 64.8 | Ab | 0.55 | 0.24 | 0.00 | 3 | A# (1.36 vs 0.34) |
| 99.1 | Em | 0.55 | 0.00 | 0.00 | 2 | A# (1.60 vs 0.00) |
| 76.4 | Bb | 0.57 | 0.65 | 0.56 | 4 | confirms |
| 139.5 | Abmaj7 | 0.58 | 1.00 | 0.67 | 5 | confirms |
| 230.6 | Bb | 0.58 | — | — | 0 | inconclusive |
| 187.4 | Ab | 0.58 | 0.39 | — | 7 | confirms |
| 149.9 | Cm | 0.59 | 0.78 | 0.00 | 6 | G# (1.10 vs 0.88) |
| 63.4 | Gm | 0.60 | 0.34 | 0.67 | 5 | D# (0.99 vs 0.78) |
| 71.3 | Cm | 0.60 | 0.31 | 0.00 | 3 | D# (0.98 vs 0.41) |
| 126.3 | G7 | 0.60 | 1.00 | 1.00 | 4 | confirms |
| 236.1 | F | 0.61 | — | — | 0 | inconclusive |
| 136.7 | Gm | 0.61 | 0.70 | 0.75 | 8 | confirms |
| 107.7 | C# | 0.61 | 0.48 | 0.45 | 6 | G# (0.96 vs 0.70) |
| 195.7 | Cm | 0.62 | 0.58 | 0.50 | 6 | Fm (1.09 vs 0.93) |
| 141.5 | C#maj7 | 0.62 | 1.00 | 1.00 | 6 | confirms |
| 235.4 | Cm | 0.62 | — | — | 0 | inconclusive |
| 108.6 | Ab | 0.63 | 0.70 | 1.00 | 3 | confirms |
| 197.0 | F7 | 0.63 | 0.72 | 1.00 | 3 | confirms |
| 61.5 | Eb | 0.63 | 0.59 | 0.00 | 8 | confirms |

## Flip Flops and Barbeque

83 chords · key Eb major · stems bass, guitar, other, piano, vocals · bucket pass 15.8s

Low-confidence chords (<0.65): 8

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 164.2 | F | 0.55 | — | — | 0 | inconclusive |
| 165.8 | Gm | 0.59 | 0.70 | 0.00 | 2 | D# (1.10 vs 0.80) |
| 21.9 | Bb | 0.62 | 0.42 | — | 3 | Gm (0.72 vs 0.52) |
| 176.2 | Ab | 0.63 | 0.59 | 0.67 | 8 | confirms |
| 166.9 | Eb | 0.63 | 0.66 | 0.00 | 8 | confirms |
| 77.8 | Eb | 0.64 | 0.74 | 0.34 | 18 | confirms |
| 118.8 | C | 0.64 | 0.31 | — | 6 | D# (0.79 vs 0.31) |
| 77.3 | Bb | 0.65 | 1.00 | 1.00 | 2 | confirms |

## Back To You- Cross Cut Saw

114 chords · key G major · stems bass, guitar, other, piano, vocals · bucket pass 24.8s

Low-confidence chords (<0.65): 1

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 65.3 | Em | 0.64 | 0.41 | 0.28 | 15 | confirms |

## It Is Well With My Soul - Quartet

213 chords · key C major · stems bass, guitar, other, piano, vocals.backing, vocals.lead · bucket pass 22.3s

Low-confidence chords (<0.65): 6

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 207.0 | Bm | 0.62 | 0.56 | — | 2 | confirms |
| 86.2 | C | 0.63 | 0.00 | — | 1 | inconclusive |
| 0.6 | F | 0.63 | — | — | 0 | inconclusive |
| 178.3 | Em | 0.64 | 0.74 | — | 4 | confirms |
| 96.4 | Dm | 0.65 | 0.77 | — | 2 | confirms |
| 171.7 | Gmaj7 | 0.65 | 0.20 | — | 2 | C (0.77 vs 0.30) |

## I'm not coming back

110 chords · key Bb major · stems bass, guitar, other, piano, vocals · bucket pass 21.0s

Low-confidence chords (<0.65): 22

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 232.3 | F | 0.54 | 0.32 | 0.00 | 26 | A# (0.92 vs 0.42) |
| 230.0 | F | 0.55 | — | — | 0 | inconclusive |
| 170.1 | F | 0.55 | 0.33 | 0.20 | 32 | A# (0.99 vs 0.53) |
| 57.8 | Bb | 0.56 | — | — | 0 | inconclusive |
| 232.1 | Ab | 0.57 | — | — | 0 | inconclusive |
| 213.2 | Cm | 0.58 | 0.33 | 0.00 | 3 | D# (0.87 vs 0.43) |
| 193.7 | F | 0.59 | 0.70 | 0.00 | 3 | A# (1.60 vs 0.80) |
| 63.0 | Bb | 0.59 | 0.47 | 0.24 | 8 | confirms |
| 230.4 | Cm | 0.60 | 0.38 | 0.00 | 6 | Fm (1.21 vs 0.47) |
| 144.4 | F | 0.60 | 0.89 | 1.00 | 3 | confirms |
| 59.7 | Ab | 0.60 | 0.20 | 0.00 | 8 | A# (1.40 vs 0.20) |
| 69.1 | Eb | 0.61 | 0.55 | 0.00 | 4 | Gm (0.88 vs 0.65) |
| 156.8 | Ab | 0.62 | 0.74 | 0.50 | 6 | confirms |
| 124.6 | Bb | 0.63 | 0.89 | 1.00 | 3 | confirms |
| 215.9 | F | 0.63 | 0.69 | 0.43 | 9 | confirms |
| 189.2 | G | 0.63 | 0.00 | 0.00 | 3 | Fm (1.35 vs 0.00) |
| 214.2 | Gm7 | 0.63 | — | — | 0 | inconclusive |
| 142.8 | F | 0.64 | 0.65 | 0.00 | 3 | A# (1.30 vs 0.75) |
| 58.1 | Eb | 0.64 | 0.65 | 0.00 | 4 | confirms |
| 179.4 | Eb | 0.64 | 0.80 | 0.00 | 6 | confirms |
| 194.7 | Bb | 0.64 | 0.74 | 0.41 | 39 | confirms |
| 152.3 | Bb | 0.64 | 0.44 | 0.00 | 3 | D# (0.71 vs 0.54) |

## Grass of my Home

104 chords · key D major · stems bass, guitar, other, piano, vocals · bucket pass 22.1s

Low-confidence chords (<0.65): 61

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 176.5 | D | 0.54 | — | 0.00 | 1 | inconclusive |
| 196.9 | Bm7 | 0.55 | — | 1.00 | 1 | inconclusive |
| 9.2 | D | 0.56 | — | 0.00 | 1 | inconclusive |
| 121.2 | G | 0.57 | — | 0.00 | 1 | inconclusive |
| 150.2 | D | 0.57 | 0.50 | 0.00 | 7 | A (0.83 vs 0.60) |
| 8.0 | A | 0.57 | — | — | 0 | inconclusive |
| 110.5 | B | 0.58 | — | 0.00 | 1 | inconclusive |
| 46.4 | D | 0.58 | 0.30 | 0.00 | 2 | B (1.00 vs 0.40) |
| 157.4 | A | 0.58 | — | 1.00 | 2 | confirms |
| 184.8 | D | 0.58 | 0.27 | 0.00 | 5 | A (1.10 vs 0.37) |
| 149.7 | A | 0.58 | — | 1.00 | 1 | inconclusive |
| 116.6 | Bmaj7 | 0.58 | 0.20 | 0.80 | 6 | Bm (1.00 vs 0.60) |
| 22.1 | E | 0.59 | — | 0.00 | 1 | inconclusive |
| 90.5 | Bm7 | 0.59 | 0.70 | 1.00 | 5 | confirms |
| 35.5 | D | 0.59 | 0.60 | 0.00 | 8 | A (0.87 vs 0.70) |
| 166.3 | A | 0.59 | 0.83 | 0.88 | 14 | confirms |
| 170.8 | Bm7 | 0.60 | — | 1.00 | 3 | confirms |
| 38.2 | Bm7 | 0.60 | 0.68 | 0.75 | 9 | confirms |
| 34.1 | A | 0.60 | 0.30 | 1.00 | 5 | confirms |
| 153.0 | Bm7 | 0.60 | 0.63 | 1.00 | 7 | confirms |
| 188.1 | Bm7 | 0.60 | — | 1.00 | 1 | inconclusive |
| 115.5 | A | 0.60 | — | 1.00 | 2 | confirms |
| 160.3 | A | 0.60 | — | 0.67 | 3 | confirms |
| 107.1 | A | 0.60 | — | 0.67 | 3 | confirms |
| 121.7 | A | 0.61 | 0.93 | 1.00 | 6 | confirms |

## Beach Weather - High In Low Places (Official Video)

81 chords · key F major · stems bass, guitar, other, piano, vocals.backing, vocals.lead · bucket pass 21.0s

Low-confidence chords (<0.65): 22

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 0.6 | Fmaj7 | 0.54 | 0.84 | 1.00 | 10 | confirms |
| 175.6 | Cm | 0.56 | 0.50 | 0.00 | 3 | F (1.50 vs 0.50) |
| 48.0 | F | 0.57 | 0.65 | 0.00 | 3 | A# (1.20 vs 0.75) |
| 47.3 | F | 0.58 | 0.70 | 0.00 | 2 | A# (1.40 vs 0.80) |
| 170.2 | Ab | 0.59 | 0.64 | 1.00 | 8 | confirms |
| 165.9 | C | 0.59 | 0.55 | 0.00 | 3 | F (1.45 vs 0.65) |
| 53.6 | Ab | 0.59 | 0.59 | 0.40 | 26 | confirms |
| 8.3 | C# | 0.59 | 0.55 | 0.00 | 12 | F (0.80 vs 0.55) |
| 108.6 | Ab | 0.59 | 0.81 | 0.50 | 23 | confirms |
| 49.1 | Bb | 0.60 | 0.36 | 0.50 | 8 | F (1.10 vs 0.71) |
| 105.4 | Bbm | 0.60 | 0.00 | 0.00 | 3 | F (1.60 vs 0.00) |
| 69.7 | Bbmaj7 | 0.61 | — | — | 0 | inconclusive |
| 122.4 | Gm | 0.62 | — | — | 0 | inconclusive |
| 114.4 | F | 0.62 | 0.83 | 0.33 | 16 | confirms |
| 60.1 | Bb | 0.62 | 0.42 | 0.50 | 6 | F (1.21 vs 0.77) |
| 100.5 | Abmaj7 | 0.62 | 0.57 | 0.43 | 15 | confirms |
| 96.2 | C | 0.63 | 0.56 | 0.00 | 7 | F (1.41 vs 0.66) |
| 66.4 | Eb | 0.64 | 0.30 | 0.00 | 3 | G# (1.50 vs 0.30) |
| 180.7 | Eb | 0.65 | 0.15 | 0.00 | 3 | G# (1.25 vs 0.15) |
| 34.2 | Eb | 0.65 | 0.23 | 0.00 | 15 | A#m (0.88 vs 0.23) |
| 48.3 | Am | 0.65 | 0.50 | 0.00 | 2 | A# (0.90 vs 0.60) |
| 4.9 | Bb | 0.65 | 0.82 | 0.00 | 3 | F (1.15 vs 0.92) |

## Just get up and dance

236 chords · key Ab major · stems bass, guitar, other, piano, vocals · bucket pass 21.4s

Low-confidence chords (<0.65): 76

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 203.7 | Dm | 0.51 | 0.17 | 0.00 | 7 | G# (1.38 vs 0.17) |
| 202.0 | Ab | 0.52 | — | — | 0 | inconclusive |
| 203.0 | Bb | 0.53 | — | 0.00 | 1 | inconclusive |
| 105.3 | Eb | 0.55 | 0.61 | 0.00 | 14 | confirms |
| 190.9 | Abm | 0.55 | 0.62 | — | 1 | inconclusive |
| 2.1 | E | 0.55 | 0.20 | — | 1 | inconclusive |
| 240.4 | C# | 0.56 | — | — | 0 | inconclusive |
| 40.4 | Dm | 0.56 | 0.50 | 0.00 | 3 | A (0.75 vs 0.50) |
| 99.0 | D | 0.57 | — | — | 0 | inconclusive |
| 238.2 | Abmaj7 | 0.57 | 0.20 | 0.00 | 3 | A# (0.65 vs 0.30) |
| 142.1 | Dm | 0.58 | — | — | 0 | inconclusive |
| 11.5 | Eb | 0.58 | 0.77 | 0.00 | 6 | confirms |
| 230.8 | Ab | 0.58 | 0.89 | 1.00 | 3 | confirms |
| 151.2 | D | 0.58 | 0.50 | 0.00 | 2 | A# (1.30 vs 0.50) |
| 224.3 | Bb | 0.58 | 0.11 | 1.00 | 3 | G# (0.82 vs 0.61) |
| 136.7 | C# | 0.58 | 0.37 | 0.00 | 2 | A#m (1.23 vs 0.47) |
| 147.4 | C | 0.59 | — | 0.00 | 1 | inconclusive |
| 151.4 | Bbmaj7 | 0.59 | 0.90 | 1.00 | 4 | confirms |
| 126.2 | Eb | 0.59 | 0.61 | 0.00 | 37 | confirms |
| 85.6 | Eb | 0.59 | 0.33 | 0.00 | 3 | G# (1.07 vs 0.43) |
| 105.1 | Ab | 0.59 | — | — | 0 | inconclusive |
| 135.3 | Ab | 0.59 | 1.00 | 1.00 | 6 | confirms |
| 2.9 | Fm | 0.60 | — | — | 0 | inconclusive |
| 4.5 | Bb | 0.60 | 0.24 | — | 4 | G# (0.73 vs 0.24) |
| 141.4 | Cm | 0.60 | 0.00 | 0.00 | 2 | D# (1.10 vs 0.10) |

## Key West Bar

213 chords · key Eb major · stems bass, guitar, other, piano, vocals · bucket pass 20.0s

Low-confidence chords (<0.65): 28

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 105.1 | Ab | 0.58 | — | — | 0 | inconclusive |
| 145.9 | Ab | 0.58 | 0.43 | 1.00 | 4 | confirms |
| 46.3 | Ab | 0.59 | 0.32 | 0.77 | 9 | confirms |
| 210.1 | Gm | 0.59 | 0.20 | 0.00 | 3 | G# (1.25 vs 0.30) |
| 75.7 | Bb | 0.59 | 0.90 | 1.00 | 3 | confirms |
| 19.6 | F | 0.60 | 0.75 | 0.00 | 4 | A# (1.00 vs 0.75) |
| 61.7 | F# | 0.60 | — | — | 0 | inconclusive |
| 121.0 | Bb | 0.60 | 0.89 | 1.00 | 9 | confirms |
| 12.6 | Gm | 0.62 | 0.50 | 0.00 | 3 | G# (0.99 vs 0.60) |
| 96.5 | Bb | 0.62 | 0.59 | 1.00 | 7 | confirms |
| 10.5 | Gm | 0.62 | — | — | 0 | inconclusive |
| 171.5 | Bb | 0.62 | — | — | 0 | inconclusive |
| 86.2 | Bb | 0.62 | 0.88 | 1.00 | 8 | confirms |
| 214.4 | Bbmaj7 | 0.63 | — | — | 0 | inconclusive |
| 102.7 | Ab | 0.63 | 0.34 | 0.70 | 9 | confirms |
| 225.8 | Eb | 0.63 | 0.82 | 0.00 | 8 | confirms |
| 48.9 | Bb | 0.64 | 0.64 | 0.56 | 10 | confirms |
| 56.7 | Ab | 0.64 | 0.30 | 0.53 | 16 | confirms |
| 104.9 | D | 0.64 | 0.28 | 0.00 | 3 | G# (1.16 vs 0.28) |
| 133.7 | Cm7 | 0.64 | — | — | 0 | inconclusive |
| 214.6 | Cm | 0.64 | 0.46 | 0.67 | 9 | confirms |
| 210.7 | Bb | 0.64 | 0.88 | 1.00 | 12 | confirms |
| 82.4 | Cm | 0.64 | — | — | 0 | inconclusive |
| 48.2 | Gm | 0.64 | — | — | 0 | inconclusive |
| 123.5 | Ab | 0.65 | 0.67 | 1.00 | 3 | confirms |

## The Byrds - Eight Miles High (Audio)

185 chords · key D major · stems bass, guitar, other, piano, vocals.backing, vocals.lead · bucket pass 21.0s

Low-confidence chords (<0.65): 37

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 173.5 | A | 0.57 | 1.00 | 0.00 | 2 | confirms |
| 79.9 | E | 0.58 | — | — | 0 | inconclusive |
| 115.6 | A | 0.60 | 1.00 | — | 1 | inconclusive |
| 201.4 | G | 0.60 | — | 0.00 | 1 | inconclusive |
| 157.0 | E | 0.60 | 0.80 | 0.00 | 3 | confirms |
| 200.5 | E | 0.60 | 0.70 | 0.00 | 3 | confirms |
| 203.4 | E | 0.60 | 0.80 | 1.00 | 3 | confirms |
| 45.3 | D | 0.60 | 0.90 | — | 2 | confirms |
| 153.6 | D | 0.62 | 0.80 | — | 1 | inconclusive |
| 175.0 | E | 0.62 | — | 1.00 | 1 | inconclusive |
| 100.3 | Bm | 0.62 | 0.70 | — | 1 | inconclusive |
| 79.0 | F#m | 0.62 | 0.50 | — | 2 | D (0.75 vs 0.60) |
| 144.7 | E | 0.62 | 0.00 | 1.00 | 2 | D (1.10 vs 0.50) |
| 72.4 | D | 0.62 | 0.74 | — | 4 | confirms |
| 122.8 | Bm | 0.63 | 0.00 | — | 2 | Em (0.77 vs 0.10) |
| 108.0 | Bm7 | 0.63 | 0.33 | — | 3 | Em (0.69 vs 0.43) |
| 63.0 | E | 0.63 | 0.75 | 0.57 | 4 | Em (1.24 vs 1.04) |
| 142.8 | G | 0.63 | 0.80 | 1.00 | 3 | confirms |
| 19.7 | Bm | 0.63 | 0.23 | — | 7 | Em (0.87 vs 0.33) |
| 123.0 | Ab | 0.63 | 0.25 | — | 2 | C#m (0.75 vs 0.25) |
| 118.6 | F# | 0.63 | 0.28 | — | 4 | Em (0.70 vs 0.28) |
| 171.9 | A | 0.64 | 1.00 | 0.00 | 3 | confirms |
| 60.8 | Dm | 0.64 | — | 0.00 | 1 | inconclusive |
| 23.5 | Bm | 0.64 | 0.35 | 0.00 | 3 | D (0.95 vs 0.45) |
| 191.5 | E | 0.64 | 0.40 | — | 2 | Am (0.80 vs 0.40) |

## Moving on

97 chords · key Eb major · stems bass, guitar, other, piano, vocals · bucket pass 20.7s

Low-confidence chords (<0.65): 18

| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |
|---|---|---|---|---|---|---|
| 177.6 | Ab | 0.53 | 0.71 | 0.50 | 5 | confirms |
| 109.0 | Cm | 0.54 | 0.52 | 1.00 | 10 | confirms |
| 147.9 | Ab | 0.56 | 0.62 | 0.44 | 25 | confirms |
| 111.2 | Bb | 0.57 | 0.45 | 0.26 | 67 | confirms |
| 230.7 | Ebm | 0.57 | 0.62 | 0.00 | 8 | G# (1.15 vs 0.62) |
| 45.9 | Gm | 0.57 | 0.70 | — | 1 | inconclusive |
| 50.9 | F | 0.58 | 0.32 | 0.00 | 3 | G# (1.08 vs 0.32) |
| 79.7 | Cm | 0.59 | 0.85 | 0.50 | 5 | confirms |
| 49.0 | F | 0.60 | 0.50 | 0.00 | 2 | C (1.20 vs 0.50) |
| 231.9 | Eb | 0.61 | 0.63 | 0.00 | 35 | confirms |
| 184.4 | Eb | 0.61 | 0.52 | 0.00 | 7 | Cm (1.05 vs 0.62) |
| 81.0 | Bb | 0.61 | 0.84 | 0.79 | 11 | confirms |
| 187.1 | Ab | 0.62 | 0.44 | 0.31 | 12 | confirms |
| 82.9 | Eb | 0.62 | 0.61 | 0.00 | 12 | G# (1.02 vs 0.71) |
| 107.1 | Eb | 0.63 | 0.47 | 0.00 | 6 | A# (1.34 vs 0.57) |
| 95.9 | Cm | 0.63 | 0.43 | 1.00 | 4 | confirms |
| 11.1 | Bb | 0.64 | 1.00 | 0.00 | 2 | confirms |
| 108.0 | Dm | 0.65 | 0.40 | — | 4 | A# (0.77 vs 0.50) |
