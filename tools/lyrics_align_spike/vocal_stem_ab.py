#!/usr/bin/env python3
"""Does a better vocal stem actually improve lyric alignment?

Three arms, same song, same words, same aligner — only the audio differs:

  A  current   the app's 6-stem HTDemucs vocals stem
  B  polar     BS PolarFormer 2-stem vocals, separated from the original mix
  C  mix       the original mix, unseparated

## What this can and cannot answer

There is no human-annotated ground truth, so this CANNOT say which arm is right.
It can answer the question that actually decides the model swap:

  **Do the word times move at all?**

If A and B agree to within a frame on nearly every word, the aligner is saturated:
the +2.9 dB of vocal SDR is real but buys nothing here, and the swap is not worth
its cost. That is a decisive result and needs no annotation.

Two supporting measures:

  * **CTC path score per frame** — how well the phoneme sequence explains the audio,
    straight from the Viterbi. Independent of any onset detector. A cleaner stem
    should fit its own transcript better.
  * **Onset agreement against a FIXED reference** — onsets measured once, from arm A's
    stem, and reused for every arm. Scoring each arm against onsets from its OWN stem
    would be circular, since a different separator moves the onsets too.

Arm C is the control: if the mix scores as well as either stem, separation is not
earning its place in the alignment path at all.

Usage: vocal_stem_ab.py [limit]
"""
import contextlib
import glob
import io
import json
import os
import re
import sys
import time

import librosa
import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "LyricsAlignment-MTL")
POLAR = os.path.join(HERE, "polarformer")
CONTAINER = os.path.expanduser(
    "~/Library/Containers/com.local.SongWorkbench/Data/Library/"
    "Application Support/SongWorkbench"
)
RESOLUTION = 256 / 22050 * 3
HOP = 512
SCORE = re.compile(r"Alignment Score:\s*(-?[\d.]+)")


def align(stem_path, lyrics_path, method="MTL"):
    """Returns (word start seconds, CTC path score per output frame)."""
    sys.path.insert(0, REPO)
    cwd = os.getcwd()
    os.chdir(REPO)
    try:
        import wrapper

        audio, words, lp, iw, il = wrapper.preprocess_from_file(stem_path, lyrics_path)
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            spans, _ = wrapper.align(audio, words, lp, iw, il, method=method, cuda=False)
        text = captured.getvalue()
        raw = float(SCORE.search(text).group(1)) if SCORE.search(text) else float("nan")
        frames = audio.shape[1] / 22050 / RESOLUTION
        return [s[0] * RESOLUTION for s in spans], raw / max(frames, 1)
    finally:
        os.chdir(cwd)


def separate_vocals(mix_path, out_path):
    """BS PolarFormer 2-stem vocals, via the model's own reference runner."""
    if os.path.exists(out_path):
        return out_path
    sys.path.insert(0, POLAR)
    import importlib

    runner = importlib.import_module("run_onnx_inference")
    config = runner.load_config(os.path.join(POLAR, "model_bs_polarformer_float16.yaml"))
    with tempdir() as work:
        with contextlib.redirect_stdout(io.StringIO()):
            runner.run_inference(
                mix_path, config,
                os.path.join(POLAR, "bs_polarformer_fp16.onnx"), work)
        produced = os.path.join(work, "vocals.wav")
        if not os.path.exists(produced):
            raise RuntimeError("separator produced no vocals.wav")
        audio, sr = sf.read(produced)
        sf.write(out_path, audio, sr)
    return out_path


