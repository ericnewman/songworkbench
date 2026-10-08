# Separating individual harmony singers from a backing-vocal stem (survey, 2026-10-07)

Question: how well can SongWorkbench pull "voice 3 of 4" out of the backing-vocal stem as its own
audio track? The first version uses an F0-informed harmonic mask driven by `VocalHarmonyAnalyzer`.
How good can that mask get, what do learned separators add, and what would a robust implementation
need?

Sources are primary: ISMIR, ICASSP, Interspeech, TASLP, IEEE JSTSP, and Frontiers papers or the
authors' arXiv preprints; GitHub repositories (README, `LICENSE`, file tree through the GitHub API);
Hugging Face model cards; and Zenodo dataset records. Every number links to the paper and table or
section that reports it. **Inference** marks conclusions drawn here and not stated by a source.
**Unverified** marks claims that could not be confirmed from a primary source.

## Bottom line

- **The harmonic mask can isolate a voice usefully only where the voices sing different notes that
  do not share many partials.** Published F0- or score-informed mask/NMF systems reach about
  5–7.6 dB SDR or SI-SDR on clean four-part vocal mixtures with good pitch input
  ([Gover & Depalle 2020 §7.6](https://program.ismir2020.net/static/final_papers/135.pdf);
  [Richard et al. 2024 Table 1](https://arxiv.org/abs/2401.16837)). That is an audible, usable
  practice track with clear bleed. It is not a clean stem.
- **Unisons and octave doubles cannot be separated by any magnitude mask, harmonic or learned.** On
  MedleyVox, even the oracle ideal ratio mask improves unison pairs by only 4.5 dB SI-SDR, against
  15.3 dB for duets ([Jeon et al. 2023 Table 4](https://arxiv.org/abs/2211.07302)). Stacked doubles
  of one singer are common in pop backing vocals (**inference**), so the app must detect these
  frames and label them as merged rather than claim a separated voice.
- **Pitch precision is the main lever for the mask.** An F0-driven separator degrades smoothly with
  F0 error. It loses to its baselines beyond about 5 Hz of error and is no better than a do-nothing
  separator beyond about 23 Hz ([Schulze-Forster et al. 2023 §V-B](https://arxiv.org/abs/2201.09592)).
  The app's detector reports semitone-quantised MIDI notes (`VocalHarmonyAnalysis.swift`). Each voice
  therefore needs a continuous, sub-semitone F0 track before masking (**inference**).
- **Learned separators are better on matched data but generalise poorly.** Models trained on one
  choir dataset can fall to −5 to −16 dB on the tenor part of an unseen choir
  ([Chandna et al. 2022 Table 4](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full)).
  No released model is trained on separated pop backing vocals. The only open-weight a cappella model
  (SepACap, MIT weights) was trained on jaCappella, which prohibits commercial use without a paid
  licence ([model card](https://huggingface.co/Tino3141/sepacap);
  [jaCappella terms](https://tomohikonakamura.github.io/jaCappella_corpus/)).
- **Recommended path (inference):** ship the harmonic mask with sub-semitone F0 refinement,
  overlap-aware soft Wiener masks, a residual track for unpitched energy, and per-frame "merged"
  flags. Then prototype the F0-conditioned harmonic-plus-noise model of Schulze-Forster et al.
  (Apache-2.0 code, 22 MB checkpoint). It is trained without isolated stems, so it can be adapted
  on the app's own backing-vocal stems. Expect it to add roughly 1–3 dB over a plain mask on clean
  material (inferred from the CSD comparisons below). Do not expect it to fix unisons.

## What the app does today (context, from the code)

| Item | Current behaviour | Where |
|---|---|---|
| Pitch input | Per-frame candidates on a semitone grid, MIDI 48–84 (C3–C6), up to 4 notes per frame; 4,096-sample frames, 2,048-sample hop (≈ 46 ms at 44.1 kHz) | `VocalHarmonyAnalyzer` in `Sources/SongWorkbench/VocalHarmonyAnalysis.swift` |
| Voice identity | Notes clustered into rows by a timbre vector, then ordered by median pitch | `assignVoiceRows`, `VocalTimbreClustering.swift` |
| Timbre vector | Mel cepstrum over 300–5,000 Hz with bands at least 800 Hz wide, computed **once per frame**. Every note detected in that frame gets the same vector. | `MelTimbreExtractor`; comment in `analyze(samples:…)` |
| Lead/backing split | UVR MDX-Net Karaoke 2 (ONNX) | `ModelCatalog.swift` (`karaoke-bsroformer-onnx`) |

**Inference:** the per-frame timbre vector cannot tell apart two notes that sound in the same frame,
because both notes carry the same vector. Voice identity for simultaneous notes therefore rests on
pitch order and continuity, which is the regime where published systems fail at voice crossings (see
the section on voice assignment).

## 1. F0- and score-informed separation of simultaneous voices

### Methods and reported quality

| Method | Signal model | Test material | Reported quality | Source |
|---|---|---|---|---|
| Harmonic time-frequency mask with an overlap rule (Soundprism) | Each harmonic bin goes to its source. Shared bins are split in inverse proportion to the square of the harmonic number. Non-harmonic bins are split 1/J across active sources. | Synthetic 2-voice instrument pieces; Bach10 (violin, clarinet, saxophone, bassoon) | Median SDR ≈ 5.5 dB with score following, 7.4 dB with ideal alignment, for polyphony 2. On Bach10 quartets the lowest (bass) track scores clearly worse. | [Duan & Pardo 2011 §III-C, §V-E, Figs. 4, 8, 9](https://labsites.rochester.edu/air/publications/DuanPardo_Soundprism_JSTSP11.pdf) |
| Score-informed NMF (SI-NMF, Ewert & Müller initialisation) | Per-pitch spectral templates; activations constrained by the score | Synthesised Bach chorales; real Choral Singing Dataset (CSD) | 6.2–8.1 dB below score-informed Wave-U-Net on synthetic data. On real CSD it scores **5.6 dB** median SDR, beating Wave-U-Net trained on synthetic data (1.4–1.5 dB). | [Gover & Depalle 2020 §7.5–7.6](https://program.ismir2020.net/static/final_papers/135.pdf) |
| F0-informed NMF and source-filter NMF (Durrieu-style), Wiener filtering | Templates per 1/10 semitone (NMF1); glottal source × smooth filter (NMF2) | CSD, 2 and 4 voices, F0 from a multi-F0 estimator | Below the UMSS model in both settings (figure only; no table values) | [Schulze-Forster et al. 2023 §IV-C, Fig. 4](https://arxiv.org/abs/2201.09592) |
| Differentiable harmonic-plus-noise source-filter model, F0-conditioned, soft-mask Wiener output (UMSS) | DDSP-style harmonics plus filtered noise per voice; network estimates the filter, amplitudes, and noise from the mixture given each F0 | Trained on Bach Chorales + Barbershop Quartet (91 min); tested on CSD, 4 voices | Mean SI-SDR **6.91 dB**, median **7.60 dB** (U-Net with F0 conditioning: 4.44 / 5.71) | [Richard et al. 2024 Table 1b](https://arxiv.org/abs/2401.16837) (reporting UMSS as its baseline) |
| Fully differentiable UMSS with built-in multi-F0 and voice assignment | Same, but pitch and assignment learned jointly | Same | Mean SI-SDR 6.20 dB, below UMSS with an external F0 tracker and heuristic assignment | [Richard et al. 2024 Table 1b](https://arxiv.org/abs/2401.16837) |

Common ground across these methods: each assigns mixture energy to voices by the predicted
harmonic positions, then applies a soft (Wiener-style) mask. Soundprism's authors call their
equal-amplitude, 12 dB/octave overlap assumption "very coarse"
([Duan & Pardo 2011 §III-C](https://labsites.rochester.edu/air/publications/DuanPardo_Soundprism_JSTSP11.pdf)).
UMSS synthesises each voice and uses that synthesis only to build the soft masks. The directly
synthesised voices scored worse, because the network overestimates noise content
([Schulze-Forster et al. 2023 §V-C](https://arxiv.org/abs/2201.09592)). **Inference:** a mask over
the real stem should stay the delivered output, and synthesis should only shape the mask. That is
the same split as the app's plan to deliver a masked track plus a separate guide tone.

### Known failure cases

| Failure | Evidence | Consequence for the app |
|---|---|---|
| **Unison and octave doubling** | IRM ceiling on MedleyVox unison pairs: 4.5 dB SI-SDRi, versus 15.3 dB on duets; the authors conclude phase information is critical for unison ([Jeon et al. 2023 Table 4, Exp 3](https://arxiv.org/abs/2211.07302)). A unison mixture of the same singer's two takes is part of their definition. | Masks cannot split doubles. Flag these frames as merged. |
| **Octave error in the F0** | Transposing F0 up one octave degrades UMSS rapidly; transposing down degrades it moderately, because every even harmonic of the lower guess still lands on the target ([Schulze-Forster et al. 2023 §V-B, Fig. 8](https://arxiv.org/abs/2201.09592)). | A note detected an octave too high loses half its partials. A note an octave too low steals the even partials of another voice. |
| **Fifths, fourths, and shared partials** | The harmonic overlap of a mixture, measured on the first 16 partials (strongest for octaves, then fifths, fourths, major thirds), correlates with SI-SDR at Pearson r = −0.334 for Conv-TasNet ([Sarkar et al. 2021 §3.2, §4.3](https://www.isca-archive.org/interspeech_2021/sarkar21_interspeech.pdf)). The bass part, which shares the most harmonics, scores lowest ([Petermann et al. 2020 §5.2.1](https://archives.ismir.net/ismir2020/paper/000276.pdf)). | Close-harmony parts (thirds, fifths) leak into each other most. |
| **Pitch-track error, vibrato, portamento** | UMSS with oracle F0 beats estimated F0 by more than 3 dB; quality falls smoothly with Hz error; above about 5 Hz it no longer beats its baselines; above about 23 Hz it is no better than the "dummy" separator at −7.23 dB ([Schulze-Forster et al. 2023 §V-B](https://arxiv.org/abs/2201.09592)). A cappella mixtures feature vibrato and portamento ([Lanzendörfer et al. 2025 §1](https://arxiv.org/abs/2509.26580)). SI-NMF needed a 1-semitone pitch tolerance ([Gover & Depalle 2020 §4](https://program.ismir2020.net/static/final_papers/135.pdf)). | **Inference:** a semitone grid is ±50 cents, about ±6.4 Hz at A3 and roughly 10 times that at the 10th harmonic. Without per-frame F0 refinement the comb misses the upper partials. |
| **Voice activity errors** | UMSS stays effective below about 20 % voice-muting errors and degrades roughly linearly ([Schulze-Forster et al. 2023 §V-B, Fig. 9](https://arxiv.org/abs/2201.09592)). | Missed short notes cost less than wrong pitches. |
| **Unvoiced consonants, sibilants, breath** | Singing produces sounds with no harmonic content, such as unvoiced consonants ([Schulze-Forster et al. 2023 §IV](https://arxiv.org/abs/2201.09592)). Soundprism shares non-harmonic bins equally because discarding them caused artifacts ([Duan & Pardo 2011 §III-C](https://labsites.rochester.edu/air/publications/DuanPardo_Soundprism_JSTSP11.pdf)). Breath and sibilant noise and tightly aligned consonants are listed as a cappella difficulties ([Lanzendörfer et al. 2025 §1](https://arxiv.org/abs/2509.26580)). A comparable method's overall accuracy is about 8 points below its pitch accuracy because it predicts periodicity in unvoiced frames ([Richard et al. 2024 §5.1](https://arxiv.org/abs/2401.16837)). | A pure harmonic comb drops consonants, so words sound mumbled. Give unpitched energy to a residual track, or spread it across active voices by their envelope. |
| **Reverb** | UMSS states that reverberation must be modelled explicitly and known beforehand ([Schulze-Forster et al. 2023 §V-C](https://arxiv.org/abs/2201.09592)). Its training data was reverberant and its test data much less so ([§IV-A](https://arxiv.org/abs/2201.09592)). The vocal multi-F0 CNN was evaluated with added reverb ([Cuesta et al. 2020](https://arxiv.org/abs/2009.04172)). | **Inference:** reverb tails smear partials across note boundaries, so a hard per-note mask chops tails and leaks the previous chord. |
| **Voice assignment (wrong voice gets the note)** | The most common low-SDR cause in Wave-U-Net was notes assigned to the wrong voice, at voice crossings and when one voice rests; score conditioning removed it ([Gover & Depalle 2020 §7.1, §7.5](https://program.ismir2020.net/static/final_papers/135.pdf)). Learned duet separators swap singers between outputs mid-segment ([Jeon et al. 2023, failure analysis](https://arxiv.org/abs/2211.07302)). UMSS assigns voices by pitch sort plus continuity ([Schulze-Forster et al. 2023 §IV-B](https://arxiv.org/abs/2201.09592)). | An assignment error moves the right audio into the wrong track. The mask quality metric does not see it, but the user does. |
| **Several singers per part** | Conditioning on one F0 per section loses most of its advantage on 16-singer mixtures, because a unison has no single F0 ([Petermann et al. 2020 §5.2.2](https://archives.ismir.net/ismir2020/paper/000276.pdf)). | Group vocals and gang choruses behave like unisons. |

## 2. Learned models for multiple singers

SDR figures are not comparable across rows: datasets, metrics (SDR, SI-SDR, improvement over the
mixture), and sample rates differ.

| Work | Task and data | Reported result | Code / weights licence | Size, rate | On-device plausibility (**inference** unless cited) |
|---|---|---|---|---|---|
| **Petermann et al., ISMIR 2020** — F0-conditioned U-Net (FiLM) | SATB; CSD + 26-song proprietary set; oracle F0 from DIO | About +1 dB SDR and +1.5 dB SIR over unconditioned models (4 singers). Best average SIR 12.08 dB, SAR 7.21 dB. SDR is shown in box plots only. ([§5.2, Table 1](https://archives.ismir.net/ismir2020/paper/000276.pdf)) | Paper says pre-trained models are linked from a results page; **unverified** (GitHub repo not found) | Spectrogram U-Net; size not stated | Small U-Net is Core ML-friendly. Trained on 3 public songs plus a private set. |
| **Gover & Depalle, ISMIR 2020** — score-informed Wave-U-Net | Synthesised Bach chorales (3 h 48 min); tested on real CSD | Synthetic: +2.7 dB median SDR for alto and tenor from the score. Real CSD: 1.4–1.5 dB, below SI-NMF at 5.6 dB ([§7.5–7.6](https://program.ismir2020.net/static/final_papers/135.pdf)). | MIT; README links pretrained models ([repo](https://github.com/matangover/score-informed-Wave-U-Net)) | Wave-U-Net, 22.05 kHz | Feasible, but domain shift makes it worse than NMF on real voices. |
| **Sarkar, Benetos & Sandler, Interspeech 2021** — Conv-TasNet / DPTNet with PIT | Bach Chorales + Barbershop Quartet (104 min, commercial, no bleed) | 4-voice SDR 7.52 dB (Conv-TasNet), 8.61 dB (DPTNet). Random re-mixing of parts costs 4.32 dB SI-SDR. Cross-dataset performance is "really poor" ([Tables 1–2, §4.2, §5](https://www.isca-archive.org/interspeech_2021/sarkar21_interspeech.pdf)). | No code or weights located; **unverified** | 22.05 kHz | Conv-TasNet is 5.1 M parameters at 8 kHz in the original speech paper ([Luo & Mesgarani 2019 Table IV](https://arxiv.org/abs/1809.07454)). |
| **Chen et al., ISMIR 2022** — synthetic expressive choir data | 8.2 h synthesised JSB chorales; fine-tuned on Cantoría, CSD, BBC | Spec-U-Net 10.61 dB median SDR on synthetic vocal test. Real data after pretraining + 70 % fine-tune: Cantoría 5.71, CSD 7.50, BBC 7.64 dB; 10 % fine-tune: 3.73 / 4.19 / 5.58 dB ([Tables 3–4](https://arxiv.org/abs/2209.02871)) | MIT code ([repo](https://github.com/RetroCirce/Choral_Music_Separation)); no weights listed in README | Spectrogram U-Net | Shows synthetic pretraining helps, but each real dataset still needed in-domain fine-tuning. |
| **Chandna et al., Frontiers 2022** — U-Net, Wave-U-Net, Open-Unmix, Conv-TasNet | CSD + Bach Chorales + Dagstuhl ChoirSet + cleaned ESMUC; tested on an unseen ESMUC song | Open-Unmix (choir case) SDR: soprano −0.14, alto 10.82, tenor −7.09, bass 8.02 dB. Conv-TasNet average −5.11 dB ([Table 4](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full)). | Not checked; **unverified** | 22.05 kHz | Evidence that inner voices collapse on unseen material. |
| **UMSS, Schulze-Forster et al., TASLP 2023** — unsupervised, F0-informed | Trained on mixtures only (BC + BQ); the paper also shows good results from 2 min 40 s of training audio | CSD 4 voices: mean SI-SDR 6.91 dB, median 7.60 dB ([Richard et al. 2024 Table 1b](https://arxiv.org/abs/2401.16837)). Nearly equal to the same model trained supervised ([§V-A](https://arxiv.org/abs/2201.09592)). | Code: Apache-2.0 `LICENSE`, but the README says "All rights reserved" (conflict, ask the author). Checkpoints in repo: `trained_models/*/…pth` 22.3 MB for 2- and 4-voice models ([repo](https://github.com/schufo/umss)). Training audio is commercial (PG Music). | 16 kHz, 4 s excerpts | Small. The network part should convert to Core ML. The all-pole filter and harmonic synthesis are cheap DSP that can be ported to Accelerate. RTF not reported. |
| **Richard, Chouteau & Torres, 2024** — fully differentiable UMSS | Same data; adds a multi-F0 estimator and learned assignment; tested on CSD and Cantoría | 6.20 dB mean SI-SDR on CSD, below UMSS with an external F0 tracker ([Table 1b](https://arxiv.org/abs/2401.16837)) | Not located; **unverified** | 16 kHz | Shows learned assignment does not yet beat explicit F0 plus heuristic assignment. |
| **MedleyVox, Jeon et al., ICASSP 2023** — Conv-TasNet + iSRNet | Pop multi-singing from MedleyDB (evaluation); trained on 400 h of single-singing + 460 h LibriSpeech, mixed on the fly | SI-SDRi: duet 14.2, unison 4.4, main vs. rest 6.3 dB. IRM ceiling: 15.3 / 4.5 / 13.2 dB ([Tables 4–5](https://arxiv.org/abs/2211.07302)) | Code without licence file; "no plan to upload the pre-trained weights" ([repo](https://github.com/jeonchangbin49/MedleyVox)). Dataset CC BY 4.0 ([Zenodo](https://zenodo.org/records/7984549)). | 24 kHz; iSRNet 166 K parameters ([Table 6](https://arxiv.org/abs/2211.07302)) | **No weights.** MedleyVox is the closest public evaluation set to pop harmony. |
| **Lin, Chen & Jang, 2021/2024** — DPRNN / DPTNet singer separation | YouTube English and Chinese songs, synthetic duets and same-singer "self-harmonic" pairs | English duet SDRi 8.78 dB. Same-singer self-harmony: 5.27 dB with a dedicated model, 3.22 dB with the duet model ([Table 3](https://arxiv.org/abs/2110.06707)) | Dataset released ([project page](https://gulaerchen.github.io/MIR-SingerSeparation/)); weights **unverified** | **8 kHz** | 8 kHz output is not usable as a practice track. |
| **SepACap, Lanzendörfer et al., 2025** — SepReformer adapted | jaCappella (35 songs, 34 min), power-set augmented to 145 h; 6 parts | All stems present, SI-SDRi: alto 14.6, bass 23.2, lead 13.0, soprano 13.1, tenor 17.0 dB. Mel-Band RoFormer trained on the same data: 6.3 / 17.8 / 0.7 / 4.5 / 10.3 dB ([Table 3](https://arxiv.org/abs/2509.26580)). Handles absent stems ([Table 4](https://arxiv.org/abs/2509.26580)). | Weights MIT on the model card, `SepACap.pth` 161 MB ([HF](https://huggingface.co/Tino3141/sepacap)); code repo has no licence file ([GitHub](https://github.com/ETH-DISCO/SepACap)). **Training data prohibits commercial use** ([jaCappella terms](https://tomohikonakamura.github.io/jaCappella_corpus/)). | 24 kHz, mono; fixed 6-part output names | Tested only in-domain on jaCappella. Its fixed SATB-plus-lead output does not map onto pop backing vocals. Transformer size suggests Core ML conversion is feasible but heavy; RTF not reported. |
| **Xu & Kim, 2026** — singer-informed (enrollment) separation | Duets built from DAMP-VSEP; Open-Unmix + singer embedding (FiLM or concat) | Duet target SI-SDR 0.33 → 5.58 dB ([abstract, Table 1](https://arxiv.org/abs/2608.14516)) | Checkpoints on Google Drive; no licence file ([repo](https://github.com/jocelynxu01/singer-separation-paper)) | Open-Unmix (small) | Keys on singer identity, so it cannot split stacked parts by one singer (**inference**). |
| **Narahata et al., APSIPA 2026** — phoneme-conditioned BS-RoFormer | Lead vs. other parts on jaCappella | Lead SI-SDRi gains of up to about 10 dB per song over audio-only ([Table I](https://arxiv.org/abs/2609.06488)) | Uses the ZFTurbo training code; weights not stated | BS-RoFormer | Solves lead-vs-rest, which the karaoke model already covers. |
| **NoteSep, Chou et al., 2026** — note-level score-informed separation | Per-note extraction conditioned on pitch, onset, offset; 16 instruments | Median per-note SI-SDR 7.39 dB vs. 2.49 dB for the strongest baseline ([abstract, Table 1](https://arxiv.org/abs/2609.29071)) | "Code and pretrained models … coming soon" ([repo](https://github.com/ben2002chou/notesep)) | 27.4 M parameters per stream ([§2](https://arxiv.org/abs/2609.29071)) | **No weights.** Instruments, not voices. Its per-note interface matches the app's note observations, so watch for a release. |

### Pop backing vocals specifically

- MoisesDB groups vocal tracks into "Background Vocals", "Lead Female Singer", "Lead Male Singer",
  and "Other" ([Pereira et al. 2023 Table 2](https://arxiv.org/abs/2307.15913)). It is offered for
  non-commercial research use only ([§1](https://arxiv.org/abs/2307.15913)). No published model
  separates individual harmony parts inside the MoisesDB background-vocal stem; none was found in
  this search. Whether the individual MoisesDB tracks keep separate harmony parts was not checked
  (**unverified**).
- MedleyVox is the only public multi-singer pop evaluation set found. Its "main vs. rest" category is
  the closest to a backing stack, and the best model reaches 6.3 dB SI-SDRi there against a 13.2 dB
  oracle ([Jeon et al. 2023 Table 5](https://arxiv.org/abs/2211.07302)).

### Datasets with isolated singers

| Dataset | Content | Licence |
|---|---|---|
| Choral Singing Dataset | 3 songs, 16 singers (4 per SATB part), about 7 min, some same-section bleed ([Chandna et al. 2022 §2.2](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full)) | CC BY 4.0 ([Zenodo](https://zenodo.org/records/1286485)) |
| Dagstuhl ChoirSet | 2 songs plus exercises, 13 singers, about 55 min, some inter-section bleed ([same](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full)) | CC BY 4.0 ([Zenodo](https://zenodo.org/records/3897181)) |
| ESMUC Choir Dataset | 3 songs, 12 singers, about 21 min, high inter-section bleed ([same](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full)) | CC BY 4.0 ([Zenodo](https://zenodo.org/records/5848989)) |
| Cantoría | 11 songs, SATB, 36 min 10 s ([Richard et al. 2024 §4.1](https://arxiv.org/abs/2401.16837)) | CC BY 4.0 ([Zenodo](https://zenodo.org/records/5851070)) |
| Bach Chorales + Barbershop Quartet | 26 + 22 songs, clean, about 104 min ([Sarkar et al. 2021 §3.3](https://www.isca-archive.org/interspeech_2021/sarkar21_interspeech.pdf)) | Commercial; not publicly available for research ([Chandna et al. 2022 §2.2](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full)) |
| jaCappella | 35 songs, 6 parts incl. lead and vocal percussion ([Lanzendörfer et al. 2025 §2](https://arxiv.org/abs/2509.26580)) | No commercial use or redistribution; paid commercial licence available ([terms](https://tomohikonakamura.github.io/jaCappella_corpus/)) |
| MedleyVox | 23 MedleyDB songs, 381 segments, 1.1 h, unison/duet/main-vs-rest/N-singing ([Jeon et al. 2023 Table 1](https://arxiv.org/abs/2211.07302)) | CC BY 4.0 ([Zenodo](https://zenodo.org/records/7984549)) |
| MoisesDB | 240 tracks, 14 h, background-vocal stem ([Pereira et al. 2023](https://arxiv.org/abs/2307.15913)) | Non-commercial research use ([§1](https://arxiv.org/abs/2307.15913)) |

Two training-data findings pull against each other. Sarkar et al. lost 4.32 dB SI-SDR when SATB
parts were randomly re-paired across songs, and concluded that harmony models need musically
coherent mixtures ([§4.2](https://www.isca-archive.org/interspeech_2021/sarkar21_interspeech.pdf)).
MedleyVox found that random mixing of different singers gave fair quality with 400 h of data
([§4.2, Table 2](https://arxiv.org/abs/2211.07302)). **Inference:** with little data, coherent
harmony matters. With hundreds of hours, random mixing is tolerable.

## 3. Recommendation

### Expected quality of the harmonic-mask baseline (inference)

- **Best case** (two or three backing parts in distinct thirds or sixths, dry, accurate F0): similar
  to F0-informed NMF and Soundprism, around 5–7 dB SDR. The voice is clearly dominant, with audible
  bleed from the other parts and thin consonants.
- **Typical pop backing stack:** lower. The input is already a karaoke-model estimate, so its
  artifacts carry through. Parts are often doubled or stacked by one singer. Reverb is common. The
  pitch input is semitone-quantised.
- **Unison and octave doubles:** no separation. The two takes stay in one track whatever the method
  ([Jeon et al. 2023 Table 4](https://arxiv.org/abs/2211.07302)).

### What a robust harmonic-mask implementation needs (inference, grounded in the failure table)

1. **Continuous F0 per note.** Refine each detected MIDI note into a per-frame F0 within ±1
   semitone, using a shorter hop than 46 ms so vibrato is followed. Target an error well under 5 Hz
   on the fundamental ([threshold from Schulze-Forster et al. 2023](https://arxiv.org/abs/2201.09592)).
2. **Harmonic-number-aware comb.** Widen each partial's band with harmonic number, so F0 uncertainty
   does not drop upper partials. Stop at a partial count or frequency ceiling where the stem
   becomes noise.
3. **Overlap-aware soft masks that sum to one.** Apportion shared partials with each voice's
   spectral envelope, as a source-filter Wiener filter does, rather than by equal split or the
   1/h² rule ([Duan & Pardo 2011 §III-C](https://labsites.rochester.edu/air/publications/DuanPardo_Soundprism_JSTSP11.pdf)).
   The per-note envelope must be measured per note, not per frame, because the current timbre
   vector is per frame.
4. **A residual track.** Keep unpitched energy (consonants, breath, reverb tails) in a residual
   track, or spread it across active voices by envelope. Otherwise extracted voices lose their
   words.
5. **Merged-voice flags.** Mark frames where two voices' F0s fall within a few cents or at an exact
   octave. Show "voices 2+3 doubled here" instead of two near-identical tracks.
6. **Voice-assignment checks.** Treat crossings and rests as the main assignment risk
   ([Gover & Depalle 2020 §7.1](https://program.ismir2020.net/static/final_papers/135.pdf)). Keep
   assignments stable across the song, and let the user swap a note's voice.
7. **Runtime.** One STFT of the stem, a mask per voice, and one inverse STFT per voice. This should
   take seconds per song on Apple Silicon (**unverified**; not measured). It does not need the
   long-running job machinery that ML models use.

### Learned upgrade path (inference)

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| UMSS-style F0-conditioned harmonic-plus-noise model + Wiener mask | Uses the app's F0 directly. Trains on unlabelled mixtures, so it can be adapted on the app's own backing stems; the authors suggest per-mixture optimisation and lead vs. background vocals as use cases ([§V-A](https://arxiv.org/abs/2201.09592)). 22 MB checkpoint. About 7.6 dB median SI-SDR on clean CSD. | Assumes known voice count, harmonic monophonic sources, and no unmodelled reverb ([§V-C](https://arxiv.org/abs/2201.09592)). 16 kHz output needs bandwidth extension or masking at full rate. Code licence statement conflicts. | **Prototype next.** Run its masks on the full-rate STFT. |
| SepACap (a cappella SepReformer) | Best published in-domain numbers; handles absent parts; MIT weights | Weights trained on non-commercial jaCappella; fixed SATB + lead outputs; no F0 conditioning; generalisation to pop untested | Offline comparison only, unless a commercial jaCappella licence is bought |
| Train a pitch-conditioned separator (FiLM-conditioned band-split or U-Net, as in Petermann et al. 2020 and Gover & Depalle 2020) | Conditioning fixes voice-assignment errors ([Gover & Depalle 2020 §7.5](https://program.ismir2020.net/static/final_papers/135.pdf)) | Needs coherent multitrack harmony data. CC BY choir sets total about 2 h and are classical. Pop stems carry non-commercial terms. Synthetic data needs real fine-tuning ([Chen et al. 2022 Table 4](https://arxiv.org/abs/2209.02871)). | Only with a licensed pop harmony dataset |
| Speaker-style PIT models (Conv-TasNet, DPTNet) without conditioning | Small (5.1 M parameters for Conv-TasNet) | Output order is arbitrary; singers swap mid-segment; poor cross-dataset results ([Sarkar et al. 2021 §5](https://www.isca-archive.org/interspeech_2021/sarkar21_interspeech.pdf); [Jeon et al. 2023](https://arxiv.org/abs/2211.07302)) | Not recommended |

### How to measure

- Build a small evaluation set with isolated harmony parts: MedleyVox "duet" and "main vs. rest"
  segments (CC BY 4.0), plus CSD and Cantoría quartets mixed to two to four voices. Report SI-SDR per
  voice, separately for unison or octave frames and other frames.
- Feed the evaluation mixtures through the app's own detector, not oracle F0, and also report the
  oracle-F0 score. The gap measures how much the pitch front end costs.
- Count voice-assignment errors (notes in the wrong track) as a separate number, because SI-SDR hides
  them.
- Listen to consonant-heavy lines. Report residual-track energy, which shows how much was dropped.

### Main risks

- **Expectation risk:** users will hear bleed on every track and no separation on doubles. Label the
  feature "practice isolation", and show merged regions.
- **Pitch front end:** semitone quantisation and per-frame timbre limit both mask accuracy and voice
  assignment. Refinement is required, not optional (**inference**).
- **Input quality:** the backing stem is itself a model estimate. Any lead residue becomes a
  "voice" (**inference**).
- **Licensing:** every learned model with released weights was trained on data with commercial
  restrictions or unclear provenance (jaCappella, PG Music Bach Chorales/Barbershop, DAMP-VSEP).

## What could not be verified

- Pretrained-model availability for Petermann et al. 2020 (results page not checked), Sarkar et al.
  2021, Lin et al. 2021, Chandna et al. 2022, and Richard et al. 2024.
- Exact SDR values for Petermann et al. 2020 and the NMF baselines in Schulze-Forster et al. 2023:
  both papers give them only in box plots.
- Real-time factor on Apple Silicon for any model here. None of the papers reports Core ML or ONNX
  export or timing.
- Whether UMSS's 16 kHz masks transfer to a 44.1 kHz STFT without loss.
- Whether MoisesDB keeps individual harmony parts as separate tracks inside "Background Vocals".
- The licence of DAMP-VSEP, which underlies the singer-informed checkpoints.

## References

- Chandna, Cuesta, Petermann, Gómez. "A Deep-Learning Based Framework for Source Separation, Analysis, and Synthesis of Choral Ensembles." Frontiers in Signal Processing, 2022. https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full
- Chen, Dong, Luo, McAuley, Berg-Kirkpatrick, Puckette, Dubnov. "Improving Choral Music Separation through Expressive Synthesized Data from Sampled Instruments." ISMIR 2022. https://arxiv.org/abs/2209.02871 — code: https://github.com/RetroCirce/Choral_Music_Separation
- Chou et al. "On a Separate Note: Robust Score-Informed Note Separation with a Two-Stream TFC–TDF U-Net and Adaptive Set Ownership." arXiv 2609.29071, 2026. https://arxiv.org/abs/2609.29071 — repo: https://github.com/ben2002chou/notesep
- Cuesta, McFee, Gómez. "Multiple F0 Estimation in Vocal Ensembles using Convolutional Neural Networks." ISMIR 2020. https://arxiv.org/abs/2009.04172 — code (MIT): https://github.com/helenacuesta/multif0-estimation-polyvocals
- Duan, Pardo. "Soundprism: An Online System for Score-Informed Source Separation of Music Audio." IEEE JSTSP, 2011. https://labsites.rochester.edu/air/publications/DuanPardo_Soundprism_JSTSP11.pdf
- Gover, Depalle. "Score-Informed Source Separation of Choral Music." ISMIR 2020. https://program.ismir2020.net/static/final_papers/135.pdf — code (MIT): https://github.com/matangover/score-informed-Wave-U-Net
- Jeon, Moon, Choi, Chon, Lee. "MedleyVox: An Evaluation Dataset for Multiple Singing Voices Separation." ICASSP 2023. https://arxiv.org/abs/2211.07302 — repo: https://github.com/jeonchangbin49/MedleyVox — dataset: https://zenodo.org/records/7984549
- Lanzendörfer, Pinkl, Grötschla. "Source Separation for A Cappella Music." arXiv 2509.26580, 2025. https://arxiv.org/abs/2509.26580 — code: https://github.com/ETH-DISCO/SepACap — weights: https://huggingface.co/Tino3141/sepacap
- Lin, Chen, Jang. "Singer Separation for Karaoke Content Generation." arXiv 2110.06707. https://arxiv.org/abs/2110.06707 — dataset: https://gulaerchen.github.io/MIR-SingerSeparation/
- Luo, Mesgarani. "Conv-TasNet: Surpassing Ideal Time-Frequency Magnitude Masking for Speech Separation." IEEE/ACM TASLP, 2019. https://arxiv.org/abs/1809.07454
- Nakamura et al. jaCappella corpus, project page and terms of use. https://tomohikonakamura.github.io/jaCappella_corpus/ — paper: https://arxiv.org/abs/2211.16028
- Narahata, Nakamura, Saito, Saruwatari. "Lead Vocal Separation from Vocal Ensemble Mixtures Using Phoneme Alignment." APSIPA ASC 2026. https://arxiv.org/abs/2609.06488
- Pereira et al. "MoisesDB: A Dataset for Source Separation Beyond 4-Stems." ISMIR 2023. https://arxiv.org/abs/2307.15913
- Petermann, Chandna, Cuesta, Bonada, Gómez. "Deep Learning Based Source Separation Applied to Choir Ensembles." ISMIR 2020. https://archives.ismir.net/ismir2020/paper/000276.pdf
- Richard, Chouteau, Torres. "A Fully Differentiable Model for Unsupervised Singing Voice Separation." arXiv 2401.16837, 2024. https://arxiv.org/abs/2401.16837
- Sarkar, Benetos, Sandler. "Vocal Harmony Separation Using Time-Domain Neural Networks." Interspeech 2021. https://www.isca-archive.org/interspeech_2021/sarkar21_interspeech.pdf
- Schulze-Forster, Richard, Kelley, Doire, Badeau. "Unsupervised Music Source Separation Using Differentiable Parametric Source Models." IEEE/ACM TASLP 31, 2023. https://arxiv.org/abs/2201.09592 — code and checkpoints: https://github.com/schufo/umss
- Xu, Kim. "Singer-Informed Vocal Source Separation for Multi-Singer Music Mixtures." arXiv 2608.14516, 2026. https://arxiv.org/abs/2608.14516 — repo: https://github.com/jocelynxu01/singer-separation-paper
- Dataset records: Choral Singing Dataset https://zenodo.org/records/1286485 · Dagstuhl ChoirSet https://zenodo.org/records/3897181 · ESMUC Choir Dataset https://zenodo.org/records/5848989 · Cantoría https://zenodo.org/records/5851070
