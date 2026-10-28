#!/usr/bin/env python3
"""Score a call's Speakers against its two tracks, without listening: speech in the system audio is the other side, and
speech only in the microphone is the user's side. Prints each voice's seconds on each side, and how much speech sits
with a voice whose majority is the other side.

  bekitzur speakers --turns mic.m4a system.m4a > turns.txt
  python3 eval/score_call_sides.py mic.m4a system.m4a turns.txt
"""

import audioop
import collections
import math
import re
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

WINDOW = 0.1  # seconds


def levels(audio, folder):
    """dBFS of each window of the track, decoded to 8 kHz mono."""
    decoded = Path(folder) / (Path(audio).stem + ".wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@8000", "-c", "1", audio, str(decoded)], check=True)
    w = wave.open(str(decoded))
    frames = int(w.getframerate() * WINDOW)
    out = []
    while chunk := w.readframes(frames):
        out.append(20 * math.log10(max(audioop.rms(chunk, 2), 1) / 32768))
    return out


def main(microphone, system, turns):
    with tempfile.TemporaryDirectory() as folder:
        mic, sys_ = levels(microphone, folder), levels(system, folder)

    def side(i):
        if i >= len(sys_):
            return None
        if sys_[i] > -40:
            return "other"
        if sys_[i] < -55 and mic[i] > -35:
            return "user"
        return None

    tally = collections.defaultdict(collections.Counter)
    for line in Path(turns).read_text(encoding="utf-8").splitlines():
        if m := re.match(r"^\s*([\d.]+) → \s*([\d.]+)\s+(.+)$", line):
            for i in range(int(float(m[1]) / WINDOW), int(float(m[2]) / WINDOW)):
                tally[m[3].strip()][side(i)] += 1

    mixed = total = 0
    print(f"{'voice':22} {'user':>6} {'other':>6} {'unclear':>8}  (seconds)")
    for voice, c in sorted(tally.items(), key=lambda kv: -sum(kv[1].values())):
        user, other = c["user"] * WINDOW, c["other"] * WINDOW
        print(f"{voice:22} {user:6.0f} {other:6.0f} {c[None] * WINDOW:8.0f}")
        mixed += min(user, other)
        total += user + other
    print(f"speech with a voice from the other side: {mixed:.0f} of {total:.0f} s ({100 * mixed / max(total, 1):.1f}%)")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
