# Chord recognition models and lead/rhythm guitar separation (survey, 2026-10-07)

Question: which open chord-recognition (ACR) models, guitar note/tab transcription models, and
lead-versus-rhythm guitar separators (2019 baselines plus 2023–2026 work) could replace or
improve SongWorkbench's chroma-template + Viterbi chord line on the separated `guitar` stem,
run on-device through Core ML, and carry licenses that allow shipping their weights?

Sources are primary: GitHub repositories (README, `LICENSE`, source), Hugging Face model cards
and API metadata, arXiv/ISMIR/DAFx papers, MIREX result pages, Zenodo records, and vendor pages
for closed services. Every claim links to its source. Items marked **unverified** could not be
confirmed from a primary source. Code and weight licenses are reported separately.

## Current baseline in this repo

Checked in the source tree on 2026-10-07:

| Component | What the repo uses | Where |
|---|---|---|
| Chord method | Chroma (4096/2048 front end) template matching, then a Viterbi with a switch penalty | `Sources/SongWorkbench/ChordTimelineDecoder.swift` |
| Chord input | The separated `guitar` stem only | design rule "each instrument from its own stem" |
| Separator | HTDemucs 6-source, ONNX export, listed as `CC-BY-NC-4.0` | `ModelCatalog.swift` (`htdemucs-6s-onnx`) |
| Chart scoring | Ordered LCS match against an untimed ChordPro chart, root + maj/min, repeats collapsed, transposed to the chart key; reports precision, recall, F1, `inChart` | `Tests/SongWorkbenchTests/ChartMatchProbeTests.swift` |
| Current score | About 0.63 F1 on chord order; 77–90 % of labels inside the chart's chord set (one E-major chart) | caller's report |
| Lead/rhythm stems | `StemID.guitarLead` / `.guitarRhythm` declared, no model registered | `StemSeparation.swift:106`; `tasks/todo.md` "Decision needed (guitar)" |
| Basic Pitch | Spiked 2026-09-08: `nmp.onnx` runs in-app; per-beat polyphony separates lead bars from strummed bars on the guitar stem ("GO-with-caveats") | `tasks/spike-basic-pitch.md` |

## Ranked shortlist

### 1. BTC (Bi-directional Transformer for Chord recognition, ISMIR 2019), plus the 2026 BTC-CL retrain

