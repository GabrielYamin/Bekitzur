#!/usr/bin/env python3
"""Rewrite English terms that a transcript spells in Hebrew letters back into English letters.

  python3 eval/latinize.py <transcript.txt> [--model gemma4:26b-a4b-it-qat]

Sends only the distinct Hebrew-letter words (not the transcript) to a local model through Ollama, asks which
ones are English terms, and applies the mapping in code. Writes <transcript>.latin.txt next to the input.
"""

import argparse
import json
import re
import time
import urllib.request
from pathlib import Path

PROMPT = """These words come from a Hebrew transcript of an Israeli tech team's meeting. Speech recognition sometimes spells English words in Hebrew letters, for example פייפליין (pipeline), הגייטוויי (ה + gateway), לסטייג'ינג (ל + staging).

For each word below that is an English word, product name, or technical term written in Hebrew letters, return:
- hebrew: the word exactly as given
- prefix: any Hebrew prefix letters attached at the start (ה, ל, ב, מ, ש, ו, כ, or combinations such as וה, שה, כשה), or "" if none
- english: the English spelling, lowercase unless it is a proper name or acronym

Leave out ordinary Hebrew words, including slang and words that take Hebrew suffixes (for example טסטים). If unsure, leave the word out."""

SCHEMA = {
    "type": "object",
    "properties": {
        "terms": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"hebrew": {"type": "string"}, "prefix": {"type": "string"}, "english": {"type": "string"}},
                "required": ["hebrew", "prefix", "english"],
            },
        }
    },
    "required": ["terms"],
}

HEBREW_WORD = re.compile(r"[\u05d0-\u05ea][\u05d0-\u05ea'\"״׳]*")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript")
    parser.add_argument("--model", default="gemma4:26b-a4b-it-qat")
    args = parser.parse_args()

    path = Path(args.transcript)
    text = path.read_text(encoding="utf-8")
    unique = sorted(set(HEBREW_WORD.findall(text)))
    start = time.time()
    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=json.dumps({
            "model": args.model,
            "messages": [{"role": "system", "content": PROMPT}, {"role": "user", "content": "\n".join(unique)}],
            "format": SCHEMA,
            "stream": False,
            "think": False,
            "options": {"temperature": 0, "seed": 42, "num_ctx": 8192, "num_predict": 4096},
        }).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=600) as resp:
        terms = json.loads(json.loads(resp.read())["message"]["content"])["terms"]

    mapping = {}
    for t in terms:
        if t["hebrew"] in unique and t["english"].strip():
            prefix = t["prefix"] if t["hebrew"].startswith(t["prefix"]) else ""
            mapping[t["hebrew"]] = f"{prefix}-{t['english']}" if prefix else t["english"]
    out = HEBREW_WORD.sub(lambda m: mapping.get(m[0], m[0]), text)
    out_path = path.with_suffix(".latin.txt")
    out_path.write_text(out, encoding="utf-8")
    print(f"{len(unique)} distinct Hebrew words, {len(mapping)} mapped in {time.time() - start:.1f}s -> {out_path.name}")
    for k, v in sorted(mapping.items(), key=lambda kv: kv[1]):
        print(f"  {k} -> {v}")


if __name__ == "__main__":
    main()
