#!/usr/bin/env python3
"""Candidates for English terms from a second Whisper run forced to English, with no term list.

  python3 eval/english_run.py <transcript.json> <english.json> <audio-check.json> [--script] [--write <out.txt>]

english.json is whisper-cli's JSON (-oj) from plain Whisper turbo run with -l en on the same audio: turbo ignores the
translate task, but forced to English it writes a rough translation that keeps English terms in English. For each
Hebrew-letter word of the ivrit.ai transcript, the English words written within 3 seconds of it are the candidates, and
one that sounds like the word (the Vocabulary's sound rules) is proposed. The audio-check file supplies the
Vocabulary's own candidates for comparison. With --script, words are labeled against the scripted read; --write
writes the transcript with every word that has exactly one proposal rewritten to it.
"""

import json
import re
import sys
from pathlib import Path

from audio_check import english, reference_of
from match_vocab import english_sounds, match
from score_asr import words

COMMON = set("""a about after again all also am an and any are as at be because been before being but by can could did
do does doing done down each even every few for from get gets getting go goes going gone good got had has have having he
her here him his how i if in into is it its just know let like made make many may me more most much must my need no not
now of off ok okay on once one only or other our out over own really right said same say see she should so some still
such take than that the their them then there these they thing think this those through time to too two under up us
very want was way we well were what when where which while who why will with would yes yet you your""".split())
HEBREW_UNIT = re.compile(r"[\u05d0-\u05ea][\u05d0-\u05ea'׳\"״]*")


def english_words(path):
    """(start, end, word) for the English run's uncommon words, by segment time."""
    found = []
    for segment in json.loads(Path(path).read_text(encoding="utf-8"))["transcription"]:
        for w in re.findall(r"[A-Za-z][A-Za-z0-9\-]*", segment["text"]):
            if w.lower() not in COMMON and len(w) >= 3:
                found.append((segment["offsets"]["from"] / 1000, segment["offsets"]["to"] / 1000, w))
    return found


def proposals(word, english, window=3.0):
    unit = HEBREW_UNIT.search(word["text"])
    if not unit:
        return unit, []
    near = {w for start, end, w in english if start - window <= word["start"] <= end + window}
    return unit, match(unit.group(0), [(t, s) for t in near for s in english_sounds(t) if len(s) >= 2], loose=True)


def term_of(text):
    return next((t for t in words(text) if english(t)), "")


def main():
    args = sys.argv[1:]
    out = args[args.index("--write") + 1] if "--write" in args else None
    script = "--script" in args
    paths = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--write")]
    transcript = json.loads(Path(paths[0]).read_text(encoding="utf-8"))
    english_run = english_words(paths[1])
    vocabulary = {(c["segment"], c["word"]): [a["text"] for a in c["alternatives"][1:]]
                  for c in json.loads(Path(paths[2]).read_text(encoding="utf-8"))}
    aligned = reference_of(transcript) if script else {}

    counts = {"said English": 0, "right from the Vocabulary": 0, "right from the English run": 0, "said Hebrew": 0,
              "Vocabulary candidate for a Hebrew word": 0, "English-run candidate for a Hebrew word": 0}
    rows = {"same": [], "different": [], "only the English run": []}
    lines = []
    for s, segment in enumerate(transcript["segments"]):
        shown = []
        for w, word in enumerate(segment.get("words") or []):
            unit, proposed = proposals(word, english_run)
            candidates = vocabulary.get((s, w), [])
            if unit and script:
                truth = next((r for r in aligned.get((s, w), []) if english(r)), None)
                if truth:
                    counts["said English"] += 1
                    counts["right from the Vocabulary"] += any(term_of(c).rstrip("s") == truth.rstrip("s") for c in candidates)
                    counts["right from the English run"] += any(t.lower().rstrip("s") == truth.rstrip("s") for _, t in proposed)
                else:
                    counts["said Hebrew"] += 1
                    counts["Vocabulary candidate for a Hebrew word"] += bool(candidates)
                    counts["English-run candidate for a Hebrew word"] += bool(proposed)
            elif proposed:
                line = f'{word["start"]:7.1f} {word["text"]:14} English run: {", ".join(sorted({t for _, t in proposed})):24}' \
                       f' Vocabulary: {", ".join(candidates) or "-"}'
                if not candidates:
                    rows["only the English run"].append(line)
                else:
                    same = {term_of(c) for c in candidates} & {t.lower() for _, t in proposed}
                    rows["same" if same else "different"].append(line)
            if unit and len({t.lower() for _, t in proposed}) == 1:
                prefix, term = proposed[0]
                shown.append(word["text"].replace(unit.group(0), f"{prefix}-{term}" if prefix else term, 1))
            else:
                shown.append(word["text"])
        lines.append(" ".join(shown))

    if script:
        print("; ".join(f"{k}: {v}" for k, v in counts.items()))
    else:
        print("; ".join(f"{k}: {len(v)}" for k, v in rows.items()))
        for title in ("different", "only the English run"):
            print(f"== {title}\n" + "\n".join(rows[title]))
    if out:
        Path(out).write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
