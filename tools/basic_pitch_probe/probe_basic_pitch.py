#!/usr/bin/env python3
"""Spike: can Spotify's Basic Pitch transcribe the `guitar` stem well enough to find lead
passages (where the chroma-sparsity classifier cannot) and give tab-usable note events?

Runs Basic Pitch's ONNX model (the artifact a Swift port would load) on the guitar stem of the
analysed songs named on the command line, buckets the note events on the app's MetronomeGrid
(period = 60 / estimatedBPM, phase anchor = beatTimes[barGrid.barPhase]), classifies every
beat as lead / chordal / silent, groups lead runs of >= 2 bars into passages, and prints the
first two bars of each passage as a 16th-note list. Note events go to /tmp/bp_<song>_<stem>.json.

    .probevenv/bin/python probe_basic_pitch.py "Eight Miles High" "Back To You" "It Is Well"
    .probevenv/bin/python probe_basic_pitch.py --stems guitar,other "Eight Miles High"
"""
import argparse
import glob
import json
import math
import os
import re
import sys
import time

SONGS_DIR = os.path.expanduser(
    "~/Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench/songs"
)


def load_model_onnx():
    """Force the ONNX runtime path (Basic Pitch prefers TF > CoreML > TFLite > ONNX when all are
    importable); that is the artifact the Swift port would consume, so measure that one."""
    import basic_pitch.inference as inf
    from basic_pitch import ICASSP_2022_MODEL_PATH

    inf.TF_PRESENT = False
    inf.CT_PRESENT = False
    inf.TFLITE_PRESENT = False
    model_path = str(ICASSP_2022_MODEL_PATH)
    if model_path.endswith(".onnx") is False:
        model_path = os.path.join(os.path.dirname(model_path), "nmp.onnx")
        if not os.path.exists(model_path):
            model_path = os.path.join(model_path.rsplit("/", 1)[0], "nmp.onnx")
    model = inf.Model(model_path)
    assert model.model_type == inf.Model.MODEL_TYPES.ONNX, model.model_type
    sess = model.model
    contract = {
        "model_path": model_path,
        "inputs": [(i.name, i.shape, i.type) for i in sess.get_inputs()],
        "outputs": [(o.name, o.shape, o.type) for o in sess.get_outputs()],
        "sample_rate": inf.AUDIO_SAMPLE_RATE,
        "window_samples": inf.AUDIO_N_SAMPLES,
        "fft_hop": inf.FFT_HOP,
        "annotations_fps": inf.ANNOTATIONS_FPS,
        "overlap_frames": 30,
        "hop_samples": inf.AUDIO_N_SAMPLES - 30 * inf.FFT_HOP,
    }
    return model, contract


def find_songs(patterns):
    hits = []
    for path in sorted(glob.glob(os.path.join(SONGS_DIR, "*.json"))):
        with open(path) as fh:
            doc = json.load(fh)
        source = os.path.basename(doc.get("sourcePath") or "")
        for pat in patterns:
            if pat.lower() in source.lower():
                hits.append((pat, source, doc["analysis"]))
    return hits


def stem_path(analysis, stem_id):
    for asset in (analysis.get("stemSet") or {}).get("assets", []):
        if (asset.get("id") or asset.get("stemID")) == stem_id:
            return asset["audio"]["path"]
    return (analysis.get("stems") or {}).get(stem_id, {}).get("path")


def metronome_grid(analysis, duration):
    """MetronomeGrid.clickTimes: 60/bpm period, anchored at beatTimes[barPhase]."""
    beats = sorted(analysis.get("beatTimes") or [])
    bpm = analysis.get("estimatedBPM")
    bar = analysis.get("barGrid") or {}
    beats_per_bar = int(bar.get("beatsPerBar") or 4)
    if not beats or not bpm:
        return None, None, beats_per_bar
    phase = min(max(int(bar.get("barPhase") or 0), 0), len(beats) - 1)
    anchor = beats[phase]
    period = 60.0 / bpm
    first_k = -int(math.floor(anchor / period))
    last_k = int(math.floor((duration - anchor) / period))
    grid = [anchor + k * period for k in range(first_k, last_k + 1)]
    # index of the anchor beat in `grid` — it is beat 1 of a bar
    anchor_index = -first_k
    return grid, anchor_index, beats_per_bar


