#!/usr/bin/env python3
"""Validate Vibe's key detection against the GiantSteps key dataset.

Runs the debug build's `scan_key` verb over the dataset's audio and scores the
results with the MIREX audio-key metric, as implemented by mir_eval:

  1.0  exact match
  0.5  perfect fifth above the reference, same mode (the dominant)
  0.3  relative major/minor
  0.2  parallel major/minor (same tonic, other mode)
  0.0  anything else, including no key returned

The weighted score is the mean of those; "correct" alone is the exact-match
rate. Both are reported, since a detector can score well on the weighted
metric purely by landing on relatives.

`scan_key` runs inside the CLI client's own process: no app instance, no
window, no caches, and a running Vibe is left alone. That also makes the run
parallelisable, since each file is an independent process.

    scripts/validate-key.py --limit 10              # a quick sample
    scripts/validate-key.py --jobs 8 --csv out.csv  # the whole set

The dataset is not vendored; point --dataset at a local clone of
https://github.com/GiantSteps/giantsteps-key-dataset with audio downloaded.
"""

import argparse
import concurrent.futures
import csv
import json
import os
import random
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_APP = REPO / "build/DerivedData/Build/Products/Debug/Vibe.app"

# Vibe's own encoding, matching MusicalKey.h: 0-11 major by pitch class,
# 12-23 minor, -1 unknown. The harness scores in the same space, so a reply's
# "index" needs no translation.
NONE = -1
PITCH_CLASSES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11, "H": 11}


def parse_key(text: str):
    """'Eb minor' -> 15. Returns NONE for anything unparseable."""
    parts = text.strip().replace("♯", "#").replace("♭", "b").split()
    if len(parts) != 2:
        return NONE
    tonic, mode = parts
    if not tonic or tonic[0].upper() not in PITCH_CLASSES:
        return NONE
    pitch = PITCH_CLASSES[tonic[0].upper()]
    for accidental in tonic[1:]:
        if accidental == "#":
            pitch += 1
        elif accidental == "b":
            pitch -= 1
        else:
            return NONE
    mode = mode.lower()
    if mode in ("major", "maj", "dur"):
        return pitch % 12
    if mode in ("minor", "min", "moll"):
        return 12 + pitch % 12
    return NONE


def key_name(key: int):
    if key == NONE:
        return "none"
    names = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    return f"{names[key % 12]} {'minor' if key >= 12 else 'major'}"


def score(detected: int, reference: int):
    """(weight, category) per the MIREX audio-key metric."""
    if detected == NONE:
        return 0.0, "none"
    det_pitch, det_minor = detected % 12, detected >= 12
    ref_pitch, ref_minor = reference % 12, reference >= 12
    if detected == reference:
        return 1.0, "correct"
    if det_minor == ref_minor and (det_pitch - ref_pitch) % 12 == 7:
        return 0.5, "fifth"
    if det_minor != ref_minor:
        # The relative key: minor is 9 semitones above its major, major 3
        # above its minor.
        if not ref_minor and (det_pitch - ref_pitch) % 12 == 9:
            return 0.3, "relative"
        if ref_minor and (det_pitch - ref_pitch) % 12 == 3:
            return 0.3, "relative"
        if det_pitch == ref_pitch:
            return 0.2, "parallel"
    return 0.0, "wrong"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dataset", type=Path,
                   default=Path.home() / "projects/giantsteps-key-dataset",
                   help="clone of the GiantSteps key dataset (default: %(default)s)")
    p.add_argument("--app", type=Path, default=None,
                   help=f"Vibe.app to test (default: {DEFAULT_APP}, or $VIBE_APP)")
    p.add_argument("--limit", type=int, default=0,
                   help="score only the first N files (0 = all)")
    p.add_argument("--sample", type=int, default=0,
                   help="score a random sample of N files (with --seed for repeatability)")
    p.add_argument("--seed", type=int, default=1234, help="sample seed (default: %(default)s)")
    p.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) // 2),
                   help="parallel scans (default: half the cores, %(default)s)")
    p.add_argument("--csv", type=Path, default=None, help="write per-file results here")
    p.add_argument("--per-file", action="store_true",
                   help="print a row per file (implied when scoring 20 or fewer)")
    return p.parse_args()


def load_dataset(dataset: Path):
    """Pair each audio file with its reference key."""
    audio_dir = dataset / "audio"
    ann_dir = dataset / "annotations/key"
    if not audio_dir.is_dir() or not ann_dir.is_dir():
        sys.exit(f"dataset not found: expected {audio_dir} and {ann_dir}")
    items, unusable = [], 0
    for audio in sorted(audio_dir.iterdir()):
        if audio.suffix.lower() not in (".mp3", ".wav", ".flac", ".m4a"):
            continue
        # 1004923.LOFI.mp3 -> 1004923.LOFI.key
        ann = ann_dir / (audio.name.rsplit(".", 1)[0] + ".key")
        if not ann.is_file():
            unusable += 1
            continue
        reference = parse_key(ann.read_text())
        if reference == NONE:
            unusable += 1
            continue
        items.append((audio, reference))
    return items, unusable