- **License:** MIT for code and for both shipped checkpoints, which sit in the same repo
  (`test/btc_model.pt` 12.2 MB, majmin; `test/btc_model_large_voca.pt` 12.2 MB, 170 classes)
  ([repo](https://github.com/jayg996/BTC-ISMIR19), [LICENSE](https://github.com/jayg996/BTC-ISMIR19/blob/master/LICENSE)).
- **Training data:** 221 Isophonics songs, 65 Robbie Williams, 185 uspop2002. Audio was bought from
  streaming services and the labels were shifted by hand to match it ([paper §4.1](https://arxiv.org/abs/1907.02698)).
- **Accuracy (paper Table 1, 5-fold CV over that pool):** majmin vocabulary: Root 83.8, MajMin 82.7.
  Large vocabulary: Root 83.5, Thirds 80.8, Triads 75.9, Sevenths 71.8, Tetrads 65.5, MajMin 82.3, MIREX 80.8.
  In the same table, the CNN+CRF baseline in the madmom style scores 84.0 / 83.1 (majmin). Adding a CRF to BTC changed little (83.1 MajMin).
- **Cross-dataset evidence:** In the ISMIR 2025 consonance paper, a BTC retrained on Isophonics + Billboard
  and tested on RWC-Pop + USPop scores Root 81.6, MajMin 77.3, MIREX 79.0 ([arXiv:2509.01588, Table 2](https://arxiv.org/abs/2509.01588)).
- **2026 retrain (BTC-CL):** Phan et al. (DAFx 2026) used the original BTC as a teacher on about 1,300 h of
  unlabeled FMA, DALI, and MAESTRO audio, then continued training on labels. On their 120-song held-out split,
  BTC-CL (full) scores Root 83.03, Thirds 80.17, MajMin 80.24, MIREX 80.16. Their supervised-only BTC (3.03 M
  parameters) scores 81.52 / 78.00 / 78.11 / 77.79 ([arXiv:2602.19778, Table 2](https://arxiv.org/abs/2602.19778)).
  The checkpoint `checkpoints/btc_model_best.pth` (35.9 MB) ships in an MIT repo
  ([ChordMini](https://github.com/ptnghia-j/ChordMini)). The training audio's own licenses (MAESTRO,
  DALI) are not addressed by the repo; treat weight provenance as **unverified** for commercial use.
- **Input:** mono 22,050 Hz; `librosa.cqt` with 144 bins, 24 bins/octave, from C1, hop 2048 (≈ 93 ms);
  `log(|CQT| + 1e-6)`; z-normalised with the `mean`/`std` stored in the checkpoint; fixed windows of
  108 frames (≈ 10 s) ([run_config.yaml](https://github.com/jayg996/BTC-ISMIR19/blob/master/run_config.yaml),
  [mir_eval_modules.py](https://github.com/jayg996/BTC-ISMIR19/blob/master/utils/mir_eval_modules.py)).
- **Model:** 8 bidirectional self-attention layers, 4 heads, hidden 128. Inference is per-frame argmax with no CRF
  ([test.py](https://github.com/jayg996/BTC-ISMIR19/blob/master/test.py)).
- **Core ML risk: low.**
  - Fixed `[1, 108, 144]` input.
  - The timing signal and forward/backward attention masks are constant buffers (`_gen_timing_signal`,
    `_gen_bias_mask` in [btc_model.py](https://github.com/jayg996/BTC-ISMIR19/blob/master/btc_model.py)),
    the same pattern as beat_this's constant rotary tables.
  - No decoder to port: softmax posteriors can feed the existing `ChordTimelineDecoder` Viterbi as emissions.
  - The real work is a Swift CQT that matches `librosa.cqt`'s multi-rate implementation. This needs golden-feature tests.
- **Why first:** it has the lowest conversion risk of any model with permissive weights. The posteriors drop into
  the app's own decoder, and its front end is shared with candidate 3. One checkpoint swap also gives an A/B
  against BTC-CL.

### 2. Jiang et al., "Large-Vocabulary Chord Transcription via Chord Structure Decomposition" (ISMIR 2019)

- **License:** MIT (2023) for code. Five pretrained fold models,
  `joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s{0..4}.best.sdict` (5.7 MB each), are in `cache_data/`
  of the same repo and averaged at inference
  ([repo](https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition),
  [chord_recognition.py](https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition/blob/master/chord_recognition.py)).
- **Training data:** 1217 songs from Isophonics, Billboard, and the MARL collections (Humphrey and Bello),
  5-fold 60/20/20 ([paper §4.1](https://archives.ismir.net/ismir2019/paper/000078.pdf)). The paper gives results only as
  a median-recall figure (Fig. 4), with no numeric table.
- **Best held-out evidence of any open model:** it is the "Baseline: ISMIR2019" entry in
  [MIREX 2025 ACE](https://music-ir.org/mirex/wiki/2025:Audio_Chord_Estimation_Results), whose main
  test sets no system may train on:

  | Test set | Root | MajMin | MajMinBass | Sevenths |
  |---|---|---|---|---|
  | Billboard2013 | 78.61 | 76.39 | 74.72 | 64.15 |
  | Yamaha_Balanced (241 songs) | 82.00 | 81.16 | 79.69 | 66.97 |
  | Yamaha_JPop (200 songs) | 81.49 | 79.99 | 78.58 | 62.81 |

  - Chordino on the same sets scores 67.18 / 74.64 / 71.99 MajMin.
  - The best 2025 submissions on MajMin are MD1 79.15 on Billboard2013, wu-ensemble 81.29 on Yamaha_Balanced, and
    wu-ensemble 77.58 on JPop. This 2019 model beats every 2025 entry on JPop and is within 2.8 points on the other two sets.
  - No 2025 submission's abstract links public weights (checked [MD1](http://futuremirex.com/portal/wp-content/uploads/2025/audio-chord-estimation/MD1.pdf),
    [YK1](http://futuremirex.com/portal/wp-content/uploads/2025/audio-chord-estimation/YK1.pdf),
    [wu](http://futuremirex.com/portal/wp-content/uploads/2025/audio-chord-estimation/wu-single.pdf),
    [BMACE](http://futuremirex.com/portal/wp-content/uploads/2025/audio-chord-estimation/BMACE.pdf)).
- **Evidence on stems:** Fed with HTDemucs drum-removed and drum+vocal-removed renders, this model gained
  about 1 point. On IdolSongsJp, MIREX went from 79.50 to 80.67 and MajMin from 80.52 to 82.35; an in-house set gained a similar
  amount ([arXiv:2509.18700, Table 1](https://arxiv.org/abs/2509.18700)). Those are harmonic sub-mixes,
  not a single guitar stem.
- **Input:** 22,050 Hz, hop 512, `librosa.hybrid_cqt` with 36 bins/octave. The code (`CQTV2`) uses 288 bins from
  F#0, while the paper says 252 bins from C1. Use the code's values
  ([extractors/cqt.py](https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition/blob/master/extractors/cqt.py),
  [settings.py](https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition/blob/master/settings.py)).
- **Model:** a CNN feature extractor, then a bidirectional LSTM, then separate heads for root, triad, bass, 7th, 9th, 11th, and 13th.
  An `XHMMDecoder` decodes over a chord dictionary file (`data/submission_chord_list.txt`)
  ([chordnet_ismir_naive.py](https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition/blob/master/chordnet_ismir_naive.py)).
- **Core ML risk: medium.**
  - coremltools 9.0 converts bidirectional `torch.nn.LSTM`
    ([torch frontend ops.py](https://github.com/apple/coremltools/blob/main/coremltools/converters/mil/frontend/torch/ops.py)).
  - The LSTM runs over the whole song (training used 1000-frame segments), so a fixed shape means chunking with
    overlap, and chunking might change results.
  - The model has 5 ensemble members, which means 5 conversions or one fused graph.
  - The XHMM, which maps component posteriors to dictionary chords and runs Viterbi, needs a Swift port.
    The Viterbi itself can be the app's.
  - The hybrid CQT is a second front end, separate from BTC's.

### 3. Consonance-ACE ("From Discord to Harmony", ISMIR 2025)

- **License:** MIT for code. The checkpoint `ACE/checkpoints/conformer_decomposed_smooth.ckpt` (57.6 MB, a Lightning
  checkpoint) is in the same repo ([repo](https://github.com/andreamust/consonance-ACE)).
- **Training data:** Isophonics + Billboard (ChoCo annotations); tested on RWC-Pop + USPop, a cross-dataset split.
- **Accuracy (decomposed + consonance smoothing):** Root 84.0, MajMin 77.8, Thirds 80.3, Triads 72.7,
  Tetrads 60.8, Sevenths 66.0, MIREX 79.8. A BTC trained in the same setup scores 81.6 / 77.3 / 78.4 / 72.1 / 60.0 / 65.7 / 79.0
  ([arXiv:2509.01588, Table 2](https://arxiv.org/abs/2509.01588)).
- **Model:** a 6-layer Conformer (dimension 144, 4 heads, FFN 1024, depthwise kernel 31) with separate heads for root (13), bass
  (13), and 12 pitch-class activations. A threshold of 0.5 gives the chord tones, and the label is rebuilt from them
  ([conformer_decomposed.gin](https://github.com/andreamust/consonance-ACE/blob/main/ACE/models/conformer_decomposed.gin)).
  This output exposes the third directly, which suits the app's major/minor confusions.
- **Input:** the same `librosa.cqt` front end as BTC (22,050 Hz, hop 2048, 24 bins/octave × 6 octaves from C1;
  [dataset.gin](https://github.com/andreamust/consonance-ACE/blob/main/ACE/preprocess/dataset.gin),
  [transforms.py](https://github.com/andreamust/consonance-ACE/blob/main/ACE/preprocess/transforms.py)).
  Inference runs in fixed 20 s chunks, and the README says the chunk length "cannot be changed" for this model.
  An optional `--beat-sync` mode assigns one chord per beat using Beat This!, the same beat tracker the app uses
  ([inference.py](https://github.com/andreamust/consonance-ACE/blob/main/ACE/inference.py)).
- **Core ML risk: medium.**
  - torchaudio Conformer blocks with depthwise convolution and a positional encoding need tracing at the fixed 20 s shape.
    Op coverage is **unverified**.
  - The decomposed-to-label decode needs a Swift port.
  - It shares the Swift CQT with BTC.

### 4. Spotify Basic Pitch as a note front end (complement, not a chord model)

- **License:** Apache-2.0. Ships `nmp.mlpackage`, `nmp.onnx`, and `nmp.tflite`
  ([saved_models](https://github.com/spotify/basic-pitch/tree/main/basic_pitch/saved_models/icassp_2022)).
- **Model:** 16,782 parameters. CQT at 3 bins/semitone with harmonic stacking, about 11 ms hop.
- **Accuracy on GuitarSet:** note F (no offset) 0.79, F with offsets 0.56, frame accuracy 0.70
  ([arXiv:2203.09893, Table 2](https://arxiv.org/abs/2203.09893)).
- **Already spiked in this repo:** it runs in-app, and bar-level lead/chordal classification works on the guitar stem
  (`tasks/spike-basic-pitch.md`).
- **Role here:** chord-tone evidence (bass note, presence of the third) to cross-check an ACR model's
  maj/min call, and the time mask for lead passages (see [Lead versus rhythm guitar](#lead-versus-rhythm-guitar)).

## Rejected or deferred chord recognizers

| Item | Code license | Weights license | Why not first |
|---|---|---|---|
| madmom `CNNChordFeatureProcessor` + `CRFChordRecognitionProcessor`; `DeepChromaProcessor` + `DeepChromaChordRecognitionProcessor` ([chords.py](https://github.com/CPJKU/madmom/blob/main/madmom/features/chords.py)) | BSD-style ([LICENSE](https://github.com/CPJKU/madmom/blob/main/LICENSE)) | **CC BY-NC-SA 4.0** for all model files ([madmom_models LICENSE](https://github.com/CPJKU/madmom_models/blob/master/LICENSE)) | Noncommercial weights. Majmin only (25 classes). 44.1 kHz, frame 8192, 10 fps. The CRF decoder needs a port. As "FK2" in [MIREX 2018](https://music-ir.org/mirex/wiki/2018:Audio_Chord_Estimation_Results) it scored Billboard2013 MajMin 78.37 |
| Chordino / NNLS-Chroma (Vamp) ([repo](https://github.com/c4dm/nnls-chroma)) | **GPL-2.0** | n/a (no learned weights) | GPL would bind the app. MIREX 2025 baseline: Billboard2013 MajMin 67.18 |
| autochord ([repo](https://github.com/cjbayron/autochord)) | Apache-2.0 | Downloaded at import; license **unverified** | Needs the NNLS-Chroma Vamp plugin (GPL). Bi-LSTM-CRF in TensorFlow. 25 classes. README reports 67.33 % test accuracy |
| omnizart chord ([app.py](https://github.com/Music-and-Culture-Technology-Lab/omnizart/blob/main/omnizart/chord/app.py)) | MIT | Checkpoint in the repo (MIT) | Feature extraction calls `vamp` (NNLS chroma, GPL). Trained on McGill Billboard only. Accuracy not checked |
| Essentia ([repo](https://github.com/MTG/essentia)) | **AGPL-3.0** | MTG models CC BY-NC-SA 4.0 ([models page](https://essentia.upf.edu/models.html)) | No learned chord model; only template `ChordsDetection` |
| crema chord ([repo](https://github.com/bmcfee/crema), [models.rst](https://github.com/bmcfee/crema/blob/main/docs/models.rst)) | BSD-2-Clause | `training/chords/resources/model.h5` (6.4 MB) in the repo (same license) | Keras/TensorFlow. 602 classes with inversions (McFee and Bello, ISMIR 2017). Older than BTC and Jiang; accuracy not checked |
| ChordFormer (Akram et al., 2025) ([arXiv:2502.11840](https://arxiv.org/abs/2502.11840)) | No code found | No weights found | Conformer + CRF on the same 1217-song set. Root 84.69, MajMin 84.09, MIREX 83.62 against 83.39 / 82.62 / 81.52 for CNN+BLSTM. Not runnable |
| MIREX 2025 entries MD1, YK1, wu, BMACE | not found | not found | No weights linked in the abstracts. BMACE scored MajMin 8.88 on Billboard2013 (broken output) |
| ChordSync (SMC 2024) ([repo](https://github.com/andreamust/ChordSync)) | MIT | No checkpoint in the repo; README cites `models/chordsync_v.0.1.0.ckpt` (**unverified** where hosted) | Aligns an existing chord annotation to audio rather than recognizing chords. Relevant later for turning the hand charts into timed references |
| MERT-v1 95M/330M (foundation model) | — | **CC-BY-NC-4.0** ([card](https://huggingface.co/m-a-p/MERT-v1-95M)) | Noncommercial. Needs a trained chord head |
| MusicFM ([repo](https://github.com/minzwon/musicfm)) | MIT | MIT on the [HF card](https://huggingface.co/minzwon/MusicFM); pretrained on MSD or FMA audio | No released chord head. Training one is a project, not a prototype |
| LLM chain-of-thought correction ([arXiv:2509.18700](https://arxiv.org/abs/2509.18700)) | — | GPT-4o | Cloud LLM; not on-device. +1–2.77 MIREX points |

## Guitar note and tab transcription (from the guitar stem)

| Model | Code | Weights | Notes |
|---|---|---|---|
| Basic Pitch | Apache-2.0 | Apache-2.0, Core ML shipped | Instrument-agnostic. GuitarSet note F (no offset) 0.79. Already runs in-app |
| TabCNN ([repo](https://github.com/andywiggins/tab-cnn)) | **No license file** | None in the repo | Not usable |
| FretNet (Cwitkowitz, 2022/23) ([repo](https://github.com/cwitkowitz/guitar-transcription-continuous)) | MIT | No pretrained weights (training scripts only) | Would need training on GuitarSet |
| SynthTab (ICASSP 2024) ([repo](https://github.com/yongyizang/SynthTab)) | NOASSERTION | Dataset **CC BY-NC 4.0** | Dataset of about 2 TB; pretrained tab model **unverified** |
| High-resolution guitar transcription (Riley et al., ICASSP 2024) ([site](https://github.com/xavriley/HighResolutionGuitarTranscription), [arXiv:2402.15258](https://arxiv.org/abs/2402.15258)) | — | Not linked (**unverified**) | Domain-adapted from a piano model. Claims zero-shot SOTA on GuitarSet |
| GAPS benchmark model (ISMIR 2024) ([arXiv:2408.08653](https://arxiv.org/abs/2408.08653)) | — | Not linked (**unverified**) | Classical guitar, 14 h. Paper CC BY 4.0 |
| TART (2025/2026) ([arXiv:2609.11904](https://arxiv.org/abs/2609.11904)) | not found | not found | Four-stage audio→MIDI→technique→string/fret pipeline. Averages 81.35 % audio-to-MIDI F50 and 54.08 % end-to-end Tab F1 across GuitarSet/EGDB, clean and noisy |
| NATSolo / EG-Solo (electric guitar solos) ([repo](https://github.com/soravolk/NATSolo)) | no license | not stated | Solo note + technique transcription. Relevant to later solo work. License blocks reuse |
| YourMT3 ([repo](https://github.com/mimbres/YourMT3)) | **GPL-3.0** (repo) | Space card says Apache-2.0 (conflicts with the repo) | Multi-instrument. GPL code |
| MT3 ([repo](https://github.com/magenta/mt3)) | Apache-2.0 | — | T5 decoder (autoregressive); heavy for Core ML |
| Strumming direction + chord CRNN ([arXiv:2508.07973](https://arxiv.org/abs/2508.07973)) | not found | not found | 90 min of real plus 4 h of synthetic acoustic strumming |
| Rhythm-pattern transcription (Yousician, [arXiv:2510.05756](https://arxiv.org/abs/2510.05756)) | example data on [GitHub](https://github.com/YousicianGit/rhythmic-pattern-transcription) (no license) | not found | MERT strum detector on separated audio. HTDemucs 4-stem "other" beat 6-stem "guitar" as the input in their setup |

Takeaway: Basic Pitch is the only guitar-capable transcriber with permissive weights already in Core ML
form. Every guitar-specific model from 2023–2026 either has no released weights or has a license that blocks reuse.

## Lead versus rhythm guitar

### Open-weight separators

- **None found.**
  - ZFTurbo's Music-Source-Separation-Training pretrained list (MIT code) has no lead/rhythm guitar model
    ([pretrained_models.md](https://github.com/ZFTurbo/Music-Source-Separation-Training/blob/main/docs/pretrained_models.md)).
  - Hugging Face searches for `guitar`, `lead-guitar`, `rhythm-guitar`, and `guitar-solo` on 2026-10-07 returned only
    whole-guitar separators: `becruily/mel-band-roformer-guitar` (no card, no license) and
    [`adityalakhani/htdemucs-6s-guitar-ft`](https://huggingface.co/adityalakhani/htdemucs-6s-guitar-ft)
    (Apache-2.0 card, fine-tuned on MoisesDB, which is CC BY-NC-SA). They also returned a solo-segment classifier,
    `LongshenOu/guitar-solo-segment-cls-mjn`, with no card and no license.
- **Closed services:**
  - **MVSEP** added "MVSep Lead/Rhythm Guitar" in its 2026-03-21 news ([news](https://mvsep.com/en/news)). No
    weights, architecture, or SDR are published.
  - **Moises:** "if you have a Moises Pro subscription, Moises can separate lead and rhythm guitar"
    ([made-for/guitarists](https://moises.ai/made-for/guitarists)). No weights and no API for it are mentioned.
  - **LALAL.AI** lists Guitars, Acoustic Guitar, and Electric Guitar stems, and lead/back splitting only for vocals
    ([homepage](https://www.lalal.ai/), 2026-10-07).
- **Closest research:**
  - [GuitarDuets](https://arxiv.org/abs/2507.01172) (2025, dataset CC BY 4.0 on
    [Zenodo](https://zenodo.org/records/12802440)) separates two classical guitars with a Demucs variant. The best
    real-test SDR is 5.88 dB for guitar 1, and guitar 2 ranges from 0.2 to 1.4 dB across training mixes (Table 3), and the authors say SDR is a weak
    metric for same-timbre sources.
  - Shibata et al. ([ICASSP 2019](https://eita-nakamura.github.io/articles/Shibata_etal_GuitarTranscription_ICASSP2019.pdf))
    transcribe lead, bass, and rhythm guitar jointly with a factorial HSMM. That is transcription, not separation;
    code **unverified**.

### Datasets that could train one

| Dataset | Lead/rhythm signal | License |
|---|---|---|
| GuitarSet ([paper](https://archives.ismir.net/ismir2018/paper/000188.pdf), [Zenodo](https://zenodo.org/records/3371780)) | Every excerpt is recorded twice by the same player, once comping and once soloing over their own comp. 6 players × 30 excerpts, about 3 h, acoustic, hexaphonic, with chord annotations | **CC BY 4.0** |
| MedleyDB ([metadata](https://github.com/marl/medleydb/tree/master/medleydb/data/Metadata)) | Stems carry `component: melody` / `bass` / empty. Counted on 2026-10-07 across 330 metadata files: 106 melody-tagged guitar stems; 62 songs with 2+ guitar stems; **34 songs with a melody-tagged guitar plus another guitar** | Code MIT. Audio access-restricted on Zenodo ([1649325](https://zenodo.org/records/1649325)); CC BY-NC-SA per the project site (**unverified** from Zenodo metadata) |
| MoisesDB ([repo](https://github.com/moises-ai/moises-db), [defaults.py](https://github.com/moises-ai/moises-db/blob/main/moisesdb/defaults.py)) | Guitar sub-classes are clean electric, distorted electric, lap steel, and acoustic. Multiple guitar sources per song, but **no lead/rhythm role**. Would need hand labels | **CC BY-NC-SA 4.0** |
| Slakh2100 ([Zenodo](https://zenodo.org/records/4599666)) | 145 h, synthesized from Lakh MIDI. Guitar tracks have MIDI programs, **no role label**. Role could be derived from MIDI polyphony | CC BY 4.0 |
| GOAT ([arXiv:2509.22655](https://arxiv.org/abs/2509.22655)), Guitar-TECHS ([arXiv:2501.03720](https://arxiv.org/abs/2501.03720)) | Electric DI + amp-rendered audio with tabs or MIDI. Lead-style and chord material, solo instrument only | not checked |

### Upstream fact: the guitar stem itself is weak

- HTDemucs 6s scores a median guitar SDR of 3.16 dB over 88 MoisesDB tracks (computed from the repo's
  [benchmark/htdemucs6.csv](https://github.com/moises-ai/moises-db/blob/main/benchmark/htdemucs6.csv)).
  On MVSEP's guitar leaderboard, Demucs4HT (6 stems) scores 5.22 dB.
- On the same leaderboard, "BS Roformer SW" scores 9.01 dB and Logic Pro 11.2's Stem Splitter 9.00 dB
  ([leaderboard](https://mvsep.com/quality_checker/leaderboard/guitar/?sort=guitar),
  [2024-07 news](https://mvsep.com/en/news)).
- BS-Roformer-SW 6-stem weights circulate on Hugging Face as rehosts, for example an
  [ONNX export](https://huggingface.co/elicwhite/bs-roformer-sw-6stem-onnx). Its card says the weights were rehosted
  "without a stated license" and with no provenance. That is **not shippable** until an owner and license are found.
- This matters for every chord method in this note: chord errors on a 3–5 dB guitar stem partly reflect separation, not the recognizer.

## Evidence on stems versus full mixes

- No primary source evaluates any ACR model on an isolated guitar stem. Every model above trains on full
  mixes, so the guitar stem is out-of-distribution. The size of that shift is **unmeasured**.
- Harmonic sub-mixes help: the drum-removed and drum+vocal-removed HTDemucs renders added about 1 MIREX point to the
  Jiang 2019 model ([arXiv:2509.18700](https://arxiv.org/abs/2509.18700)).
- For strum detection, HTDemucs 4-stem `other` beat 6-stem `guitar` as the input
  ([arXiv:2510.05756 §4.1](https://arxiv.org/abs/2510.05756)).

## Recommendation

### What to prototype first

1. **Run a one-time Python bake-off, before any conversion** (a probe tool like `tools/basic_pitch_probe`, not runtime).
   Run BTC (majmin and large-vocab), BTC-CL, Jiang 2019, and consonance-ACE on the songs that have hand charts.
   Score each with the existing `ChartMatchProbeTests` metric (LCS precision, recall, F1, and `inChart` after
   reducing to root + maj/min). Use two inputs per song:
   - the `guitar` stem, which is the design input;
   - as a diagnostic only, the full mix, to size the stem domain shift.

   This costs about a day and decides the conversion target on the app's own data instead of on Beatles/Billboard numbers.
2. **Convert BTC to Core ML first, unless the bake-off shows Jiang 2019 clearly ahead on the guitar stem.**
   - Trace the attention stack plus the output layer at `[1, 108, 144]` with coremltools 9, the same recipe as
     beat_this. Store the timing signal and masks as constants.
   - Port the CQT to Swift and validate it against `librosa.cqt` golden features. This is the main risk, and the
     same CQT later serves consonance-ACE.
   - Feed the 25- or 170-class softmax into the existing `ChordTimelineDecoder` as emissions in place of chroma-template
     scores. Keep the switch penalty and beat alignment.
   - Effort: small to medium (about 12 MB of weights, 3 M parameters).
   - Try BTC-CL as a drop-in checkpoint (same architecture), subject to the training-data provenance caveat.
3. **If maj/min quality errors persist, add evidence rather than another network:** use Basic Pitch note posteriors on
   the guitar stem to confirm or flip the third and the bass note per segment. Consonance-ACE's decomposed pitch
   activations are the model-based alternative (medium effort; shares BTC's CQT).

### Lead/rhythm: best path

1. **Now: segment in time, do not separate.** Use the Basic Pitch polyphony classifier from the 2026-09-08 spike to
   mark chordal and lead bars on the guitar stem.
   - Down-weight or mask lead bars in the chord decoder.
   - Route lead bars to `SoloTranscriptionAnalyzer`.
   - This needs no new model. It does not split a lead played *over* a rhythm part on the same stem; the spike saw that
     as "lead notes + chord fragments".
2. **Later, only if (1) is not enough: train a refiner** `guitar` → `guitar.lead` / `guitar.rhythm` with the MIT
   MSST trainer (MelBand or BS-RoFormer).
   - Build synthetic pairs from GuitarSet comp/solo (CC BY 4.0, already paired), plus Slakh guitars labelled by MIDI
     polyphony (CC BY 4.0), plus MedleyDB's 34 melody-plus-other-guitar songs (noncommercial; evaluation only).
   - Expect low SDR: same-timbre two-guitar separation tops out around 5.9 / 1 dB in GuitarDuets.
   - Effort: large (data pipeline, GPU training, Core ML export of a RoFormer).
   - No open checkpoint exists to shortcut this. MVSEP and Moises have one but publish no weights.

### What to measure

- The chart-match F1, precision, recall, and `inChart` per song and per model, against the current 0.63 F1 baseline.
- Report the major/minor confusion count separately from missed changes, because those are the two failure modes seen.
- **More charts are needed.** One E-major chart cannot separate model quality from key or arrangement effects. Aim for
  at least 8–10 hand charts: several keys including flat keys and minor keys, at least two songs with guitar solos,
  one capo/tuned-down song, and one song with acoustic strumming only.
- Once a chart is timed (manually, or later with ChordSync-style alignment), add `mir_eval` WCSR (root, majmin)
  so results compare with the published numbers above.
- Keep the guitar stem as the input under test, and record the full-mix score beside it as a domain-shift diagnostic,
  not as a shipping path.

## Measured on Eric's charts (2026-10-07)

All runs on the separated **guitar stem** only, scored by `ChartMatchProbeTests` (Swift) and
`score_lab.py` (same rules): chords reduced to root + major/minor, repeats collapsed, the best
transposition applied, then longest-common-subsequence precision and recall against the chart, and
"in chart" = share of detected chords in the chart's chord set. Reference set: 22 songs — Eric's
checked chart of Flip Flops And Barbeque (106 chord symbols), the reviewed Those Were the Days
chart, and 20 generated catalogue charts matched to their recordings by SHA-256. The catalogue
charts mostly name one chord per lyric line, so precision understates any detector that reports
every change; recall and "in chart" are the fairer measures there.

| Chord line (guitar stem) | Chords/song | Precision | Recall | F1 | In chart |
|---|---:|---:|---:|---:|---:|
| App today (template matching + Viterbi) | 91 | 0.35 | 0.74 | 0.48 | 77 % |
| App, smoother decoder (penalty 2.0, weak beat ×2.0, min 1 beat) | 37 | 0.62 | 0.51 | 0.56 | 85 % |
| Jiang et al. 2019 (5-model ensemble) | 82 | 0.41 | 0.80 | 0.53 | 93 % |
| consonance-ACE (default, 0.5 s minimum) | 69 | 0.44 | 0.69 | 0.51 | 82 % |
| BTC (maj/min model) | 117 | 0.32 | 0.85 | 0.45 | 87 % |

Flip Flops alone, against the detailed chart: app today F1 0.58 (76 % in chart); Jiang 0.87
(P 0.93, R 0.81, 98 %); BTC 0.82 (P 0.84, R 0.80, 99 %); consonance-ACE 0.69. Per-song wins
(F1) across the 22: Jiang 12, consonance-ACE 10, BTC 0.

Reproduce: `/Volumes/SSD/chord-models-ref` (repos, `run_btc.py`, `run_jiang.py`, `run_ace.py`
shims for NumPy 2 / PyYAML 6 / CPU loading, `compare.py`, `score_lab.py`, `runs/results.json`).
