# Findings — stem separation beyond 6 stems (2026-09-18)

Status: needs-triage · no code written · every number below is someone else's measurement, traced to the paper, leaderboard or repository that owns it

Answers the question raised by competitors advertising 8 stems: **is there anything real behind it, and should SongWorkbench follow?**

The short answer is that "8 stems" is a pricing tier, not a capability, and chasing it would trade away the one stem this app actually depends on.

## Recommendation

**Do not go to 8 stems. Replace the vocal path instead.**

Three findings drive this, each independently sufficient:

1. **Nobody publishes a quality number for the stems that make 8.** MVSep's Multisong leaderboard — the largest public leaderboard in this field — scores exactly five categories: bass, drums, other, vocals, instrumental. There is **no published quality metric for guitar, piano, wind, strings, synth, or any drum sub-stem** on any public leaderboard, from any vendor. Where the added stems *have* been measured, they are poor: on MoisesDB, `htdemucs_6s` scores **piano 1.60 dB and guitar 3.07 dB** against an ideal-ratio-mask ceiling of only 4.71 and 5.28 (Pereira et al., ISMIR 2023, Table 3), and Banquet's Q:ALL experiment — the state of the art in many-stem separation — reports that across background vocals, organ, synths, strings, brass and reeds, **"no sample performing above 5 dB SNR"** (Watcharasupat & Lerch, ISMIR 2024, §5.4).

2. **More stems measurably costs you the vocal.** Same architecture, same test set, same metric, MVSep Multisong: `HTDemucs4` 4-stem scores **vocals 8.24**; `HTDemucs4 (6 stems)` scores **vocals 8.05**. Bass drops 11.76 → 11.22 and drums 10.88 → 10.22. That is the price already paid for the guitar and piano stems currently shipping, and it is paid on the exact stem the lyric aligner reads.

3. **The vocal stem has ~3 dB of free headroom.** The best open vocal separators on that same Multisong protocol are **BS PolarFormer 11.00** and **Mel-Band RoFormer (KimberleyJensen) 10.98**, against the shipping 6-stem HTDemucs's **8.05**. That is **+2.95 dB on the stem that drives word timing** — larger than every architectural generation gap in the table below.

**So, concretely, in order:**

**First, add a dedicated 2-stem vocal separator and feed the aligner from it, not from the 6-stem model.** This is additive — the 6-stem path keeps producing guitar/piano/bass/drums for the chord and mixer features, and a second, smaller, vocals-only model produces the stem the aligner reads. There are two routes, and they fail in opposite places:

- **BS PolarFormer — take this one.** 51 M parameters, **SDR 11.00 vocals on Multisong**, and `bgkb/bs_polarformer` on Hugging Face already publishes **`bs_polarformer.onnx` (201 MB FP32) and `bs_polarformer_fp16.onnx` (103 MB)** under a declared MIT licence. SongWorkbench already runs ONNX Runtime. Licensing is clean and the artifact exists. The gap: it uses *polar* position embeddings rather than RoPE, and **no Core ML conversion of it exists**, so the Core ML route is unstudied.
- **Mel-Band RoFormer vocal — better documented conversion, unusable licence.** `trevorjs/melbandroformer-vocal-coreml` is a verified fp16 Core ML conversion at **cosine 0.999946 / 39.6 dB SDR** against PyTorch, built with coremltools 9.0. But the underlying KimberleyJensen checkpoint — the second-best vocal model measured anywhere — has **no licence on the repo and none on the checkpoint**. Do not ship it.

**Second, if the 6-stem base is replaced at all, replace it with SCNet — not with a RoFormer.** SCNet is the only frontier-quality architecture whose cost profile fits a local app: **10.08 M parameters** (41.2 M for `SCNet-large`), a published **CPU real-time factor of 0.669 s versus HT Demucs's 1.38 s on the same single-threaded Xeon**, and quality that beats HTDemucs everywhere. `SCNet XL IHF`, trained on MUSDB18-HQ alone, scores **MUSDB test vocals 11.42, average 10.08** — above `BS Roformer` (vocals 11.08, avg 9.65) trained on the same data. Someone has already exported SCNet to ONNX: `elicwhite/scnet-web-wasm` (MIT) ships a **44.5 MB FP32 / 22.6 MB FP16** core graph at **0.9992 correlation** with PyTorch, using exactly the DFT-as-matmul trick this repo already wrote in `tools/demucs_export/realstft.py`.

**Third, do not build a lead/backing vocal split yet, and do not extend the drum split.** Both are real features with real models behind them, and both are blocked on licensing rather than quality — see §6 and §7.

**Explicitly not recommended.** BS-RoFormer as the shipping base model — its headline 11.99 dB required **four separate 93.4 M-parameter models** (three trained, "other" by subtraction) and ~12 A100-months; the single-model L=6 variant is 72.2 M parameters for 9.80 dB, which SCNet beats at a seventh of the size. An 8-stem taxonomy of any shape. LarsNet for drums — weights are **CC BY-NC**, the code has **no licence file at all**, and its headline numbers are nSDR on **100 % synthetic Logic Pro X renders**.

**And one thing to fix regardless.** `ModelCatalog.swift:94` labels the DrumSep weights `MIT`; inagoy's MIT licence covers the *code*, and the checkpoint is distributed from an unlabelled Google Drive link with no terms. Separately, `ModelCatalog.swift:10` labels the base model `CC-BY-NC-4.0` on the strength of the MansfieldPlumbing export's claim that htdemucs_6s is "released under a research license" — but `facebookresearch/demucs` ships a plain **MIT** `LICENSE` and its README says "Demucs is released under the MIT license," with no weights carve-out anywhere. The app's own `tools/demucs_export/` already builds from Meta's checkpoint directly, so the NC claim may be inherited from a mirror the app no longer needs. Both entries deserve a second look.

## Comparison

**Protocols are not interchangeable and this table does not pretend they are.** Rows are only comparable within a block.

### MUSDB18-HQ test set, median SDR via `museval` (median of per-1 s-chunk medians)

| model | vocals | bass | drums | other | avg | params | extra data | source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Spleeter | 6.86 | 5.51 | 6.71 | 4.55 | 5.91 | — | 2500 | BS-RoFormer T2 ‡ |
| Conv-TasNet | 6.81 | 5.66 | 6.08 | 4.37 | 5.73 | — | no | BS-RoFormer T2 ‡ |
| HDemucs (v3) | 8.13 | 8.76 | 8.24 | 5.59 | 7.68 | — | 800 | BS-RoFormer T2 |
| HT Demucs | 7.93 | 8.48 | 7.94 | 5.72 | 7.52 | ~41 M † | no | SCNet T2 |
| HT Demucs | 9.20 | 10.39 | 10.08 | 6.32 | 9.00 | ~41 M † | 800 | SCNet T2 |
| BSRNN | 10.01 | 7.22 | 9.01 | 6.70 | 8.24 | — | no | SCNet T2 |
| TFC-TDF-UNet-V3 | 9.59 | 8.45 | 8.44 | 6.86 | 8.34 | — | no | Mel-Band T1 |
| Sparse HT Demucs | 9.37 | 10.47 | 10.83 | 6.41 | 9.27 | — | 800 | BS-RoFormer T2 |
| **SCNet** | 9.89 | 8.82 | 10.51 | 6.76 | **9.00** | **10.08 M** | no | SCNet T2 |
| **SCNet-large** | 10.86 | 9.49 | 10.98 | 7.44 | **9.69** | **41.2 M** | no | SCNet T2 |
| **SCNet-large** | 11.1 | 9.86 | 11.23 | 7.51 | **9.92** | 41.2 M | 235 | SCNet T2 |
| BS-RoFormer (L=6, OA) | 10.66 | 11.31 | 9.49 | 7.73 | 9.80 | 72.2 M | no | BS-RoFormer T2 |
| BS-RoFormer (L=9) | 11.02 | 11.58 | 9.66 | 7.80 | 10.02 | 82.8 M | no | Mel-Band T1 |
| Mel-RoFormer (L=6) | 11.21 | 9.64 | 9.91 | 7.81 | 9.64 | 84.2 M | no | Mel-Band T1 |
| **BS-RoFormer (L=12, OA)** | **12.72** | **13.32** | **12.91** | **9.01** | **11.99** | 93.4 M ×4 ‖ | 500 | BS-RoFormer T2 |