def classify_beats(notes, grid, beats_per_bar):
    """Per beat: polyphony sampled at 50 ms, onset count, and a lead/chordal/silent class."""
    beats = []
    for i in range(len(grid) - 1):
        t0, t1 = grid[i], grid[i + 1]
        onsets = [n for n in notes if t0 <= n["onset"] < t1]
        # polyphony sampled every ~50 ms: a strummed part sits at 4-7 simultaneous notes, a
        # single line at 1-2 (an octave-doubled 12-string or a ringing open string makes 2).
        samples = max(4, int((t1 - t0) / 0.05))
        polys = []
        for q in range(samples):
            t = t0 + (t1 - t0) * (q + 0.5) / samples
            polys.append(sum(1 for n in notes if n["onset"] <= t < n["offset"]))
        active_max = max(polys)
        mono_fraction = sum(1 for p in polys if 1 <= p <= 2) / samples
        chord_fraction = sum(1 for p in polys if p >= 3) / samples
        if active_max == 0:
            kind = "silent"
        elif chord_fraction >= 0.5:
            kind = "chordal"
        elif mono_fraction >= 0.5 and len(onsets) >= 1:
            kind = "lead"
        else:
            kind = "sustain"  # held notes / mixed; neutral, tolerated inside a passage as a gap
        beats.append({"start": t0, "end": t1, "onsets": len(onsets), "poly": active_max,
                      "mono_fraction": mono_fraction, "kind": kind})
    return beats


def passages(beats, beats_per_bar, anchor_index, min_bars=2, max_gap=1):
    """Bar-level vote (bars start on the anchor beat): a bar is lead when at least half its beats
    are lead and lead beats outnumber chordal ones. Runs of >= min_bars lead bars, tolerating
    max_gap non-lead bars, returned as (first_beat, last_beat) index pairs."""
    first_bar_start = anchor_index % beats_per_bar
    bars = []
    for start in range(first_bar_start, len(beats), beats_per_bar):
        chunk = beats[start:start + beats_per_bar]
        lead = sum(1 for b in chunk if b["kind"] == "lead")
        chordal = sum(1 for b in chunk if b["kind"] == "chordal")
        bars.append((start, start + len(chunk) - 1, lead >= len(chunk) / 2 and lead > chordal))
    out = []
    run = []
    gap = 0
    for bar in bars:
        if bar[2]:
            run.append(bar)
            gap = 0
        elif run:
            gap += 1
            if gap > max_gap:
                if len(run) >= min_bars:
                    out.append((run[0][0], run[-1][1]))
                run = []
                gap = 0
    if len(run) >= min_bars:
        out.append((run[0][0], run[-1][1]))
    return out


def mmss(t):
    return f"{int(t // 60)}:{t % 60:05.2f}"


