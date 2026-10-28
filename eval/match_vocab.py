#!/usr/bin/env python3
"""Rewrite English terms that a transcript spells in Hebrew letters into English letters, using the Vocabulary.

  python3 eval/match_vocab.py [--verify] [--loose] <transcript.txt> [<transcript.txt> ...]

A Hebrew-letter word is rewritten only when its consonant sounds match a Vocabulary term (eval/vocabulary/).
--verify also asks a local model, with the sentence as context, to pick among the matched terms or reject them;
it can never propose a term of its own. --loose (meant for use with --verify) accepts closer-but-inexact matches
and short terms, and also tries pairs of adjacent words for terms that speech recognition splits in two.
Writes <transcript>.vocab[-loose][-verified].txt next to each input.
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

VOCAB_DIR = Path(__file__).resolve().parent / "vocabulary"
# The team's own terms stay on this Mac, out of the repository.
PRIVATE_VOCAB_DIR = Path(__file__).resolve().parent / "private" / "vocabulary"
HEBREW_TOKEN = re.compile(r"[\u05d0-\u05ea][\u05d0-\u05ea'׳\"״]*")
_WORD = r"[\u05d0-\u05ea][\u05d0-\u05ea'׳\"״]*"
# Only hyphenated pairs: the model hyphenates terms it splits (און-קול), and a space-separated pair can absorb a real
# word (העונקו לא matched on-call and swallowed the negation).
HEBREW_PAIR = re.compile(rf"(?<![\u05d0-\u05ea'׳\"״])(?=({_WORD}-{_WORD}))")
PREFIXES = ["", "ה", "ו", "ב", "ל", "מ", "ש", "כ", "וה", "שה", "כשה", "מה", "וב", "ול", "ומ", "וש", "כש", "שב", "שמ"]
HEBREW_SOUNDS = {"ב": "B", "ג": "G", "ד": "D", "ה": "H", "ז": "S", "ח": "H", "ט": "T", "כ": "K", "ל": "L",
                 "מ": "M", "נ": "N", "ס": "S", "פ": "P", "צ": "S", "ק": "K", "ר": "R", "ש": "X", "ת": "T"}
ENGLISH_RULES = [("tion", ["XN"]), ("sion", ["XN"]), ("sch", ["SK", "X"]), ("sh", ["X"]), ("ch", ["C", "K"]),
                 ("ph", ["P"]), ("th", ["T"]), ("ck", ["K"]), ("qu", ["KB", "K"]), ("x", ["KS"]), ("q", ["K"]),
                 ("w", ["B", ""]), ("y", [""]), ("h", ["H", ""]), ("j", ["J"]), ("f", ["P"]), ("v", ["B"]),
                 ("z", ["S"]), ("s", ["S"]), ("b", ["B"]), ("p", ["P"]), ("k", ["K"]), ("d", ["D"]), ("t", ["T"]),
                 ("l", ["L"]), ("m", ["M"]), ("n", ["N"]), ("r", ["R"])]


def hebrew_sounds(word):
    w = word.translate(str.maketrans("ךםןףץ", "כמנפצ")).replace('"', "").replace("״", "")
    w = re.sub("ג['׳]", "J", w)
    w = re.sub("צ['׳]", "C", w)
    w = re.sub("ז['׳]", "J", w)
    w = w.replace("וו", "B")
    w = re.sub("ה$", "", w)
    return "".join(c if c in "JCB" and not "\u05d0" <= c <= "\u05ea" else HEBREW_SOUNDS.get(c, "") for c in w)


def english_sounds(term):
    variants = [""]
    for word in re.findall(r"[a-z]+", term.lower()):
        word = re.sub(r"(.)\1", r"\1", word)
        options, i = [""], 0
        while i < len(word):
            rule = next(((p, o) for p, o in ENGLISH_RULES if len(p) > 1 and word.startswith(p, i)), None)
            if rule:
                outs, step = rule[1], len(rule[0])
            elif word[i] in "cg":
                soft = i + 1 < len(word) and word[i + 1] in "eiy"
                outs = (["S", "K"] if soft else ["K"]) if word[i] == "c" else (["J", "G"] if soft else ["G"])
                step = 1
            else:
                outs, step = next((o for p, o in ENGLISH_RULES if p == word[i]), [""]), 1
            options = [o + x for o in options for x in outs][:64]
            i += step
        variants = [v + o for v in variants for o in options][:64]
    return set(variants)


def edit_distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]


def load_vocabulary(loose=False):
    terms = []
    for path in sorted(VOCAB_DIR.glob("*.txt")) + sorted(PRIVATE_VOCAB_DIR.glob("*.txt")):
        terms += [t.strip() for t in path.read_text(encoding="utf-8").splitlines() if t.strip()]
    return [(t, s) for t in terms for s in english_sounds(t) if len(s) >= (2 if loose else 3)]


def match(unit, vocabulary, loose=False):
    """Every (prefix, term) this Hebrew-letter word or word pair sounds like at the closest distance; empty if none.

    Word pairs must match exactly: two ordinary words joined together often land near some term."""
    hits = []
    near = 99 if re.search(r"[ -]", unit) else 4 if loose else 5
    for prefix in PREFIXES:
        if not unit.startswith(prefix) or len(unit) - len(prefix) < 2:
            continue
        sounds = hebrew_sounds(re.sub(r"[ -]", "", unit[len(prefix):]))
        if len(sounds) < (2 if loose else 3):
            continue
        for term, term_sounds in vocabulary:
            d = edit_distance(sounds, term_sounds)
            if d <= (1 if len(term_sounds) >= near else 0):
                hits.append((d, len(prefix), prefix, term))
    if not hits:
        return []
    # On a tie, keep the longest prefix so a real conjunction or article (ו, ה) isn't dropped.
    best = min((d, -n) for d, n, _, _ in hits)
    return sorted({(p, t) for d, n, p, t in hits if (d, -n) == best})


VERIFY_PROMPT = ("Each item has one or two Hebrew words from a speech transcript of an Israeli tech meeting, the text around "
                 "them, and candidate English terms. If the Hebrew words are one of the candidates spelled in Hebrew letters "
                 "(possibly with a Hebrew prefix such as ה or ל), answer with that candidate exactly. If they are ordinary "
                 "Hebrew words or none of the candidates, answer none. Repeat each item's hebrew_word in your answer.")
VERIFY_SCHEMA = {"type": "object", "properties": {"answers": {"type": "array", "items": {"type": "object", "properties": {
    "id": {"type": "integer"}, "hebrew_word": {"type": "string"}, "term": {"type": "string"}},
    "required": ["id", "hebrew_word", "term"]}}}, "required": ["answers"]}
VERIFY_CTX = 8192


def context_of(word, text, width=60):
    i = text.find(word)
    window = text[max(0, i - width): i + len(word) + width]
    return re.sub(r"^\S*\s|\s\S*$", "", window).strip()


def verify(candidates, text, model="gemma4:26b-a4b-it-qat", batch=20):
    """Ask the model to pick one of each word's candidate terms, or none. It can't add terms.

    Each item carries only nearby text and items go in small batches, so a request can't overflow the context;
    an answer counts only if it echoes the right word, so a misaligned id can't apply a term to the wrong word."""
    chosen = {}
    for start in range(0, len(candidates), batch):
        items = [{"id": k, "hebrew_word": w, "context": context_of(w, text), "candidates": [t for _, t in options]}
                 for k, (w, options) in enumerate(candidates[start:start + batch], start)]
        request = urllib.request.Request("http://127.0.0.1:11434/api/chat", headers={"Content-Type": "application/json"}, data=json.dumps({
            "model": model, "stream": False, "think": False, "format": VERIFY_SCHEMA,
            "options": {"temperature": 0, "seed": 42, "num_ctx": VERIFY_CTX, "num_predict": 2048},
            "messages": [{"role": "system", "content": VERIFY_PROMPT}, {"role": "user", "content": json.dumps(items, ensure_ascii=False)}],
        }).encode())
        with urllib.request.urlopen(request, timeout=600) as resp:
            body = json.loads(resp.read())
        if body.get("prompt_eval_count", 0) >= VERIFY_CTX - 64:
            raise RuntimeError(f"verifier input was truncated ({body['prompt_eval_count']} tokens)")
        for a in json.loads(body["message"]["content"])["answers"]:
            if start <= a["id"] < start + len(items) and candidates[a["id"]][0] == a["hebrew_word"]:
                word, options = candidates[a["id"]]
                chosen.update({word: (p, t) for p, t in options if t == a["term"]})
    return list(chosen.items())


