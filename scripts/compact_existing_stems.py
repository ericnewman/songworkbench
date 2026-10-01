"""Rewrite the library's existing 32-bit float stems as 16-bit PCM, like new stems
(`StemWAVCompaction`). A stem that peaks above full scale stays float: 16-bit would clip it.

Quit SongWorkbench first. Run once; already-converted files are skipped.
"""

import os
import struct
import subprocess
import sys
import uuid

import numpy as np

STEMS = os.path.expanduser(
    "~/Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/"
    "SongWorkbench/Analysis/Stems"
)


def float_peak(path):
    """Peak magnitude of a 32-bit float WAV; None for any other format."""
    with open(path, "rb") as f:
        f.read(12)
        is_float = False
        while True:
            header = f.read(8)
            if len(header) < 8:
                return None
            chunk, size = header[:4], struct.unpack("<I", header[4:])[0]
            if chunk == b"fmt ":
                tag, _, _, _, _, bits = struct.unpack("<HHIIHH", f.read(size + (size & 1))[:16])
                is_float = (tag, bits) == (3, 32) or (tag == 0xFFFE and bits == 32)
            elif chunk == b"data":
                if not is_float:
                    return None
                return float(np.abs(np.fromfile(f, "<f4", size // 4)).max())
            else:
                f.seek(size + (size & 1), 1)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else STEMS
    before = after = converted = kept = 0
    failed = []
    for directory, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".wav") or name.startswith("."):
                continue
            path = os.path.join(directory, name)
            size = os.path.getsize(path)
            before += size
            peak = float_peak(path)
            if peak is None or peak > 1:
                kept += 1
                after += size
                continue
            temporary = os.path.join(directory, f".{uuid.uuid4().hex}.wav")
            result = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16", path, temporary])
            if result.returncode != 0:
                if os.path.exists(temporary):
                    os.remove(temporary)
                failed.append(path)
                kept += 1
                after += size
                continue
            os.replace(temporary, path)
            converted += 1
            after += os.path.getsize(path)
    print(f"converted {converted}, left as is {kept}: {before / 1e9:.1f} GB -> {after / 1e9:.1f} GB")
    for path in failed:
        print(f"could not convert (left as float): {path}")


if __name__ == "__main__":
    main()
