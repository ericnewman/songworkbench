# ASR and lyric models for sung vocals on Apple Silicon (survey, 2026-09-30)

Question: have any new or improved speech-recognition, lyric-transcription, or lyric-alignment
models been released (focus 2026-01 to 2026-09, plus notable 2025 releases) that could improve
lyric transcription of an isolated vocal stem in SongWorkbench, on-device on Apple Silicon, with
a license that allows commercial use?

Sources are primary: model cards, official GitHub release notes and PRs, arXiv papers, and the
Open ASR Leaderboard results CSVs. Every claim links to its source. Items marked **unverified**
could not be confirmed from a primary source.

## Current baseline in this repo

Checked in the source tree on 2026-09-30:

| Component | What the repo uses | Where |
|---|---|---|
| Whisper model | `ggml-large-v3-turbo-q5_0.bin` plus `ggml-large-v3-turbo-encoder.mlmodelc` (Core ML encoder) | `Sources/SongWorkbench/ModelCatalog.swift`, `WhisperCPPTranscriptionEngine.swift` (`modelVersion: "large-v3-turbo-q5_0"`) |
| whisper.cpp decode settings | Beam search, `beam_size = 5`, `best_of = 5`, `suppress_blank`, `suppress_nst`, `token_timestamps = true`, default entropy/logprob/no-speech thresholds with temperature fallback, context reused across calls | `WhisperCPPTranscriptionEngine.swift` lines 262-300 |
| FluidAudio | `0.15.4` (released 2026-06-16) | `Package.resolved` |
| Parakeet | `FluidInference/parakeet-tdt-0.6b-v3-coreml` (Parakeet TDT 0.6B v3) | `ModelCatalog.swift`, `FluidAudioTranscriptionEngine.swift` |

## Ranked shortlist

### 1. Qwen3-ASR (1.7B, 0.6B) plus Qwen3-ForcedAligner-0.6B