‡ evaluated on non-HQ MUSDB18. † SCNet states its 10.08 M is "a mere quarter of the parameter count in HT Demucs"; HT Demucs's own count is not given in either paper. ‖ see §4 — this row is *four* models.

Vocals-only, same protocol, Mel-RoFormer ISMIR 2024 Table 2 — the last block is the most interesting in this document:

| model | vocals SDR | params | rate | extra data |
| --- | --- | --- | --- | --- |
| BS-RoFormer ⓐ | 11.49 | 93.4 M | 44.1 k stereo | no |
| Mel-RoFormer ⓐ | 12.08 | 105 M | 44.1 k stereo | no |
| BS-RoFormer ⓑ | 12.82 | 93.4 M | 44.1 k stereo | 1533 in-house |
| **Mel-RoFormer ⓑ** | **13.29** | 105 M | 44.1 k stereo | 1533 in-house |
| BS-RoFormer 24k-small ⓒ | 10.56 | **8.0 M** | **24 k mono** | MoisesDB |
| **Mel-RoFormer 24k-small ⓒ** | **11.01** | **9.1 M** | **24 k mono** | MoisesDB |
| Mel-RoFormer 24k-large ⓒ | 12.69 | 50.7 M | 24 k mono | MoisesDB |

### MVSep "Multisong" — 100 tracks × 1 min, global SDR

Protocol from Solovyev et al., arXiv:2305.07489: `SDR = 10·log₁₀(Σs²/Σe²)` per stem, averaged over stems then records; mixtures public, stems withheld. The authors flag possible train/test leakage.

| model | vocals | bass | drums | other | licence of weights |
| --- | --- | --- | --- | --- | --- |
| **BS PolarFormer** | **11.00** | — | — | — | MIT (declared on the HF mirror) |
| **MelBand RoFormer (KimberleyJensen)** | **10.98** | — | — | — | **none stated anywhere** |
| BS Roformer (viperx) | 10.87 | — | — | — | none stated |
| MDX23C | 10.17 | — | — | — | none stated |
| SCNet XL IHF | 9.68 | 11.94 | 11.58 | 6.48 | none stated (code MIT) |
| MelBand RoFormer (viperx) | 9.67 | — | — | — | none stated |
| BS Roformer (MUSDB18HQ only) | 9.19 | 11.08 | 11.29 | 5.96 | none stated (code MIT) |
| HTDemucs4 FT Vocals | 8.38 | — | — | — | MIT (Meta) |
| **HTDemucs4 (4 stems)** | **8.24** | 11.76 | 10.88 | 5.74 | MIT (Meta) |
| Demucs3 mmi | 8.22 | 11.17 | 10.70 | 5.42 | MIT (Meta) |
| **HTDemucs4 (6 stems) ← shipping today** | **8.05** | 11.22 | 10.22 | — | MIT (Meta) |

The two bolded HTDemucs rows are the whole argument about stem count, measured once, under one protocol, on one architecture.

### SDX23 Music Demixing, Leaderboard C, global SDR on the organisers' hidden set

| # | system | vocals | bass | drums | other | mean | TrueSkill μ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | SAMI-ByteDance (BS-RoFormer) | 11.36 | 11.15 | 10.27 | 7.08 | **9.97** | 24.011 (3rd) |
| 2 | ZFTurbo | 10.51 | 9.94 | 9.53 | 7.05 | 9.26 | 24.362 (2nd) |
| 3 | kimberley jensen | 10.40 | 10.06 | 9.47 | 6.80 | 9.18 | **24.793 (1st)** |
| 4 | kuielab | 10.01 | 9.72 | 9.43 | 6.72 | 8.97 | — |
| — | baseline BSRNN | 7.98 | 5.63 | 6.53 | 4.43 | 6.14 | — |

**The TrueSkill column inverts the SDR column.** The organisers report plainly that the listening-test figure "does not show a clear correlation between objective scores and the judgements made by the listeners," with draw probabilities above 0.97 for all three pairs. Read as: past roughly 9 dB, SDR stops predicting what a human hears. That is a warning against optimising SDR for the *mixer* feature — and *not* against it for the aligner, which is a machine reading a waveform, and for which Jaffe & Burgoyne (2025) found SDR is the best-correlating metric of those they tested, specifically on vocals.

---

## 1. What "8 stems" actually is

Every taxonomy below was read off the vendor's own documentation on 2026-09-18.

**The phrase originates with LALAL.AI, literally.** Their blog post announcing the synthesizer stem is framed around being "the world's first 8-stem separation service," counting: vocal, instrumental, drums, bass, piano, acoustic guitar, electric guitar, synthesizer. LALAL.AI now lists **10 cloud stems** (adding `Voice and Noise`, `String Instruments`, `Wind Instruments`) and **7 on-device** through an engine it calls Lyra. **LALAL.AI does not sub-split drums at all.** Lead-versus-backing is a separate product.

So the canonical "8 stems" is **not** a drum split and **not** a vocal split. It is the 6-stem taxonomy SongWorkbench already ships, plus a synthesizer stem and an acoustic/electric guitar split.

The vendors who go further:

| product | stem names it actually publishes | drums sub-split | vocals sub-split | where it runs |
| --- | --- | --- | --- | --- |
| **Moises (Pro)** | ~26 named types across Voice / Strings & Fretted / Keyboards / Winds / Drums & Percussion | **yes** — `Kick`, `Snare`, `Toms`, `Hi-Hat`, `Cymbals`, `Percussion` (Pro tier) | **yes** — `Lead Vocals`, `Background Vocals` (Premium); `Female`/`Male Vocals` (Pro) | cloud |
| **Music.AI (Musical Stems Advanced)** | 20 literal API keys incl. `kick_drum`, `snare_drum`, `toms`, `hi_hat`, `cymbals`, `vocals_bg`, `solo_guitars`, `rhythm_guitars`, `acoustic_guitar`, `electric_guitar` | yes (6 parts) | yes | cloud |
| **AudioShake** | 16 instrument models incl. `vocals_lead`, `vocals_backing`, `guitar_electric`, `guitar_acoustic`, `keys`, `strings`, `wind`, `other-x-guitar`; `drum_kit` splits 6 ways | yes | yes | cloud API |
| **Stemulator** | 18 audio stems + 2 MIDI; lead/backing and kick/snare/hat/tom/cymbal both gated at $19.99 | yes (tier) | yes (tier) | cloud |
| **LALAL.AI** | 10 cloud / 7 local | no | separate product | both |
| **SpectraLayers 12** | `Vocals`, `Drums`, `Bass`, `Guitar`, `Piano`, `Sax & Brass`, `Other` | no | no | local |
| **Logic Pro Stem Splitter** | `vocals`, `drums`, `bass`, `guitar`, `piano`, other — **exactly SongWorkbench's six** | no | no | **on device, M1+** |
| **RipX DAW PRO** | "6+"; Hit'n'Mix does not publish the list | partial (layers) | no | local GPU |
| **Serato / FL Studio / iZotope RX / djay** | 4 | no | no | mostly local |

Three things fall out of that table.

**Apple ships the same six stems SongWorkbench does, on device, and stopped there.** Stem Splitter shipped with four in Logic Pro 11 and added guitar and piano in 11.2. The company with the most on-device ML capability and the strongest incentive to differentiate in a DAW chose exactly this taxonomy.

**Every product that exceeds six runs in the cloud.** Moises' own VST plugin says it "requires an active internet connection" and is "not a real-time stem splitter." This matters because the cloud lets them run one specialised model per stem, serially, with no memory ceiling — which, per §4, is exactly how the best published numbers are obtained. SongWorkbench has a ~3 GB per-process ceiling on iPad and a measured ~2 GB peak on macOS.

**No commercial vendor discloses its architecture.** LALAL.AI names engines (Orion, Perseus, Andromeda, Lyra, Phoenix) but not architectures. Nobody says "Demucs" or "RoFormer" on a public page. The claims are unfalsifiable by construction.