def rewrite(text, units, vocabulary, check, loose):
    candidates = [(u, m) for u in sorted(set(units)) if (m := match(u, vocabulary, loose))]
    if not candidates:
        return text, {}, []
    accepted = verify(candidates, text) if check else [(u, m[0]) for u, m in candidates if len(m) == 1]
    mapping = {u: (f"{p}-{t}" if p else t) for u, (p, t) in accepted}
    for unit, replacement in sorted(mapping.items(), key=lambda kv: -len(kv[0])):
        text = re.sub(rf"(?<![\u05d0-\u05ea'׳\"״]){re.escape(unit)}(?![\u05d0-\u05ea'׳\"״])", replacement, text)
    return text, mapping, sorted(set(u for u, _ in candidates) - set(mapping))


def main():
    args = sys.argv[1:]
    check, loose = "--verify" in args, "--loose" in args
    vocabulary = load_vocabulary(loose)
    for name in [a for a in args if not a.startswith("--")]:
        path = Path(name)
        text = path.read_text(encoding="utf-8")
        mapping, rejected = {}, []
        if loose:
            text, pairs, skipped = rewrite(text, HEBREW_PAIR.findall(text), vocabulary, check, loose)
            mapping.update(pairs)
            rejected += skipped
        text, words, skipped = rewrite(text, HEBREW_TOKEN.findall(text), vocabulary, check, loose)
        mapping.update(words)
        rejected += skipped
        out_path = path.with_suffix(".vocab" + ("-loose" if loose else "") + ("-verified" if check else "") + ".txt")
        out_path.write_text(text, encoding="utf-8")
        print(f"{path.name}: {len(mapping)} applied -> {out_path.name}")
        print("  applied:", ", ".join(f"{u}->{v}" for u, v in sorted(mapping.items(), key=lambda kv: kv[1])))
        if rejected:
            print("  matched but not applied:", ", ".join(rejected))


if __name__ == "__main__":
    main()