- **Why:** This is the only open model with a commercial license that publishes WER on singing and whole songs.
  On `EntireSongs-en` (songs with accompaniment), Qwen3-ASR-1.7B scores 14.60 % WER, against
  30.71 % for GPT-4o-Transcribe, 33.51 % for Doubao-ASR, and 12.18 % for Gemini-2.5-Pro. On four
  Chinese singing sets it beats Whisper-large-v3 by about 2x (for example M4Singer 5.98 vs 13.58).
  ([model card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B),
  [technical report arXiv:2601.21337, Table 7](https://arxiv.org/abs/2601.21337)). The report
  says the models handle "singing voice, speech, and songs with background music" up to 1200 s.
  It is also the best open-weight entry on the current Open ASR Leaderboard English short-form
  average: 4.31 % for 1.7B and 5.04 % for 0.6B, against 6.36 % for `whisper-large-v3-turbo`
  ([results CSV](https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results)).
- **Repetition evidence:** An independent study (Ohio State / AFRL, April 2026) applied 30 % chunk
  masking. Qwen3-ASR-1.7B produced 0.68 % insertions with under 4 % repetition. Whisper-large-v3
  produced 35 % repetition across 10,365 insertions. The authors conclude that "repetition loops are a
  decoder-driven phenomenon" ([arXiv:2604.21276](https://arxiv.org/abs/2604.21276)). The test used
  speech, not singing.
- **Aligner:** Qwen3-ForcedAligner-0.6B is an LLM-based non-autoregressive aligner for 11 languages,
  including English, on audio up to 300 s. Its accumulated average shift is 32.4 ms on human-labeled
  sets, against 101.2 ms for NeMo Forced Aligner (report Table 9). It was **not evaluated on singing**. Treat it as a
  candidate to compare against LyricsAlignmentMTL, not a replacement.
- **Runtime on Apple Silicon:**
  - [`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift) (MIT, Swift Package, macOS 14+,
    last release v0.1.3 on 2026-07-09) ships `Qwen3ASRModel` and `Qwen3ForcedAlignerModel`. It
    loads MLX weights from `mlx-community/Qwen3-ASR-{0.6B,1.7B}-{4,6,8bit,bf16}` and
    `mlx-community/Qwen3-ForcedAligner-0.6B-*`
    ([README](https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioSTT/Models/Qwen3ASR/README.md)).
  - llama.cpp `mtmd` supports `ggml-org/Qwen3-ASR-0.6B-GGUF` and `-1.7B-GGUF`
    ([docs/multimodal.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md)).
  - FluidAudio had an experimental Core ML Qwen3-ASR backend and **removed** it in
    [PR #676](https://github.com/FluidInference/FluidAudio/pull/676) (merged 2026-06-10); the PR
    states no reason. FluidAudio also converted Qwen3-ForcedAligner to Core ML but lists it as
    "not supported: large footprint" ([Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)).
- **License:** Apache-2.0 (all three checkpoints).
- **Integration effort:** medium. This adds an `mlx-swift` dependency and a third engine behind the existing
  transcription-engine seam. The weights are roughly 0.5-3.5 GB depending on size and quantization, and they run on the
  Metal GPU, so schedule them so they do not compete with Demucs.
- **Gaps:** No published singing WER for the 0.6B model. No independent English lyric benchmark
  (Jam-ALT, MUSDB-ALT) result was found for Qwen3-ASR (**unverified**).

### 2. Upgrade whisper.cpp from v1.9.1 to v1.9.4 (2026-09-11)

- **Why:** This is a small-effort correctness fix that applies directly to the app's decode path. v1.9.4 includes
  [PR #4025 "whisper : re-seed decoder 0 between calls"](https://github.com/ggml-org/whisper.cpp/pull/4025).
  Decoder 0's RNG was seeded once per state and never re-seeded. It is read only on the
  temperature-fallback path, which sung vocals trigger. The PR shows that the same audio decoded
  twice in one process can produce different text (repro used `large-v3-turbo-q5_0`). SongWorkbench
  reuses a context and keeps temperature fallback on, so this bug is in its path.
- Other changes after v1.9.1:
  - v1.9.2 (2026-08-04): token timestamps map back to original time when whisper.cpp VAD is on
    ([#3910](https://github.com/ggml-org/whisper.cpp/pull/3910)); VAD speech segments exposed
    ([#3916](https://github.com/ggml-org/whisper.cpp/pull/3916)); Parakeet included in
    `build-xcframework.sh` ([#3899](https://github.com/ggml-org/whisper.cpp/pull/3899)).
  - v1.9.3 (2026-08-20): memory-safety fixes (log-mel out-of-bounds read on very short audio
    [#3956](https://github.com/ggml-org/whisper.cpp/pull/3956), malformed-tensor rejection #3957).
  - v1.9.4 also fixes Parakeet TDT decoding in whisper.cpp: 41 % of tokens were getting duration 0,
    and word-end error against NeMo fell from 89 ms to 2 ms
    ([#4017](https://github.com/ggml-org/whisper.cpp/pull/4017)). It also adds many Metal tunings.
  - No release adds a repetition-specific decoding guard. There are no whisper-relevant commits on
    master after v1.9.4 (checked 2026-09-30).
- ([release list](https://github.com/ggml-org/whisper.cpp/releases))
- **License:** MIT. **Effort:** small (rebuild the xcframework; the API is unchanged as far as the notes show).
- This does not fix loops by itself. See [Hallucination and loop evidence](#hallucination-and-loop-evidence)
  for the segmentation technique that does address them.

### 3. Parakeet Ultra (or Parakeet TDT v2) through a FluidAudio upgrade

- **Why:** Parakeet Ultra is moondream's post-training of `parakeet-tdt-0.6b-v3`, released 2026-09-22.
  It has the same architecture and API. Background noise (9 MUSAN conditions) improves from 6.72 to 5.82 % WER, and
  TED-LIUM long-form improves from 2.71 to 1.94 % ([model card](https://huggingface.co/moondream/parakeet-ultra)).
  The FluidAudio Core ML build measures LibriSpeech test-other at 4.12 → 3.81 % at the same ANE speed
  ([ParakeetUltra.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)).
  It uses a TDT transducer, which has no free-running autoregressive text decoder like Whisper's.
- It needs FluidAudio **v0.17.3 or later** (2026-09-24) and `AsrModelVersion.ultra`
  ([release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.3)). The latest
  release is v0.17.4 (2026-09-25).
- A zero-upgrade test is also possible: FluidAudio 0.15.4 already ships
  `parakeet-tdt-0.6b-v2-coreml`, which is English-only and which FluidAudio describes as "highest recall". v2
  averages 4.70 % on the Open ASR English board against 4.86 % for v3.
- Also between 0.15.4 and 0.17.4: v0.15.6 (2026-08-19) exposes token timings from the Parakeet
  Unified batch path and adds CTC custom-vocabulary evidence APIs. When reference lyrics exist,
  custom vocabulary could bias Parakeet toward lyric words (**untested for singing**).
- **License:** CC-BY-4.0 (Ultra, v2, v3). **Effort:** small for v2. Ultra is small to medium because of
  API changes across two minor FluidAudio versions.
- **Gap:** No singing or lyric benchmark exists for any Parakeet variant.

### 4. Cohere Transcribe 03-2026 through FluidAudio `CoherePipeline`

- **Why:** This 2B-parameter Conformer AED model was released 2026-03 under Apache-2.0. It has the best
  open-weight long-form English WER on the leaderboard (9.73 % average, against 11.01 % for
  `whisper-large-v3-turbo` and 10.72 % for Parakeet v3)
  ([longform CSV](https://huggingface.co/datasets/hf-audio/leaderboard_longform)).
  Its short-form average is 4.67 %.
- **Already in the pinned dependency:** FluidAudio 0.15.4 contains
  `Sources/FluidAudio/ASR/Cohere/CoherePipeline.swift` (beta; INT8 encoder 1.8 GB for iOS 18+/macOS 15+,
  FP16 3.6 GB otherwise). Added in [PR #487](https://github.com/FluidInference/FluidAudio/pull/487)
  and [#537](https://github.com/FluidInference/FluidAudio/pull/537), merged 2026-04-23
  ([Cohere.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Cohere.md)).
- **Caveats (from the [model card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)):**
  - No timestamps. That is acceptable here, because the app measures word times with its own aligner.
  - The language must be passed explicitly.
  - The model is "eager to transcribe, even non-speech sounds" and needs a VAD or noise gate in front of it.
    The app's vocal VAD fills that role.
  - There is a hard 35 s limit per call.
  - The Hugging Face repo is click-through gated.
- It is also available in `mlx-audio` and `mlx-audio-swift`.
- **License:** Apache-2.0. **Effort:** small to medium. **Gap:** No singing evidence.

### 5. Watch list: Fun-ASR-Nano-2512 and Granite Speech 5.0 TurboCTC

- **Fun-ASR-Nano-2512** (Alibaba Tongyi, 2025-12-15, about 0.8B, Apache-2.0) explicitly claims
  "Music Background Lyric Recognition." On its in-house `Lyrics` set it scores 30.85 % against 54.82 % for
  Whisper-large-v3, and on `Hiphop` 30.87 % against 46.56 %
  ([model card](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512)). It supports zh/en/ja. The language
  mix of the lyric set is not stated (**unverified**; it is likely mostly Chinese). No maintained
  Apple runtime was found: a llama.cpp PR
  ([#27607](https://github.com/ggml-org/llama.cpp/pull/27607)) is still open. **Effort:** large today.
- **Granite Speech 5.0 470M TurboCTC** (IBM, 2026-08-25, Apache-2.0, English) is an encoder-only CTC
  model that decodes non-autoregressively, so it cannot loop. Its leaderboard average is 5.04 %
  ([model card](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc)). It could
  cross-check stretches where Whisper loops. The Apple runtime is `mlx-audio` in Python only
  ([README](https://github.com/Blaizzy/mlx-audio)), so it would need a Core ML conversion. **Effort:** medium to
  large. **Gap:** No singing evidence.

## Hallucination and loop evidence

- **OpenAI's own card** says Whisper's seq2seq architecture "makes it prone to generating repetitive
  texts, which can be mitigated to some degree by beam search and temperature scheduling but not
  perfectly" ([whisper-large-v3-turbo card](https://huggingface.co/openai/whisper-large-v3-turbo)).
- **Autoregressive decoders cause loops:** see arXiv:2604.21276 above. Wav2Vec2 (CTC, no LM) showed under 2 %
  repetition, Whisper-small 86 %, Whisper-large-v3 35 %, Granite-Speech-8B 49-57 %, and Qwen3-ASR-1.7B under 4 %.
- **Source separation and segmentation for lyrics** (QMUL + AudioShake, June 2025,
  [arXiv:2506.15514](https://arxiv.org/abs/2506.15514), [code](https://github.com/jaza-syed/mss-alt)):
  - Whisper large-v2 with beam 5 and no fine-tuning scored 23.02 % WER on Jam-ALT long-form with native segmentation.
    Segmenting on RMS energy of separated vocals ("RMS-VAD") and decoding each segment reduced that to 20.35 %, the
    stated open-source state of the art.
  - Hallucination, measured as runs of 10 or more consecutive insertions, was low on mixes and true stems but
    "higher for some cases with MSS". Separation artifacts can therefore trigger Whisper hallucination.
  - Whisper "systematically deletes non-lexical vocables and backing vocals".
  - For this app, decoding Whisper per vocal-activity segment rather than through native
    30 s sequential windows with carried context is the published mitigation closest to the hook-loop
    failure.
- **Calm-Whisper** (Interspeech 2025, [arXiv:2505.12969](https://arxiv.org/abs/2505.12969)) fine-tunes 3 of the 20
  decoder heads of large-v3 and reports over 80 % less hallucination on non-speech audio. That targets
  non-speech, not repetition on sung words. Public weights are **unverified**.
- **Model-card statements:**
  - Cohere Transcribe: "eager to transcribe, even non-speech sounds".
  - Granite-Speech-4.1-2B-NAR: NAR editing "prefers deletions over insertions, which reduces
    hallucination risk".
  - Canary-Qwen-2.5B and Canary-1B-v2 report 138.1 and 134.7 hallucinated characters per minute on MUSAN noise
    and music.
  - Boson AI's `higgs-audio-v3-stt` ships a "phrase-level repetition-loop collapse" post-processor, which
    acknowledges loops in LLM-decoder ASR.

## Excluded and why

| Item | Reason |
|---|---|
| [SongPrep-7B](https://huggingface.co/tencent/SongPrep-7B) (Tencent, 2025-09) full-song structure and lyrics | License allows "academic purposes" only and forbids commercial or production use |
| [Music Flamingo](https://huggingface.co/nvidia/music-flamingo-hf) (NVIDIA, 2025-11) and Audio Flamingo 3 | NVIDIA OneWay Noncommercial License |
| AudioShake and Music.AI lyric transcription or alignment | Cloud APIs, not on-device |
| OpenAI GPT-4o-transcribe and realtime transcription models | API only; OpenAI has published no new open Whisper checkpoint since large-v3-turbo (the last `openai/whisper` release is v20250625; 2026 commits are maintenance). Claims of 2026 API models ("GPT-Realtime-Whisper", "gpt-live-transcribe") came from secondary sites and are **unverified** |
| [VocalParse](https://github.com/pymaster17/VocalParse) (2026-05, Apache-2.0) | A Qwen3-ASR-1.7B fine-tune that outputs lyrics plus notes (singing voice transcription). Its training sets and English lyric WER are **unverified**. It might load through the Qwen3-ASR runtime with an extended vocabulary (**untested**). Worth a look only after item 1 |
| [MUSDB-ALT](https://huggingface.co/datasets/jazasyed/musdb-alt) dataset | CC-BY-NC-SA-4.0. It is usable for local evaluation only, and it is the one long-form lyric set with true vocal stems, which suits this app's stem input |

## Everything checked

"Open ASR avg" is the English short-form average WER from `english_short_latest.csv`, fetched
2026-09-30 (lower is better). Dates are Hugging Face repository creation dates unless noted.

| Name | Released | Source | License | Apple Silicon runtime | Relevance |
|---|---|---|---|---|---|
| Qwen3-ASR-1.7B | 2026-01-28 | [card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), [report](https://arxiv.org/abs/2601.21337) | Apache-2.0 | mlx-audio-swift (Swift/MLX), llama.cpp GGUF | **High**: published singing and song WER; avg 4.31 |
| Qwen3-ASR-0.6B | 2026-01-28 | [card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) | Apache-2.0 | same | High; avg 5.04; no singing numbers published |
| Qwen3-ForcedAligner-0.6B | 2026-01-28 | [card](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B) | Apache-2.0 | mlx-audio-swift; FluidAudio Core ML port unsupported | Medium: 300 s cap, not evaluated on singing |
| whisper.cpp v1.9.2 / v1.9.3 / v1.9.4 | 2026-08-04 / 08-20 / 09-11 | [releases](https://github.com/ggml-org/whisper.cpp/releases) | MIT | xcframework (Metal, Core ML encoder) | **High**: decoder re-seed fix |
| OpenAI Whisper (new checkpoints) | none since large-v3-turbo (2024-10) | [openai/whisper](https://github.com/openai/whisper) | MIT code; large-v3 card Apache-2.0 | n/a | None |
| Parakeet Ultra (moondream) | 2026-09-22 | [card](https://huggingface.co/moondream/parakeet-ultra), [FluidAudio v0.17.3](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.3) | CC-BY-4.0 | FluidAudio Core ML (ANE) ≥ 0.17.3 | **High**: drop-in v3 upgrade |
| Parakeet Redux (moondream) | 2026-09 | [FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetRedux.md) | CC-BY-4.0 (upstream card not fetched; **unverified**) | FluidAudio, macOS 15+ | Low: smaller, worse on English |
| Parakeet TDT 0.6B v3 (current) | 2025-08-04 | [card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | CC-BY-4.0 | FluidAudio (in use) | Baseline; avg 4.86 |
| Parakeet TDT 0.6B v2 (English) | 2025-04-15 | [card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) | CC-BY-4.0 | FluidAudio 0.15.4 already | Medium: free A/B; avg 4.70 |
| Parakeet Unified EN 0.6B | 2026-04-07 | [card](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) | NVIDIA Open Model License | FluidAudio `UnifiedAsrManager` | Low-medium: English batch with punctuation and token timings |
| Nemotron Speech Streaming 0.6B | 2025-12-17 | [card](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) | NVIDIA Open Model License | FluidAudio | Low: streaming-oriented; avg 5.25 |
| Canary-Qwen-2.5B | 2025-06-26 | [card](https://huggingface.co/nvidia/canary-qwen-2.5b) | CC-BY-4.0 | None maintained found | Low: avg 4.43, English only, no Apple runtime |
| Canary-1B-v2 | 2025-08-04 | [card](https://huggingface.co/nvidia/canary-1b-v2) | CC-BY-4.0 | mlx-audio, mlx-audio-swift | Low; avg 5.71 |
| Cohere Transcribe 03-2026 | 2026-03-24 | [card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) | Apache-2.0 (gated click-through) | FluidAudio `CoherePipeline` (in 0.15.4), mlx-audio-swift | **Medium-high**: best open long-form WER |
| IBM Granite Speech 4.1 2B | 2026-04 | [card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b) | Apache-2.0 | mlx-audio / mlx-audio-swift "Granite Speech" (exact variant **unverified**) | Medium; avg 4.62 |
| IBM Granite Speech 4.1 2B NAR | 2026-04 | [card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b-nar) | Apache-2.0 | None confirmed | Medium: NAR, fewer insertions by design; avg 4.67 |
| IBM Granite Speech 4.1 2B Plus | 2026-04-16 | [card](https://huggingface.co/ibm-granite/granite-speech-4.1-2b-plus) | Apache-2.0 | None confirmed | Low-medium: adds word timings and speakers |
| IBM Granite Speech 5.0 470M TurboCTC | 2026-08-25 | [card](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc) | Apache-2.0 | mlx-audio (Python) | Medium: loop-free CTC cross-check; avg 5.04 |
| Fun-ASR-Nano-2512 | 2025-12-15 | [card](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512) | Apache-2.0 | None merged (llama.cpp PR open) | Medium: claims lyric recognition; avg 5.74 |
| SenseVoiceSmall | 2024-07 | [card](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | FunASR model license ("other") | FluidAudio, mlx-audio-swift | Low |
| FireRedASR2 (AED, LLM) | 2026-02-12 / 02-25 | [card](https://huggingface.co/FireRedTeam/FireRedASR2-AED), [arXiv:2603.10420](https://arxiv.org/abs/2603.10420) | Apache-2.0 | mlx-audio-swift (converted checkpoints) | Low-medium: claims singing transcription for Mandarin and English; results are Mandarin-focused |
| FireRedVAD | 2026-02-12 | same | Apache-2.0 | None confirmed | Low: speech, singing, and music VAD labels |
| Mistral Voxtral Mini 3B / Small 24B (2507) | 2025-07 | [card](https://huggingface.co/mistralai/Voxtral-Mini-3B-2507) | Apache-2.0 | mlx-audio, llama.cpp GGUF | Low; avg 5.54 / 4.99 |
| Mistral Voxtral Mini 4B Realtime 2602 | 2026-01-21 | [card](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) | Apache-2.0 | mlx-audio, mlx-audio-swift | Low: streaming; avg 6.46 |
| Microsoft Phi-4-multimodal-instruct | 2025-02 | [card](https://huggingface.co/microsoft/Phi-4-multimodal-instruct) | MIT | mlx-vlm (**unverified**) | Low: 6B general model; avg 5.02 |
| Microsoft VibeVoice-ASR | 2026-01-21 | [card](https://huggingface.co/microsoft/VibeVoice-ASR) | MIT | None confirmed | Low: 60 min single pass with speakers; about 8B; avg 5.58 |
| Kyutai STT 2.6B EN / 1B EN-FR | 2025-06 | [card](https://huggingface.co/kyutai/stt-2.6b-en), [repo](https://github.com/kyutai-labs/delayed-streams-modeling) | CC-BY-4.0 weights, Apache-2.0 code | MLX (official) | Low: streaming; avg 5.57 |
| Moonshine Streaming | 2026-01-06 | [card](https://huggingface.co/UsefulSensors/moonshine-streaming-medium) | MIT | mlx-audio | Low: small edge models |
| GLM-ASR-Nano-2512 | 2025-12-09 | [card](https://huggingface.co/zai-org/GLM-ASR-Nano-2512) | MIT | mlx-audio-swift | Low: lyric score 46.56 on Fun-ASR's table |
| distil-large-v3.5 | 2024-12 | [card](https://huggingface.co/distil-whisper/distil-large-v3.5) | MIT | whisper.cpp, MLX | Low: Whisper family |
| TheStageAI thewhisper-large-v3-turbo | 2025-10-27 | [card](https://huggingface.co/TheStageAI/thewhisper-large-v3-turbo) | CC-BY-4.0 | Not checked | Low: Whisper-turbo derivative; avg 4.54 |
| HojoAI Hojo-ASR-V1 | 2026-05-24 | [card](https://huggingface.co/HojoAI/Hojo-ASR-V1) | Apache-2.0 | None found | Low: 5.2B; avg 4.33 |
| Boson AI higgs-audio-v3-stt | 2026-03-25 | [card](https://huggingface.co/bosonai/higgs-audio-v3-stt) | Apache-2.0 | None found | Low: avg 4.39; ships a loop-collapse post-processor |
| AutoArk ARK-ASR 0.6B / 3B | 2026-05 / 06 | [card](https://huggingface.co/AutoArk-AI/ARK-ASR-0.6B) | Apache-2.0 | None found | Low; avg 4.56 / 4.47 |
| OpenMOSS MOSS-Transcribe-Diarize | 2026-05-19 | [card](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) | Apache-2.0 | mlx-audio-swift | Low; avg 4.64 |
| VocalParse-1.7B | 2026-05 | [paper](https://arxiv.org/abs/2605.04613), [repo](https://github.com/pymaster17/VocalParse) | Apache-2.0 | Possibly the Qwen3-ASR runtime (**untested**) | Medium-low: singing lyrics and notes |
| SongPrep-7B | 2025-09-19 | [card](https://huggingface.co/tencent/SongPrep-7B) | Academic-only | n/a | Excluded |
| Music Flamingo / Audio Flamingo 3 | 2025-11 / 2025-10 | [card](https://huggingface.co/nvidia/music-flamingo-hf) | NVIDIA noncommercial | n/a | Excluded |
| Calm-Whisper | 2025-05 | [arXiv:2505.12969](https://arxiv.org/abs/2505.12969) | Weights **unverified** | n/a | Low: non-speech hallucination only |
| MSS + RMS-VAD for ALT (technique) | 2025-06 | [arXiv:2506.15514](https://arxiv.org/abs/2506.15514) | Code on GitHub; license not checked | Technique only | **High**: segmentation cut Jam-ALT WER from 23.02 to 20.35 % |

## Suggested evaluation before adopting anything

No source benchmarks these candidates on English sung vocal stems. Measure them on the app's own
songs and, for a public reference, on MUSDB-ALT vocal stems and Jam-ALT
([alt-eval](https://github.com/audioshake/alt-eval)). Score WER, the IR10 hallucination count from
arXiv:2506.15514, and the existing per-stretch acoustic alignment score. Include the known hook-loop
song as a fixed regression case.
