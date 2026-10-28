#!/usr/bin/env python3
"""Score local LLMs (served by Ollama) on writing Notes from Conversation transcripts.

  python3 bakeoff.py run --model gemma4:26b-a4b-it-qat [--think] [--only t1,t3]
  python3 bakeoff.py score results/<run-dir>
"""

import argparse
import copy
import json
import random
import re
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TRANSCRIPTS = ROOT / "transcripts"
KEYS = ROOT / "answer-keys"
RESULTS = ROOT / "results"
OLLAMA = "http://127.0.0.1:11434"

TURN_RE = re.compile(r"^\[T(\d+)\]\s+([^:]+):\s*(.*)$")

SYSTEM_PROMPT = """You are the note-taker for a recorded work conversation. You get a transcript with numbered speaker turns like [T012]. Speakers are either named people or unnamed voices such as "Speaker 5".

Write the Notes in English, even when the conversation is in Hebrew. Keep quotes verbatim in the transcript's original language.

Extract:
- title: a short title for the conversation.
- summary: 3 to 6 sentences.
- decisions: conclusions the participants actually reached. If a decision changed during the conversation, report only the final version.
- action_items: concrete commitments or assignments. For each: what needs doing, the owner, and the due date.
  - The owner is the person who will do it. If a speaker commits ("I'll do it"), the owner is that speaker's label exactly as written in the transcript, even if it is "Speaker 5". If the group assigns it to someone by name, the owner is that person, even if they are not in the conversation. Use null if nobody took it.
  - Resolve relative dates ("tomorrow", "by Thursday", "next Monday") against the conversation date. The Israeli work week starts on Sunday. Use YYYY-MM-DD, or null if no date was given.
  - Leave out hypothetical ideas, jokes, things already done, offers nobody accepted, vague suggestions nobody took on, and anything cancelled later in the conversation.
- open_questions: questions that were raised and left unresolved.

For every decision, action item, and open question, give the turn IDs where it was established (for example "T012"). For decisions and action items, also give a short verbatim quote from those turns. Never add anything that is not in the transcript."""

# v2 adds an explicit owner rule for relayed requests and a calendar in the user message for date resolution.
SYSTEM_PROMPT_V2 = SYSTEM_PROMPT.replace(
    "Use null if nobody took it.",
    "If someone asks or arranges for another person to do the work, the owner is the person doing the work, not the person passing on the request. Use null if nobody took it.",
).replace(
    "Resolve relative dates (\"tomorrow\", \"by Thursday\", \"next Monday\") against the conversation date. The Israeli work week starts on Sunday.",
    "Resolve relative dates (\"tomorrow\", \"by Thursday\", \"next Monday\") with the calendar given before the transcript. Look the date up in the calendar; do not calculate it. The Israeli work week starts on Sunday.",
)
PROMPTS = {"v1": SYSTEM_PROMPT, "v2": SYSTEM_PROMPT_V2}
HEBREW_WEEKDAYS = ["שני", "שלישי", "רביעי", "חמישי", "שישי", "שבת", "ראשון"]

_TURN_IDS = {"type": "array", "items": {"type": "string"}}
NOTES_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        "summary": {"type": "string"},
        "decisions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "source_turns": _TURN_IDS, "quote": {"type": "string"}},
                "required": ["text", "source_turns", "quote"],
            },
        },
        "action_items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "owner": {"type": ["string", "null"]},
                    "due_date": {"type": ["string", "null"]},
                    "source_turns": _TURN_IDS,
                    "quote": {"type": "string"},
                },
                "required": ["text", "owner", "due_date", "source_turns", "quote"],
            },
        },
        "open_questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "source_turns": _TURN_IDS},
                "required": ["text", "source_turns"],
            },
        },
    },
    "required": ["title", "summary", "decisions", "action_items", "open_questions"],
}


@dataclass
class Turn:
    id: int
    speaker: str
    text: str


@dataclass
class Case:
    name: str
    meta: dict
    turns: list
    key: dict


def load_case(name):
    meta, turns = {}, []
    for line in (TRANSCRIPTS / f"{name}.txt").read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            k, _, v = line[1:].partition(":")
            meta[k.strip()] = v.strip()
        elif m := TURN_RE.match(line):
            turns.append(Turn(int(m[1]), m[2].strip(), m[3].strip()))
    key = json.loads((KEYS / f"{name}.json").read_text(encoding="utf-8"))
    return Case(name, meta, turns, key)


