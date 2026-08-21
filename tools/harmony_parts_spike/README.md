# Harmony part spike

Offline proof of PRD Layer 3 and of the Track A / Track B split (PRD §2b) (`.scratch/multipart-stem-separation/PRD.md`): multi-f0
estimation, timbral fingerprinting, part assignment, and harmonic-mask synthesis. Python,
because the question is "does this approach work at all", and answering it in Swift first
would mean building the native STFT/ISTFT core before knowing whether it is worth building.

Nothing here ships. `Sources/` is untouched.

## Running it

```bash
pip install numpy scipy

python3 tools/harmony_parts_spike/selftest.py                   # 1.6 s regression guard
python3 tools/harmony_parts_spike/run_spike.py --cast distinct --parts 3
python3 tools/harmony_parts_spike/run_spike.py --cast quartet_no_octave --parts 4
python3 tools/harmony_parts_spike/debug_tracks.py distinct 3    # per-note diagnosis
python3 tools/harmony_parts_spike/compare_masks.py              # mask variants, all casts
python3 tools/harmony_parts_spike/run_stereo.py                 # stereo evidence
python3 tools/harmony_parts_spike/run_octave.py                 # the octave trap
python3 tools/harmony_parts_spike/run_octave_seeds.py           # ...across seeds, with guards
python3 tools/harmony_parts_spike/interval_sweep.py             # separability vs interval
python3 tools/harmony_parts_spike/run_notes.py                  # Track A: note metrics
python3 tools/harmony_parts_spike/run_notes.py --sweep           # confidence gate
```

On a real vocal stem (16-bit PCM WAV, mono or stereo):

```bash
python3 tools/harmony_parts_spike/run_spike.py --input backing.wav --parts 3 \
    --write-audio /tmp/parts
```

With `--input` the ground-truth metrics are skipped — there is no truth to score against —
so you get reconstruction, leakage, and the audio to listen to. `--write-audio` also dumps
the fixture's true sources next to the estimates when running synthetically, which is the
quickest way to hear what a given failure mode actually sounds like.

## Files

| file | role |
| --- | --- |
| `fixture.py` | synthetic singers (source-filter, per-voice formants/tilt/vibrato) + scores |
| `parts.py` | STFT/ISTFT, multi-f0, tracks, fingerprints, clustering, mask synthesis |
| `run_spike.py` | runs the chain and scores it against the PRD gates |
| `debug_tracks.py` | per-note table: f0, cluster label, true owner, timbral features |
| `compare_masks.py` | A/B/C/D the mask-synthesis variants across every cast |
| `stereo.py` | pan estimation and spatial masking (the four-part lever) |
| `run_stereo.py` | measures the spatial term, with a near-mono control |
| `run_octave.py` | the octave trap: pan-slice vs octave-aware f0, with a near-mono control |
| `run_octave_seeds.py` | the same across 4 seeds, plus non-octave casts as a regression guard |
| `interval_sweep.py` | separability at every interval from unison to the octave |
| `notes.py` | Track A: f0 tracks → note events (no ISTFT, no masks) |
| `run_notes.py` | note-level metrics; `--sweep` for the confidence gate |
| `selftest.py` | asserts the working configuration stays working |

## Casts

| cast | what it contains | why |
| --- | --- | --- |
| `distinct` | 3 singers, 3 pitch lines, one voice crossing | the tractable case |
| `quartet_no_octave` | 4 singers, 4 pitch lines, no octave pair | the 4-part target |
| `quartet` | same, but bottom exactly an octave below top | the octave trap |
| `hard` | 3 singers + a unison double of the lead | the unison limit |

Results and interpretation: `.scratch/multipart-stem-separation/FINDINGS-timbral-spike.md`.
