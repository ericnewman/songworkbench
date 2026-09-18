#!/usr/bin/env python3
"""Paired A/B over every song that has both a vocal stem and lyrics.

For each song: take the app's CURRENT word times and the times LyricsAlignment-MTL
produces for the SAME word list, and score both against the same measured stem
onsets, plus a random-placement control.

The word list is identical across arms by construction, so the comparison is paired
per word. Reported per song and aggregated with a sign test over songs.

Usage: batch_eval.py [limit]
"""
import glob
import json
import os
import sys
import time

import librosa
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "LyricsAlignment-MTL")
CONTAINER = os.path.expanduser(
    "~/Library/Containers/com.local.SongWorkbench/Data/Library/"
    "Application Support/SongWorkbench"
)
RESOLUTION = 256 / 22050 * 3
HOP = 512


def score(times, onsets, rms, sr, thresh):
    times = np.asarray(times, dtype=float)
    if len(onsets) == 0 or len(times) == 0:
        return None
    d = np.abs(onsets[np.argmin(np.abs(onsets[None, :] - times[:, None]), axis=1)] - times)
    idx = (times * sr / HOP).astype(int)
    idx = np.clip(idx, 0, len(rms) - 1)
    silent = float(np.mean(rms[idx] <= thresh))
    return {
        "median_ms": float(np.median(d) * 1000),
        "within100": float(np.mean(d <= 0.100)),
        "derail": float(np.mean(d > 1.0)),
        "silent": silent,
        "first": float(times[0]),
    }


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 99
    sys.path.insert(0, REPO)
    os.chdir(REPO)
    import wrapper

    rows = []
    docs = sorted(glob.glob(os.path.join(CONTAINER, "songs", "*.json")))
    for doc_path in docs:
        song = os.path.basename(doc_path)[:-5]
        stem = os.path.join(CONTAINER, "Analysis", "Stems", song, "vocals.wav")
        if not os.path.exists(stem):
            continue
        try:
            doc = json.load(open(doc_path))
        except Exception:
            continue
        a = doc.get("analysis") or {}
        lines = a.get("lyrics") or []
        cur_words, cur_times, text_lines = [], [], []
        for line in lines:
            ws = line.get("words") or []
            t = " ".join(w.get("text", "") for w in ws).strip()
            if not t:
                continue
            text_lines.append(t)
            for w in ws:
                cur_words.append(w.get("text", ""))
                cur_times.append(w.get("start", 0.0))
        if len(cur_words) < 40:
            continue
        if len(rows) >= limit:
            break

        name = os.path.basename(doc.get("sourcePath", song))[:38]
        lyr = os.path.join(HERE, f"_batch_{song[:12]}.txt")
        open(lyr, "w").write("\n".join(text_lines) + "\n")

        try:
            t0 = time.time()
            audio, words, lp, iw, il = wrapper.preprocess_from_file(stem, lyr)
            wa, words = wrapper.align(audio, words, lp, iw, il, method="MTL", cuda=False)
            secs = time.time() - t0
        except Exception as e:
            print(f"SKIP {name}: {type(e).__name__}: {e}", flush=True)
            continue

        mtl_times = [s[0] * RESOLUTION for s in wa]
        y, sr = librosa.load(stem, sr=22050, mono=True)
        dur = len(y) / sr
        rms = librosa.feature.rms(y=y, frame_length=2048, hop_length=HOP)[0]
        thresh = np.percentile(rms, 99) * 0.10
        onsets = librosa.onset.onset_detect(y=y, sr=sr, hop_length=HOP, units="time", backtrack=True)

        n = min(len(mtl_times), len(cur_times))
        cur = score(cur_times[:n], onsets, rms, sr, thresh)
        new = score(mtl_times[:n], onsets, rms, sr, thresh)
        rng = np.random.default_rng(7)
        rnd = score(np.sort(rng.uniform(0, dur, size=n)), onsets, rms, sr, thresh)
        if not (cur and new):
            continue

        rows.append({"song": name, "words": n, "dur": dur, "secs": secs,
                     "cur": cur, "new": new, "rnd": rnd})
        print(f"{name:40s} {dur:6.1f}s {n:4d}w  {dur/secs:5.1f}x  "
              f"cur[med {cur['median_ms']:5.0f}ms derail {cur['derail']*100:4.1f}% silent {cur['silent']*100:4.1f}%]  "
              f"new[med {new['median_ms']:5.0f}ms derail {new['derail']*100:4.1f}% silent {new['silent']*100:4.1f}%]",
              flush=True)
        try:
            os.remove(lyr)
        except OSError:
            pass

    json.dump(rows, open(os.path.join(HERE, "batch_results.json"), "w"), indent=1)
    print()
    print(f"=== {len(rows)} songs ===")
    if not rows:
        return
    for key, label, better_is_low in [
        ("median_ms", "median |delta| (ms)", True),
        ("derail", "derailment >1s (%)", True),
        ("silent", "words on silent stem (%)", True),
        ("within100", "within 100ms (%)", False),
    ]:
        c = np.array([r["cur"][key] for r in rows])
        nw = np.array([r["new"][key] for r in rows])
        rd = np.array([r["rnd"][key] for r in rows])
        scale = 1 if key == "median_ms" else 100
        wins = int(np.sum(nw < c)) if better_is_low else int(np.sum(nw > c))
        print(f"{label:26s} current {np.mean(c)*scale:7.1f}   MTL {np.mean(nw)*scale:7.1f}   "
              f"random {np.mean(rd)*scale:7.1f}   MTL wins {wins}/{len(rows)} songs")
    sp = np.mean([r["dur"] / r["secs"] for r in rows])
    print(f"{'alignment speed':26s} {sp:.1f}x realtime (CPU, python)")


if __name__ == "__main__":
    main()
