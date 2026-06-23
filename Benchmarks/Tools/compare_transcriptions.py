#!/usr/bin/env python3

import argparse
import re
import unicodedata
from pathlib import Path


def words(path: Path) -> list[str]:
    text = unicodedata.normalize("NFKD", path.read_text(encoding="utf-8")).lower()
    text = text.replace("’", "'")
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)?", text)


def edit_counts(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int]:
    rows = len(reference) + 1
    columns = len(hypothesis) + 1
    costs = [[(0, 0, 0, 0)] * columns for _ in range(rows)]
    for row in range(1, rows):
        costs[row][0] = (row, 0, row, 0)
    for column in range(1, columns):
        costs[0][column] = (column, 0, 0, column)

    for row in range(1, rows):
        for column in range(1, columns):
            if reference[row - 1] == hypothesis[column - 1]:
                costs[row][column] = costs[row - 1][column - 1]
                continue
            diagonal = costs[row - 1][column - 1]
            deletion = costs[row - 1][column]
            insertion = costs[row][column - 1]
            candidates = (
                (diagonal[0] + 1, diagonal[1] + 1, diagonal[2], diagonal[3]),
                (deletion[0] + 1, deletion[1], deletion[2] + 1, deletion[3]),
                (insertion[0] + 1, insertion[1], insertion[2], insertion[3] + 1),
            )
            costs[row][column] = min(candidates)

    _, substitutions, deletions, insertions = costs[-1][-1]
    return substitutions, deletions, insertions


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("hypotheses", nargs="+", type=Path)
    args = parser.parse_args()

    reference = words(args.reference)
    for path in args.hypotheses:
        hypothesis = words(path)
        substitutions, deletions, insertions = edit_counts(reference, hypothesis)
        errors = substitutions + deletions + insertions
        print(
            f"{path.name} reference_words={len(reference)} "
            f"hypothesis_words={len(hypothesis)} substitutions={substitutions} "
            f"deletions={deletions} insertions={insertions} "
            f"wer={errors / max(len(reference), 1):.4f}"
        )


if __name__ == "__main__":
    main()
