#!/usr/bin/env python3
"""Score Speaker attribution in an engine Transcript of the scripted read.

  python3 eval/score_attribution.py <reference-whisper.json> <engine-transcript.json> <name>=<reader> ...

Ground truth is who read each script line, timed by aligning an independent whisper.cpp transcript (with its own
segment timings) to the script. Each reader is "you" or "colleague"; map each Speaker name to one, for example
Omer=you Colleague=colleague.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score_speakers  # noqa: E402


def main():
    reference, engine, *mapping = sys.argv[1:]
    readers = dict(m.split("=", 1) for m in mapping)
    truth = score_speakers.ground_truth(reference)
    segments = json.loads(Path(engine).read_text(encoding="utf-8"))["segments"]
    total = right = 0.0
    for t0, t1, reader in truth:
        for s in segments:
            shared = min(t1, s["end"]) - max(t0, s["start"])
            if shared > 0:
                total += shared
                right += shared * (readers.get(s.get("speaker")) == reader)
    print(f"{Path(engine).name}: {right / total:.1%} of {total:.0f} s of speech attributed to the right reader")


if __name__ == "__main__":
    main()
