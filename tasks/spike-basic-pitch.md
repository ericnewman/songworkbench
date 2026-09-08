# Spike — Basic Pitch on the guitar stem (2026-09-08)

Question: can Spotify's Basic Pitch (Apache-2.0, ~228 KB CNN, per-frame note/onset/contour
posteriors) transcribe our `guitar` stem well enough to (1) find lead passages ON the guitar
stem — where the chroma-sparsity classifier finds nothing (tasks/spec-solo-tab.md) — and
(2) yield note events usable for tab? Evidence only; nothing is wired into the app.

## Verdict: GO-with-caveats
- (1) **Yes.** Basic Pitch's polyphony (simultaneous note events sampled at 50 ms) separates
  "single line" from "strummed" bars on the guitar stem itself. On Eight Miles High every
  instrumental section (checked against the vocal stem's silence) is found and the sung verses
  produce zero passages; on Back To You the 1:04–1:16 vocal gap is found as a 5-bar passage
  (the chroma classifier found nothing on either).
- (2) **Partly.** Note events are on-grid and in the right register, but a lead over a
  rhythm part on the same stem comes out as lead notes + chord fragments + low-string drone,
  4–5 onsets per beat. Tab needs a voice-selection step (skyline / register split) first; a
  12-string additionally produces octave pairs (F#3+F#4 at the same 16th).
- Swift: **no blockers.** The shipped `nmp.onnx` loads and runs under the app's onnxruntime
  1.24.2 (opset 15, plain Conv/Pad/Slice/Reshape ops) — 15 ms per 2-second window on this Mac.
- Leakage is NOT solved by the model: the a cappella control yields 603 "guitar" notes (the
  voices), and Basic Pitch's amplitude is a posterior, not a level, so the existing
  vocal-prominence RMS gate stays.

## Install / inference path
    cd tools/basic_pitch_probe
    uv venv --python 3.12 .probevenv            # basic-pitch 0.3.0 has no 3.14 wheels
    uv pip install --python .probevenv/bin/python "basic-pitch[onnx]" "basic-pitch[coreml]" \
        soundfile "setuptools<81" "scipy<1.13"  # resampy needs pkg_resources; note_creation
                                                # uses scipy.signal.gaussian (removed in 1.13)
    .probevenv/bin/python probe_basic_pitch.py "Eight Miles High" "Back To You" "It Is Well"
    .probevenv/bin/python probe_basic_pitch.py --stems guitar,other "Eight Miles High"
`basic-pitch[onnx]` still drags in TensorFlow 2.16 (the extras are additive); the probe forces
the ONNX path (`Model.model_type == ONNX`) because that is the artifact a Swift port loads.
Default thresholds (onset 0.5, frame 0.3, min note 127.7 ms, melodia trick on). Note events
land in `/tmp/bp_<song>_<stem>.json` as {onset, offset, midi, amplitude, bends}.

The wheel ships all three non-TF artifacts under `basic_pitch/saved_models/icassp_2022/`:
`nmp.onnx` (228 KB), `nmp.mlpackage` (272 KB), `nmp.tflite` (200 KB) plus the TF SavedModel.

## Model contract (nmp.onnx, tf2onnx 1.15.1, IR 8, opset 15 + ai.onnx.ml 2; 248 nodes:
Reshape 67, Unsqueeze 37, Conv 32, Pad 24, Transpose 21, Concat 20, Slice 11, Neg 9, …)
- Audio: 22 050 Hz mono float32, scaled to [-1, 1]. Input `serving_default_input_2:0`
  shape `[N, 43844, 1]` — one window is `AUDIO_SAMPLE_RATE * 2 s - FFT_HOP(256)` samples.
- Windowing (inference.py): pad 30·256/2 = 3840 zeros in front, hop 43844 − 7680 = 36164
  samples, batch all windows, drop 15 frames from each end of every window's output, concat,
  trim to `floor(len · 86/22050)` frames. Frame rate 86 fps (hop 256 → 11.6 ms).
- Outputs (all `[N, 172, bins]` float32 posteriors 0…1):
  `StatefulPartitionedCall:1` = note (88 bins, MIDI 21…108),
  `StatefulPartitionedCall:2` = onset (88 bins),
  `StatefulPartitionedCall:0` = contour (264 bins, 3 per semitone from MIDI 21).
- Core ML variant: input `input_2`, outputs `Identity_1` (note), `Identity_2` (onset),
  `Identity` (contour) — same shapes. Not exercised in Swift; the ONNX path needs nothing new.
- Note events = `basic_pitch.note_creation.output_to_notes_polyphonic`: onset peaks above
  the onset threshold, extended forward while the note posterior stays ≥ frame threshold,
  min length 11 frames, then "melodia trick" mops up frame-only notes; pitch bends read
  from the contour bins around each note. ~150 lines of numpy, straightforward to port; the
  frame posteriors alone already suffice for the lead/chordal classification below.

## Timings (Apple silicon, CPU EP, onnxruntime 1.29 in Python)
| stem | length | inference incl. load+resample+note extraction |
|---|---|---|
| Eight Miles High guitar | 3:35 | 1.7–2.0 s (105–127× realtime) |
| Eight Miles High other | 3:35 | 1.3–1.7 s |
| Back To You guitar | 4:34 | 2.8–3.1 s (88–98×) |
| It Is Well guitar | 3:39 | 1.3 s (164×) |
Swift (ORT 1.24.2, 2 intra-op threads, one 2 s window): 15 ms → ≈1.6 s per 3.5-minute stem.
Compare ≈5 s per stem for the current chroma + pitch-tracker pass.

## Per-song results (probe_basic_pitch.py, guitar stem unless noted)
Beat classes: polyphony sampled at 50 ms across the beat; chordal = ≥ 50 % of samples with
≥ 3 simultaneous notes; lead = ≥ 50 % with 1–2 notes and ≥ 1 onset; bar = lead when ≥ half its
beats are lead and lead > chordal; passage = ≥ 2 lead bars, 1-bar gaps tolerated.

| song / stem | notes | /min | beats L / C / silent | passages found | ground truth (vocal-stem silence) |
|---|---|---|---|---|---|
| Eight Miles High guitar | 2241 | 624 | 171 / 221 / 3 | 0:01–0:12, **0:16–0:31**, 1:35–1:44, 1:50–1:56, 2:03–2:24, 2:52–2:58, **3:13–3:22** | instrumentals 0:00–0:28, 1:36–2:16, 2:52–3:35; sung 0:28–1:36, 2:16–2:52 |
| Eight Miles High other | 485 | 135 | 133 / 12 / 126 | 11 passages incl. 0:18–0:22 and 3:11–3:20, but also 0:52–1:16 and 2:39–2:52 inside verses | leaked lead + leaked everything else; stem is −35…−76 dB |
| Back To You guitar | 3068 | 672 | 56 / 351 / 13 | **1:06–1:19** (5 bars, 108 onsets) | vocal gaps 0:00–0:20 (intro), 1:04–1:16, 2:08–2:28 |
| It Is Well guitar (control) | 603 | 165 | 245 / 20 / 56 | 7 passages, 45 bars of "lead" | a cappella — every note is leakage |

Eight Miles High: the passages cover the intro solo (0:16–0:31 ⊇ the 0:17–0:23 the chroma
classifier only found on `other`), the whole middle break (1:35–2:24, three passages with
1-bar gaps) and two stretches of the outro (2:52–2:58, 3:13–3:22 — the 3:25–3:29 bars read
"CLLC CCCC LLCC", i.e. lead beats but not a bar majority). No passage inside a sung verse;
2:03–2:24 overruns verse 3's start (2:16) by 2 bars. The verses are 0–26 % mono/duo frames;
the solos 45–91 %. With the old beat-level rule (max polyphony ≤ 2 anywhere in the beat) the
guitar stem reads chordal even in the solos — the 12-string's octave pairs plus the low E
drone push instantaneous polyphony to 3 — so the classification hinges on the fraction, not
the max.

Back To You: the first vocal gap is found; the second (2:08–2:28) stays chordal (polyphony
2–5, "CCCL CCLL" bars) — either the break there is not on the guitar stem or it is a
double-stop/chordal solo. Which of the two gaps is "the guitar break" is unverified (no
listening from this session). Verse bars sit at polyphony 4–7 throughout.

It Is Well: 603 notes on a stem that should be empty; median amplitude 0.49 vs 0.45–0.47 on
the real guitars, so the posterior cannot gate leakage. The current `minimumProminence` RMS
gate against the vocal stems is still required in front of any Basic Pitch pass.

## Tab-ability observations (first two bars of each passage, 16th grid)
- Eight Miles High 0:16 passage: `1:A3 3:E2 4:D4 5:D3 6:E4×4 8:A2 8:E2 11:B1 11:B2 11:E2 …
  16:F#3 16:F#4×2 17:A3 18:A4 20:F#4 21:F#3×4 22:A2 22:F#4 … 30:C#3 31:C#4`. The solo
  line (E4 D4 F#4 A4 C#4 …) is there and lands on 16ths, but interleaved with an E2/A2/B1
  drone every 16th (bass leakage + low strings — 63 of 102 notes in 0:15–0:25 are below
  E3) and with octave twins (F#3/F#4, C#3/C#4, D3/D4 at the same onset) from the 12-string.
  Density 5.2 onsets/beat. Against the full mix Basic Pitch found only ~10 notes ≥ E4 per
  8 s in the intro solo, so the model under-reports fast 12-string runs regardless of
  separation; lowering thresholds (onset 0.3 / frame 0.15) quadruples the count but the
  extra notes are E7/F#7 harmonics everywhere including verses — noise, not recall.
- Back To You 1:06 passage: `0:A3 1:G2 1:G3 2:A2 3:D4 3:G3 3:G4 3:D5 3:D3 6:D3 6:A3 8:A#3
  9:B3 10:A3 11:G3 …` — a G-major line in the 3rd/4th octave with chord tones stacked under
  the melody notes (three to five notes at one 16th). 5.4 onsets/beat. Usable for tab only
  after picking a voice; the top note per 16th is a plausible first cut.
- Durations: median 0.22–0.24 s, p90 0.49 s, on all real stems — Basic Pitch splits sustains
  at re-articulations rather than merging them, so repeated 16ths on one pitch (the outro's
  B3/E2 pairs at 205–209 s) come out as separate events, which is what tab wants.
- Pitch bends are emitted for every note (contour-derived); not evaluated.
- Octave errors: not systematic in the sense of wrong-octave singletons; the failure mode is
  octave PAIRS on the 12-string (both are physically sounding) and sub-octave drone from
  bass leakage on the guitar stem (E1/B1 events).

## Swift feasibility
Tests/SongWorkbenchTests/BasicPitchSpikeTests.swift (`SW_BASIC_PITCH_SPIKE=1 swift test
--filter BasicPitchSpikeTests`; model path from `SW_BASIC_PITCH_MODEL` or the probe venv):
loads `nmp.onnx` with `ORTEnv`/`ORTSessionOptions`/`ORTSession` exactly as
`ONNXKaraokeChunkPredictor` does, feeds one `[1, 43844, 1]` window of a 440 Hz sine, and gets
note posterior peak at bin 48 = MIDI 69 (0.628, runner-up 0.116 — identical to Python's
0.628) and the contour peak at bin 145 = 69.33; 15 ms per window. Passed. No missing ops,
no Core ML conversion needed, model is 228 KB (bundle it as a resource — it does not need
the `ModelPackageManager` download path). Not run in Xcode, only SwiftPM; the pbxproj is
regenerated so `XcodeProjectRegistrationTests` accepts the new file.

## Integration sketch (5 lines)
1. `BasicPitchTranscriber` (ONNX session, resampler to 22.05 kHz mono via `MonoSampleLoader`
   + vDSP, the window/overlap/unwrap above, `output_to_notes_polyphonic` port) →
   `NoteEventTimeline` per stem: `[NoteEvent(onset, offset, midi, confidence)]` + frame posteriors.
2. Persist `noteEvents: [StemID: NoteEventTimeline]` on `SongAnalysisDocument` under the same
   `BucketGridKey`/versionTag staleness contract as `bucketNotes`; run right after separation.
3. `SoloTranscriptionPass`: replace the chroma-sparsity beat rule with the polyphony
   fraction from the timeline (keep the vocal-prominence RMS gate); passages by bar vote.
4. `SoloNote` per 16th = highest note event alive in that 16th above a per-passage register
   floor (median of the bar's notes) — feeds `GuitarTabAssigner` unchanged.
5. `BucketNotePass`: bucket the same events (pitch-class histogram from note events instead
   of chroma frames) so bucket notes and solo tab agree by construction.

## Not verified
- No listening: "guitar break" location on Back To You inferred from vocal-stem silence.
- Core ML `.mlpackage` variant untested; TFLite untested.
- Thresholds other than defaults not tuned beyond the one low-threshold sanity check above.
