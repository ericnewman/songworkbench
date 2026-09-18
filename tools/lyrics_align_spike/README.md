# Lyrics forced-alignment spike

Evaluates replacing the app's ASR-derived word times with **forced alignment** — measuring where
each known word is sung rather than repairing what the ASR guessed. Background and the option
survey are in [`.scratch/forced-alignment-spike/FINDINGS-forced-alignment.md`](../../.scratch/forced-alignment-spike/FINDINGS-forced-alignment.md).

The model under test is [`jhuang448/LyricsAlignment-MTL`](https://github.com/jhuang448/LyricsAlignment-MTL)
(ICASSP 2022, MIT, weights in-repo): phoneme CTC trained on **singing** and on **source-separated
vocals**, which is exactly what our Demucs stem is. 34.8 ms frames.

## Setup

Nothing here is committed except the scripts — the upstream clone, the venv, stems, converted
models and extracted lyrics are all ignored. Lyric text is the songs' copyrighted content and
stays local.

```bash
cd tools/lyrics_align_spike
uv venv --python 3.12 .venv
VIRTUAL_ENV=.venv uv pip install torch torchaudio numpy soundfile librosa resampy g2p_en tqdm coremltools
git clone --depth 1 https://github.com/jhuang448/LyricsAlignment-MTL.git
.venv/bin/python -c "import nltk; nltk.download('averaged_perceptron_tagger_eng')"
sed -i '' 's/np\.Inf/np.inf/g' LyricsAlignment-MTL/*.py
```

Two fixes the upstream repo needs, both version drift rather than bugs in it:

- `np.Inf` was removed in NumPy 2.0, and the alignment DP uses it. Hence the `sed`.
- `g2p_en` downloads `averaged_perceptron_tagger`, but current nltk looks for
  `averaged_perceptron_tagger_eng` and raises `LookupError`. Hence the extra download.

## Scripts

| script | what it does |
| --- | --- |
| `extract_lyrics.py` | Pulls a song document's lyric lines out as plain text, and prints the word times the app currently believes. |
| `align_song.py` | Runs the aligner over a vocal stem. Prints word onsets and speed, writes `<lyrics>.<method>.aligned.json`. |
| `check_onsets.py` | Scores an alignment against **measured** stem onsets — no human annotation needed. `control()` scores random word times, so you can tell whether the metric is measuring anything. |
| `batch_eval.py` | Paired A/B over every song that has a stem and lyrics: current app times vs aligned times, same word list, same onsets, plus the random control. |
| `convert_coreml.py` | Converts the acoustic model to Core ML and verifies it against PyTorch. |

```bash
.venv/bin/python align_song.py vocals.wav lyrics.txt MTL
.venv/bin/python check_onsets.py vocals.wav lyrics.MTL.aligned.json
.venv/bin/python batch_eval.py
.venv/bin/python convert_coreml.py 2049
```

`method` is `Baseline`, `MTL`, `Baseline_BDR` or `MTL_BDR`. BDR adds the line-boundary model to the
Viterbi score — the published "detect *when*, let the aligner decide *what*" variant.

## What the metric can and cannot tell you

`check_onsets.py` needs no annotation, which is why it works today on 19 songs instead of the 2 that
are human-reviewed. The cost is that it measures **plausibility, not correctness**: it asks whether
a word was placed where the stem has a vocal onset, not whether it is the *right* word for that
onset. A system could score well by putting the wrong words on real onsets.

So treat it as a screen, not a verdict. It reliably catches the failures that matter most — words
placed in silence, and derailment — and those were the visible symptoms. Confirming that the
correct word sits on each onset still needs human review, and the findings document's two-tier
annotation plan is how to get there.

Always read the random control printed alongside. If a system is not clearly beating random
placement, the metric is not resolving anything on that song.

## Core ML conversion

`convert_coreml.py` answers the spike's biggest open engineering question — the three bidirectional
LSTMs, which nobody had published a conversion for. It converts and matches PyTorch.

It does two things beyond a naive trace:

1. The stock `forward` calls `x.view(sizes[0], sizes[1] * sizes[2], sizes[3])` with sizes read off a
   traced tensor. coremltools cannot scalarize those and fails with *"only 0-dimensional arrays can
   be converted to Python scalars"*. We convert at a fixed frame count, so those shapes are static
   and are written as literals instead.
2. It folds in the post-processing `wrapper.py` does — sum over the pitch head for MTL, then
   `log_softmax` — so the Core ML model emits the `[T, 41]` posteriorgram that forced alignment
   consumes, rather than raw logits the Swift side would have to finish.

The Swift side that consumes it is `CTCForcedAlignment` in `Sources/SongWorkbench/`.
