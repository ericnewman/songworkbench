# Findings — forced alignment for sung word onsets (2026-09-18)

Status: needs-triage · no code written · every number below is someone else's measurement, traced to the paper, wiki or repository that owns it

Answers the question the "times are measured, never computed" rule forces: **if word onsets must be measured off the vocal stem, what measures them?**

The headline is not one of the six options the brief named. It is a small MIT-licensed model that none of the mainstream tooling wraps.

## Recommendation

**Try `jhuang448/LyricsAlignment-MTL` first.** It is the only candidate that is simultaneously: trained on **singing**, trained on **source-separated vocals** (exactly SongWorkbench's input), **MIT-licensed with weights committed in the repo** (57 MB Baseline / 69 MB MTL / 1.9 MB BDR), **CTC-based** so the alignment is the Viterbi you want in Swift anyway, **34.8 ms per frame**, and **independently measured**: 0.23 s mean absolute error / 94 % PCO on Jamendo word-level, 0.20 s / 0.91 on Mauch.

Verified from source, not from the README. `model.py`: Mel spectrogram (22.05 kHz, `n_fft=512`, hop 256, 128 mels) → `Conv2d(1,32)+ReLU` → N × ResidualCNN (`Conv2d` + `LayerNorm` + `GELU`) → `MaxPool2d((2,3))` → `Linear` → **3 × bidirectional LSTM** → `Linear` → CTC over 41 classes (`blank=40`) on the ARPABET phone set. Frame resolution is `256/22050*3` = **34.8 ms**. `utils.py` carries `alignment()` and `alignment_bdr()` — the Viterbi and the boundary-informed Viterbi. License MIT confirmed via the GitHub API; last push 2025-06-26. A multilingual successor (`jhuang448/LyricsAlignment-Multilingual`, also MIT, pushed 2025-10-18) exists and the original README says it performs better.

Why this over everything else:

- **It is the only singing-trained aligner with shippable weights.** The MIREX-winning systems are Kaldi (AutoLyrixAlign is **GPLv3**), Spotify's 2023 SOTA released nothing, Deezer released nothing (their repo contains 20 `.npy` split files and no license), Demirel's ALTA is CC-BY-NC-SA with no weights. This is the gap, and this model is the only thing in it.
- **Separation direction matters and this model is on the right side of it.** The evidence (§ *Separation*) is that separated vocals *help* when the model was trained on separated vocals and *hurt* badly when fed to a mix-trained model. LyricsAlignment-MTL was trained on separated DALI vocals. Feeding it the Demucs stem is the configuration it was built for.
- **The conversion risk is ordinary.** `Conv2d`, `LayerNorm`, `GELU`, `MaxPool2d`, `Linear` are bread-and-butter coremltools. There is no group-norm-on-3D bug, no `weight_norm` decomposition, no 128-tap positional conv. **The one real risk is the three bidirectional LSTMs**: coremltools supports them, but they will not land on the ANE and will want fixed or enumerated sequence lengths. At 57 MB on CPU/GPU for a 3-minute stem that is very likely fine, and it is a bounded, testable risk rather than the open-ended one wav2vec2 carries.
- **Its BDR variant is a published measurement of this project's own thesis.** A separate boundary-detection model injected into the Viterbi score improves line-level Jamendo AAE 0.30 → 0.25 s and PCO 0.93 → 0.95. That is "detect *when*, let the aligner decide *what*" — measured, on this exact task.

**Then snap word onsets to measured vocal-stem onsets.** 34.8 ms frames are four times better than Parakeet's 80 ms and still a quantisation floor. The stem onset detector answers *when* at hop resolution; the aligner answers *which word*. Snapping converts a frame index into a measured time, which is what the project rule demands and what no interpolation could legitimately produce. Break ties **early** — the one perceptual study measured an asymmetric tolerance of **[−0.33 s early, +0.22 s late]**, so a word shown early is roughly 50 % more forgivable than one shown late.

**Fallback, and useful regardless: Parakeet-CTC-0.6b via FluidAudio.** Already converted to Core ML, Apache-2.0 code, `logProbs: [[Float]]` public in Swift, and a blank-expanded CTC dynamic program already written. Its 80 ms frames make it the weaker aligner, but it is the fastest route to *any* on-device Swift CTC Viterbi, and that Viterbi is reusable across acoustic models. Build the Swift alignment layer against Parakeet because it is easy, then swap the acoustic model.

**Explicitly not recommended.** MFA (best on speech, but GMM-HMM Kaldi with a PostgreSQL dependency — unshippable in a Swift app, and zero published singing results). WhisperX (worst aligner in the only head-to-head that exists, 110.90 ms mean word-boundary error on speech *with the reference text supplied*). stable-ts (archived 2026-05-30, **no published accuracy numbers of any kind**, `suppress_silence=True` by default — it is a library of exactly the heuristics this project just deleted). `torchaudio.pipelines.MMS_FA` (best neural aligner measured, and **CC-BY-NC 4.0**, so it cannot ship).

## Comparison

Word-level mean boundary error and % within tolerance, all from McAuliffe et al. 2026 Table 4 — the only source that puts these systems under one protocol. **Every number in this table is SPEECH** (Buckeye, spontaneous American English). There is no equivalent singing table and this document does not pretend otherwise.

| system | mean err | ≤10 ms | ≤25 ms | ≤50 ms | ≤100 ms | frame | code lic. | weights lic. | Core ML |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MFA ARPA 3.0 | **21.75 ms** | **48.8 %** | **70.2 %** | **91.4 %** | **97.3 %** | 10 ms | MIT | CC BY 4.0 | no path |
| Charsiu (w2v2 frame-cls) | 29.24 ms | 36.5 % | 60.0 % | 87.4 % | 95.5 % | 10 ms | MIT | unverified | untested |
| MMS_FA + `forced_align` | 49.54 ms | 9.6 % | 20.3 % | 61.9 % | 92.1 % | 20 ms | BSD-2 | **CC-BY-NC** | untested |
| NeMo NFA (FastConformer) | 88.62 ms | 7.0 % | 13.3 % | 35.8 % | 63.1 % | **80 ms** | Apache-2.0 | CC-BY-4.0 | **shipping** |
| WhisperX (w2v2-base-960h) | 110.90 ms | 1.3 % | 2.9 % | 13.5 % | 57.4 % | 20 ms | BSD-2 | MIT | no path |
| stable-ts | *none published* | — | — | — | — | ~20 ms† | MIT | MIT | no path |
| **LyricsAlignment-MTL** | *not benchmarked on speech* | — | — | — | — | **34.8 ms** | **MIT** | **MIT** | untested |

† inferred from Whisper's encoder stride; stable-ts documents no resolution figure.

Singing, word-onset error — different datasets and protocol, comparable only to each other:

| condition | system | mean AE | median | PCO@0.3 s | source |
| --- | --- | --- | --- | --- | --- |
| Jamendo EN | Durand/Stoller/Ewert 2023 (char) | **0.15 s** | — | 92 % | ICASSP 2023 |
| Jamendo EN | Gupta GYL/GGL (NUS) | 0.22 s | 0.05 s | **94 %** | MIREX 2019–20 |
| Jamendo EN | **LyricsAlignment-MTL** | **0.23 s** | — | **94 %** | ICASSP 2022 |
| Jamendo EN | Demirel DE1 (Demucs stem) | 0.31 s | 0.05 s | 93 % | ICASSP 2021 |
| Jamendo EN | Vaglio (Deezer) | 0.37 s | — | 92 % | ISMIR 2020 |
| Jamendo EN | Stoller SDE2 | 0.39 s | 0.10 s | 87 % | ICASSP 2019 |
| **Jamendo Multi-Lang (79)** | Durand et al., lang-conditioned | **0.18 s** | — | **94 %** | ICASSP 2023 |
| Jamendo Multi-Lang | NUS baseline (EN-trained) | 0.65 s | 0.14 s | 73 % | MIREX 2024 |
| Hansen a cappella | GGL1 | **0.09 s** | 0.03 s | **98 %** | MIREX 2020 |
| Hansen mix | GGL1 | 0.10 s | 0.04 s | 98 % | MIREX 2020 |
| Mauch | GGL2/GYL1 | 0.19 s | 0.10 s | 91 % | MIREX 2019–20 |
| **solo-singing model on polyphonic** | Gupta C1, Hansen-poly | **36.20 s** | **30.10 s** | 14.5 %@0.25 | Interspeech 2019 T7 |

That last row is the shape of the whole problem; see § *Singing is the hard part*.

---

## 1. WhisperX

**What it is.** Whisper for transcription, a *separate* wav2vec2 CTC model for timing. `whisperx/alignment.py` sets `DEFAULT_ALIGN_MODELS_TORCH["en"] = "WAV2VEC2_ASR_BASE_960H"` — the torchaudio bundle, **character**-level despite the README's "phoneme-based ASR" language, 20 ms frames, MIT weights. Word start = start of the first character's span after `merge_repeats` over the Viterbi path.

**Accuracy — SPEECH.** Two sources that disagree, and the disagreement is the finding.

Its own paper (Bain et al., Interspeech 2023) reports word segmentation at a **200 ms** collar with exact text match: 93.2 % / 65.4 % P/R on Switchboard, 84.1 % / 60.3 % on AMI, against raw Whisper's 85.4 % / 62.8 % and 78.9 % / 52.1 %.

The only independent head-to-head (McAuliffe et al. 2026) puts WhisperX **last of ten aligners**: 110.04 ms (TIMIT) / 110.90 ms (Buckeye) mean word-boundary error, only 13.5 % of Buckeye boundaries within 50 ms against MFA's 91.4 %. **This is not an ASR-error artifact.** I read the benchmark script: `alignment/word_align_whisperx.py` builds `text = " ".join(x.label for x in reference)` from the gold transcript, wraps it in a single segment and calls `whisperx.align(...)` directly. Whisper never runs. WhisperX was measured in true forced-alignment mode with the correct text and still placed boundaries 110 ms out.

**Accuracy — SINGING.** None published.

**Runtime.** README claims "70x realtime … using whisper large-v2" with batching; **no GPU named**, and that is transcription throughput, not alignment.

**Size.** wav2vec2 base, 12 layers, 768-dim, ~95 M params, 20 ms frames.

**License.** Code BSD-2-Clause, English align weights MIT. Shippable in principle.

**Core ML.** No path — WhisperX is Python orchestration; what would convert is the underlying wav2vec2 (§ 2).

**Reference text.** Yes, and it is supported: `segments = [{"text": ..., "start": ..., "end": ...}]` → `whisperx.align(segments, model_a, metadata, audio, device)`. Documented limitation, verbatim: *"Transcript words which do not contain characters in the alignment models dictionary e.g. '2014.' or '£13.60' cannot be aligned and therefore are not given a timing."*

**Verdict.** Useful desktop-side for bootstrapping annotations. Not a shipping target, and its measured performance is bad enough that it should not be the bar the current heuristics are compared against.

## 2. torchaudio `forced_align` + MMS_FA / wav2vec2

**What it is.** `torchaudio.functional.forced_align(log_probs, targets, input_lengths, target_lengths, blank=0) -> (path, scores)` — CTC Viterbi over a `(B, T, C)` grid. Documented constraints: **`batch_size == 1` only**, `L >= L_label + N_repeat`. The algorithm is ~200 lines of Swift; the model is the problem.

**MMS_FA.** wav2vec 2.0 LARGE topology — 24 layers, 1024-dim, 4096 FF, 16 heads, `aux_num_out=28`, read from the bundle definition in `src/torchaudio/pipelines/_wav2vec2/impl.py`. That is the MMS paper's 0.3B row, **≈317 M params**. Conv strides 5·2·2·2·2·2·2 = 320 samples = **20 ms/frame**. 31 K hours, 1,130 languages. No word-boundary token, unlike other wav2vec2 bundles.

**Accuracy — SPEECH.** Meta publishes **no** boundary numbers; MMS validates alignment only indirectly through downstream ASR. Traceable numbers are McAuliffe 2026: 43.06 / 49.54 ms mean, 61.9 % of Buckeye boundaries within 50 ms, 92.1 % within 100 ms — best of the three neural ASR aligners, ~2× worse than MFA. **SINGING: none published.**

**Runtime.** MMS Figure 4 plots wall-clock against audio length for ctc-seg (CPU), Flashlight (CPU), MMS (GPU) and claims better scaling; **no readable axis values and no GPU named**. Unquantified. Memory claim is precise: GPU Viterbi avoids storing all O(T·L) forward values, reducing to O(T + L).

**License — decisive.** torchaudio code BSD-2-Clause. **MMS_FA weights CC-BY-NC 4.0**, stated verbatim in the bundle docstring and on `facebook/mms-1b-all` and `facebook/mms-300m`. The best-measured neural aligner cannot ship. `forced_align` itself is BSD and unencumbered — only the weights are poisoned.

**The MIT escape hatch and its problem.** `WAV2VEC2_ASR_BASE_960H` is MIT ("Originally published under MIT License by wav2vec 2.0 authors, redistributed with same license"), 20 ms, English, with a `|` boundary token, same `forced_align` kernel. **But it is the checkpoint WhisperX uses**, and WhisperX measured 110 ms where MMS_FA measured 49 ms on the same corpus with the same DP. Public evidence cannot separate "worse model" from "worse post-processing" because nobody has published `WAV2VEC2_ASR_BASE_960H + torchaudio.forced_align` under the McAuliffe protocol. Cheap experiment, listed in the validation plan.

**Core ML.** All ops registered: `group_norm`/`native_group_norm`, `layer_norm`, `gelu`, grouped `conv1d`, `_weight_norm`, `scaled_dot_product_attention` (since 7.0), `softmax`. The one known blocker was coremltools issue **#1607**, "GroupNormalization torch op definition is incorrect" — converting `facebook/wav2vec2-base-960h` raised `IndexError` because `group_norm` hard-unpacked four dimensions (`x.shape[3]`) while wav2vec2's feature extractor applies GroupNorm to a 3-D `(N, C, L)` tensor. **Fixed in coremltools 6.1**; current PyPI is 9.0. `gumbel_softmax` is unregistered but irrelevant — it lives in the pretraining quantiser and `Wav2Vec2ForCTC` never touches it. HuggingFace `exporters` does **not** support wav2vec2 or any audio architecture (the supported list is 38 text/vision classes), so conversion is by hand. **Nobody has published a working end-to-end wav2vec2 → Core ML conversion.** Unchecked specifically: whether the `_weight_norm` decomposition (`reduce_l2_norm` + `real_div` + `mul`) constant-folds rather than running a per-inference L2 norm over the 128-tap positional conv.

**Reference text.** `targets` is an integer tensor — tokenise yourself. MMS adds two requirements: **uroman romanisation** (near no-op for English, but numerals and symbols still need normalising) and the **`<star>` token**, inserted at text start with posterior fixed at 1. The paper: *"we introduce a star token to which audio segments can be mapped if there is no good alternative in the text"*, explicitly *"different from an OOV token or silence token in an HMM topology"*. **This is directly useful for lyrics** — `<star>` absorbs intros, instrumental breaks, ad-libs and repeated sections absent from the reference text, which is the class of event that derails a rigid aligner. Any Swift reimplementation should reproduce it.

## 3. NeMo Forced Aligner (NFA)

**What it is.** CTC Viterbi over a NeMo CTC model's log-probabilities. Supports QuartzNet, Citrinet, Conformer-CTC, FastConformer-CTC and hybrid models *in CTC mode*. **Pure Transducer models cannot be used** — which matters, since the headline `parakeet-tdt-0.6b-v2` is a TDT transducer. Emits token-, word- and segment-level timestamps.

**The 80 ms floor.** NFA derives frame rate from the loaded model. From `tools/nemo_forced_aligner/utils/data_prep.py`:

```python
model_downsample_factor = round(n_input_frames / int(T_batch[0]))
output_timestep_duration = (
    model.preprocessor.featurizer.hop_length * model_downsample_factor / model.cfg.preprocessor.sample_rate
)
```

With the standard 10 ms `window_stride`: QuartzNet 2× → 20 ms, Conformer 4× → 40 ms, **FastConformer and every Parakeet 8× → 80 ms**. The FastConformer paper states it: *"Fast Conformer increases sampling rate from 10ms to 80 ms using 3 depth-wise convolutional sub-sampling layers."* Confirmed independently in shipped Swift: FluidAudio's `ASRConstants.samplesPerEncoderFrame = 1280` = 80 ms at 16 kHz.

**Accuracy — SPEECH.** NVIDIA publishes **no** timestamp-accuracy numbers; the docs offer only "better alignments the more accurate the reference text". Traceable numbers are McAuliffe 2026 using `stt_en_fastconformer_hybrid_large_pc`: **78.24 / 88.62 ms** mean, 7.0 % of Buckeye boundaries within 10 ms, 35.8 % within 50 ms. Consistent with the floor — a perfectly placed frame still carries uniform quantisation error averaging 40 ms before any model error. **SINGING: nothing, not even a qualitative statement.**

**Runtime.** No RTF for alignment. `parakeet-tdt-0.6b-v2` reports RTFx 3380 at batch 128 on the Open ASR leaderboard — transcription, **no GPU named**, inapplicable.

**Size.** `nvidia/parakeet-ctc-0.6b`: FastConformer CTC, 600 M params, 1024-token SentencePiece (blank = 1024, logits row 1025 wide). `stt_en_fastconformer_ctc_large`: ~115 M.

**License.** NeMo code Apache-2.0; `parakeet-ctc-0.6b`, `parakeet-tdt-0.6b-v2`, `stt_en_fastconformer_ctc_large` weights all **CC-BY-4.0**. Shippable with attribution. NGC copies may carry an additional NVIDIA EULA; only HF cards were checked.

**Core ML — why it is the infrastructure fallback.** A converted CTC Parakeet already ships:

- `FluidInference/parakeet-ctc-0.6b-coreml` and `parakeet-ctc-110m-coreml`.
- The CTC repo contains only `MelSpectrogram.mlmodelc` and `AudioEncoder.mlmodelc` (plus int8) — **no separate decoder or joint**, so the CTC head is fused into the encoder and it emits logits directly. Ideal shape for forced alignment.
- FluidAudio (Apache-2.0) exposes the posterior grid publicly. Verified in `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/WordSpotting/CtcKeywordSpotter.swift`: `public struct SpotKeywordsResult` carries `public let logProbs: [[Float]]` ("CTC log-probabilities [T, V] for reuse in rescoring"), `public let frameDuration: Double`, `public let totalFrames: Int`, reachable via `public func spotKeywordsWithLogProbs(...)` and `spotKeywordsFromLogProbs(logProbs:frameDuration:...)`.
- `CTC/CtcDecoder.swift` provides `public func ctcGreedyDecode` in two overloads, one reading an `MLMultiArray` of shape `[1, T, V]` off `dataPointer`, plus `ctcBeamSearch` with ARPA LM support.
- `CustomVocabulary/WordSpotting/CtcDPAlgorithm.swift` already implements the blank-expanded CTC dynamic program — the `[B, t1, B, t2, …, tN, B]` `2N+1` lattice with the correct skip rule, citing NeMo's `ctc_word_spotter.py` (arXiv:2406.07096). It is `enum`-internal, not `public`, so a forced aligner vendors or reimplements it; Apache-2.0 permits that with attribution. The objective changes from "spot this term anywhere" to "align this transcript"; the lattice machinery does not.

**Caveats found, not resolved.** `FluidInference/parakeet-ctc-0.6b-coreml` has **no model card and no declared license** (the TDT v3 repo declares `cc-by-4.0`). Inherited CC-BY-4.0 is reasonable but unstated. No accuracy numbers exist for the *converted* model versus the NeMo original, so conversion and int8 quantisation error are unquantified.

**Reference text.** NeMo JSON manifest with a `"text"` field. **No dictionary and no OOV concept** — SentencePiece BPE decomposes any string. The real failure mode is characters outside the charset (punctuation on a non-PC model), which must be stripped; NFA documents no behaviour for this.

## 4. Montreal Forced Aligner (MFA)

**What it is.** Kaldi GMM-HMM, still, in 3.0: monophone → triphone → LDA triphone → SAT (fMLLR) → pronunciation and inter-word silence estimation. 13 MFCC + Δ + ΔΔ = 39 features, per-speaker CMVN, **25 ms window / 10 ms shift**. Rate-agnostic via an 8 kHz ceiling. No parameter count published, and it would not be meaningful for a GMM-HMM.

**Accuracy — SPEECH, and it wins.** McAuliffe 2026 word level: **19.93 / 21.75 ms** mean, 48.8 % of Buckeye boundaries within 10 ms, 91.4 % within 50 ms. Phone level 12.11 / 13.87 ms. The paper: *"MFA 3.0 substantially outperforms all three neural ASR-based aligners on both datasets… The gap is greatest for small thresholds (10, 25 ms)."* The 2017 paper anchors this against human agreement: phone boundary mean difference 17 ms on Buckeye, *"an identical figure (17 msec) is reported for intertranscriber agreement."*

**Accuracy — SINGING. No official statement exists.** Full-text search of the 2017 paper, the 2026 paper, the docs and the model zoo turns up no singing, sung, music or lyric result; the only "music" hit in the 2026 paper is the authors' affiliation. No singing acoustic model exists in the zoo.

**Runtime.** 2017 wall-clock: 1000 h of LibriSpeech aligned in 80 h on 12 × 3.4 GHz cores (≈12.5× real time at that core count); training from scratch on 20 h of Buckeye took 2 h on 4 × 2.5 GHz cores. CPU only. The 2026 paper publishes no RTF.

**License.** Code MIT; pretrained models CC BY 4.0. Both permit a commercial closed-source desktop app with attribution. Caveat: the card asserts CC BY 4.0 for the model but does not enumerate the licences of the 3,770 h of training corpora behind it.

**Core ML. No path, and this is the disqualifier.** A GMM-HMM decoder is not a neural graph. Shipping MFA means shipping Kaldi, and MFA 3.x additionally requires a PostgreSQL server for its corpus database.

**Reference text.** Not an API argument — a `.lab`/`.txt` beside each audio file, or a Praat TextGrid. **A pronunciation dictionary is mandatory.** OOV handling: `--g2p_model_path`; else `<unk>` substitution plus `oovs_found.txt`; plus an explicit `<unk>` phone that *"can match any amount of vocal noise or speech"*. The paper: *"Anecdotally, MFA's alignment quality remains very good when up to 5–10 % of word types are unknown."* For lyrics the G2P requirement is real work.

**Where MFA still earns a place.** As the *offline* Mac-side tool that pre-annotates the validation corpus. See the validation plan for the bias hazard that creates.

## 5. stable-ts

**Archived.** GitHub API reports `"archived": true`, last push **2026-05-30**. Read-only: no fixes, no Whisper-compatibility updates. That alone should end it for a shipped product.

**What it is.** Not a standalone aligner and not a wrapper around one. Modified Whisper: word timings from **DTW over Whisper's cross-attention weights**, then post-processing. `align()` runs Whisper's decoder over known text rather than re-transcribing. Resolution inherited from Whisper's encoder (~20 ms); stable-ts documents no figure of its own, so that is inference.

**Accuracy. There are no published quantitative numbers, on speech or singing.** Not in the README, not in the docs. Claims are qualitative. State this as a hard negative rather than leaving a blank cell that reads as "unknown but probably fine".

**Runtime.** No published RTF; the docstring says only that alignment is *"significantly faster than transcribing."*

**License.** MIT, Whisper weights MIT. Clean. Silero VAD, if enabled, is a separate licence that was not verified.

**Core ML.** No path as a library. Whisper converts partially — whisper.cpp's `models/generate-coreml-model.sh` runs `convert-whisper-to-coreml.py --encoder-only True` and emits `ggml-{model}-encoder.mlmodelc`; the decoder conversion is commented out with a TODO. Whisper is not CTC, so none of it yields a posterior grid to Viterbi over.

**Reference text.** `align(model, audio, text, ...)` where `text` is "String of plain-text, list of tokens, or instance of `WhisperResult`". No dictionary; failure surfaces as bad timings, guarded by `max_word_dur=3.0`, `word_dur_factor=2.0`, `remove_instant_words`, `failure_threshold`.

**Why it is actively wrong here.** `suppress_silence=True` is the **default** on `align()`, and Silero VAD is available and commonly enabled. Both make energy or speech-likelihood judgements about what is not speech; sustained vowels, melisma, breathy onsets and separation residue are exactly what those misclassify. The correction they apply is to *move timestamps* — the class of operation this project just deleted.

## 6. Singing-specific work

### MIREX "Automatic Lyrics-to-Audio Alignment"

Ran **2017, 2018, 2019, 2020**, then lapsed, then was **revived in 2024**. The 2021 page states verbatim: *"Due to not having sufficient number of participants, we are not currently holding the Audio-to-Lyrics Alignment challenge this year"* — 2021 ran Lyrics Transcription only. There are **no 2022 or 2023 year pages at all**, and MIREX 2025 has no lyrics task. MIREX itself is alive (2026 announced for ISMIR Abu Dhabi). Note `www.music-ir.org` fails TLS; the cert covers the bare domain only.

**Metrics.** AAE (mean |predicted − true| word start, seconds, averaged per song then over songs); PCS (fraction of song duration correctly positioned); **PCO/PCETW at 0.3 s tolerance**; median AE from 2018 on. **2017 had no PCO.** MIREX never used a perceptual metric.

**Datasets** (2024 page): Hansen 9 English pop songs / 3,590 words, a cappella *and* full mix, onsets and offsets; Mauch 20 songs / 5,050 words, starts only; Gracenote 8 excerpts / 1,181 words, private; Jamendo 20 songs / 5,677 words, public. The 2024 page carries an explicit warning: *"Hansen's dataset and Mauch's dataset overlap with commonly used training sets (e.g., DALI). The results are shown for reference only."*

**Best results by year** (AAE / PCO where published):

| year | best | Hansen a cap. | Hansen mix | Mauch | Jamendo |
| --- | --- | --- | --- | --- | --- |
| 2017 | AK3 (Kruspe) | 2.87 s | 7.34 s | 9.03 s | — |
| 2018 | CW2/CW3 (KKBOX) | 0.35 s / 0.79 | 2.07 s / 0.70 | 4.13 s / 0.52 | — |
| 2019 | GYL1 (NUS) | 0.13 / 0.97 | 0.10 / 0.97 | 0.19 / 0.91 | 0.22 / 0.94 |
| 2020 | GGL1/GGL2 (NUS) | **0.09 / 0.98** | **0.10 / 0.98** | 0.19 / 0.91 | 0.22 / 0.94 |
| 2024 | FZZ1 (WavLM+Conformer) vs NUS baseline | 0.101 / 0.971 | NUS 0.107 / 0.972 | NUS 0.192 / 0.910 | NUS V1 0.217 / 0.945 |

**The 2024 revival carries the most sobering number in this document.** On the multilingual Jamendo V2 set (79 songs), the 2020-winning NUS system degrades to **AAE 0.651 s / PCO 0.729**, and the new WavLM+Conformer entry reaches 0.584 / 0.887. The English-only numbers everyone quotes (0.22 / 0.94) are an over-optimistic view of a task that is much harder outside its home language and annotation set.

⚠️ The MIREX 2024 wiki has a data error: the "Jamendo V2 Fr" and "Jamendo V2 Gr" tables are byte-identical in the raw HTML. One is wrong; which one is unknown.

### DALI — weak labels, not ground truth

ISMIR 2018 (Meseguer-Brocal, Cohen-Hadria, Peeters) plus a TISMIR extension. **v1 = 5,358 songs / 344.9 h (176.9 h with vocals); v2 = 7,756 songs / 488.1 h (247.2 h with vocals).** No v3 found. Four annotation levels — **notes, words, lines, paragraphs** — with phoneme info on words in v2. Produced from karaoke-game annotations made by non-experts *without hearing the audio*, matched to YouTube audio, then refined by a two-generation teacher-student loop (singing-voice-detection teacher → global alignment → filtered student → better teacher), keeping only normalized cross-correlation ≥ 0.8.

**This is the critical caveat.** The authors' own quality evaluation against 105 manually checked songs gives **mean offset deviation 0.036 ± 0.06 s** for the best system — but that measures only the **global** offset and frame-rate fit. They explicitly enumerate remaining **local** errors (notes at wrong time positions, text misspellings, octave/semitone errors, missing notes) and **global** ones ("misaligned sections despite high NCC", where each section has a different offset), and write plainly: *"There is still the recurring question: how good are the annotations?"* Gupta et al. independently state *"the reliability of these lyrics annotations have not been verified"* and used only the 105-song manually corrected subset. **Treat DALI as training supervision with a ~30–100 ms systematic offset plus unbounded section-level outliers — never as evaluation ground truth.**

Availability: **audio is not distributed** (YouTube URLs plus a link-liveness flag; link rot is a live problem). Licensing is unresolved — the GitHub repo says CC BY-NC-SA 4.0, the TISMIR paper describes Zenodo distribution under the Academic Free License.

### JamendoLyrics — the benchmark to state results against

Stoller, Durand & Ewert (ICASSP 2019) introduced 20 English songs across nine genres with **start and end times for every word**, built because Hansen and Mauch are private and Pop-biased. Now **JamendoLyrics MultiLang v1.1 — 79 songs** (20 EN, 19 FR, 20 DE, 20 ES), word-level start+end plus derived lines. The GitHub repo is **archived read-only since 2025-04-30**; HuggingFace is canonical and **does distribute the MP3s**, unlike DALI.

⚠️ **License is per song, not dataset-wide.** Counted from `JamendoLyrics.csv`: 30 × BY-NC-ND, 25 × BY-NC-SA, 9 × BY-ND, 8 × BY-SA, 5 × BY, 2 × BY-NC. **Most songs are NC and/or ND.** Fine for internal evaluation; check per song before anything else.

Stoller's own reported error: Mauch 0.35 s AAE / 77.2 % correct segments; Jamendo 0.82 s / 70.4 %. Trained on 44,232 internal Spotify songs with **line-level** annotations only, a modified Wave-U-Net predicting character probabilities from raw 22.05 kHz audio.

**Jam-ALT** (Cífka et al., ISMIR 2024) is a revision of the same songs with corrected spelling, punctuation, capitalisation and breaks, CC BY 4.0 — a *transcription* benchmark, not an alignment one.

### Singing-adapted acoustic models

**Gupta, Yılmaz, Li (Interspeech 2019)** — Kaldi **TDNN-F, 2 conv + 10 time-delay layers + rank-reduction**, 40-d MFCC + 100-d i-vectors, frame subsampling 3 (30 ms effective), duration-modified lexicon, plus OpenSMILE auditory/energy/chroma/spectral/voicing feature groups. Trained on ~50 h DAMP solo singing, adapted on 70 polyphonic DALI songs for one epoch.

| condition | median | mean | %C @250 ms |
| --- | --- | --- | --- |
| Hansen **solo singing**, C2 (MFCC+i-vec+extra features) | **0.03 s** | 0.13 s | **94.1** |
| Hansen solo singing, C1 (MFCC+i-vec only) | 0.03 s | 0.20 s | 91.5 |
| Hansen-poly, vocal-extracted, C2 | 0.15 s | 0.94 s | 69.9 |
| Mauch-poly, vocal-extracted, C2 | 0.26 s | 4.05 s | 49.0 |
| Hansen-poly, polyphonic, C5 (poly-adapted) | 0.08 s | 1.82 s | 71.8 |
| Mauch-poly, polyphonic, C6 (poly-adapted) | 0.18 s | 1.93 s | 57.5 |
| **Hansen-poly, polyphonic, C1 (solo model, unadapted)** | **30.10 s** | 36.20 s | **14.5** |

Their Table 8 (mean AE, Hansen-poly / Mauch-poly): AK 7.34 / 9.03, GD 10.57 / 11.64, CW 2.07 / 4.13, **DS (Stoller end-to-end) — / 0.35**, CG (Sharma ICASSP'19) 1.39 / 6.34, theirs 0.93 / 1.93.

**Gupta, Yılmaz, Li (ICASSP 2020)** is the system that won MIREX 2019–2020 and is still the 2024 baseline: genre-informed silence and phone models trained directly on polyphonic audio plus a lyrics-domain LM. Mean AE Mauch 0.21, Hansen 0.18, Jamendo 0.22. Code and pretrained weights at `chitralekha18/AutoLyrixAlign` — **GPL v3**, with separate commercial licensing. That GPLv3 is a hard blocker for a closed-source app and is why the MIT model is the recommendation.

**Vaglio et al. (Deezer, ISMIR 2020)** — 3-layer BiLSTM + CTC on log-mel, **Spleeter-separated vocals**, character vs IPA-phoneme output, universal 62-phoneme set. Hansen 0.18 / 95 %, Mauch 0.22 / 91 %, Jamendo 0.37 / 92 %. Multilingual training with a universal phoneme set generalised best; oversampling to balance languages did *not* help and degraded English. **No code or weights released** — their repo contains 20 `.npy` DALI split files and no license.

**Durand, Stoller, Ewert (Spotify, ICASSP 2023)** — current SOTA on Jamendo English. Cross-modal contrastive embeddings (audio encoder + text encoder with C context symbols), line-based decoding with a mask matrix, **1.2 M params / 4.8 MB**, trained on 87,785 professional songs. Jamendo EN **0.15 s / 92 %** (character) and 0.16 / 93 (phoneme); Multi-Lang with language conditioning **0.18 / 94**. Two ablations worth knowing: character-without-context is catastrophic (1.60 s), and **a CTC model with the same encoder gets 0.90 s unless handed the similarity model's line mask, at which point it reaches 0.20 s** — i.e. CTC alignment leans heavily on external constraints, which is an argument for the boundary/onset anchoring below. **No code or weights released**; they released only the Multi-Lang word annotations.

**Huang, Benetos, Ewert (ICASSP 2022) — `jhuang448/LyricsAlignment-MTL`, the recommendation.** Multi-task phoneme + pitch CTC on DALI v2 English (4,224 train / 1,056 val), operating on **separated vocals**, plus a line-boundary model injected into the Viterbi score. Word level: baseline Jamendo 0.31 / 0.94 → **MTL 0.23 / 0.94**; Mauch 0.20 / 0.89 → MTL+BDR 0.20 / 0.91. Line level, where BDR clearly helps: Jamendo 0.30 → 0.25 AAE, PCO 0.93 → 0.95. **MIT, weights committed in-repo.**

**Demirel, Ahlbäck, Dixon (ICASSP 2021)** — anchor-word spotting then two-pass segmented alignment. Jamendo: SD1 0.82 / 0.10 / 0.85, SD2 0.39 / 0.10 / 0.87, VA 0.37 / — / 0.92, GC1 0.22 / 0.05 / 0.94, **DE1 (Demucs) 0.31 / 0.05 / 0.93**, DE2 (Spleeter) 0.38 / 0.05 / 0.90. Memory: 343 MB mean / 748 MB max against the NUS system's 13,740 / 16,745 MB — **≥ 40× less**, which matters on-device. Recipes CC BY-NC-SA 4.0, **no pretrained weights**.

**Other released checkpoints, for completeness.** `pymaster/SingAlign` (HuBERT-based singing forced aligner, Mandarin + English, phoneme-boundary metrics only, **CC-BY-NC-SA-4.0**, no peer-reviewed paper found). `nguyenvulebinh/lyric-alignment` (wav2vec2-large-vi, **Vietnamese only**, CC-BY-NC-4.0). **No HuggingFace checkpoint exists for any MIREX-winning English system.**

### How accurate is accurate enough — the one perceptual study

Lizé Masclef, Vaglio & Moussallam (ISMIR 2021) ran karaoke-realistic listening experiments precisely because MIREX's 0.3 s window had *"no experiment … conducted to confer psychological validity to this threshold."*

1. **Perception is asymmetric.** 53 participants, 14 offsets from −1 s to +1 s, 35 s excerpts. 50 %-detection thresholds: **−0.33 s for lyrics ahead**, **+0.22 s for lyrics lagging**; rounded to **[−0.3, +0.2]**. Asymmetric for **72 % of individuals**. χ²(1) = 4.26, p = .038 between −0.3 and +0.3. **You can be roughly 50 % sloppier early than late.**
2. **Tempo:** slow (≤ 93 BPM) threshold −0.36 s vs fast (≥ 138 BPM) −0.31 s; χ²(1) = 5.44, p < .02. Listeners are *less* sensitive at slow tempo.
3. **Word rate matters more:** high WPS (≥ 1.2) −0.39 s vs low WPS (≤ 1.16) −0.28 s; χ²(1) = 16.86, **p < .00004**.
4. **Negative result on local position:** 193 participants, 2,458 annotations, **no significant effect of word position in the line** (Cochran's Q χ²(2) = 5.77, p = .056). The only effect: for words **on a beat**, confidence in detecting a 0.25 s error was higher (mean 4.1 vs 3.5 for line-final words; Wilcoxon Z = 2.756, p < .006). **Beat-aligned words are the ones users catch you on.**
5. **Re-scoring Jamendo** with their perceptual PCO (skew-normal, skewness 1.12, location −0.22, scale 0.29):

| system | PCO | Asym-PCO | Perc-PCO |
| --- | --- | --- | --- |
| Gupta | 94.47 (1.52) | 93.66 (1.59) | **89.94 (1.71)** |
| Vaglio | 91.85 (1.95) | 90.82 (2.04) | **86.79 (2.13)** |
| Stoller | 87.02 (2.97) | 85.23 (3.07) | **79.93 (2.90)** |

Perc-PCO drops every system by 4–7 points *despite a wider support window*, and re-spreads systems bunched at ceiling on standard PCO.

**Engineering answer:** target within **+0.2 s late / −0.3 s early**, tighten the budget for fast-tempo, low-word-rate songs and for beat-aligned words, and prefer erring early. Caveat the authors' design forces: Experiment 1 applied a *constant* offset across a whole excerpt. How tolerance behaves for isolated per-word jitter — the realistic failure mode — is **unmeasured**.

---

## Singing is the hard part

**It is not jitter. It is derailment.** A speech-trained aligner on a polyphonic mix does not place every word 200 ms late; it places most words nearly right and a minority tens of seconds wrong, because the Viterbi path commits to the wrong stretch of audio at a section boundary and the error propagates. Gupta's solo model on polyphonic Hansen has a **median of 30.10 s** — not slightly wrong, in a different part of the song. Even for good systems the gap between mean (0.22–0.31 s) and median (0.05 s) on Jamendo says the same: the typical word is very well placed and a small tail is catastrophic.

**Consequence: the metric that matters is not mean error.** It is the **derailment rate** — fraction of words more than ~1 s out — plus the median for the rest. A change that halves the mean by fixing three derailments and a change that halves it by shaving 100 ms off every word are completely different changes, and only one is worth shipping.

**Isolated vocals recover most of the gap.** Solo a cappella aligns at 30 ms median / 94.1 % @250 ms and MIREX-2020-best 0.09 s AAE / 98 % PCO; the same model family on polyphonic mixes lands at 80–180 ms median and 57–72 % @250 ms.

### Separation: the evidence is contradictory, and the resolution is a rule

**Separation HELPS when the model is trained on separated vocals.** Stoller et al. retrained their acoustic model on their own separator's output: **Jamendo AE 0.82 → 0.38 s, correct-segments 70.4 → 76.8 %; Mauch 0.35 → 0.27 s, 77.2 → 78.1 %.** MIREX 2018 CW1 on the Mandarin a cappella subtask: source-separated ASE **0.12 s / PCO 0.939** against mix **3.354 s / 0.540**. Vaglio (Spleeter) and Huang (LyricsAlignment-MTL) both train this way.

**Separation HURTS when separated vocals are fed to a mix-trained model.** Gupta et al. ICASSP 2020, Table 3 — same pipeline, mean absolute word AE in seconds:

| test set | vocal extracted | polyphonic (no genre) | polyphonic (genre sil+phone) |
| --- | --- | --- | --- |
| Mauch | **3.62** | 0.25 | **0.21** |
| Hansen | **0.67** | 0.16 | **0.18** |
| Jamendo | **0.39** | 0.34 | **0.22** |

Their stated cause: separation artifacts, and failure around **long musical interludes** where *"extracted vocals models fail to align the lyrics … because of erratic music suppression"*, while polyphonic models capture the music→vocal transition. They also note MFCCs are noise-sensitive, so separation distortion specifically poisons MFCC-based adaptation.

**Separator choice matters, and differs by task.** Demirel et al.: Jamendo alignment Demucs 0.31 / 0.93 vs Spleeter 0.38 / 0.90 (**Demucs better for alignment**); transcription the other way (Jamendo WER 51.76 Spleeter vs 62.55 Demucs). Their verbatim conclusion: *"the choice of source separation has a crucial but inconsistent effect on the final transcription and alignment results."*

**Corroborated from the transcription side.** Jam-ALT: Whisper large-v2 WER over four languages **35.7 → 44.0** with HTDemucs, large-v3 **35.5 → 47.9** — but the authors explain it as *"with separated vocals as input, Whisper often outputs a transcript in the wrong language"*, and the English-only column for v2 goes **43.8 → 32.3**, a large improvement. Huang et al. (Interspeech 2025) isolate the cause on Multi-Lang Jamendo: no separation 36.80 EN / 35.42 overall, **HTDemucs 37.50 / 39.09**, their better in-house separator **32.36 / 31.86**. It is not separation, it is separation *quality*.

**The rule, and it is the single most actionable thing in this document: match the model's training domain to the input you feed it.** SongWorkbench feeds a Demucs stem, so use a model trained on separated vocals — which is exactly what LyricsAlignment-MTL is. The failure mode to watch is long instrumental interludes.

**Mitigations by evidence strength:** (1) train/choose a model matched to the input domain — the largest reported effect; (2) noise-robust auxiliary features alongside MFCCs (Gupta C1 → C2: solo mean 0.20 → 0.13 s; Mauch extracted-vocal median 1.49 → 0.26 s); (3) a better separator (Demucs > Spleeter for alignment); (4) boundary/onset anchoring.

**Phoneme versus character granularity is not the deciding axis.** Character-level MMS_FA (49.5 ms) beat character-level wav2vec2 in WhisperX (110.9 ms) by 2×; phoneme-level Charsiu (29.2 ms) beat both; phoneme-level MFA beat Charsiu; MAPS (neural, phoneme, alignment-specific) was best on TIMIT at 18.86 ms and nearly worst on Buckeye at 54.44 ms. Durand et al. found character (0.15 s) marginally beat phoneme (0.16 s) on Jamendo. **Training objective and domain match dominate token granularity.**

## Onsets as the complement to alignment

The project's framing — the stem onset marks *when* something is sung, the task is assigning the right *word* — is not how the alignment literature phrases it, but it is what the best results actually do.

**Direct measurement on singing.** Gong & Serra (Interspeech 2018) segment a cappella singing by jointly learning syllable and phoneme onset detection functions with a multi-task CNN, then inferring boundaries with an HMM whose transition probabilities come from a **coarse duration prior** and whose emission probabilities come from the **onset detection function**. Log-mel, 46.4 ms window / **10 ms hop**. At τ = 25 ms:

| | phoneme onset F1 | syllable onset F1 |
| --- | --- | --- |
| Proposed (ODF + duration HMM) | **75.2 ± 0.6** | **75.8 ± 0.4** |
| Baseline (alignment only) | 44.5 ± 0.9 | 41.0 ± 1.0 |

Their explanation is the argument for the architecture: *"The proposed method uses the ODF which provides the time 'anchors' for the onset detection. Besides, the ODF calculation is a binary classification task. Thus the training data for both positive and negative class is more than abundant. Whereas, the phonetic classification is a harder task."* **Deciding *whether* something started is far easier than deciding *what* started.** Caveats: jingju, a cappella, Mandarin, with teacher recordings supplying the duration prior.

**Direct measurement on lyrics.** LyricsAlignment-MTL's **BDR** variant is this idea, already built and already measured: a separate line-boundary detection model injected into the Viterbi score, worth Jamendo line-level AAE 0.30 → 0.25 s and PCO 0.93 → 0.95. And Durand et al.'s ablation — a CTC model at 0.90 s that reaches 0.20 s once handed an external line mask — is the same lesson from the opposite direction: **CTC alignment is constraint-hungry, and externally measured boundaries are the cheapest constraint available.**

**The ceiling on the onset detector.** Singing is pitched non-percussive with soft onsets — long attacks and vague envelopes, especially in legato phrases without consonants — and spectral-difference detectors that work on percussion degrade badly. Published singing-onset systems report F-measures around 78 % at a 50 ms tolerance, and papers in the area routinely also report at 100 ms *"considering the softness of singing onsets."* A stem-onset detector is not an oracle: it will miss legato word onsets entirely and fire on note changes inside a held syllable.

**The design, and its failure modes.** Snap an aligned word onset to the nearest measured stem onset within a window; leave it alone when none is found.

- Window width tied to the aligner's resolution — roughly ±40–60 ms for LyricsAlignment-MTL's 34.8 ms frames, ±80–120 ms for Parakeet's 80 ms.
- **Break ties early**, per the measured [−0.3, +0.2] s asymmetry.
- Words with no onset in window keep the aligner's frame time and are **flagged**, not silently accepted — the same confidence-gate posture the timbral spike landed on, where everything reported is trustworthy and the rest is an editable draft.
- Onsets with no word are informative: candidate ad-libs, instrumental events, or evidence of derailment. A run of unclaimed onsets inside a supposedly-sung region is a free derailment detector.
- **This must not become word stretching by another name.** Snapping moves one onset to one measured event. It must not adjust neighbours to preserve durations, and a word whose onset snapped past its own end is an error to surface, not a spacing problem to fix.
- **Complementary and cheap: constrain the Viterbi with vocal activity.** The older LyricAlly line of work zeroed phoneme likelihoods inside detected non-vocal regions so alignment cannot place words where nothing is sung. The 6-stem Demucs already provides the energy envelope that defines those regions, and Gupta's finding that mix-trained models beat stem-fed ones *because of long interludes* says exactly where this constraint pays.

## Core ML viability, concretely

**The alignment does not belong in the model.** Viterbi over a `T × V` grid is sequential with data-dependent argmax and backpointer chasing; it does not vectorise onto the ANE and Core ML has no traceback op. Every shipping precedent does the DP in host Swift over an emitted array — WhisperKit's `dynamicTimeWarping` over an `MLMultiArray` in `Sources/WhisperKit/Core/Text/SegmentSeeker.swift` (MIT), FluidAudio's `CtcDPAlgorithm` over `[[Float]]`. WhisperKit's DP is scalar Swift with a live `// TODO: Use accelerate framework` — a shipping, performance-focused product found plain loops acceptable.

**Memory is a non-issue.**

| configuration | frames / 30 s | V | posterior matrix |
| --- | --- | --- | --- |
| **LyricsAlignment-MTL, 34.8 ms, 41 phones** | **862** | **41** | **141 KB** |
| wav2vec2, 20 ms, character vocab | 1500 | 32 | 192 KB |
| Parakeet CTC, 80 ms, SPE + blank | 375 | 1025 | 1.5 MB |

The blank-expanded lattice is `2N+1` states for an N-token transcript; a Viterbi pass needs two score columns plus a `T × (2N+1)` backpointer array — tens of kilobytes for a 30 s window, tens of megabytes for a whole song. If anything binds it is the `[[Float]]` array-of-arrays (one heap allocation per frame), so flatten to a single `[Float]` of `T*V` for the hot loop.

**Conversion risk, per candidate.**

- **LyricsAlignment-MTL:** `Conv2d`, `LayerNorm`, `GELU`, `ReLU`, `MaxPool2d`, `Linear` are all routine. **The three bidirectional LSTMs are the risk** — coremltools supports them but they will not run on the ANE and will want fixed or enumerated sequence lengths. Bounded and testable. G2P is a second, separate task: the repo uses `g2p_en` (CMU ARPABET), which for known reference lyrics can be precomputed offline or served by a CMUdict lookup with a fallback, rather than ported.
- **wav2vec2:** all ops registered, the historical blocker fixed in coremltools 6.1, but **no published end-to-end conversion exists**, and its native `(B, S, C)` layout is the opposite of the ANE-friendly one, so a naive trace inserts transposes on every block. That layout cost, not op coverage, is the real expense.
- **Parakeet CTC:** already converted and shipping.

**ANE-friendliness rules, for any hand port.** Apple's `ml-ane-transformers`: carry activations as **(B, C, 1, S)** because *"the most conducive data format for the ANE … is 4D and channels-first"* and *"the last axis of an ANE buffer is not packed; it must be contiguous and aligned to 64 bytes"*; **swap every `nn.Linear` for `nn.Conv2d`**; **split multi-head attention into explicit per-head functions**; avoid reshapes — *"we avoid all reshapes and incur only one transpose on the key tensor"*, using einsum `bchq,bkhc->bkhq` which *"directly map[s] to hardware without intermediate transpose and reshape operations."* Reported effect on distilbert/iPhone 13: *"up to 10 times faster with a simultaneous reduction of peak-memory consumption of 14 times."*

**Flexible shapes are no longer the blocker folklore says.** Apple's guide: *"Use `EnumeratedShapes` for best performance"* (limit 128 shapes; pre-iOS 18 only one input may use them), and *"Setting the Reshape Frequency Optimization Hint to `Infrequent` can allow flexible shaped models to run on the Neural Engine, with iOS 17.4 or later."* Fixed-length chunks with enumerated shapes is the practical recipe, and it is what FluidAudio already does.

## Open questions and what could not be verified from public sources

**Singing.**

- **No aligner in the speech comparison table has a published word-onset number on singing.** Not MFA, not NFA, not WhisperX, not MMS_FA, not stable-ts, not Charsiu. Conversely, no singing system in § 6 has been benchmarked under the McAuliffe speech protocol. **The two tables cannot be joined, and this project will have to produce the missing cell itself.**
- Whether MFA's speech-domain win survives the move to singing is unknown and could go either way. Nobody has adapted MFA to singing publicly.
- The MIREX 2024 wiki contains a duplicated-row error (Fr and Gr tables byte-identical); one language row is wrong and which is unknown.
- DALI's local annotation error is acknowledged by its authors but never quantified — only the global offset (0.036 ± 0.06 s) is measured. DALI's license is genuinely unresolved (GitHub says CC BY-NC-SA 4.0, TISMIR says Academic Free License).
- Sharma et al. (ICASSP 2019) is paywalled with no preprint; its numbers exist only second-hand in the citing group's table.
- Huang & Benetos's ISMIR 2025 LBD "Evaluating Lyrics Alignment under Source Separated Conditions" would be the most directly relevant paper in existence — it released a **word-level timestamp extension of the MUSDB18 test set (45 songs)** and compared clean vocal stems against three separation tools. **The program page states the paper PDF, video and poster do not exist. No numbers are obtainable.** The annotations are on Zenodo and are worth pulling regardless.
- No published system does word-onset-to-stem-onset snapping for lyrics. Gong & Serra and LyricsAlignment-MTL's BDR are the nearest analogues.

**Engineering.**

- **LyricsAlignment-MTL has never been converted to Core ML**, and its three bidirectional LSTMs are the specific unknown. Nothing about its conversion is verified.
- **No end-to-end wav2vec2 → Core ML conversion has been demonstrated publicly.** Every op is registered and #1607 was fixed in 6.1, but "all ops supported" and "the graph converts, runs, and matches PyTorch numerically" are different claims and only the first is verified.
- **ANE residency is unverified for every candidate.** Needs on-device measurement with the Core ML Instruments template.
- **`FluidInference/parakeet-ctc-0.6b-coreml` declares no license and has no model card.** Inherited CC-BY-4.0 is a reading, not a fact.
- **No accuracy numbers exist for any converted model** versus its original. Conversion and int8 quantisation error are unquantified everywhere.
- **No runtime figure applicable to on-device alignment exists for any option.** MFA's 12.5× is a 2017 12-core desktop wall-clock; NFA's RTFx 3380 is batch-128 GPU transcription with no GPU named; MMS's Figure 4 has unreadable axes and names no GPU; stable-ts, torchaudio and LyricsAlignment-MTL publish nothing. **Every speed claim here is someone else's hardware doing a different job.** Demirel's 343 MB / 748 MB memory figures are the only on-device-relevant resource numbers found.
- Silero VAD's current license was not verified.

**Method.**

- Whether `WAV2VEC2_ASR_BASE_960H + torchaudio.forced_align` performs like MMS_FA (49 ms) or like WhisperX (110 ms) is unresolved by any public source, and it decides whether an MIT-licensed 20 ms speech path exists at all.
- Whether onset snapping recovers the frame quantisation is a project hypothesis with two supporting analogues (Gong & Serra, BDR) and zero direct evidence.
- The perceptual tolerance window was measured for a *constant* offset across an excerpt. Per-word jitter — the realistic failure mode — is unmeasured.

## Proposed validation plan

### Metric

Report all four, always, and never the mean alone:

1. **Median absolute word-onset error (ms)** — primary. Robust to derailment, and what the singing literature actually reports.
2. **PCO at 300 ms** — comparable to MIREX and to every number in § 6.
3. **PCO at 100 ms and 50 ms** — the bar a lyric chart actually has to clear; MIREX's 300 ms is far too loose for a bouncing ball.
4. **Derailment rate** — fraction of words with |error| > 1 s. This is the number that moves when something is genuinely broken, and it is invisible in a median.

Additionally compute **asymmetric PCO over [−0.3, +0.2] s**, and report early-vs-late error separately: a system biased early is better than one biased late at the same absolute error. **Measure word *starts*, not boundaries** — the speech literature averages start and end error; a lyric chart only cares about starts.

Segment results by **tempo, word rate, and beat-alignment**, since all three were measured to move the perceptual threshold and the third by a large margin.

### Reference-set size

**Two songs cannot support any statistical claim, and the reason is arithmetic rather than a matter of degree.** With song as the paired unit, a two-sided sign test on n songs has a minimum achievable p-value of 2·2^(−n+1) — 1.0 at n = 2, 0.25 at n = 4, first crossing 0.05 at **n = 6**. Below six paired songs a perfect sweep is not significant no matter how lopsided.

Words are the wrong unit. Errors within a song are strongly correlated — one derailment misplaces a whole line — so 500 words from one song are nowhere near 500 independent observations. With ~250 words per song and a plausible intra-song correlation of 0.1–0.3, the design effect is 26–76: 2,000 words carry roughly the information of 30–80 independent ones.

**Recommended: all 25 songs of the existing corpus, human-reviewed, as paired units.** A sign test over 25 songs detects a system winning on 75 % of songs with roughly 80 % power at α = 0.05; at 20 songs that needs an 80 % win rate. Use the **Wilcoxon signed-rank test on per-song medians** as the primary inference, not a t-test on pooled words.

**Two-tier annotation, to make 25 songs affordable:**

- **Tier 1 — all 25 songs, binary judgement.** For each word the reviewer marks only *correct* or *incorrect* at a fixed tolerance while listening with the chart. This yields PCO directly without anyone typing a timestamp, and PCO is the metric the field uses. Paired across systems it supports **McNemar** on discordant words and a sign test on per-song PCO.
- **Tier 2 — 6–8 songs, exact onsets.** Needed for median error and error-distribution shape. Annotate **every word inside two or three 20-second windows per song** rather than sampling scattered words: derailments are only visible in runs, and scattered sampling hides them. Choose windows spanning a dense chorus, a sparse verse, and **at least one section boundary**, since boundaries are where Viterbi paths commit wrong.

**Split the corpus.** Tune on 10, evaluate on 15 held out, or leave-one-song-out. Tuning a snap window on the songs that report the result will overfit — the timbral spike's own history is a warning about point estimates on single fixtures.

### A/B protocol

1. **Freeze the inputs.** Same stem file, same reference lyric text, same word tokenisation for both arms. Any difference in the word list invalidates the pairing.
2. **Pair per word.** Both systems produce an onset for the same word index, compared against the same annotation. Paired comparison is far more powerful than comparing distributions.
3. **Blind the reviewer.** Tier 1 judgements must not know which arm produced the chart. Randomise arm order per song.
4. **Report the four metrics, the win/loss/tie count by song, and the McNemar discordant counts** (b = fixed by B, c = broken by B). Fixing 8 % and breaking 2 % is a different story from fixing 5 % and breaking 5 % at the same net.
5. **Pre-register the direction.** Decide before looking whether the claim is "better median", "fewer derailments" or "higher PCO@100". Picking the metric after seeing the numbers is how noise gets shipped.

### Experiments, in order

1. **Run LyricsAlignment-MTL in Python on the existing 25-song Demucs stems, today.** No Swift, no conversion. Its published Jamendo number (0.23 s AAE / 94 % PCO) is the claim; whether it holds on this catalogue and these stems is the question. This is a few hours and it either validates or kills the recommendation before any porting.
2. **Stem vs mix**, same model, both inputs. The literature genuinely disagrees, and the domain-match rule predicts the stem wins *for this model specifically* — a falsifiable prediction worth testing rather than assuming.
3. **BDR on vs off**, since its published effect is line-level and this project cares about words. If BDR helps here, the onset-snapping thesis has direct in-house support before any onset detector is written.
4. **Onset snapping on top of 1.** Measure as a delta, with a control: snapping against a **deliberately detuned** onset detector should produce *no* improvement. Without that control, a snap that helps may be a rounding that happens to land well — the same trap the stem-separation spike escaped only because of its near-mono control, which is what made those results believable.
5. **`WAV2VEC2_ASR_BASE_960H + torchaudio.forced_align` vs MMS_FA on speech**, under the McAuliffe protocol. An afternoon in Python. Decides whether an MIT-licensed 20 ms speech path exists — relevant only if 1 fails.
6. **MFA on stems, offline, as a third opinion** for pre-annotating Tier 2. **Hazard:** correcting MFA's output into ground truth biases the ground truth toward MFA-like placements and toward whatever MFA shares with the candidate. Either annotate Tier 2 from scratch, or pre-annotate half from MFA and half from the candidate and check the two halves give the same verdict.

---

## Citations

**Benchmarks and aligner comparisons**

- McAuliffe, Gunter, Wagner, Sonderegger, "Montreal Forced Aligner and the state of speech-to-text alignment in 2026", arXiv:2606.18466 — https://arxiv.org/abs/2606.18466 · tables: https://arxiv.org/html/2606.18466v1 · benchmark scripts (how each aligner was driven): https://github.com/MontrealCorpusTools/mfa-interspeech2026
- Rousso, Cohen, Keshet, Chodroff, "Tradition or Innovation: A Comparison of Modern ASR Methods for Forced Alignment", Interspeech 2024 — https://www.isca-archive.org/interspeech_2024/rousso24_interspeech.html
- Weber, Zehavi, Rousso, Keshet, "Multilingual Word-Level Forced Alignment with Self-Supervised Representations and Learned Dynamic Programming", arXiv:2606.10675 — https://arxiv.org/abs/2606.10675

**Aligners**

- Bain, Huh, Han, Zisserman, "WhisperX", Interspeech 2023 — https://www.isca-archive.org/interspeech_2023/bain23_interspeech.pdf · https://github.com/m-bain/whisperX · default align models: https://raw.githubusercontent.com/m-bain/whisperX/main/whisperx/alignment.py
- McAuliffe, Socolof, Mihuc, Wagner, Sonderegger, "Montreal Forced Aligner", Interspeech 2017 — https://www.isca-archive.org/interspeech_2017/mcauliffe17_interspeech.pdf · docs https://montreal-forced-aligner.readthedocs.io/en/latest/ · English model v3.0.0 https://mfa-models.readthedocs.io/en/latest/acoustic/English/English%20MFA%20acoustic%20model%20v3_0_0.html · license https://github.com/MontrealCorpusTools/Montreal-Forced-Aligner/blob/main/LICENSE
- NVIDIA NeMo Forced Aligner — https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/tools/nemo_forced_aligner.html · frame-rate derivation https://github.com/NVIDIA/NeMo/blob/v1.23.0/tools/nemo_forced_aligner/utils/data_prep.py
- Rekesh et al., "Fast Conformer", arXiv:2305.05084 — https://arxiv.org/pdf/2305.05084v6 (10 ms → 80 ms subsampling)
- https://huggingface.co/nvidia/parakeet-ctc-0.6b · https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- stable-ts — https://github.com/jianfch/stable-ts · https://github.com/jianfch/stable-ts/blob/main/stable_whisper/alignment.py
- Baevski, Zhou, Mohamed, Auli, "wav2vec 2.0", arXiv:2006.11477 — https://arxiv.org/pdf/2006.11477
- Pratap et al., "Scaling Speech Technology to 1,000+ Languages", JMLR 25 (2024) / arXiv:2305.13516 — https://arxiv.org/pdf/2305.13516
- `torchaudio.functional.forced_align` — https://docs.pytorch.org/audio/main/generated/torchaudio.functional.forced_align.html · MMS_FA and its CC-BY-NC license https://docs.pytorch.org/audio/main/generated/torchaudio.pipelines.MMS_FA.html · WAV2VEC2_ASR_BASE_960H and its MIT license https://docs.pytorch.org/audio/main/generated/torchaudio.pipelines.WAV2VEC2_ASR_BASE_960H.html · bundle definitions https://github.com/pytorch/audio/blob/main/src/torchaudio/pipelines/_wav2vec2/impl.py
- Zhu, Zhang, Jurgens, "Phone-to-audio alignment without text" (Charsiu), ICASSP 2022, arXiv:2110.03876 — https://arxiv.org/abs/2110.03876 · https://github.com/lingjzhu/charsiu

**Singing**

- **Huang, Benetos, Ewert, "Improving Lyrics Alignment through Joint Pitch Detection", ICASSP 2022 — https://arxiv.org/abs/2202.01646 · code and MIT-licensed weights https://github.com/jhuang448/LyricsAlignment-MTL · multilingual successor https://github.com/jhuang448/LyricsAlignment-Multilingual**
- Gupta, Yılmaz, Li, "Acoustic Modeling for Automatic Lyrics-to-Audio Alignment", Interspeech 2019, arXiv:1906.10369 — https://arxiv.org/pdf/1906.10369
- Gupta, Yılmaz, Li, "Automatic Lyrics Alignment and Transcription in Polyphonic Music: Does Background Music Help?", ICASSP 2020, arXiv:1909.10200 — https://arxiv.org/abs/1909.10200 · code (GPLv3) https://github.com/chitralekha18/AutoLyrixAlign
- Demirel, Ahlbäck, Dixon, "Low Resource Audio-to-Lyrics Alignment from Polyphonic Music Recordings", ICASSP 2021, arXiv:2102.09202 — https://arxiv.org/abs/2102.09202 · https://github.com/emirdemirel/ASA_ICASSP2021 · https://github.com/emirdemirel/ALTA
- Demirel, Ahlbäck, Dixon, "MSTRE-Net", ISMIR 2021, arXiv:2108.02625 — https://arxiv.org/abs/2108.02625
- Vaglio, Hennequin, Moussallam, Peeters, Richard, "Multilingual Lyrics-to-Audio Alignment", ISMIR 2020 — https://program.ismir2020.net/static/final_papers/101.pdf
- Durand, Stoller, Ewert, "Contrastive Learning-Based Audio to Lyrics Alignment for Multiple Languages" / "Similarity-based Audio-Lyrics Alignment of Multiple Languages", ICASSP 2023, arXiv:2306.07744 — https://arxiv.org/abs/2306.07744
- Stoller, Durand, Ewert, "End-to-end Lyrics Alignment for Polyphonic Music", ICASSP 2019, arXiv:1902.06797 — https://arxiv.org/abs/1902.06797 · dataset https://github.com/f90/jamendolyrics · live distribution https://huggingface.co/datasets/jamendolyrics/jamendolyrics
- Lizé Masclef, Vaglio, Moussallam, "User-centered evaluation of lyrics-to-audio alignment", ISMIR 2021 — https://archives.ismir.net/ismir2021/paper/000052.pdf
- Meseguer-Brocal, Cohen-Hadria, Peeters, "DALI", ISMIR 2018, arXiv:1906.10606 — https://arxiv.org/abs/1906.10606 · "Creating DALI", TISMIR — https://transactions.ismir.net/articles/10.5334/tismir.30 · https://github.com/gabolsgabs/DALI
- Cífka, Schreiber, Miner, Stöter, "Jam-ALT", arXiv:2311.13987 — https://arxiv.org/pdf/2311.13987 · ISMIR 2024 version arXiv:2408.06370 · https://audioshake.github.io/jam-alt/
- Huang, Sousa, Demirel, Benetos, Gadelha, "Enhancing Lyrics Transcription on Music Mixtures with Consistency Loss", Interspeech 2025, arXiv:2506.02339 — https://arxiv.org/pdf/2506.02339
- Gong, Serra, "Singing Voice Phoneme Segmentation by Hierarchically Inferring Syllable and Phoneme Onset Positions", Interspeech 2018, arXiv:1806.01665 — https://arxiv.org/pdf/1806.01665
- Ou, Gu, Wang, "Transfer Learning of wav2vec 2.0 for Automatic Lyric Transcription", ISMIR 2022 — https://archives.ismir.net/ismir2022/paper/000107.pdf
- Kruspe, "More than words: Advancements and challenges in speech recognition for singing", ESSV 2024, arXiv:2403.09298 — https://arxiv.org/abs/2403.09298
- MIREX task and results pages — https://music-ir.org/mirex/wiki/2017:Automatic_Lyrics-to-Audio_Alignment_Results · .../2018:... · .../2019:... · .../2020:... · https://music-ir.org/mirex/wiki/2024:Lyrics-to-Audio_Alignment_Results · 2021 cancellation notice https://music-ir.org/mirex/wiki/2021:Automatic_Lyrics_Transcription
- Huang, Benetos, "Evaluating Lyrics Alignment under Source Separated Conditions", ISMIR 2025 LBD — https://ismir2025program.ismir.net/lbd_412.html (paper PDF does not exist) · MUSDB18 word-timestamp annotations https://zenodo.org/records/15547046

**Core ML and Swift**

- coremltools — https://github.com/apple/coremltools · torch op registry https://github.com/apple/coremltools/blob/main/coremltools/converters/mil/frontend/torch/ops.py · issue #1607 (wav2vec2 GroupNorm) https://github.com/apple/coremltools/issues/1607 · flexible shapes https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html
- HuggingFace `exporters` (no audio architectures) — https://github.com/huggingface/exporters · https://raw.githubusercontent.com/huggingface/exporters/main/src/exporters/coreml/models.py
- Apple, "Deploying Transformers on the Apple Neural Engine" — https://machinelearning.apple.com/research/neural-engine-transformers · https://github.com/apple/ml-ane-transformers
- FluidAudio (Apache-2.0) — https://github.com/FluidInference/FluidAudio · public CTC posterior API in `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/WordSpotting/CtcKeywordSpotter.swift` and `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CTC/CtcDecoder.swift` · converted model https://huggingface.co/FluidInference/parakeet-ctc-0.6b-coreml
- WhisperKit (MIT) — https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Text/SegmentSeeker.swift
- whisper.cpp Core ML encoder conversion — https://github.com/ggml-org/whisper.cpp/blob/master/models/generate-coreml-model.sh
