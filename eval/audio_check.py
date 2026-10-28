#!/usr/bin/env python3
"""Turn `bekitzur audio-check` scores into decisions, and score them on the scripted read.

  python3 eval/audio_check.py <transcript.json> <audio-check.json> <vocabulary-rewrites.txt>

The transcript comes from `bekitzur transcribe --json` without --speakers, the scores from `bekitzur audio-check` on that
transcript, and the rewrites from `bekitzur vocabulary` on it. Prints word error rate and English terms for the audio
alone (with a bias added to every English term, since Whisper prefers Hebrew letters for these words), for the
Vocabulary's own choices, and for those choices vetoed when the audio scores them well below the transcribed word; then
the audio scores of right and wrong terms, labeled against the script, and how the audio and the language model choose
between two or more matched terms. Rewritten transcripts go next to the scores file.
"""

import json
import sys
from pathlib import Path

import score_asr
from score_asr import words


def load_rewrites(path):
    """The Vocabulary step decides per spelling: its "transcribed → rewritten" lines."""
    chosen = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if " → " in line:
            before, after = line.split(" → ", 1)
            chosen[before] = after
    return chosen


def reference_of(transcript):
    """For each (segment, word) of the transcript, the script words aligned to it."""
    lines = [t["text"] for t in json.loads((score_asr.ROOT / "reference.json").read_text(encoding="utf-8"))]
    ref = words(" ".join(lines[0:39]))
    hyp, owner = [], []
    for s, segment in enumerate(transcript["segments"]):
        for w, word in enumerate(segment.get("words") or []):
            for token in words(word["text"]):
                hyp.append(token)
                owner.append((s, w))
    n, m = len(ref), len(hyp)
    d = [[i + j if i == 0 or j == 0 else 0 for j in range(m + 1)] for i in range(n + 1)]
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    aligned, i, j = {}, n, m
    while i and j:
        if d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            aligned.setdefault(owner[j - 1], []).insert(0, ref[i - 1])
            i, j = i - 1, j - 1
        elif d[i][j] == d[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return aligned


def english(token):
    return token.isascii() and token[:1].isalpha()


def main():
    transcript = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    checks = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    chosen = load_rewrites(sys.argv[3])
    by_place = {(c["segment"], c["word"]): c for c in checks}
    out_dir = Path(sys.argv[2]).with_suffix("")
    out_dir.mkdir(exist_ok=True)

    def write(name, choose):
        lines = []
        for s, segment in enumerate(transcript["segments"]):
            shown = [w["text"] for w in segment.get("words") or []]
            for w in range(len(shown)):
                if (s, w) in by_place:
                    shown[w] = choose(by_place[(s, w)])
            lines.append(" ".join(shown))
        path = out_dir / f"{name}.txt"
        path.write_text("\n".join(lines), encoding="utf-8")
        return path

    def audio(bias):
        def choose(check):
            original = check["alternatives"][0]
            best = max(check["alternatives"], key=lambda a: a["score"] + (bias if a.get("term") else 0))
            return best["text"] if best["score"] + (bias if best.get("term") else 0) > original["score"] else original["text"]
        return choose

    def vocabulary(veto=None):
        def choose(check):
            original = check["alternatives"][0]
            term = chosen.get(original["text"])
            alternative = next((a for a in check["alternatives"] if a["text"] == term), None)
            if term is None or (veto is not None and alternative and alternative["score"] < original["score"] - veto):
                return original["text"]
            return term
        return choose

    paths = [write("transcribed", lambda c: c["alternatives"][0]["text"])]
    paths += [write(f"audio-bias-{b:02d}", audio(b)) for b in (0, 2, 4, 6, 8, 10, 12, 15)]
    paths += [write("vocabulary", vocabulary())] + [write(f"vocabulary-veto-{t:02d}", vocabulary(t)) for t in (2, 4, 6, 8, 10)]
    for path in paths:
        score_asr.score(path, False)

    aligned = reference_of(transcript)
    rows = []
    for c in checks:
        truth = next((r for r in aligned.get((c["segment"], c["word"]), []) if english(r)), None)
        original = c["alternatives"][0]
        terms = [{"text": a["text"], "delta": a["score"] - original["score"],
                  "right": next((t for t in words(a["text"]) if english(t)), None) == truth}
                 for a in c["alternatives"][1:]]
        rows.append({"original": original["text"], "truth": truth, "terms": terms, "chosen": chosen.get(original["text"])})

    def quartiles(values):
        values = sorted(values)
        return [round(values[int(q * (len(values) - 1))], 1) for q in (0, 0.25, 0.5, 0.75, 1)] if values else []

    print("audio score of a term minus the transcribed word, right terms:", quartiles(t["delta"] for r in rows for t in r["terms"] if t["right"]))
    print("audio score of a term minus the transcribed word, wrong terms:", quartiles(t["delta"] for r in rows for t in r["terms"] if not t["right"]))
    ties = [r for r in rows if len(r["terms"]) > 1 and any(t["right"] for t in r["terms"])]
    by_audio = sum(max(r["terms"], key=lambda t: t["delta"])["right"] for r in ties)
    by_model = sum(any(t["right"] and t["text"] == r["chosen"] for t in r["terms"]) for r in ties)
    print(f"choosing between terms ({len(ties)} words): the audio picks the right one {by_audio}, the language model {by_model}")


if __name__ == "__main__":
    main()