### Open models above six stems: there is exactly one, and it is a warning

**MVSep Mega 53 Stems**, a BS Roformer released through `ZFTurbo/Music-Source-Separation-Training` v1.0.21. It emits 53 named stems — `lead-vocal`, `back-vocal`, `kick`, `snare`, `hh`, `toms`, `accordion`, `sitar`, `wind-chimes`, and so on. Read the release notes before being impressed:

- **the stems overlap and do not sum to the mixture** (`vocals` contains both lead and backing);
- "The model's performance on individual stems may be lower than the specialized models available on the MVSep site";
- it requires **≥16 GB VRAM**;
- it returns all 53 stems by default, including the empty ones.

**Everything else open tops out at six.** I read UVR's actual download manifest (`TRvlvr/application_data/filelists/download_checks.json`) rather than a summary: the Demucs list contains exactly one entry above four sources, `Demucs v4: htdemucs_6s`; every Roformer and MDX23C entry is 2-stem vocals/instrumental; SCNet entries are labelled 4-stem. The only other multi-output entry is a **drum** 6-way model.

### The taxonomy the research actually uses

MoisesDB (Pereira et al., ISMIR 2023) defines the two-level ontology everything downstream cites: 11 coarse stems — `Bass`, `Bowed Strings`, `Drums`, `Guitar`, `Other`, `Other Keys`, `Other Plucked`, `Percussion`, `Piano`, `Vocals`, `Wind` — over ~38 fine tracks, where `Vocals` splits into `Background Vocals` / `Lead Female Singer` / `Lead Male Singer` and `Drums` splits into `Cymbals` / `Drum Machine` / `Full Acoustic Drumkit` / `Hi-Hat` / `Kick Drum` / `Overheads` / `Snare Drum` / `Toms`. Moises' and Music.AI's product taxonomies are recognisably this ontology with a price attached. **MoisesDB itself is CC BY-NC-SA 4.0 — non-commercial research only.** That licence is the quiet constraint under this whole section: the only public dataset with fine-grained ground truth cannot be used to train a commercial model, which is a large part of why the open ecosystem stops at six.

---

## 2. HTDemucs — the incumbent, and what its own authors say

**What it is.** Hybrid Transformer Demucs (Rouard, Massa, Défossez, ICASSP 2023, arXiv:2211.08553): a hybrid temporal/spectral bi-U-Net whose innermost layers are a cross-domain Transformer encoder, self-attention within a domain and cross-attention across. Maximum segment length 7.8 s.

**Quality.** 9.20 dB average on MUSDB18-HQ with 800 extra songs; 7.52 without.

**The 6-source model, from Meta's own README, verbatim:** "We are also releasing an experimental 6 sources model, that adds a `guitar` and `piano` source. Quick testing seems to show okay quality for `guitar`, but a lot of bleeding and artifacts for the `piano` source." And in the model list: "Note that the `piano` source is not working great at the moment." **This is the model SongWorkbench ships, and its author's published assessment of two of its six stems is "a lot of bleeding and artifacts."**

**Licence.** `facebookresearch/demucs` carries a plain MIT `LICENSE` (Meta Platforms) and the README states "Demucs is released under the MIT license." No separate weights licence appears anywhere. The CC-BY-NC-4.0 in `ModelCatalog.swift` comes from the third-party `MansfieldPlumbing/Demucs_v4_TRT` mirror, which declares `cc-by-nc-4.0` and asserts the weights are "released under a research license" **without citing one**.

**Maintenance.** "As I am no longer working at Meta, this repository is not maintained anymore." The nominal fork at `adefossez/demucs` says it is "not actively maintained anymore and only important bug fixes will be processed." **The incumbent is abandonware.**

**Cost.** README: CPU time "roughly equal to 1.5 times the duration of the track"; GPU minimum 3 GB VRAM. The repo's own measured figure (`Benchmarks/STEM_SEPARATION.md`) is 18.38 s for 60 s of audio through Python Demucs on the current Apple Silicon Mac.

---

## 3. SCNet — the candidate that fits this app

**What it is.** Tong et al., ICASSP 2024, arXiv:2401.13276. STFT → encoder of three sparse down-sampling blocks → dual-path RNN separation network → decoder. The spectrogram is split into just three bands (low/mid/high) with different compression ratios. STFT is 4096-point, 23 ms hop, **no window function** ("this has no effect on the results"). Between odd-numbered dual-path layers it applies `torch.rfft` / `torch.irfft` as a feature-space conversion.

**Quality.** 9.00 dB average on MUSDB18-HQ with no extra data — matching HT Demucs *with* 800 extra songs. `SCNet-large` reaches 9.69 without extra data and 9.92 with 235 MoisesDB songs (vocals 11.1). The community `SCNet XL IHF` checkpoint reaches **MUSDB test average 10.08, vocals 11.42**, above every BS Roformer entry trained on the same data.

**Generalisation.** Table 3 is the one that should carry weight: SCNet trained on MUSDB18-HQ **only**, evaluated on MoisesDB with no fine-tuning, scores 10.33 average against HT Demucs's 9.91 — where HT Demucs had 800 extra training songs.

**Cost — the decisive number.** "SCNet's CPU inference time is only 48% of HT Demucs." Table 1 names the environment: **Intel Xeon Platinum 8372HC @ 3.40 GHz, single-threaded, CPU RTF 0.669 s, against HT Demucs's 1.38 s.**

**Size.** 10.08 M parameters; `SCNet-large` 41.2 M.

**Licence.** `starrytong/SCNet` is **MIT**. Checkpoints are on Google Drive with **no licence stated for the weights**.

**The caveat.** Every SCNet number above is **4-stem**. There is no 6-stem SCNet, no published 6-stem SCNet result, and no 6-stem SCNet checkpoint. Adopting it means either training the extra sources (§5 says the ceiling is ~5 dB) or restructuring around 4 stems plus refiners.

---

## 4. BS-RoFormer and Mel-Band RoFormer — the frontier, and its real price

**What they are.** BS-RoFormer (Lu, Wang, Kong, Hung — ByteDance SAMI, ICASSP 2024) splits the complex spectrogram into 62 non-overlapping bands, projects each through an RMSNorm+Linear MLP, and runs interleaved time-axis and frequency-axis Transformer blocks with **rotary position embeddings**, ending in per-band MLP mask estimators with Tanh and GLU. Hann 2048, 10 ms hop, 8 s input. Mel-Band RoFormer replaces the hand-tuned band split with a binarised librosa mel filterbank, so bands **overlap** and mask values on overlapping bins are averaged.

**RoPE is not decoration.** The identical model with learnable absolute positional embeddings collapses to **5.78 dB average, including 3.08 dB on drums**, against 9.80 with RoPE, and "still remains low SDRs after two weeks of training." Any conversion that perturbs the rotary embedding will not degrade gracefully.

**Mel beats band-split on vocals and loses on bass.** At L=6, mel gives vocals 11.21 vs 10.78 but bass 9.64 vs 11.43; the authors report "the training progress became very slow when using Mel-RoFormer for bass" and could not train an L=9 bass model at all. **For an app whose priority is the vocal stem, mel is the right half of that trade.**

**The price of the headline number.** The 11.99 dB row is not one model. From §4.4: "We trained three separation models respectively for vocals, bass, and drums... For the 'other' stem, we subtracted the vocals, bass, and drums signals from the input mixture in the time domain. For each model, the training process lasted for 4 weeks using 16 Nvidia A100-80GB GPUs." **Three 93.4 M-parameter models plus an arithmetic residual, ~12 A100-months.** Anyone quoting 11.99 dB as a shippable model is quoting a system.

**On parameters-per-dB, RoFormer is the worst deal in the table for a local app.** The single-model L=6 variant is 72.2 M for 9.80 dB; SCNet reaches 9.00 at 10.08 M and `SCNet-large` 9.69 at 41.2 M.

