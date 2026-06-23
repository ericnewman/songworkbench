#!/usr/bin/env python3

import argparse
from pathlib import Path

import numpy as np
import soundfile as sf


STEMS = ("vocals", "drums", "bass", "other")


def read(path: Path) -> tuple[np.ndarray, int]:
    return sf.read(path, dtype="float32", always_2d=True)


def rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(audio * audio)))


def correlation(first: np.ndarray, second: np.ndarray) -> float:
    frames = min(len(first), len(second))
    return float(np.corrcoef(first[:frames].reshape(-1), second[:frames].reshape(-1))[0, 1])


def reconstruction_metrics(mix: np.ndarray, directory: Path) -> None:
    outputs = [read(directory / f"{stem}.wav")[0] for stem in STEMS]
    frames = min([len(mix), *(len(output) for output in outputs)])
    reconstruction = sum(output[:frames] for output in outputs)
    residual = mix[:frames] - reconstruction
    residual_rms = rms(residual)
    signal_rms = rms(mix[:frames])
    snr = 20 * np.log10(signal_rms / max(residual_rms, 1e-12))
    print(
        f"{directory.name}_reconstruction "
        f"rms={residual_rms:.6f} snr_db={snr:.2f} "
        f"correlation={correlation(mix[:frames], reconstruction):.6f}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mix", type=Path)
    parser.add_argument("baseline_directory", type=Path)
    parser.add_argument("candidate_directory", type=Path)
    args = parser.parse_args()

    mix, mix_rate = read(args.mix)
    print(f"input sample_rate={mix_rate} frames={len(mix)} channels={mix.shape[1]}")

    for stem in STEMS:
        baseline, baseline_rate = read(args.baseline_directory / f"{stem}.wav")
        candidate, candidate_rate = read(args.candidate_directory / f"{stem}.wav")
        print(
            f"{stem} sample_rate={candidate_rate} frames={len(candidate)} "
            f"channels={candidate.shape[1]} rms={rms(candidate):.6f} "
            f"peak={float(np.max(np.abs(candidate))):.6f} "
            f"finite={bool(np.isfinite(candidate).all())} "
            f"baseline_rate={baseline_rate} "
            f"correlation={correlation(baseline, candidate):.6f}"
        )

    reconstruction_metrics(mix, args.baseline_directory)
    reconstruction_metrics(mix, args.candidate_directory)


if __name__ == "__main__":
    main()