# Every other occurrence is spelled in Hebrew letters, the way speech recognition sometimes writes English terms.
TRANSLITERATIONS = {
    "release calendar": "ריליס קלנדר",
    "release": "ריליס",
    "regression": "רגרסיה",
    "flaky test": "פלייקי טסט",
    "retry logic": "ריטריי לוג'יק",
    "gateway": "גייטוויי",
    "runbook": "ראנבוק",
    "design doc": "דיזיין דוק",
    "dashboard": "דשבורד",
    "pipeline": "פייפליין",
    "on-call": "און קול",
    "escalation": "אסקלציה",
    "migration": "מיגרציה",
    "login": "לוגין",
    "session": "סשן",
    "alert": "אלרט",
}
MISLABELED_TURNS = {3: "Dana", 49: "Noa"}


def noisy_variant(case):
    terms = sorted(TRANSLITERATIONS, key=len, reverse=True)
    pattern = re.compile(r"(?:([\u05d0-\u05ea]{1,3})-)?(" + "|".join(map(re.escape, terms)) + r")", re.IGNORECASE)
    seen = {}

    def transliterate(m):
        term = m[2].lower()
        seen[term] = seen.get(term, 0) + 1
        if seen[term] % 2 == 0:
            return m[0]
        return (m[1] or "") + TRANSLITERATIONS[term]

    turns = []
    for t in case.turns:
        text = re.sub(r"\([^)]*\)\s*", "", t.text)
        text = pattern.sub(transliterate, text)
        text = re.sub(r"[.,?!:;\"״]", "", text)
        turns.append(Turn(t.id, MISLABELED_TURNS.get(t.id, t.speaker), text))
    return Case("t4-hebrew-team-sync-noisy", case.meta, turns, copy.deepcopy(case.key))


FILLER_COMPONENTS = [
    "ה-API של ה-search", "ה-worker של ה-notifications", "ה-cluster ב-staging", "ה-auth service",
    "ה-billing service", "ה-cache של ה-sessions", "ה-queue של ה-events", "ה-pipeline של ה-reports",
    "ה-cron jobs של הלילה", "ה-service של ה-exports", "ה-ingress controller", "ה-feature flags service",
]
FILLER_OBSERVATIONS = [
    "היה יציב כל השבוע, לא ראיתי שום חריגה",
    "רץ עם latency של בערך {n} מילישניות ב-p95",
    "צרך בערך {n} אחוז CPU בשעות העומס",
    "עבר לגרסה החדשה בלי תקלות",
    "הוציא כמה warnings ישנים בלוגים, שום דבר חדש",
    "התנהג טוב גם כשהעומס עלה ביום שלישי שעבר",
    "קיבל patch קטן בשבוע שעבר והכל עבר חלק",
    "מראה ירידה של {n} אחוז ב-errors מאז ה-hotfix האחרון",
]
FILLER_PATTERNS = ["רק עדכון קטן: {c} {o}.", "לגבי {c}, {o}.", "ראיתי ש{c} {o}."]
FILLER_ACKS = ["כן, ראיתי את זה גם.", "מעניין, תודה.", "אוקיי, טוב לדעת.", "יפה.", "זה מסתדר עם מה שראיתי ב-dashboard.", "מעולה.", "טוב, זה מרגיע."]
FILLER_SPEAKERS = ["Dana", "Amir", "Noa", "Speaker 5"]
FILLER_AFTER_TURNS = [4, 16, 23, 37, 49, 54, 59]


def long_variant(case, blocks_per_gap=35):
    rng = random.Random(7)
    turns, new_id = [], {}

    def add(speaker, text):
        turns.append(Turn(len(turns) + 1, speaker, text))

    for t in case.turns:
        add(t.speaker, t.text)
        new_id[t.id] = len(turns)
        if t.id in FILLER_AFTER_TURNS:
            for _ in range(blocks_per_gap):
                speaker = rng.choice(FILLER_SPEAKERS)
                observation = rng.choice(FILLER_OBSERVATIONS).format(n=rng.randint(5, 95))
                add(speaker, rng.choice(FILLER_PATTERNS).format(c=rng.choice(FILLER_COMPONENTS), o=observation))
                add(rng.choice([s for s in FILLER_SPEAKERS if s != speaker]), rng.choice(FILLER_ACKS))

    key = copy.deepcopy(case.key)
    for section in ("decisions", "action_items", "open_questions", "borderline", "traps"):
        for item in key.get(section, []):
            item["turns"] = [new_id[i] for i in item["turns"]]
            item["also_turns"] = [new_id[i] for i in item.get("also_turns", [])]
    return Case("t5-hebrew-team-sync-long", case.meta, turns, key)


