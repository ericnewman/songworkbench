#!/usr/bin/env python3
"""Pull a song document's lyric lines out as plain text for the aligner, and print
the word times the app currently believes, so the two can be compared.

Usage: extract_lyrics.py <song.json> <out-lyrics.txt>
"""
import json
import sys


def main():
    doc_path, out_path = sys.argv[1], sys.argv[2]
    with open(doc_path) as f:
        doc = json.load(f)
    analysis = doc.get("analysis", doc)
    lines = analysis.get("lyrics") or []

    out_lines = []
    current = []
    for line in lines:
        words = line.get("words") or []
        text = " ".join(w.get("text", "") for w in words).strip()
        if text:
            out_lines.append(text)
            start = words[0].get("start") if words else line.get("start")
            current.append((start, text))

    with open(out_path, "w") as f:
        f.write("\n".join(out_lines) + "\n")

    print(f"wrote {len(out_lines)} lines, {sum(len(l.split()) for l in out_lines)} words -> {out_path}")
    print()
    print("what the app currently believes (first 8 lines):")
    for start, text in current[:8]:
        print(f"  {start:8.2f}s  {text[:62]}")


if __name__ == "__main__":
    main()