def midi_name(m):
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return f"{names[m % 12]}{m // 12 - 1}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("songs", nargs="+", help="substrings of the source file name")
    ap.add_argument("--stems", default="guitar", help="comma-separated stem ids (default guitar)")
    ap.add_argument("--onset", type=float, default=0.5)
    ap.add_argument("--frame", type=float, default=0.3)
    ap.add_argument("--min-bars", type=int, default=2)
    args = ap.parse_args()

    import basic_pitch.inference as inf

    model, contract = load_model_onnx()
    print("MODEL CONTRACT")
    for k, v in contract.items():
        print(f"  {k}: {v}")

    for pat, source, analysis in find_songs(args.songs):
        for stem_id in args.stems.split(","):
            path = stem_path(analysis, stem_id)
            if not path or not os.path.exists(path):
                print(f"\n== {source} [{stem_id}] — no stem file")
                continue
            import soundfile as sf

            info = sf.info(path)
            duration = info.frames / info.samplerate
            t0 = time.time()
            model_output, _midi, note_events = inf.predict(
                path, model, onset_threshold=args.onset, frame_threshold=args.frame,
                multiple_pitch_bends=False, melodia_trick=True,
            )
            elapsed = time.time() - t0
            notes = [
                {"onset": float(s), "offset": float(e), "midi": int(p), "amplitude": float(a),
                 "bends": [int(x) for x in (b or [])][:8]}
                for s, e, p, a, b in note_events
            ]
            notes.sort(key=lambda n: (n["onset"], n["midi"]))
            slug = re.sub(r"[^A-Za-z0-9]+", "_", source.rsplit(".", 1)[0]).strip("_")[:40]
            out_path = f"/tmp/bp_{slug}_{stem_id}.json"
            with open(out_path, "w") as fh:
                json.dump({"source": source, "stem": stem_id, "duration": duration,
                           "inference_seconds": elapsed, "notes": notes}, fh)

            print(f"\n== {source} [{stem_id}]  {mmss(duration)}  {info.samplerate} Hz  "
                  f"inference {elapsed:.1f} s ({duration / elapsed:.1f}x realtime)")
            print(f"   notes: {len(notes)}  ({len(notes) / max(duration, 1e-9) * 60:.0f}/min)  "
                  f"note shape {model_output['note'].shape}  onset shape {model_output['onset'].shape}  "
                  f"contour shape {model_output['contour'].shape}")
            if notes:
                durs = sorted(n["offset"] - n["onset"] for n in notes)
                mids = sorted(n["midi"] for n in notes)
                print(f"   midi range {mids[0]}({midi_name(mids[0])})..{mids[-1]}({midi_name(mids[-1])}), "
                      f"median {mids[len(mids)//2]}; duration median {durs[len(durs)//2]:.2f} s, "
                      f"p90 {durs[int(len(durs)*0.9)]:.2f} s; with bends: {sum(1 for n in notes if n['bends'])}")

            grid, anchor_index, bpb = metronome_grid(analysis, duration)
            if grid is None:
                print("   no metronome grid (no bpm/beats)")
                continue
            beats = classify_beats(notes, grid, bpb)
            counts = {}
            for b in beats:
                counts[b["kind"]] = counts.get(b["kind"], 0) + 1
            print(f"   grid: bpm {analysis['estimatedBPM']:.2f}, {bpb}/bar, {len(beats)} beats; "
                  f"beat classes {counts}")
            # coarse timeline: one char per beat, a bar per group
            strip = "".join({"lead": "L", "chordal": "C", "silent": ".", "sustain": "s"}[b["kind"]] for b in beats)
            for i in range(0, len(strip), bpb * 16):
                print(f"   {mmss(beats[i]['start']):>8} " + " ".join(
                    strip[j:j + bpb] for j in range(i, min(i + bpb * 16, len(strip)), bpb)))
            runs = passages(beats, bpb, anchor_index, args.min_bars)
            print(f"   passages (>= {args.min_bars} lead bars by majority vote, 1-bar gaps ok): {len(runs)}")
            for s, e in runs:
                ps, pe = beats[s]["start"], beats[e]["end"]
                on = sum(b["onsets"] for b in beats[s:e + 1])
                print(f"     {mmss(ps)}–{mmss(pe)}  {(e - s + 1) / bpb:.1f} bars, {on} onsets, "
                      f"{on / (e - s + 1):.1f} onsets/beat")
                # first two bars as 16ths from passage start
                two_bars_end = min(pe, ps + 2 * bpb * (grid[1] - grid[0]))
                six = (grid[1] - grid[0]) / 4
                cells = []
                for n in notes:
                    if ps <= n["onset"] < two_bars_end:
                        pos = round((n["onset"] - ps) / six)
                        length = max(1, round((n["offset"] - n["onset"]) / six))
                        cells.append(f"{pos}:{midi_name(n['midi'])}x{length}")
                print("       16ths: " + " ".join(cells))


if __name__ == "__main__":
    main()
