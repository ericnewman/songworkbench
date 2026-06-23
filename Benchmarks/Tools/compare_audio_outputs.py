#!/usr/bin/env python3

import argparse

import numpy as np
import soundfile as sf


def metrics(path: str) -> tuple[np.ndarray, float, float]:
    audio, _ = sf.read(path, dtype="float32", always_2d=True)
    return audio, float(np.sqrt(np.mean(audio * audio))), float(np.max(np.abs(audio)))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("first")
    parser.add_argument("second")
    args = parser.parse_args()

    first, first_rms, first_peak = metrics(args.first)
    second, second_rms, second_peak = metrics(args.second)
    frames = min(len(first), len(second))
    first_mono = first[:frames].mean(axis=1)
    second_mono = second[:frames].mean(axis=1)
    correlation = float(np.corrcoef(first_mono, second_mono)[0, 1])

    print(f"frames={frames}")
    print(f"zero_lag_correlation={correlation:.6f}")
    print(f"first_rms={first_rms:.6f}")
    print(f"second_rms={second_rms:.6f}")
    print(f"first_peak={first_peak:.6f}")
    print(f"second_peak={second_peak:.6f}")


if __name__ == "__main__":
    main()
