#!/usr/bin/env python3
"""Score speaker separation and Voiceprint naming on a scripted read.

  python3 eval/score_speakers.py <meeting.whisper.json> <meeting.diar.json> <name>=<enroll.diar.json> ...

Ground truth comes from the script: the transcript's timed segments are aligned to the script lines, and each
line says who read it. Voiceprints are the average speaker embedding of each voice sample.
"""

import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score_asr  # noqa: E402

READERS = {"You": "you", "Colleague": "colleague"}


def aligned_pairs(ref, hyp):
    d = [[0] * (len(hyp) + 1) for _ in range(len(ref) + 1)]
    for i in range(len(ref) + 1):
        d[i][0] = i
    for j in range(len(hyp) + 1):
        d[0][j] = j
    for i in range(1, len(ref) + 1):
        for j in range(1, len(hyp) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    pairs, i, j = [], len(ref), len(hyp)
    while i and j:
        if d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif d[i][j] == d[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return pairs


def mean(vectors, weights=None):
    weights = weights or [1.0] * len(vectors)
    total = sum(weights)
    return [sum(w * v[k] for v, w in zip(vectors, weights)) / total for k in range(len(vectors[0]))]


def cosine(a, b):
    return sum(x * y for x, y in zip(a, b)) / math.sqrt(sum(x * x for x in a) * sum(y * y for y in b))


def ground_truth(whisper_json):
    script = json.loads((score_asr.ROOT / "reference.json").read_text(encoding="utf-8"))
    ref, ref_reader = [], []
    for t in script:
        for w in score_asr.words(t["text"]):
            ref.append(w)
            ref_reader.append(READERS[t["reader"]])
    segments = json.loads(Path(whisper_json).read_text(encoding="utf-8"))["transcription"]
    hyp, hyp_segment = [], []
    for k, seg in enumerate(segments):
        for w in score_asr.words(seg["text"]):
            hyp.append(w)
            hyp_segment.append(k)
    votes = defaultdict(Counter)
    for ri, hj in aligned_pairs(ref, hyp):
        votes[hyp_segment[hj]][ref_reader[ri]] += 1
    truth = []
    for k, seg in enumerate(segments):
        if votes[k]:
            reader, n = votes[k].most_common(1)[0]
            if n / sum(votes[k].values()) >= 0.8:
                truth.append((seg["offsets"]["from"] / 1000, seg["offsets"]["to"] / 1000, reader))
    return truth


def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def main():
    whisper_json, diar_json, *enrollments = sys.argv[1:]
    truth = ground_truth(whisper_json)
    segments = json.loads(Path(diar_json).read_text(encoding="utf-8"))["segments"]

    voiceprints = {}
    for arg in enrollments:
        name, path = arg.split("=", 1)
        enroll = json.loads(Path(path).read_text(encoding="utf-8"))["segments"]
        voiceprints[name] = mean([s["embedding"] for s in enroll], [s["endTimeSeconds"] - s["startTimeSeconds"] for s in enroll])

    by_cluster = defaultdict(list)
    for s in segments:
        s["truth"] = Counter()
        for t0, t1, reader in truth:
            s["truth"][reader] += overlap(s["startTimeSeconds"], s["endTimeSeconds"], t0, t1)
        by_cluster[s["speakerId"]].append(s)

    print("Speakers found:", len(by_cluster))
    named = {}
    for cid, segs in sorted(by_cluster.items()):
        duration = sum(s["endTimeSeconds"] - s["startTimeSeconds"] for s in segs)
        centroid = mean([s["embedding"] for s in segs], [s["endTimeSeconds"] - s["startTimeSeconds"] for s in segs])
        sims = {name: cosine(centroid, vp) for name, vp in voiceprints.items()}
        named[cid] = max(sims, key=sims.get)
        truth_time = sum((s["truth"] for s in segs), Counter())
        print(f"  {cid}: {duration:5.1f}s speech, true reader time {dict((k, round(v, 1)) for k, v in truth_time.items())}, "
              f"similarity {', '.join(f'{n} {v:.2f}' for n, v in sims.items())} -> named {named[cid]}")

    labeled = [s for s in segments if sum(s["truth"].values()) > 0]
    total = sum(sum(s["truth"].values()) for s in labeled)
    cluster_right = sum(s["truth"][named[s["speakerId"]]] for s in labeled)
    segment_right = 0.0
    for s in labeled:
        sims = {name: cosine(s["embedding"], vp) for name, vp in voiceprints.items()}
        segment_right += s["truth"][max(sims, key=sims.get)]
    print(f"Speech time with a known reader: {total:.1f}s")
    print(f"Named correctly, per Speaker (how the app names): {cluster_right / total:.1%}")
    print(f"Named correctly, per segment (each segment on its own): {segment_right / total:.1%}")


if __name__ == "__main__":
    main()
