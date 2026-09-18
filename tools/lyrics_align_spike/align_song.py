#!/usr/bin/env python3
"""Run LyricsAlignment-MTL over a vocal stem and print word onsets.

Usage: align_song.py <vocals.wav> <lyrics.txt> [method]
  method: Baseline | MTL | Baseline_BDR | MTL_BDR   (default MTL)

Prints one line per word: index, onset seconds, word. Also writes <lyrics>.aligned.json
so a later comparison can read it back.
"""
import json
import os
import sys
import time

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "LyricsAlignment-MTL")
sys.path.insert(0, REPO)


def main():
    audio_path = os.path.abspath(sys.argv[1])
    lyrics_path = os.path.abspath(sys.argv[2])
    method = sys.argv[3] if len(sys.argv) > 3 else "MTL"

    # checkpoint paths inside the repo are relative ("./checkpoints/...")
    os.chdir(REPO)

    import wrapper  # noqa: E402  (after chdir + sys.path)

    RESOLUTION = 256 / 22050 * 3

    t0 = time.time()
    audio, words, lyrics_p, idx_word_p, idx_line_p = wrapper.preprocess_from_file(
        audio_path, lyrics_path
    )
    t_pre = time.time() - t0

    duration = audio.shape[1] / 22050.0

    t1 = time.time()
    word_align, words = wrapper.align(
        audio, words, lyrics_p, idx_word_p, idx_line_p, method=method, cuda=False
    )
    t_align = time.time() - t1

    out = []
    for i, span in enumerate(word_align):
        start_f, end_f = span[0], span[1]
        out.append(
            {
                "index": i,
                "word": words[i] if i < len(words) else "",
                "start": start_f * RESOLUTION,
                "end": end_f * RESOLUTION,
            }
        )

    total = t_pre + t_align
    print()
    print(f"audio      : {duration:.1f}s")
    print(f"preprocess : {t_pre:.1f}s")
    print(f"align      : {t_align:.1f}s")
    print(f"TOTAL      : {total:.1f}s   ({duration / total:.1f}x realtime)")
    print(f"words      : {len(out)}")
    print()
    print("first 20 words:")
    for w in out[:20]:
        print(f"  {w['index']:3d}  {w['start']:8.2f}s  {w['word']}")

    dest = lyrics_path.replace(".txt", f".{method}.aligned.json")
    with open(dest, "w") as f:
        json.dump(
            {"method": method, "duration": duration, "seconds": total, "words": out}, f, indent=1
        )
    print()
    print(f"wrote {dest}")


if __name__ == "__main__":
    main()