**The one RoFormer row that genuinely matters here.** Mel-RoFormer **24k-small: 9.1 M parameters, 24 kHz mono, 11.01 dB vocal SDR**. The authors' own comment: "the smaller model with 9.1M parameters achieves over 11 dB, demonstrating its potential for resource-constrained environments." For SongWorkbench this is close to ideal-shaped — `LyricsAlignmentMTL` consumes **22.05 kHz mono**, so a 24 kHz mono vocal separator wastes nothing, at a tenth of the shipping model's size. **ByteDance has not released these weights.** That is the gap, and it is the single most valuable artifact that does not exist for this app.

**Licence.** `lucidrains/BS-RoFormer` (the reference implementation, including `MelBandRoformer` and `FlowBSRoformer`) is **MIT**. ByteDance released no weights. Every usable checkpoint is community-trained.

---

## 5. Does more stems help or hurt?

Four independent pieces of evidence. They agree.

**(a) Same architecture, same protocol, 4 vs 6.** MVSep Multisong: `HTDemucs4` vocals **8.24**, bass 11.76, drums 10.88. `HTDemucs4 (6 stems)` vocals **8.05**, bass 11.22, drums 10.22. Piano, guitar and other are recorded as `---` — **not measured**. Cost of the two extra stems: −0.19 dB vocals, −0.54 bass, −0.66 drums, and no number at all for what was bought.

**(b) Same protocol, 4 vs 6, second measurement.** Banquet's Tables 1 and 3 measure HT-Demucs on MoisesDB with median SNR: the VDBO model scores **vocals 9.1**, the 6-stem VDBGPO model **vocals 8.9**, with guitar 2.4 and piano 1.7 against an oracle IRM of 5.2 and 5.0. Independent lab, different metric, same direction and magnitude.

**(c) The ceiling on the added stems is low, and it is not the model's fault.** MoisesDB Table 3, 6-stem subset (N=88): the **ideal ratio mask** — a theoretical upper bound for any mask-based separator — reaches only **piano 4.71, guitar 5.28, other 4.67**, against vocals 9.73, bass 7.92, drums 9.19. HT-Demucs lands at piano 1.60, guitar 3.07 and **other 0.28**. Guitar and piano are not stems a better architecture rescues.

**(d) The frontier system says the trade is explicit.** Banquet §5.3, on tuning for guitar and piano: "slight gains in median SNRs of guitar and piano were observed, **albeit at the cost of vocals and drum SNRs**." And §5.4, on effects, pitched percussion, organs, synth pad, synth lead, strings, brass, reeds and **background vocals**: "there are significant variations in performance, but they are all still very weak in terms of SNR, with **no sample performing above 5 dB SNR**." Model collapse was routine: "No TE+DA+BS system was stable enough to finish the training run without collapse."

Banquet's architectural answer — a single stem-agnostic decoder conditioned by a PaSST instrument-recognition embedding, 24.9 M trainable parameters — is the right idea, and it still cannot make the long tail work, because the bottleneck is data. Performance correlates with target track-level RMS at Spearman ρ 0.78–0.81: **the model is good at loud things and bad at quiet things.**

**Conclusion.** The vocal stem drives lyric alignment; adding stems costs vocal SDR; the added stems land between 0.3 and 3 dB; even a perfect mask reaches only ~5 dB on them. **The app is already paying this tax for guitar and piano.** Whether that is worth it for the chord features is a separate question the repo's own notes already flag (`tasks/stem-algorithm-selection-findings.md` proposes exactly the right A/B: chords from `guitar` vs `accompaniment` vs the full mix). It is certainly not worth paying twice.

### The other caveat on SDR, which cuts the other way

Ding (2026, arXiv:2609.04224) ran four open separators over the 50-track MUSDB18-HQ test set. Median BSS-Eval SDR per stem:

| model | bass | drums | other | vocals |
| --- | --- | --- | --- | --- |
| Spleeter | 4.96 | 5.69 | 4.22 | 6.35 |
| HT-Demucs | 9.78 | 10.06 | 6.51 | 8.63 |
| SCNet-XL | 10.87 | 11.63 | 8.00 | **10.87** |
| BS-Roformer | 9.68 | **11.68** | 8.12 | 10.78 |

The finding: **"SDR predicts timing, but not transient or dynamic shape."** Onset F-measure tracks SI-SDR at ρ = 0.62 and is invariant to input length; transient and dynamic distortion correlate at |ρ| ≤ 0.29 and the ranking *inverts* — HT-Demucs reshapes the drum dynamic envelope ~2.3× more than BS-Roformer despite a 1.6 dB SDR gap, and more than Spleeter despite a 4.4 dB gap.

For SongWorkbench this points the right way. **Onset timing is the property SDR does protect**, and onset timing is exactly what the vocal stem feeds the aligner and the onset snapper. The transient caveat lands on drums, where this app's stake is beat tracking rather than microdynamics. Note also this is an independent, single-protocol confirmation that **SCNet-XL and BS-Roformer are within 0.1 dB on vocals** — which, with §3's cost figures, is the case for SCNet in one line.

---

## 6. Drum sub-separation

SongWorkbench already ships this — `ONNXDrumPieceSeparationEngine` with inagoy's DrumSep, kick/snare/cymbals/toms, macOS `advancedDesktop` tier only.

**LarsNet** (Mezza, Giampiccolo, Bernardini, Sarti — *Pattern Recognition Letters* 183 (2024), arXiv:2312.09663) is the only peer-reviewed system. **Five stems**: kick, snare, tom-toms, hi-hat, cymbals. Architecture: **five parallel independent U-Nets**, magnitude-STFT soft masks with mixture phase reused; 13 conv layers each, STFT 4096/1024; optional α-Wiener post-filtering.

Published numbers are **nSDR, not SI-SDR and not BSS-Eval SDR**, on the StemGMD Eval Session (400 clips): kick 27.19, snare 21.77, toms 9.10, hi-hat 6.43, cymbals 4.09, all 17.70 — against NMFD 10.97 and SAB-NMF 7.24. On "zero-energy" clips it leaks at −0.84 dB against the baselines' −25.56, a genuinely good false-positive result.

**The problem is the training data.** StemGMD is **fully synthetic**: MIDI from Magenta's Groove MIDI Dataset re-rendered through **ten Logic Pro X sampled kits**. No real miked drums, no room, no overhead crosstalk, no bleed. 103,500 clips / 1,224 h / ~1.13 TB, CC BY 4.0. **Every LarsNet number is in-domain synthetic audio, and there is no published evaluation on real recorded drums.** Riley & Dixon (arXiv:2509.24853) declined to use it for exactly this reason: "the training data is derived entirely from drum samples produced by Logic Pro X. This lack of diversity could harm separation quality when extending to real-world examples."

**Licensing is fatal anyway.** The GitHub API reports `license: null` for `polimi-ispl/larsnet` — **no licence file, default all rights reserved** — and the README states the **weights are CC BY-NC 4.0**. Inference cost is published and good: RTF 0.016 on a Titan V, **0.15 on an Intel Xeon E5-2687W**. Parameter count is not published; ~49 M total is arithmetic from `unet.py`, and the weights bundle is 562 MB.

**The community models measurably beat it on real kits.** MVSep's DrumSep 5-stem leaderboard uses **150 tracks — 18 acoustic kits × 5 playing styles plus 60 electronic kits**, plain SDR:

| model | kick | snare | toms | hi-hat | cymbals |
| --- | --- | --- | --- | --- | --- |
| DrumSep Mel Band Roformer v2 (4 stems) | **18.67** | **13.56** | 13.61 | — | — |
| DrumSep SCNet XL (5 stems) | 17.89 | 12.56 | **14.14** | 3.63 | 6.15 |
| DrumSep Mel Band Roformer (6 stems) | 17.47 | 12.65 | 13.69 | **5.06** | **7.06** |
| mdx23c_drumsep_5stem (aufr33/jarredou) | 16.66 | 11.53 | 12.32 | 4.05 | 6.36 |
| **DrumSep (inagoy) ← shipping today** | **10.53** | **6.06** | **4.68** | — | — |

LarsNet is absent from this leaderboard, so its 27.19 nSDR kick is **not** comparable to the 18.67 SDR here.