def build_cases():
    t1 = load_case("t1-hebrew-team-sync")
    cases = [t1, load_case("t2-english-one-on-one"), load_case("t3-hebrew-switches-to-english"), noisy_variant(t1), long_variant(t1)]
    generated = TRANSCRIPTS / "generated"
    generated.mkdir(exist_ok=True)
    for case in cases[3:]:
        header = "".join(f"# {k}: {v}\n" for k, v in case.meta.items())
        body = "".join(f"[T{t.id:03d}] {t.speaker}: {t.text}\n" for t in case.turns)
        (generated / f"{case.name}.txt").write_text(header + body, encoding="utf-8")
        (generated / f"{case.name}.json").write_text(json.dumps(case.key, ensure_ascii=False, indent=2), encoding="utf-8")
    return cases


def render_calendar(start, days=14):
    first = date.fromisoformat(start)
    rows = []
    for i in range(days):
        d = first + timedelta(days=i)
        note = {0: " (today, the conversation date)", 1: " (tomorrow)"}.get(i, "")
        rows.append(f"{d.isoformat()} {d.strftime('%A')} / יום {HEBREW_WEEKDAYS[d.weekday()]}{note}")
    return "\n".join(rows)


def render_transcript(case, prompt="v1"):
    lines = "\n".join(f"[T{t.id:03d}] {t.speaker}: {t.text}" for t in case.turns)
    calendar = f"Calendar:\n{render_calendar(case.meta['date'])}\n\n" if prompt == "v2" else ""
    return (
        f"Conversation date: {case.meta['date']} ({case.meta['weekday']})\n"
        f"Language: {case.meta['language']}\n\n"
        f"{calendar}"
        f"Transcript:\n{lines}"
    )


def post(path, payload, timeout=1800):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def chat(model, case, think, num_ctx, prompt, max_tokens):
    return post("/api/chat", {
        "model": model,
        "messages": [{"role": "system", "content": PROMPTS[prompt]}, {"role": "user", "content": render_transcript(case, prompt)}],
        "format": NOTES_SCHEMA,
        "think": think,
        "stream": False,
        "keep_alive": "15m",
        "options": {"temperature": 0, "seed": 42, "num_ctx": num_ctx, "num_predict": max_tokens},
    })


def loaded_memory():
    """Ollama's /api/ps size leaves out the memory-mapped weights, so measure the llama-server runner directly."""
    try:
        pid = subprocess.run(["pgrep", "-f", "llama-server --model"], capture_output=True, text=True).stdout.split()[0]
        command = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        weights = Path(re.search(r"--model (\S+)", command)[1]).stat().st_size / 1e9
        footprint = subprocess.run(["footprint", "-p", pid], capture_output=True, text=True).stdout
        amount, unit = re.search(r"phys_footprint:\s+([\d.]+)\s+(MB|GB)", footprint).groups()
        runtime = float(amount) / (1000 if unit == "MB" else 1)
    except (IndexError, TypeError, AttributeError, OSError, ValueError):
        return None
    return {"weights_gb": round(weights, 1), "runtime_gb": round(runtime, 1), "total_gb": round(weights + runtime, 1)}


def turn_ids(values):
    ids = set()
    for v in values or []:
        ids.update(int(n) for n in re.findall(r"\d+", str(v)))
    return ids


def normalize(value):
    if value is None:
        return None
    s = str(value).strip().lower()
    return None if s in ("", "null", "none", "unassigned", "n/a", "unknown") else s


def owner_ok(key_item, owner):
    o = normalize(owner)
    return o is not None and any(o == alias or alias in o for alias in key_item["owner"])


def due_ok(spec, value):
    v = normalize(value)
    if spec.get("any"):
        return True
    if v is None:
        return spec.get("null", False) or spec.get("null_ok", False)
    if "date" in spec:
        return v == spec["date"]
    if "range" in spec:
        return spec["range"][0] <= v <= spec["range"][1]
    return False