@contextlib.contextmanager
def tempdir():
    import shutil
    import tempfile

    path = tempfile.mkdtemp(prefix="polarformer-")
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def onset_scores(times, onsets, rms, sr, thresh):
    t = np.asarray(times, dtype=float)
    if len(t) == 0 or len(onsets) == 0:
        return None
    d = np.abs(onsets[np.argmin(np.abs(onsets[None, :] - t[:, None]), axis=1)] - t)
    idx = np.clip((t * sr / HOP).astype(int), 0, len(rms) - 1)
    return dict(
        median_ms=float(np.median(d) * 1000),
        within100=float(np.mean(d <= 0.100)),
        derail=float(np.mean(d > 1.0)),
        silent=float(np.mean(rms[idx] <= thresh)),
    )


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 99
    os.makedirs(os.path.join(HERE, "ab_stems"), exist_ok=True)
    rows = []

    for doc_path in sorted(glob.glob(os.path.join(CONTAINER, "songs", "*.json"))):
        song = os.path.basename(doc_path)[:-5]
        stem = os.path.join(CONTAINER, "Analysis", "Stems", song, "vocals.wav")
        if not os.path.exists(stem):
            continue
        try:
            doc = json.load(open(doc_path))
        except Exception:
            continue
        source = doc.get("sourcePath")
        if not source or not os.path.exists(source):
            continue
        a = doc.get("analysis") or {}
        lines = [
            " ".join(w.get("text", "") for w in (line.get("words") or []))
            for line in (a.get("lyrics") or [])
        ]
        lines = [l.strip() for l in lines if l.strip()]
        if sum(len(l.split()) for l in lines) < 40:
            continue
        if len(rows) >= limit:
            break

        name = os.path.basename(source)[:38]
        lyrics_path = os.path.join(HERE, f"_ab_{song[:12]}.txt")
        open(lyrics_path, "w").write("\n".join(lines) + "\n")
        polar_path = os.path.join(HERE, "ab_stems", f"{song[:12]}_polar.wav")

        try:
            t0 = time.time()
            separate_vocals(source, polar_path)
            sep_seconds = time.time() - t0
            arms = {
                "current": align(stem, lyrics_path),
                "polar": align(polar_path, lyrics_path),
                "mix": align(source, lyrics_path),
            }
        except Exception as exc:
            print(f"SKIP {name}: {type(exc).__name__}: {exc}", flush=True)
            continue

        # One fixed onset reference for every arm — arm A's stem.
        y, sr = librosa.load(stem, sr=22050, mono=True)
        rms = librosa.feature.rms(y=y, frame_length=2048, hop_length=HOP)[0]
        thresh = np.percentile(rms, 99) * 0.10
        onsets = librosa.onset.onset_detect(
            y=y, sr=sr, hop_length=HOP, units="time", backtrack=True)

        n = min(len(v[0]) for v in arms.values())
        record = {"song": name, "words": n, "separation_seconds": sep_seconds}
        for arm, (times, score) in arms.items():
            record[arm] = onset_scores(times[:n], onsets, rms, sr, thresh) or {}
            record[arm]["ctc_per_frame"] = score
            record[arm]["first"] = times[0] if times else None

        # THE decisive number: how far apart are the arms' word times?
        cur = np.asarray(arms["current"][0][:n])
        for arm in ("polar", "mix"):
            other = np.asarray(arms[arm][0][:n])
            delta = np.abs(other - cur)
            record[f"vs_current_{arm}"] = dict(
                median_ms=float(np.median(delta) * 1000),
                beyond_frame=float(np.mean(delta > RESOLUTION)),
                beyond_300ms=float(np.mean(delta > 0.300)),
            )
        rows.append(record)
        print(
            f"{name:38s} {n:4d}w  "
            f"cur[ctc {record['current']['ctc_per_frame']:6.3f} med {record['current']['median_ms']:5.0f}ms] "
            f"pol[ctc {record['polar']['ctc_per_frame']:6.3f} med {record['polar']['median_ms']:5.0f}ms] "
            f"mix[ctc {record['mix']['ctc_per_frame']:6.3f} med {record['mix']['median_ms']:5.0f}ms]  "
            f"pol-vs-cur {record['vs_current_polar']['median_ms']:5.0f}ms "
            f"({100*record['vs_current_polar']['beyond_frame']:.0f}% moved)",
            flush=True)
        try:
            os.remove(lyrics_path)
        except OSError:
            pass

    json.dump(rows, open(os.path.join(HERE, "vocal_ab_results.json"), "w"), indent=1)
    if not rows:
        print("no songs scored")
        return

    print()
    print(f"=== {len(rows)} songs ===")
    for arm in ("current", "polar", "mix"):
        print(
            f"  {arm:8s} CTC/frame {np.mean([r[arm]['ctc_per_frame'] for r in rows]):7.3f}   "
            f"median {np.mean([r[arm]['median_ms'] for r in rows]):6.1f}ms   "
            f"within100 {100*np.mean([r[arm]['within100'] for r in rows]):5.1f}%   "
            f"derail {100*np.mean([r[arm]['derail'] for r in rows]):4.1f}%   "
            f"silence {100*np.mean([r[arm]['silent'] for r in rows]):4.1f}%")
    print()
    print("  How much did word times actually MOVE from the current stem:")
    for arm in ("polar", "mix"):
        print(
            f"    {arm:6s} median {np.mean([r[f'vs_current_{arm}']['median_ms'] for r in rows]):6.1f}ms   "
            f"beyond one frame {100*np.mean([r[f'vs_current_{arm}']['beyond_frame'] for r in rows]):5.1f}%   "
            f"beyond 300ms {100*np.mean([r[f'vs_current_{arm}']['beyond_300ms'] for r in rows]):5.1f}%")
    print()
    print("  Separation cost: "
          f"{np.mean([r['separation_seconds'] for r in rows]):.1f}s per song (CPU, ONNX)")


if __name__ == "__main__":
    main()
