#!/usr/bin/env python3
"""Score transcripts of a scripted read against the text that was read.

  python3 eval/score_asr.py [--terms] <transcript.txt> [<transcript.txt> ...]

Finds the run of script lines (or the voice-sample paragraph) that best matches each transcript, then
reports word error rate and how many English terms came out in English letters. --terms also lists
what each English term turned into.
"""

import json
import re
import sys
from pathlib import Path

# The scripted read stays on this Mac, out of the repository.
ROOT = Path(__file__).resolve().parent / "private" / "scripted-read"
HEBREW = r"\u0590-\u05ff"


def words(text):
    text = re.sub(r"\([^)]*\)|[\u200e\u200f\u202a-\u202e]", " ", text)
    text = re.sub(r"\[\d\d:\d\d:\d\d\.\d+ --> \d\d:\d\d:\d\d\.\d+\]", " ", text)
    # Abbreviation marks (סופ"ש) are part of the word; a hyphenated prefix on an English term (ה-release) is
    # scored with the term, so a term written in Hebrew letters (הרליז) counts as one error, not two.
    text = re.sub(rf"(?<=[{HEBREW}])[\"״](?=[{HEBREW}])", "", text)
    text = re.sub(rf"(?<![{HEBREW}])[ובלמהשכ]{{1,3}}-(?=[A-Za-z])", "", text)
    text = re.sub(rf"(?<=[{HEBREW}])-?(?=[A-Za-z0-9])|(?<=[A-Za-z0-9])-?(?=[{HEBREW}])", " ", text)
    text = re.sub(r"[.,?!:;\"'״׳”“\-–]", " ", text)
    return text.lower().split()


def best_window(lines, hyp):
    """Edit distance of every run of whole lines against the transcript, one DP pass per start line."""
    best = None
    for start in range(len(lines)):
        ref, ends = [], []
        for i in range(start, len(lines)):
            ref += words(lines[i])
            ends.append((i, len(ref)))
        prev = list(range(len(hyp) + 1))
        dist_at = {0: prev[-1]}
        for r, w in enumerate(ref, 1):
            row = [r] + [0] * len(hyp)
            for j, h in enumerate(hyp, 1):
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (w != h))
            prev = row
            dist_at[r] = row[-1]
        for end, n in ends:
            wer = dist_at[n] / n
            if best is None or wer < best[0]:
                best = (wer, start, end)
    return best


def align(ref, hyp):
    """For each reference word, the transcript words aligned to it (empty if deleted)."""
    d = [[0] * (len(hyp) + 1) for _ in range(len(ref) + 1)]
    for i in range(len(ref) + 1):
        d[i][0] = i
    for j in range(len(hyp) + 1):
        d[0][j] = j
    for i in range(1, len(ref) + 1):
        for j in range(1, len(hyp) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    out, i, j = [[] for _ in ref], len(ref), len(hyp)
    while i or j:
        if i and j and d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            out[i - 1].insert(0, hyp[j - 1])
            i, j = i - 1, j - 1
        elif i and d[i][j] == d[i - 1][j] + 1:
            i -= 1
        else:
            out[max(i - 1, 0)].insert(0, hyp[j - 1])
            j -= 1
    return out


def score(path, show_terms):
    hyp_text = Path(path).read_text(encoding="utf-8")
    hyp = words(hyp_text)
    lines = [t["text"] for t in json.loads((ROOT / "reference.json").read_text(encoding="utf-8"))]
    wer, start, end = best_window(lines, hyp)
    label, ref_text = f"script lines {start + 1}-{end + 1}", " ".join(lines[start:end + 1])
    sample = (ROOT / "enrollment.md").read_text(encoding="utf-8")
    sample = re.sub(r"<[^>]+>", "", sample).strip().splitlines()[-1].replace("___", "")
    sample_wer = best_window([sample], hyp)[0]
    if sample_wer < wer:
        wer, label, ref_text = sample_wer, "voice-sample paragraph", sample
    ref = words(ref_text)
    aligned = align(ref, hyp)
    terms = [(w, aligned[k]) for k, w in enumerate(ref) if re.fullmatch(r"[a-z][a-z0-9]*", w)]
    kept = sum(1 for w, got in terms if w in got)
    hebrew = [k for k, w in enumerate(ref) if re.search(rf"[{HEBREW}]", w)]
    hebrew_right = sum(1 for k in hebrew if ref[k] in aligned[k]) / max(len(hebrew), 1)
    print(f"{Path(path).name:40} {label:24} words {len(ref):4}  WER {wer:6.1%}  "
          f"Hebrew words right {hebrew_right:6.1%}  English letters {kept}/{len(terms)}")
    if show_terms:
        for w, got in terms:
            print(f"    {'ok  ' if w in got else 'MISS'} {w:14} -> {' '.join(got) or '(dropped)'}")


if __name__ == "__main__":
    args = sys.argv[1:]
    show = "--terms" in args
    for p in [a for a in args if a != "--terms"]:
        score(p, show)