def match(key_items, items, with_owner):
    matches, used = {}, set()
    passes = [(0, True), (0, False), (1, True), (1, False)] if with_owner else [(0, False), (1, False)]
    for tolerance, need_owner in passes:
        for k in key_items:
            if k["id"] in matches:
                continue
            wanted = set(k["turns"]) | set(k.get("also_turns", []))
            if tolerance:
                wanted = {t + d for t in wanted for d in (-1, 0, 1)}
            best, best_overlap = None, 0
            for i, item in enumerate(items):
                if i in used or (need_owner and not owner_ok(k, item.get("owner"))):
                    continue
                overlap = len(wanted & turn_ids(item.get("source_turns")))
                if overlap > best_overlap:
                    best, best_overlap = i, overlap
            if best is not None:
                matches[k["id"]] = best
                used.add(best)
    return matches, used


def classify_unmatched(item, key, kind):
    ids = turn_ids(item.get("source_turns"))
    for b in key.get("borderline", []):
        if b["kind"] == kind and ids & set(b["turns"]):
            return "borderline", b["label"]
    for t in key.get("traps", []):
        if t["kind"] == kind and ids & set(t["turns"]):
            return "trap", t["label"]
    return "extra", item.get("text", "")


def quote_grounded(item, text_by_turn):
    words = lambda s: re.findall(r"[\w'\-]+", s.lower())
    quote = words(item.get("quote") or "")
    source = set(words(" ".join(text_by_turn.get(i, "") for i in turn_ids(item.get("source_turns")))))
    return bool(quote) and sum(w in source for w in quote) / len(quote) >= 0.8


def score_case(case, notes):
    key, text_by_turn = case.key, {t.id: t.text for t in case.turns}
    card = {}
    for section, kind, with_owner in (("action_items", "action_item", True), ("decisions", "decision", False), ("open_questions", "open_question", False)):
        items = notes.get(section) or []
        expected = key.get(section, [])
        matches, used = match(expected, items, with_owner)
        required = [k for k in expected if not k.get("optional")]
        s = {
            "expected": len(required),
            "found": sum(1 for k in required if k["id"] in matches),
            "missed": [k["label"] for k in required if k["id"] not in matches],
            "trap": [], "borderline": [], "extra": [],
        }
        if with_owner:
            s["owner_ok"], s["due_ok"], s["wrong"] = 0, 0, []
            for k in expected:
                if k["id"] not in matches:
                    continue
                item = items[matches[k["id"]]]
                o, d = owner_ok(k, item.get("owner")), due_ok(k["due"], item.get("due_date"))
                s["owner_ok"] += o
                s["due_ok"] += d
                if not (o and d):
                    s["wrong"].append(f"{k['id']} {k['label']} -> owner={item.get('owner')!r} due={item.get('due_date')!r}")
            s["matched_total"] = len(matches)
        for i, item in enumerate(items):
            if i not in used:
                bucket, label = classify_unmatched(item, key, kind)
                s[bucket].append(label)
        card[section] = s
    quoted = (notes.get("decisions") or []) + (notes.get("action_items") or [])
    card["quotes_grounded"] = f"{sum(quote_grounded(i, text_by_turn) for i in quoted)}/{len(quoted)}"
    return card


def timing(record):
    r = record["response"]
    ns = 1e9
    prompt_s = r.get("prompt_eval_duration", 0) / ns
    gen_s = r.get("eval_duration", 0) / ns
    return {
        "prompt_tokens": r.get("prompt_eval_count", 0),
        "prefill_tps": round(r.get("prompt_eval_count", 0) / prompt_s) if prompt_s else None,
        "gen_tokens": r.get("eval_count", 0),
        "gen_tps": round(r.get("eval_count", 0) / gen_s, 1) if gen_s else None,
        "load_s": round(r.get("load_duration", 0) / ns, 1),
        "wall_s": round(record["wall_s"], 1),
    }


