#!/usr/bin/env python3
"""Objective check against the audio itself: where does the vocal stem first carry
energy, and how close is each aligned word onset to a measured stem onset?

No human annotation needed. Answers two things:
  1. Is the first aligned word anywhere near the first sung sound?
  2. Do aligned onsets land on measured onsets (the project's snapping thesis)?

Usage: check_onsets.py <vocals.wav> <aligned.json>
"""
import json
import sys

import librosa
import numpy as np


def main():
    wav, aligned_path = sys.argv[1], sys.argv[2]
    y, sr = librosa.load(wav, sr=22050, mono=True)
    dur = len(y) / sr

    # Where does the stem first sustain real energy? RMS over 20ms hops, threshold
    # relative to the track's own loudness so it does not depend on mastering.
    hop = 512
    rms = librosa.feature.rms(y=y, frame_length=2048, hop_length=hop)[0]
    times = librosa.frames_to_time(np.arange(len(rms)), sr=sr, hop_length=hop)
    peak = np.percentile(rms, 99)
    thresh = peak * 0.10
    voiced = rms > thresh
    # first run of >= 5 consecutive voiced frames (~116ms), to skip single-frame noise
    first_voice = None
    run = 0
    for i, v in enumerate(voiced):
        run = run + 1 if v else 0
        if run >= 5:
            first_voice = times[i - 4]
            break

    onsets = librosa.onset.onset_detect(
        y=y, sr=sr, hop_length=hop, units="time", backtrack=True
    )

    with open(aligned_path) as f:
        data = json.load(f)
    words = data["words"]

    print(f"stem duration        : {dur:.1f}s")
    print(f"stem 99th-pct RMS    : {peak:.4f}   (threshold {thresh:.4f})")
    print(f"FIRST SUNG SOUND     : {first_voice:.2f}s" if first_voice is not None else "no voiced frames found")
    print(f"measured onsets      : {len(onsets)}")
    print(f"first 6 onsets       : {[round(float(o), 2) for o in onsets[:6]]}")
    print()
    print(f"first aligned word   : {words[0]['start']:.2f}s  ({words[0]['word']!r})")
    if first_voice is not None:
        print(f"  -> difference      : {words[0]['start'] - first_voice:+.2f}s")
    print()

    # How close is each aligned word to SOME measured onset?
    deltas = []
    for w in words:
        if len(onsets) == 0:
            break
        d = onsets - w["start"]
        near = d[np.argmin(np.abs(d))]
        deltas.append(float(near))
    deltas = np.array(deltas)
    absd = np.abs(deltas)
    print("aligned word onset -> nearest measured stem onset:")
    print(f"  median |delta|     : {np.median(absd) * 1000:.0f} ms")
    print(f"  within  50 ms      : {100 * np.mean(absd <= 0.050):.0f}%")
    print(f"  within 100 ms      : {100 * np.mean(absd <= 0.100):.0f}%")
    print(f"  within 200 ms      : {100 * np.mean(absd <= 0.200):.0f}%")
    print(f"  beyond 1 s         : {100 * np.mean(absd > 1.0):.0f}%   (derailment proxy)")
    print()
    # Words placed where the stem is silent are the real failure — check energy at each word.
    silent = 0
    for w in words:
        i = int(w["start"] * sr / hop)
        if 0 <= i < len(rms) and rms[i] <= thresh:
            silent += 1
    print(f"words landing on SILENT stem frames: {silent}/{len(words)} ({100*silent/len(words):.0f}%)")


if __name__ == "__main__":
    main()


def control(wav, aligned_path, seed=7):
    """Control: how well would RANDOM word times score on this same metric?
    If the real systems do not clearly beat this, the metric is measuring nothing."""
    import librosa, numpy as np, json
    y, sr = librosa.load(wav, sr=22050, mono=True)
    hop = 512
    onsets = librosa.onset.onset_detect(y=y, sr=sr, hop_length=hop, units="time", backtrack=True)
    words = json.load(open(aligned_path))["words"]
    dur = len(y) / sr
    rng = np.random.default_rng(seed)
    meds, w100, far = [], [], []
    for _ in range(200):
        t = np.sort(rng.uniform(0, dur, size=len(words)))
        d = np.abs(onsets[np.argmin(np.abs(onsets[None, :] - t[:, None]), axis=1)] - t)
        meds.append(np.median(d)); w100.append(np.mean(d <= 0.1)); far.append(np.mean(d > 1.0))
    print()
    print("CONTROL — uniformly random word times, 200 trials:")
    print(f"  median |delta|     : {np.median(meds)*1000:.0f} ms")
    print(f"  within 100 ms      : {100*np.mean(w100):.0f}%")
    print(f"  beyond 1 s         : {100*np.mean(far):.0f}%")
