#!/usr/bin/env python3
"""Validate Vibe's tempo detection against the GiantSteps tempo dataset.

Runs the debug build's `scan_bpm` verb over the dataset's audio and scores the
results with the standard MIREX tempo metrics:

  Accuracy1  detected tempo within TOLERANCE of the ground truth
  Accuracy2  within TOLERANCE of the truth or of a metrical multiple of it
             (1/3, 1/2, 2, 3) — i.e. Accuracy1 plus forgiven octave errors

`scan_bpm` runs inside the CLI client's own process: no app instance, no
window, no caches, and a running Vibe is left alone. That also makes the run
parallelisable, since each file is an independent process.

    scripts/validate-tempo.py --limit 10             # a quick sample
    scripts/validate-tempo.py --jobs 8 --csv out.csv # the whole set

The dataset is not vendored; point --dataset at a local clone of
https://github.com/GiantSteps/giantsteps-tempo-dataset with audio downloaded.
Annotations v2 (Schreiber & Müller's crowdsourced revision) are the default
ground truth, as in current literature; --annotations v1 selects the original.
"""

import argparse
import concurrent.futures
import json
import os
import random
import statistics
import subprocess
import sys
from pathlib import Path

# MIREX convention: a detection within 4% of the reference counts as correct.
TOLERANCE = 0.04
# The metrical relatives Accuracy2 forgives.
OCTAVE_FACTORS = (1 / 3, 1 / 2, 1, 2, 3)

REPO = Path(__file__).resolve().parent.parent
DEFAULT_APP = REPO / "build/DerivedData/Build/Products/Debug/Vibe.app"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dataset", type=Path,
                   default=Path.home() / "projects/giantsteps-tempo-dataset",
                   help="clone of the GiantSteps tempo dataset (default: %(default)s)")
    p.add_argument("--annotations", choices=("v1", "v2"), default="v2",
                   help="which ground-truth set to score against (default: %(default)s)")
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


def load_dataset(dataset: Path, annotations: str):
    """Pair each audio file with its reference tempo, newest annotations first."""
    audio_dir = dataset / "audio"
    ann_dir = dataset / ("annotations_v2/tempo" if annotations == "v2" else "annotations/tempo")
    if not audio_dir.is_dir() or not ann_dir.is_dir():
        sys.exit(f"dataset not found: expected {audio_dir} and {ann_dir}")

    items, missing = [], 0
    for audio in sorted(audio_dir.iterdir()):
        if audio.suffix.lower() not in (".mp3", ".wav", ".flac", ".m4a"):
            continue
        # 1030011.LOFI.mp3 -> 1030011.LOFI.bpm
        ann = ann_dir / (audio.name.rsplit(".", 1)[0] + ".bpm")
        if not ann.is_file():
            missing += 1
            continue
        try:
            reference = float(ann.read_text().strip().split()[0])
        except (ValueError, IndexError):
            missing += 1
            continue
        if reference > 0:
            items.append((audio, reference))
    return items, missing