def score_dir(run_dir):
    cases = {c.name: c for c in build_cases()}
    rows, details = [], []
    for path in sorted(Path(run_dir).glob("t*.json")):
        record = json.loads(path.read_text(encoding="utf-8"))
        case = cases[record["case"]]
        try:
            notes = json.loads(record["response"]["message"]["content"])
        except (KeyError, json.JSONDecodeError) as e:
            rows.append(f"{case.name:30} INVALID JSON ({e})")
            continue
        card = score_case(case, notes)
        t = timing(record)
        ai, dec, oq = card["action_items"], card["decisions"], card["open_questions"]
        rows.append(
            f"{case.name:30} {ai['found']}/{ai['expected']:<5} {ai['owner_ok']}/{ai['matched_total']:<5} {ai['due_ok']}/{ai['matched_total']:<5} "
            f"{len(ai['trap']):<5} {len(ai['extra']):<5} {dec['found']}/{dec['expected']:<4} {oq['found']}/{oq['expected']:<4} {card['quotes_grounded']:<7} "
            f"{t['prompt_tokens']:<7} {t['prefill_tps'] or '-':<8} {t['gen_tokens']:<6} {t['gen_tps'] or '-':<7} {t['wall_s']}"
        )
        details.append((case.name, notes, card))
        (Path(run_dir) / f"{case.name}.score.json").write_text(json.dumps({"timing": t, "card": card}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n{'case':30} {'AI':7} {'owner':7} {'due':7} {'traps':5} {'extra':5} {'dec':6} {'OQ':6} {'quotes':7} {'prompt':7} {'pre t/s':8} {'gen':6} {'gen t/s':7} wall s")
    print("\n".join(rows))
    for name, notes, card in details:
        print(f"\n== {name}: {notes.get('title', '')}\n{notes.get('summary', '')}")
        for section in ("action_items", "decisions", "open_questions"):
            s = card[section]
            for label in ("missed", "wrong", "trap", "extra", "borderline"):
                for entry in s.get(label, []):
                    print(f"  [{section} {label}] {entry}")


def score_notes(notes_dir):
    """Score plain Notes JSON files named <case>.notes.json, such as the engine's `bekitzur notes` output."""
    cases = {c.name: c for c in build_cases()}
    print(f"{'case':30} {'AI':7} {'owner':7} {'due':7} {'traps':5} {'extra':5} {'dec':6} {'OQ':6} quotes")
    for path in sorted(Path(notes_dir).glob("t*.notes.json")):
        case = cases[path.name.removesuffix(".notes.json")]
        card = score_case(case, json.loads(path.read_text(encoding="utf-8")))
        ai, dec, oq = card["action_items"], card["decisions"], card["open_questions"]
        print(f"{case.name:30} {ai['found']}/{ai['expected']:<5} {ai['owner_ok']}/{ai['matched_total']:<5} {ai['due_ok']}/{ai['matched_total']:<5} "
              f"{len(ai['trap']):<5} {len(ai['extra']):<5} {dec['found']}/{dec['expected']:<4} {oq['found']}/{oq['expected']:<4} {card['quotes_grounded']}")
        for section in ("action_items", "decisions", "open_questions"):
            for label in ("missed", "wrong", "trap", "extra"):
                for entry in card[section].get(label, []):
                    print(f"    [{section} {label}] {entry}")


def run(args):
    cases = build_cases()
    if args.only:
        prefixes = tuple(args.only.split(","))
        cases = [c for c in cases if c.name.startswith(prefixes)]
    suffix = ("" if args.prompt == "v1" else f"-{args.prompt}") + ("-think" if args.think else "")
    run_dir = RESULTS / (re.sub(r"[^\w.-]+", "_", args.model) + suffix)
    run_dir.mkdir(parents=True, exist_ok=True)
    for case in cases:
        print(f"{case.name}: {len(case.turns)} turns ...", end=" ", flush=True)
        start = time.time()
        response = chat(args.model, case, args.think, args.num_ctx, args.prompt, args.max_tokens)
        record = {"case": case.name, "model": args.model, "prompt": args.prompt, "think": args.think, "wall_s": time.time() - start,
                  "memory": loaded_memory(), "response": response}
        (run_dir / f"{case.name}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{record['wall_s']:.0f}s, memory {record['memory']}")
    score_dir(run_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--model", required=True)
    r.add_argument("--think", action="store_true")
    r.add_argument("--prompt", choices=sorted(PROMPTS), default="v1")
    r.add_argument("--only", help="comma-separated case name prefixes, e.g. t1,t3")
    r.add_argument("--num-ctx", type=int, default=32768)
    r.add_argument("--max-tokens", type=int, default=8192, help="output cap; stops runaway generation")
    s = sub.add_parser("score")
    s.add_argument("run_dir")
    n = sub.add_parser("score-notes")
    n.add_argument("notes_dir")
    args = parser.parse_args()
    if args.command == "run":
        run(args)
    elif args.command == "score-notes":
        score_notes(args.notes_dir)
    else:
        score_dir(args.run_dir)


if __name__ == "__main__":
    sys.exit(main())
