#!/usr/bin/env python3
"""Ask every question in questions.json about its transcript, each in a chat of its own, and print the answers next
to what's expected, for a reviewer to read.

  swift build -c release --product bekitzur
  python3 spikes/ask-eval/run.py
"""

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    spec = json.loads((Path(__file__).parent / "questions.json").read_text(encoding="utf-8"))
    for q in spec["questions"]:
        # A run of its own for each question: in one run, every chat after the first is given the earlier answers.
        run = subprocess.run(
            [str(ROOT / ".build/release/bekitzur"), "ask", str(ROOT / spec["transcript"]), q["question"]],
            capture_output=True, text=True, check=True,
        )
        print(f"[{q['kind']}] {q['question']}")
        print(f"  expected: {q['expected']}")
        for line in run.stdout.splitlines()[1:]:
            print(f"  {line}")
        print(flush=True)


if __name__ == "__main__":
    main()