def scan(binary: Path, audio: Path):
    """One scan_bpm run. The audio rides stdin because the direct-exec'd client
    is sandboxed and cannot read arbitrary argv paths."""
    try:
        with audio.open("rb") as f:
            proc = subprocess.run([str(binary), "--debug-cmd", "scan_bpm", "-"],
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


def score(detected: float, reference: float):
    """(accuracy1, accuracy2, matched factor or None)."""
    if detected <= 0:
        return False, False, None
    matched = None
    for factor in OCTAVE_FACTORS:
        if abs(detected - reference * factor) <= TOLERANCE * reference * factor:
            # Prefer the exact match when several would pass.
            if factor == 1:
                return True, True, 1
            if matched is None:
                matched = factor
    return False, matched is not None, matched


def factor_label(factor):
    return {1: "exact", 2: "double", 3: "triple",
            1 / 2: "half", 1 / 3: "third"}.get(factor, "none")


def main():
    args = parse_args()
    app = args.app or Path(os.environ.get("VIBE_APP", DEFAULT_APP))
    binary = app / "Contents/MacOS/Vibe"
    if not binary.is_file():
        sys.exit(f"no debug build at {app} — run: make build CONFIG=Debug")

    items, missing = load_dataset(args.dataset, args.annotations)
    if not items:
        sys.exit("no audio/annotation pairs found — is the audio downloaded?")
    if args.sample:
        items = random.Random(args.seed).sample(items, min(args.sample, len(items)))
        items.sort()
    if args.limit:
        items = items[:args.limit]

    print(f"dataset:     {args.dataset}")
    print(f"annotations: {args.annotations}  ({len(items)} files scored"
          + (f", {missing} without audio/annotation" if missing else "") + ")")
    print(f"binary:      {binary}")
    print(f"jobs:        {args.jobs}\n", flush=True)

    rows, done = [], 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(scan, binary, audio): (audio, ref) for audio, ref in items}
        for future in concurrent.futures.as_completed(futures):
            audio, reference = futures[future]
            reply = future.result()
            done += 1
            if not reply.get("ok"):
                rows.append({"file": audio.name, "reference": reference, "detected": None,
                             "error": reply.get("error", "unknown")})
                continue
            detected = float(reply.get("bpm", 0))
            acc1, acc2, factor = score(detected, reference)
            timing = reply.get("timing", {})
            rows.append({
                "file": audio.name, "reference": reference, "detected": detected,
                "acc1": acc1, "acc2": acc2, "factor": factor_label(factor),
                "error_pct": (detected - reference) / reference * 100 if detected > 0 else None,
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
        print(f"{'file':<22}{'truth':>8}{'detected':>10}{'err %':>8}  {'result':<12}{'cost':>8}")
        print("-" * 70)
        for r in rows:
            if r["detected"] is None:
                print(f"{r['file']:<22}{r['reference']:>8.1f}{'ERROR':>10}   {r['error'][:30]}")
                continue
            verdict = "OK" if r["acc1"] else (f"octave ({r['factor']})" if r["acc2"] else "WRONG")
            print(f"{r['file']:<22}{r['reference']:>8.1f}{r['detected']:>10.2f}"
                  f"{r['error_pct']:>8.2f}  {verdict:<12}"
                  f"{r['decode_seconds'] + r['analyze_seconds']:>7.2f}s")
        print()

    n = len(scored)
    if n:
        acc1 = sum(r["acc1"] for r in scored)
        acc2 = sum(r["acc2"] for r in scored)
        undetected = sum(1 for r in scored if r["detected"] <= 0)
        print(f"Accuracy1 (within {TOLERANCE:.0%}):        {acc1:>4}/{n}  {acc1 / n:6.1%}")
        print(f"Accuracy2 (octave-forgiven):    {acc2:>4}/{n}  {acc2 / n:6.1%}")
        if undetected:
            print(f"No tempo returned:              {undetected:>4}/{n}  {undetected / n:6.1%}")
        breakdown = {}
        for r in scored:
            if r["acc2"] and not r["acc1"]:
                breakdown[r["factor"]] = breakdown.get(r["factor"], 0) + 1
        if breakdown:
            print("  octave errors: " + ", ".join(f"{k} x{v}" for k, v in sorted(breakdown.items())))
        exact = [abs(r["error_pct"]) for r in scored if r["acc1"]]
        if exact:
            print(f"  |error| on Accuracy1 hits:    median {statistics.median(exact):.2f}%"
                  f"  max {max(exact):.2f}%")
        audio = sum(r["audio_seconds"] for r in scored)
        decode = sum(r["decode_seconds"] for r in scored)
        analyze = sum(r["analyze_seconds"] for r in scored)
        if audio > 0 and (decode + analyze) > 0:
            print(f"\nCost: {audio / 60:.0f} min of audio in {decode + analyze:.1f}s "
                  f"(decode {decode:.1f}s + analyze {analyze:.1f}s), "
                  f"{audio / (decode + analyze):.0f}x realtime, "
                  f"{analyze / audio * 1000:.2f} ms analysis per audio-second")
    if failed:
        print(f"\n{len(failed)} file(s) failed to scan; first: "
              f"{failed[0]['file']} — {failed[0]['error'][:100]}")

    if args.csv:
        import csv
        fields = ["file", "reference", "detected", "error_pct", "acc1", "acc2", "factor",
                  "audio_seconds", "decode_seconds", "analyze_seconds", "error"]
        with args.csv.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    main()
