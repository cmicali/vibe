#!/usr/bin/env python3
"""Build a corpus shaped like a real cloud music folder, for stress.py's
--profile cloud and for cloud-scenarios.py.

  BIG FOLDERS. The scan is deferred until the picked open settles or two
  seconds pass, and a replacement playlist drops the loader outright; against
  a small folder the sweep finishes instantly and the serial scan lane is
  never populated.

  EMBEDDED ART AND REAL TAGS. Generated test tones carry neither, so the art
  path sits idle. Tags vary per file, or every row renders the same and a
  mixed-up delivery would look correct.

  A MIXTURE. Some files carry no art at all, a legitimate state the app must
  handle quietly (iOS has no folder-art fallback).

ffmpeg stream-copies each source with new tags, so this is fast and lossless.

    make-cloud-corpus.py [--out build/stress-corpus] [--folders 12] [--per-folder 40]
"""

import argparse
import pathlib
import random
import shutil
import subprocess
import sys

ARTISTS = ["Adriatique", "Ame", "Chaos in the CBD", "DJ Seinfeld", "Delano Smith",
           "Four Tet", "Impérieux", "Kerri Chandler", "Theo Parrish", "Yonef",
           "Nuke", "Raxon", "Jesse Bru", "Mau P", "Roland Clark"]
TITLES = ["Rollox", "Basic Track", "Sirena Deep", "the one", "Free To Explore",
          "Into Dust", "Cawuso", "You Are In My System", "The Rink", "Erode II",
          "Ignorant Groovers", "Acid Call", "Personality", "Deep Burnt",
          "Heel Goed", "Whipped", "Frizza", "Untouchable", "Torn in Two",
          "Floresta", "Ausklang", "End Truth", "Everybody", "Sound Of Us"]


def main():
    here = pathlib.Path(__file__).resolve().parents[4]
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(here / "build/stress-corpus"))
    parser.add_argument("--folders", type=int, default=12)
    parser.add_argument("--per-folder", type=int, default=40)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--artless-percent", type=int, default=25,
                        help="share of files carrying no embedded art at all")
    args = parser.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found — brew install ffmpeg")

    src_dir = here / "Assets/test_audio_files"
    # Both tag parsers: MP4 metadata and ID3v2 share no code path in TagLib.
    with_art = [src_dir / n for n in
                ("tone-art-red.m4a", "tone-art-blue.m4a", "tone-art-green.mp3")]
    without_art = [src_dir / n for n in ("tone.flac", "tone-cbr.mp3", "tone-long.wav")]
    missing = [p for p in with_art + without_art if not p.exists()]
    if missing:
        sys.exit("missing test audio: " + ", ".join(p.name for p in missing)
                 + "\nrun the vibe-debug skill's generate-test-audio.sh first")

    out = pathlib.Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    rng = random.Random(args.seed)

    made = art_count = 0
    for d in range(args.folders):
        folder = out / f"2025-{d + 1:02d}"
        folder.mkdir(parents=True)
        for i in range(args.per_folder):
            artless = rng.randrange(100) < args.artless_percent
            src = rng.choice(without_art if artless else with_art)
            artist, title = rng.choice(ARTISTS), rng.choice(TITLES)
            # The folder number is in the FILE name: the fake's trace records a
            # transfer by basename alone, so basenames must be corpus-unique.
            dest = folder / f"{artist} - {title} ({d + 1:02d}-{i:02d}){src.suffix}"
            # -c copy keeps the audio and, on these containers, the attached
            # cover; only the tags change.
            subprocess.run(
                ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(src),
                 "-c", "copy", "-metadata", f"title={title}",
                 "-metadata", f"artist={artist}",
                 "-metadata", f"album=2025-{d + 1:02d}", str(dest)],
                check=True)
            made += 1
            art_count += 0 if artless else 1

    total_mb = sum(f.stat().st_size for f in out.rglob("*")) // (1024 * 1024)
    print(f"{made} files across {args.folders} folders, {art_count} with embedded art, {total_mb} MB")
    print(f"corpus: {out}")


if __name__ == "__main__":
    main()