Two takeaways. **The model currently shipping is the worst entry on the board**, by 6–9 dB on toms and snare. And **hi-hat and cymbals sit at 3–7 dB across every model ever measured** — any "8 stems including hi-hat" claim is selling a 4 dB stem.

**Licensing, again.** inagoy's repo is MIT for the **code**; the checkpoint comes from an unlabelled Google Drive ID with no terms. The jarredou/aufr33/MVSep family has **no stated licence for the weights**, no paper, no documented training data (Riley & Dixon describe "a private dataset of MIDI and rendered audio from drum-sample libraries with 21.8 hours" — also synthetic, also undocumented). Moises separates six drum parts at Pro tier with no published metric, architecture, or paper.

---

## 7. Lead versus backing vocal separation

**Ground truth exists, but there is no community benchmark.**

- **MUSDB18 / MUSDB18-HQ: no lead/backing split.** The mainstream MSS benchmark cannot evaluate this task.
- **MedleyDB: not by label.** The taxonomy has `male singer`, `female singer`, `vocalists`, `choir` — no lead/backing distinction. MedleyVox derived its data by hand.
- **MoisesDB: yes** — `Vocals` splits into `Background Vocals` / `Lead Female Singer` / `Lead Male Singer`. **CC BY-NC-SA 4.0, non-commercial research only.**
- **MedleyVox: yes, for evaluation** — 381 segments / 1.1 h from 23 MedleyDB songs, including **main-vs-rest (64)**.
- **jaCappella: yes, a cappella only** — copyright-cleared Japanese pieces with an explicit `lead_vocal` part.
- Choir/SATB sets (Choral Singing Dataset, Cantoría, Dagstuhl ChoirSet, Bach10) are part-wise, not lead/backing.

**The de facto leaderboard is one vendor's undocumented 48-track private set** (MVSep, 48 tracks × exactly 40 s, plain SDR, ground-truth construction not documented):

| algorithm | lead | back | instrum |
| --- | --- | --- | --- |
| Mel-RoFormer (Karaoke / Duet) | **11.08** | **7.14** | — |
| MVSep Lead/Back BSRoformer (2025.09) | 10.42 | 6.62 | 15.70 |
| BS Roformer Karaoke (anvuew) | 10.23 | — | — |
| MDX-B Karaoke (older) | 7.94 | 1.88 | — |

**The ~4 dB gap between lead and backing is the story**, corroborated academically: MedleyVox puts **main-vs-rest at 7.2 dB SDRi against an ideal-ratio-mask ceiling of 13.7** — roughly half the achievable — and the one preprint publishing background-vocal numbers on real full mixes (Vardhan et al., arXiv:2410.20773, MoisesDB) reports **lead male 10.34, lead female 11.86, background −0.80**, with backing degrading 2.82 dB under bleed against lead's 0.04.

**Nothing usable is licensed.** MedleyVox: "Currently, we have no plan to upload the pre-trained weights of our models." The karaoke checkpoints everyone runs — aufr33+viperx, anvuew, Gabox, becruily — have **no licence stated anywhere**; UVR issue #2295 asks precisely this and has sat unanswered since 2026-07-07. The only clearly-licensed option is UVR's own MDX-Net karaoke models (MIT, with a README request to credit UVR), ~2.5 dB behind on lead and ~5 dB behind on backing. AudioShake ships `vocals_lead` and `vocals_backing` with **no metric, no architecture, no parameter count** published.

Newer academic work is promising but unreleased: Narahata et al. (arXiv:2609.06488) condition BS-RoFormer with FiLM on frame-level phoneme labels and report **SI-SDRi 14.85 dB for lead** on jaCappella against a 9.87 audio-only baseline — a nice echo of this app's own thesis that lyric information helps, but a cappella only and with no stated release. UNMIXX (ICASSP 2026, arXiv:2601.12802) claims >2.2 dB SDRi over prior methods; release status not stated.

---

## 8. Core ML convertibility

**The headline has changed since this investigation started.** My first pass found no published Core ML conversion of any RoFormer. That was a search failure. **Working conversions exist, all of them from 2026, all solving the same problem the same way: get complex tensors and `torch.istft` out of the graph.**

### The actual blocker: `torch.istft` and the complex boundary

`torch.stft` **is** supported — registered in the torch frontend (`ops.py`), landed in **coremltools 7.0** via PR #1824. `torch.istft` is **not**, and never has been: no entry in `ops.py`, `complex_dialect_ops.py`, or `lower_complex_dialect_ops.py`, and no `complex_istft` dialect op. Feature requests #2016 (2023) and #2330 (2024) are both open — **#2330 is literally this use case**, a developer converting an MSS model "to later integrate with my inference implementation in Swift." PR #2029 "Add istft operation" has been open since 2023-10-24; Apple's `junpeiz` on #2330: "It should work for most cases, and we haven't checked in the code because there are some CI failures on the Intel machine." **Do not use PR #2029 as-is** — its `_overlap_add` unrolls a Python loop over frames into one chained `mb.scatter_along_axis` per frame; at hop 512 over an 8 s chunk that is ~690 serial scatters × 2 × stems.

Constraints on the STFT that *is* supported: `n_fft`, `hop_length`, `win_length`, `window`, `normalized`, `onesided` must **all be compile-time constants**; `window` is `const` fp32; input type domain is `fp32, complex64`, **not fp16**. There is no `center` parameter, which is fine — PyTorch's Python layer does the reflect pad before `_VF.stft`, so it lands in the traced graph as an ordinary `pad`.

**Complex tensors are converter-internal only.** The lowering pass raises verbatim: `"MIL doesn't support complex data as model's output, please extract real and imaginary parts explicitly."` Apple's `TobyRoseman` on #2212: "The Core ML Framework does not support models with complex inputs." The complex-aware op surface is tiny — `add`, `size`, `view`/`reshape`, `pad`, `abs`, plus the fft/complex constructors. **`mul` is not complex-aware**, so `stft_repr * mask` fails outright (#2212), and #2112 shows the same failure on `slice_by_index` over a `complex64` tensor **from a Hybrid Demucs trace**.

### The repo's own `realstft.py` is the same technique Apple uses internally

This is worth stating plainly, because it means the hardest-looking part of this problem is already solved in-tree. coremltools' own STFT lowering (`lower_complex_dialect_ops.py`) says verbatim: *"We can write STFT in terms of convolutions with a DFT kernel… Adapted from: https://github.com/adobe-research/convmelspec/blob/main/convmelspec/mil.py"*, emitting `mb.conv(..., strides=hop, pad_type="valid")` against cos/sin DFT kernels. That is exactly what `tools/demucs_export/realstft.py` does, and it is validated in-repo at **79 dB SDR against the stock complex-STFT model**. The same technique carries to every candidate here.

**One accuracy landmine at exactly the relevant `n_fft`.** PR #2746, merged 2026-07-02, fixes a fp32 overflow in the DFT outer product that reaches `(n_fft-1)²` and corrupts high-frequency rows. Reported impact: "on an `n_fft=2048` STFT/iSTFT model: high-frequency reconstruction error against PyTorch dropped from ~0.47% to ~0.06%." BS-RoFormer and Mel-RoFormer both use `n_fft=2048`. **The fix is on `main` only and absent from released 9.0.**

### RoPE is not the blocker

`rotary-embedding-torch` — what BS-RoFormer depends on — is **real-valued, not complex**. Its `rotate_half` uses `rearrange`/`unbind`/`stack`, and the application is `(t * freqs.cos() * scale) + (rotate_half(t) * freqs.sin() * scale)`. No `view_as_complex`, no `polar`, no float64; the `@autocast('cuda')` decorator is inert on a CPU trace. Every op — `unbind`, `stack`, `cat`, `neg`, `cos`, `sin`, `split`, `einsum`, `expand` — is registered.

