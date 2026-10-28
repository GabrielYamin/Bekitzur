#!/usr/bin/env python3
"""Split transcription errors in a scripted read into reading deviations and model errors, per reader.

  python3 eval/reader_errors.py <model-a.txt> <model-b.txt> [--last-line N]

Two independently trained models rarely make the same mistake, so where both write the same word that differs
from the script, the reader most likely said that word. Where only model A deviates and model B matches the
script, model A misheard. Only Hebrew script words are judged, so English-term spelling doesn't count here.
"""

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import match_vocab  # noqa: E402
import score_asr  # noqa: E402

HEBREW = re.compile(r"[\u0590-\u05ff]")


def heard_as(term, written):
    """Whether what a model wrote sounds like the English term, in either alphabet."""
    written = written.replace(" ", "")
    if not written:
        return False
    targets = match_vocab.english_sounds(term)
    if HEBREW.search(written):
        candidates = [match_vocab.hebrew_sounds(written[len(p):]) for p in match_vocab.PREFIXES if written.startswith(p)]
    else:
        candidates = list(match_vocab.english_sounds(written))
    best = min(match_vocab.edit_distance(c, t) for c in candidates for t in targets)
    longest = max(len(t) for t in targets)
    return best <= (1 if longest >= 4 else 0)


def alignment(ref, hyp):
    """Edit operations: (op, ref_index, hyp_index) with op in ok, sub, del, ins."""
    d = [[0] * (len(hyp) + 1) for _ in range(len(ref) + 1)]
    for i in range(len(ref) + 1):
        d[i][0] = i
    for j in range(len(hyp) + 1):
        d[0][j] = j
    for i in range(1, len(ref) + 1):
        for j in range(1, len(hyp) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    ops, i, j = [], len(ref), len(hyp)
    while i or j:
        if i and j and d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            ops.append(("ok" if ref[i - 1] == hyp[j - 1] else "sub", i - 1, j - 1))
            i, j = i - 1, j - 1
        elif i and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", i - 1, None))
            i -= 1
        else:
            ops.append(("ins", i - 1 if i else 0, j - 1))
            j -= 1
    return ops[::-1]


def outputs(ops, hyp):
    """What the model wrote for each reference word, and extra words inserted after it."""
    said, extra = defaultdict(list), defaultdict(list)
    for op, ri, hj in ops:
        if op in ("ok", "sub"):
            said[ri].append(hyp[hj])
        elif op == "ins":
            extra[ri].append(hyp[hj])
    return said, extra


def main():
    args = sys.argv[1:]
    last = 38
    if "--last-line" in args:
        k = args.index("--last-line")
        last = int(args[k + 1])
        del args[k:k + 2]
    a_path, b_path = args
    script = json.loads((score_asr.ROOT / "reference.json").read_text(encoding="utf-8"))[:last]
    ref, reader_of = [], []
    for t in script:
        for w in score_asr.words(t["text"]):
            ref.append(w)
            reader_of.append(t["reader"])
    a = score_asr.words(Path(a_path).read_text(encoding="utf-8"))
    b = score_asr.words(Path(b_path).read_text(encoding="utf-8"))
    a_said, a_extra = outputs(alignment(ref, a), a)
    b_said, b_extra = outputs(alignment(ref, b), b)

    stats = defaultdict(lambda: defaultdict(int))
    examples = defaultdict(list)
    terms = defaultdict(lambda: defaultdict(int))
    garbled = defaultdict(list)
    for i, w in enumerate(ref):
        r = reader_of[i]
        if not HEBREW.search(w):
            if re.fullmatch(r"[a-z][a-z0-9]*", w):
                in_a, in_b = heard_as(w, " ".join(a_said[i])), heard_as(w, " ".join(b_said[i]))
                terms[r]["English terms"] += 1
                terms[r]["recognized by ivrit.ai (any alphabet)"] += in_a
                terms[r]["garbled by both models"] += not in_a and not in_b
                terms[r]["garbled by ivrit.ai only"] += not in_a and in_b
                if not in_a:
                    garbled[r].append(f"{w} -> {' '.join(a_said[i]) or '(nothing)'}{'' if in_b else ' (both)'}")
            continue
        stats[r]["hebrew words"] += 1
        got_a, got_b = " ".join(a_said[i]), " ".join(b_said[i])
        if got_a == w:
            continue
        if got_a == got_b:
            stats[r]["reader said it differently (both models agree)"] += 1
            examples[r].append(f"{w} -> {got_a or '(nothing)'}")
        elif got_b == w:
            stats[r]["ivrit.ai misheard (regular Whisper got it)"] += 1
        else:
            stats[r]["unclear (models disagree)"] += 1
    for i in range(len(ref)):
        r = reader_of[i]
        common = [w for w in a_extra[i] if w in b_extra[i]]
        if common:
            stats[r]["extra words in both models (repeats, fillers)"] += len(common)
            examples[r].append(f"+ {' '.join(common)}")

    for r in ("You", "Colleague"):
        s = stats[r]
        n = s["hebrew words"]
        print(f"\n== {r}: {n} Hebrew words")
        for k, v in s.items():
            if k != "hebrew words":
                print(f"  {k}: {v} ({v / n:.1%})")
        print("  examples:", "; ".join(examples[r]))
        t = terms[r]
        n_terms = t["English terms"]
        for k, v in t.items():
            print(f"  {k}: {v}" + ("" if k == "English terms" else f" ({v / max(n_terms, 1):.0%})"))
        print("  not recognized:", "; ".join(garbled[r]))


if __name__ == "__main__":
    main()