def scan(binary: Path, audio: Path):
    """One scan_key run. The audio rides stdin because the direct-exec'd client
    is sandboxed and cannot read arbitrary argv paths."""
    try:
        with audio.open("rb") as f:
            proc = subprocess.run([str(binary), "--debug-cmd", "scan_key", "-"],
                                  stdin=f, capture_output=True, timeout=300)
    except subprocess.TimeoutExpired:
        return {"error": "timed out"}
    if proc.returncode != 0 and not proc.stdout.strip():
        return {"error": (proc.stderr.decode(errors="replace").strip() or
                          f"exit {proc.returncode}")}
    try:
        return json.loads(proc.stdout.decode(errors="replace"))
    except json.JSONDecodeError:
        return {"error": "unparseable reply: " + proc.stdout.decode(errors="replace")[:120]}


def main():
    args = parse_args()
    app = args.app or Path(os.environ.get("VIBE_APP", DEFAULT_APP))
    binary = app / "Contents/MacOS/Vibe"
    if not binary.is_file():
        sys.exit(f"no debug build at {app} — run: make build CONFIG=Debug")

    items, unusable = load_dataset(args.dataset)
    if not items:
        sys.exit("no audio/annotation pairs found — is the audio downloaded?")
    if args.sample:
        items = random.Random(args.seed).sample(items, min(args.sample, len(items)))
        items.sort()
    if args.limit:
        items = items[:args.limit]

    print(f"dataset: {args.dataset}")
    print(f"scoring: {len(items)} files"
          + (f", {unusable} without usable audio/annotation" if unusable else ""))
    print(f"binary:  {binary}")
    print(f"jobs:    {args.jobs}\n", flush=True)

    rows, done = [], 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(scan, binary, audio): (audio, ref) for audio, ref in items}
        for future in concurrent.futures.as_completed(futures):
            audio, reference = futures[future]
            reply = future.result()
            done += 1
            if not reply.get("ok"):
                rows.append({"file": audio.name, "reference": key_name(reference),
                             "detected": None, "error": reply.get("error", "unknown")})
                continue
            detected = int(reply.get("index", NONE))
            weight, category = score(detected, reference)
            timing = reply.get("timing", {})
            rows.append({
                "file": audio.name,
                "reference": key_name(reference),
                "detected": key_name(detected),
                "camelot": reply.get("camelot", ""),
                "weight": weight,
                "category": category,
                "audio_seconds": timing.get("audioSeconds", 0),
                "decode_seconds": timing.get("decodeSeconds", 0),
                "analyze_seconds": timing.get("analyzeSeconds", 0),
                "error": None,
            })
            if done % 50 == 0:
                print(f"  ... {done}/{len(items)}", file=sys.stderr, flush=True)

    rows.sort(key=lambda r: r["file"])
    scored = [r for r in rows if r.get("detected") is not None]
    failed = [r for r in rows if r.get("detected") is None]

    if args.per_file or len(rows) <= 20:
        print(f"{'file':<22}{'reference':>12}{'detected':>12}{'score':>7}  {'result':<10}{'cost':>8}")
        print("-" * 74)
        for r in rows:
            if r["detected"] is None:
                print(f"{r['file']:<22}{r['reference']:>12}{'ERROR':>12}   {r['error'][:28]}")
                continue
            print(f"{r['file']:<22}{r['reference']:>12}{r['detected']:>12}"
                  f"{r['weight']:>7.1f}  {r['category']:<10}"
                  f"{r['decode_seconds'] + r['analyze_seconds']:>7.2f}s")
        print()

    n = len(scored)
    if n:
        counts = Counter(r["category"] for r in scored)
        weighted = sum(r["weight"] for r in scored) / n
        correct = counts["correct"]
        print(f"MIREX weighted score:           {weighted:6.1%}")
        print(f"Correct (exact match):        {correct:>4}/{n}  {correct / n:6.1%}")
        for label, key in (("Perfect fifth", "fifth"), ("Relative major/minor", "relative"),
                           ("Parallel major/minor", "parallel"), ("Wrong", "wrong"),
                           ("No key returned", "none")):
            if counts[key]:
                print(f"{label + ':':<30}{counts[key]:>4}/{n}  {counts[key] / n:6.1%}")
        # A detector that always answers minor scores well on a minor-heavy
        # set, so report the mode split too.
        ref_minor = sum(1 for r in scored if r["reference"].endswith("minor"))
        det_minor = sum(1 for r in scored if r["detected"].endswith("minor"))
        print(f"\nMode balance: references {ref_minor}/{n} minor, "
              f"detections {det_minor}/{n} minor")
        audio = sum(r["audio_seconds"] for r in scored)
        decode = sum(r["decode_seconds"] for r in scored)
        analyze = sum(r["analyze_seconds"] for r in scored)
        if audio > 0 and (decode + analyze) > 0:
            print(f"Cost: {audio / 60:.0f} min of audio in {decode + analyze:.1f}s "
                  f"(decode {decode:.1f}s + analyze {analyze:.1f}s), "
                  f"{audio / (decode + analyze):.0f}x realtime, "
                  f"{analyze / audio * 1000:.2f} ms analysis per audio-second")
    if failed:
        print(f"\n{len(failed)} file(s) failed to scan; first: "
              f"{failed[0]['file']} — {failed[0]['error'][:100]}")

    if args.csv:
        fields = ["file", "reference", "detected", "camelot", "weight", "category",
                  "audio_seconds", "decode_seconds", "analyze_seconds", "error"]
        with args.csv.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    main()