Three real RoPE-adjacent breakages, each with a known fix: the `einsum('..., f -> ... f')` ellipsis was mis-parsed (#2644, fixed by PR #2706 merged 2026-05-22, **`main` only**; workaround `t.unsqueeze(-1) * freqs`); `apply_rotary_emb` produces zero-width slices that Core ML rejects; and `freqs[-seq_len:]` becomes `aten::Int` under trace. `view_as_complex` is **still unregistered** (#2003, open since 2023). `torch.polar` is registered on `main` only (PR #2739, absent from 9.0).

**einops `rearrange` traces fine** (it lowers to reshape/permute, with a cosmetic `floor_divide` warning). **`pack`/`unpack` is what breaks** — they read shapes at run time, so tracing yields `aten::Int` on non-scalars. BS-RoFormer calls them ~6× per layer, Mel-Band ~8×.

### Conversions that exist, verified

| artifact | what it is |
| --- | --- |
| `benkaron/BSRoformer-Wind-CoreML` | **BS-RoFormer**, fp16 `.mlpackage`, STFT *and* iSTFT folded in as windowed-DFT matmuls. **cos 0.99998, 44.7 dB SDR** vs PyTorch. Uploaded 2026-09-17 |
| `trevorjs/melbandroformer-vocal-coreml` | Mel-Band RoFormer vocal, fp16, coremltools 9.0, macOS 15+ GPU. **cos 0.999946, 39.6 dB SDR** |
| `jonkubis/BS-ROFO-SW-Fixed-CoreML` | **6-stem BS Roformer SW** + ~1200-line Swift driver, STFT/iSTFT stripped out |
| `TrevorS/slurper` | `convert_melband_roformer.py`, pins torch 2.7.0 / coremltools 9.0 / rotary-embedding-torch 0.3.5, gates the save on cosine ≥ 0.9999 |
| `JCTec/SoundView` `WORKLOG.md` | Dated gate log, 2026-07-12: waveform end-to-end FAIL (`view_as_complex`), stft/istft inside FAIL, STFT-externalized spectral core **PASS** |

**`jonkubis`' patch list is the most actionable document found**, and it reports real numbers on real hardware: 16 GB MacBook Air M-series, 3:44 track — ONNX Runtime CPU fp32 **~7–8 s/chunk, 22:41 total** → Core ML `cpuAndGPU` **~1.1 s/chunk, 2:56 total, 0.78× realtime**, NRMSE 0.39 %. That is roughly a **7× speedup over the ONNX CPU path this app currently uses**. His patches: eliminate 0-dim slices in `apply_rotary_emb`; replace the RoPE einsum with `t.unsqueeze(-1) * freqs`; strip `view_as_complex`/`view_as_real` and write the complex mask multiply as `(ac−bd) + (ad+bc)i`; `cache_if_possible=False`; **`flash_attn=False`**. And the warning: "`cpuOnly` and `cpuAndNeuralEngine` compute units **crash** on this model in coremltools 9.0."

**Demucs Core ML conversions exist and are instructive.** `john-rocky/CoreML-Models` ships a 4-stem `demucs-v1` that routes through ONNX and forces `compute_precision=ct.precision.FLOAT32` with the comment "to prevent overflow in the frequency branch" — which, per Apple's typed-execution rule, **bars it from the ANE entirely**. `tsyrenov1987/demucs-coreml-ios` has a dense `docs/GOTCHAS.md`: `ComputeUnit.ALL` → correlation `nan`; `CPU_AND_GPU` → correlation 1.00000; simulator GPU silently returns zeros; `MLMultiArray` outputs come back row-padded.

**No Core ML conversion exists for SCNet, Open-Unmix, BSRNN, Bandit, or Apollo.** That is a real gap against the §3 recommendation — the ONNX export exists (`elicwhite/scnet-web-wasm`), but nobody has taken SCNet to Core ML. The ONNX export does most of the hard work: it replaces `torch.fft.rfft`/`irfft` with `MatMulRFFT`/`MatMulIRFFT` modules and leaves STFT to the host, which is the same shape the Core ML ports use.

Also worth knowing: **`kylehowells/demucs-mlx-swift`** runs all eight Demucs models **including `htdemucs_6s`** on MLX as an SPM package, reporting M1 Pro, 3:19 track: `htdemucs` 14.8 s, `htdemucs_6s` 17.7 s. That is a third route that bypasses Core ML conversion entirely.

### Set ANE expectations low

Apple's own guidance (`apple/ml-ane-transformers`) requires a `(B, C, 1, S)` channels-first layout with `nn.Linear` swapped for `nn.Conv2d`, softmax over channels rather than the last axis, chunked per-head einsum, and a rank cap of 5. The last-axis rule is commonly misquoted; Apple's actual wording is that the last axis "is **not packed**; it must be contiguous and aligned to 64 bytes" — 32 fp16 elements.

The hard, Apple-documented rule that matters most: from **Typed Execution**, "Only the NE is barred as a compute unit when a model is typed with float 32 precision." A float32 mlprogram cannot touch the ANE at all — which is why the only widely-used Demucs Core ML conversion, forced to FLOAT32 for numerical reasons, can never be an ANE model.

`scaled_dot_product_attention` has been registered since 7.0b1 (decomposed) with a fused `ios18` MIL op since 8.0b1 — but passing an explicit `scale` **disables the fused path**, and Apple frames the fused op as a GPU optimisation ("It really shines on Apple Silicon GPUs", WWDC24 10159), never stating it is ANE-resident. fp16 softmax on the ANE has three open numerical bugs (#2728, #2690, #2687, all 2026); coremltools' own SDPA converter masks with `-3e4` rather than `-inf`, commented "Use a big enough but not easily fp16-overflow number."

There is one useful opt-in pass for long sequences — `common::scaled_dot_product_attention_sliced_q` (8.2, defaults `min_seq_length=1280`, iOS18+), with release notes reporting "34% faster and used 45% less memory on ANE" for a sequence-1814 model. **It is not in the default pipeline.**

**No ANE benchmark exists for any separation model.** Every source that tried reports `nan`, a crash, or a GPU watchdog stall. **`cpuAndGPU` is the realistic target**, and jonkubis' 0.78× realtime is the number to beat.

### What it would take, concretely

Five moves, each attested by at least one working port:

1. **Fixed shapes everywhere.** One chunk, no dynamic axes.
2. **Freeze RoPE to constant `cos`/`sin` buffers** at the two sequence lengths. Kills the einsum bug, the empty slices and the `aten::Int` nodes at once.
3. **All-real arithmetic.** Complex mask multiply → `(ac−bd, ad+bc)`. For Mel-Band specifically, its complex `scatter_add_` band-average is a hard stop — but the scatter pattern is static, so it becomes a constant band×bin matmul.
4. **`flash_attn=False`** — the flash path wraps SDPA in a CUDA context manager that tracing cannot follow.
5. **STFT/iSTFT either externalized to vDSP or folded in as constant DFT matmuls.** Both are proven. **This repo already has the second one written and validated.**

Then trace, convert with `compute_precision=FLOAT16`, and gate on cosine ≥ 0.9999 against PyTorch before shipping. Note that several fixes you will want — the `n_fft=2048` DFT accuracy fix, the einsum-ellipsis fix, `torch.polar`, the `aten.alias` no-op — are on coremltools `main` only and **absent from released 9.0** (current release, published 2025-11-10).

---

## 9. What would actually improve THIS app, ranked

**1. Measure before changing anything.** The repo's own notes say the only recorded benchmark (`Benchmarks/STEM_SEPARATION.md`) is for the **older 4-stem Core ML FP16 engine**, and there is "no recorded number for the 6-stem ONNX CPU path in use today." Before swapping models, get (a) wall time and peak RSS for the shipping path, and (b) **word-timing error on the in-house set with the current vocal stem**, using the forced-alignment harness. Without (b), every number in this document is a proxy for the thing you actually care about.

**2. Add a dedicated vocals/instrumental model and feed the aligner from it.** Expected gain: **+2.9 dB vocal SDR** on Multisong (8.05 → 11.00), additive rather than replacing. Take **BS PolarFormer** via `bgkb/bs_polarformer` — 51 M parameters, ONNX already built (201 MB FP32 / 103 MB FP16, declared MIT), and SongWorkbench already runs ONNX Runtime. Gate it to macOS/`advancedDesktop` first, exactly as DrumSep is gated; §5 of `tasks/stem-algorithm-selection-findings.md` correctly warns that a second model per song may be impossible on iPad. **The DrumSep integration is the worked example; this is the same shape.**

**3. Run the alignment A/B that decides whether any of this matters.** Same song set, same aligner, three inputs: current 6-stem vocal, new 2-stem vocal, raw mix. If word-timing error does not move between the first two, stop — the 2.9 dB is real but the aligner is saturated, and that is a finding worth more than the model swap. The forced-alignment findings record the relevant tolerance: an asymmetric perceptual window of [−0.33 s early, +0.22 s late], against which a 0.23 s mean absolute error leaves little to waste.

**4. Consider Core ML for the vocal model, with a real speedup on the table.** jonkubis measured a RoFormer at **~7× faster on Core ML `cpuAndGPU` than on ONNX Runtime CPU** (1.1 s vs 7–8 s per chunk on a 16 GB MacBook Air). The app's ONNX CPU path is the same configuration he was measuring against. Nobody has converted BS PolarFormer, and PoPE is unstudied — but the five-step recipe in §8 is proven on three separate RoFormer ports, and the STFT half of it is already written in `tools/demucs_export/realstft.py`.

**5. Replace the 6-stem base with SCNet — but only after deciding what 6 stems are for.** SCNet is faster (CPU RTF 0.669 vs 1.38 on the paper's hardware), a quarter the size, better on every stem, generalises better off-distribution, MIT code, and already ONNX-exported. **But every SCNet checkpoint is 4-stem, and no Core ML conversion exists.** Doing this means either training guitar/piano heads (§5 says the ceiling is ~5 dB) or accepting 4 stems + refiners. Given that the repo already asks "is separation actually the bottleneck for chord accuracy?" and notes the chord path has a 5-quality vocabulary that cannot express Asus4 or D/F♯ regardless, **answer that question first.** If guitar and piano are not earning their keep, a 4-stem SCNet base plus the existing DrumSep refiner is strictly better on speed, size, memory and quality.

**6. Upgrade the drum refiner.** The shipping inagoy DrumSep is the worst entry on MVSep's drum leaderboard — 10.53 kick / 6.06 snare / 4.68 toms against 18.67 / 13.56 / 13.61. A large jump for a feature that already exists and already has an engine, blocked on weight licensing rather than engineering. Note hi-hat and cymbals top out at 5–7 dB in every model ever measured, so a 5- or 6-piece split buys two stems that will sound broken.

**7. Fix the two licence entries in `ModelCatalog.swift`.** If the NC label on the base model is wrong, it is constraining choices that need not be constrained; if it is right, the app needs to know why.

**Not on this list, deliberately:** 8 stems, a synthesizer stem, a strings stem, an acoustic/electric guitar split, a lead/backing vocal split, and any BS-RoFormer as the base model. Every one is either unmeasured, sub-5-dB, unlicensed, or 7× the parameters for less quality than SCNet.

---

## 10. Open questions and what could not be verified from public sources

**Quality of the added stems, at all.** No public leaderboard scores guitar, piano, wind, strings, synth, or any drum sub-stem in a full-mix context. The only numbers that exist are MoisesDB Table 3 and Banquet Tables 3–4, both on MoisesDB, both non-commercial data, both showing 0.3–3.3 dB. **If a vendor claims a good guitar or piano stem, there is no way to check.**

**Whether vocal SDR predicts word-timing error at all, past ~9 dB.** This is the load-bearing assumption of the entire recommendation and it is **unverified**. The forced-alignment findings established that separation quality matters and that separated vocals help models trained on separated vocals; they did not establish a dose-response curve. The SDX23 listening test is a direct warning that the SDR scale saturates for human listeners around 9 dB; whether a CTC acoustic model saturates at the same point is unknown and cheap to measure. **Experiment 3 in §9 exists to answer this.**

**Licensing of essentially every community checkpoint.** BS PolarFormer's HF mirror declares MIT, but the upstream checkpoint in ZFTurbo's repo states no weights licence — the MSST repo's MIT covers its code. KimberleyJensen's Mel-Band RoFormer, the second-best vocal model measured anywhere, has **no licence on the repo and none on the checkpoint**. Same for viperx, anvuew, Gabox, becruily, jarredou, aufr33, inagoy's weights and starrytong's SCNet checkpoints. UVR issue #2295 is the open question in public, unanswered. **I could not verify that any high-performing community checkpoint is commercially usable.**

**What these community checkpoints were trained on.** No training-data statement exists for any of them. The MSST convention appears to be MUSDB18-HQ + MoisesDB + private data with random remixing — and MoisesDB is CC BY-NC-SA, which if true would propagate a non-commercial constraint into any model trained on it. Nobody documents this.

**HT Demucs's parameter count.** Neither the HT Demucs paper's abstract nor the SCNet paper states it; SCNet only says 10.08 M is "a mere quarter" of it. The ~41 M in the comparison table is inferred from that ratio and should be replaced with a counted number before it is quoted anywhere.

**Whether the MoisesDB 4-vs-6-stem comparison is apples to apples.** It is not, strictly: N=235 for the 4-stem block and N=88 for the 6-stem block, different track subsets, different models. The MVSep comparison (8.24 vs 8.05) and the Banquet comparison (9.1 vs 8.9) are both same-test-set and agree in direction and magnitude, which is why the conclusion rests on those two.

**Multisong leakage.** The benchmark's authors write: "There is a little chance that some of the melodies in the test Multisong MVSep were occasionally used to train some of the models." No mitigation described. Community checkpoints tuned against a public leaderboard are exactly where this bites hardest, and the +2.9 dB headline comes from that leaderboard.

**Mel-RoFormer 24k-small weights.** ByteDance published the 9.1 M-parameter, 24 kHz mono, 11.01 dB result and released nothing. No reproduction and no equivalent-shaped community checkpoint found. **The single highest-value artifact that does not exist for this app.**

**No Core ML conversion of SCNet, and no ANE benchmark for any separation model.** The §9 recommendation to move to SCNet assumes a conversion that nobody has published; the ONNX export exists and does most of the work, but the Core ML step is unattempted. Separately, every ANE attempt found in public reports `nan`, a crash, or a watchdog stall — so "runs on the ANE" should be treated as unproven for this entire model class.

**LarsNet on real drums.** No published evaluation. Its numbers are nSDR on synthetic renders, and the one follow-up that engaged with it (Separate-and-Detect, arXiv:2608.01093) explicitly refuses to report SDR because it decodes through a neural vocoder.

**Moises/Music.AI's relationship.** The two taxonomies are structurally near-identical, strongly suggesting a shared engine, but no corporate statement was found.

**Several vendors do not publish their own stem lists.** Hit'n'Mix does not enumerate RipX's "6+" stems (the six names come from a Sound on Sound review). Apple does not publish Stem Splitter's preset names. VirtualDJ's manual refers to "the main 5 stems" without listing five. Algoriddim's documentation contradicts itself on whether Neural Mix is 3 or 4 stems. Image-Line does not state whether FL Studio's separation runs cloud-side.

---

## Citations

**Papers**

- W.-T. Lu, J.-C. Wang, Q. Kong, Y.-N. Hung, "Music Source Separation with Band-Split RoPE Transformer," ICASSP 2024 — https://arxiv.org/abs/2309.02612 (Tables 1–2, §4.4 configuration and training cost, §4.6 RoPE ablation)
- J.-C. Wang, W.-T. Lu, M. Won, "Mel-Band RoFormer for Music Source Separation," ISMIR 2023 LBD — https://arxiv.org/abs/2310.01809 (Table 1; the bass-training failure)
- J.-C. Wang, W.-T. Lu, J. Chen, "Mel-RoFormer for Vocal Separation and Vocal Melody Transcription," ISMIR 2024 — https://arxiv.org/abs/2409.04702 (Table 2, including the 24 kHz mono rows)
- W. Tong et al., "SCNet: Sparse Compression Network for Music Source Separation," ICASSP 2024 — https://arxiv.org/abs/2401.13276 (Tables 1–4; CPU RTF environment; MoisesDB generalisation)
- S. Rouard, F. Massa, A. Défossez, "Hybrid Transformers for Music Source Separation," ICASSP 2023 — https://arxiv.org/abs/2211.08553
- I. Pereira, F. Araújo, F. Korzeniowski, R. Vogl, "MoisesDB: A Dataset for Source Separation beyond 4-Stems," ISMIR 2023 — https://archives.ismir.net/ismir2023/paper/000073.pdf (Table 2 taxonomy; Table 3 four/five/six-stem baselines and oracle ceilings)
- K. N. Watcharasupat, A. Lerch, "A Stem-Agnostic Single-Decoder System for Music Source Separation Beyond Four Stems" (Banquet), ISMIR 2024 — https://arxiv.org/abs/2406.18747v2 · https://github.com/kwatcharasupat/query-bandit
- G. Fabbro et al., "The Sound Demixing Challenge 2023 – Music Demixing Track," TISMIR 2024 — https://arxiv.org/abs/2308.06979 (§2.3 global SDR; §6 listening test; Table 13 TrueSkill)
- R. Solovyev, A. Stempkovskiy, T. Habruseva, "Benchmarks and leaderboards for sound demixing tasks" — https://arxiv.org/abs/2305.07489 (Multisong protocol; leakage caveat)
- C. Ding, "Beyond SDR: How Music Source Separation Reshapes Rhythm-Relevant Signal Properties," 2026 — https://arxiv.org/html/2609.04224
- N. Jaffe, J. A. Burgoyne, "Musical Source Separation Bake-Off," 2025 — https://arxiv.org/html/2507.06917v3
- E. Mezza et al., "Toward deep drum source separation" (LarsNet), *Pattern Recognition Letters* 183 (2024) — https://arxiv.org/abs/2312.09663 · https://github.com/polimi-ispl/larsnet
- C. Riley, S. Dixon, "Enhanced Automatic Drum Transcription via Drum Stem Source Separation," 2025 — https://arxiv.org/abs/2509.24853
- C.-B. Jeon et al., "MedleyVox," ICASSP 2023 — https://arxiv.org/abs/2211.07302 · https://github.com/jeonchangbin49/MedleyVox
- T. Narahata et al., "Lead Vocal Separation from Vocal Ensemble Mixtures Using Phoneme Alignment," 2026 — https://arxiv.org/abs/2609.06488
- S. Vardhan et al., "An Ensemble Approach to Music Source Separation," 2024 — https://arxiv.org/html/2410.20773v1 (not peer-reviewed as far as could be verified)
- S. H. Bryngelson, "Apple Neural Engine: Architecture, Programming, and Performance," 2026 — https://arxiv.org/abs/2606.22283 (reverse-engineered, not Apple)

**Repositories, model cards and leaderboards**

- Demucs — https://github.com/facebookresearch/demucs · iOS viability thread https://github.com/facebookresearch/demucs/issues/396
- ZFTurbo MSST — https://github.com/ZFTurbo/Music-Source-Separation-Training · model table `docs/pretrained_models.md` · Mel-RoFormer sweep `docs/mel_roformer_experiments.md` · Mega 53-stem release `releases/tag/v1.0.21` · ONNX/TensorRT fork https://github.com/ZFTurbo/MSS_ONNX_TensorRT
- lucidrains BS-RoFormer — https://github.com/lucidrains/BS-RoFormer (MIT)
- starrytong SCNet — https://github.com/starrytong/SCNet (MIT; weights licence unstated)
- KimberleyJensen Mel-Band-Roformer-Vocal-Model — https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model (**no licence**)
- bgkb BS PolarFormer ONNX — https://huggingface.co/bgkb/bs_polarformer
- elicwhite scnet-web-wasm — https://github.com/elicwhite/scnet-web-wasm (MIT)
- silverdaw mel-band-roformer-vocals-onnx — https://huggingface.co/silverdaw/mel-band-roformer-vocals-onnx
- benkaron BSRoformer-Wind-CoreML — https://huggingface.co/benkaron/BSRoformer-Wind-CoreML
- trevorjs melbandroformer-vocal-coreml — https://huggingface.co/trevorjs/melbandroformer-vocal-coreml
- jonkubis BS-ROFO-SW-Fixed-CoreML — https://github.com/jonkubis/BS-ROFO-SW-Fixed-CoreML
- kylehowells demucs-mlx-swift — https://github.com/kylehowells/demucs-mlx-swift
- john-rocky CoreML-Models — https://github.com/john-rocky/CoreML-Models
- adobe-research convmelspec — https://github.com/adobe-research/convmelspec · DakeQQ STFT-ISTFT-ONNX — https://github.com/DakeQQ/STFT-ISTFT-ONNX
- coremltools — https://github.com/apple/coremltools · istft requests #2016, #2330, PR #2029 · complex-mul #2212, #2112 · DFT accuracy PR #2746 · einsum ellipsis #2644 / PR #2706 · `view_as_complex` #2003 · ANE fp16 softmax #2728, #2690, #2687 · ANE conv_transpose #2450
- Apple, Deploying Transformers on the Apple Neural Engine — https://machinelearning.apple.com/research/neural-engine-transformers · https://github.com/apple/ml-ane-transformers · Typed Execution https://apple.github.io/coremltools/docs-guides/source/typed-execution.html
- MVSep leaderboards — Multisong https://mvsep.com/quality_checker/multisong_leaderboard · drums https://mvsep.com/quality_checker/leaderboard/drumsep5 · lead/back https://mvsep.com/quality_checker/leaderboard/lead_back_vocals · protocols https://mvsep.com/quality_checker/custom_leaderboards · algorithms https://mvsep.com/en/algorithms
- UVR manifest — https://raw.githubusercontent.com/TRvlvr/application_data/main/filelists/download_checks.json · licensing issue #2295 https://github.com/Anjok07/ultimatevocalremovergui/issues/2295
- MansfieldPlumbing Demucs_v4_TRT — https://huggingface.co/MansfieldPlumbing/Demucs_v4_TRT
- Open-Unmix — https://github.com/sigsep/open-unmix-pytorch (code MIT; `umxl` weights CC BY-NC-SA 4.0)
- inagoy drumsep — https://github.com/inagoy/drumsep · jarredou models — https://github.com/jarredou/models/releases

**Vendor documentation**

- Moises — Free https://help.moises.ai/hc/en-us/articles/29530482524316 · Premium https://help.moises.ai/hc/en-us/articles/29530520103324 · Pro https://help.moises.ai/hc/en-us/articles/360010972019 · VST https://moises.ai/features/stems-vst-plugin/
- Music.AI — Musical Stems Advanced https://music.ai/modules/stem-separation/musical-stems-advanced/ · Drum Stems https://music.ai/modules/stem-separation/drum-stems/
- AudioShake model catalogue — https://developer.audioshake.ai/models
- LALAL.AI — https://www.lalal.ai/stem-splitter/ · https://www.lalal.ai/desktop-app/ · "8th stem" post https://www.lalal.ai/blog/lalal-ai-adds-the-8th-stem-for-separation-synthesizer/ · Lead/Back https://www.lalal.ai/lead-back-vocals-remover/
- Apple Logic Pro Stem Splitter — https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac
- Steinberg SpectraLayers 12 Unmix Song — https://download.steinberg.net/downloads_software/SpectraLayers_12/help/Pro/_unmix_song.html
- Stemulator — https://www.stemulator.app/ · Serato Stems — https://support.serato.com/hc/en-us/articles/5700968326927-Stems-Overview

**In-repo**

- `Benchmarks/STEM_SEPARATION.md` — the 2026-06-20 record (4-stem Core ML FP16; Python Demucs 18.38 s / 60 s)
- `tasks/stem-algorithm-selection-findings.md` — engine map, memory ceilings, chord-accuracy A/B proposal
- `tools/demucs_export/README.md` + `realstft.py` — the real-DFT replacement for Demucs's complex STFT/iSTFT, validated at 79 dB SDR
- `.scratch/forced-alignment-spike/FINDINGS-forced-alignment.md` — the alignment baseline these changes would be measured against
