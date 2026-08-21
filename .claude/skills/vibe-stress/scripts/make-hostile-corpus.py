#!/usr/bin/env python3
"""Build a corpus of files the open path is entitled to refuse, mixed with real ones.

The other two corpus builders make files that WORK. This one makes the cases a
real folder hands the app by accident — a half-finished download, a rip that
died, a cover that is a directory — and mixes real tracks in among them, so the
run keeps changing tracks between a file that decodes and one that cannot. A
corpus of only broken files tests one error branch repeatedly; the interesting
failures are in the transition.

Why the real half is HARD LINKED rather than copied: the source library is the
user's own music and can be tens of gigabytes. A hard link costs no space, and
a path inside the corpus root keeps the sandbox grant working, which a symlink
pointing outside the granted folder would not.

    make-hostile-corpus.py --source ~/Music/big [--out build/hostile-corpus] [--real 60]

Nothing here writes to --source. Every op profile excludes convert_to_flac, the
only verb that writes beside a source file, so a run over this corpus cannot
reach the originals either.
"""

import argparse
import os
import pathlib
import random
import shutil
import struct
import sys

AUDIO_SUFFIXES = {".mp3", ".m4a", ".flac", ".wav", ".aif", ".aiff", ".mp4", ".aac", ".mp2"}


def pick_sources(source: pathlib.Path, rng, want):
    """Real tracks, spread across folders rather than drawn from one album."""
    by_folder = {}
    for dirpath, dirnames, filenames in os.walk(source):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        here = pathlib.Path(dirpath)
        for name in filenames:
            if pathlib.Path(name).suffix.lower() in AUDIO_SUFFIXES:
                by_folder.setdefault(here, []).append(here / name)
    folders = sorted(by_folder)
    rng.shuffle(folders)
    picked = []
    while folders and len(picked) < want:
        for folder in list(folders):
            files = by_folder[folder]
            if not files:
                folders.remove(folder)
                continue
            picked.append(files.pop(rng.randrange(len(files))))
            if len(picked) >= want:
                break
    return picked


def truncate_copy(src: pathlib.Path, dest: pathlib.Path, keep_bytes):
    with open(src, "rb") as fh:
        data = fh.read(keep_bytes)
    dest.write_bytes(data)


def corrupt_copy(src: pathlib.Path, dest: pathlib.Path, rng, keep_bytes=4 * 1024 * 1024):
    """Header intact, frames scrambled — the decoder gets in and then fails.

    A file with a broken header is refused at the first parse; one whose frames
    go wrong halfway is accepted, started, and fails mid-decode, which is a
    different path and the one that has a track already playing off it.
    """
    with open(src, "rb") as fh:
        data = bytearray(fh.read(keep_bytes))
    if len(data) > 40000:
        for _ in range(2000):
            index = rng.randrange(32768, len(data))
            data[index] = rng.randrange(256)
    dest.write_bytes(bytes(data))


def main():
    here = pathlib.Path(__file__).resolve().parents[4]
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, help="a real music library to link from")
    parser.add_argument("--out", default=str(here / "build/hostile-corpus"))
    parser.add_argument("--real", type=int, default=60,
                        help="real tracks hard-linked in among the broken ones")
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args()

    source = pathlib.Path(args.source).expanduser().resolve()
    if not source.is_dir():
        sys.exit(f"no source library at {source}")
    out = pathlib.Path(args.out).resolve()
    if out == source or source in out.parents:
        sys.exit("refusing to build the corpus inside the source library")
    if out.exists():
        shutil.rmtree(out)
    rng = random.Random(args.seed)

    good = out / "good"
    broken = out / "broken"
    names = out / "awkward names"
    art = out / "bad art"
    for d in (good, broken, names, art):
        d.mkdir(parents=True)

    sources = pick_sources(source, rng, args.real)
    if not sources:
        sys.exit(f"no audio files under {source}")
    linked = 0
    for index, src in enumerate(sources):
        dest = good / f"{index:03d} {src.name}"
        try:
            os.link(src, dest)
            linked += 1
        except OSError:
            # A different volume, or a filesystem without hard links: fall back
            # to a copy rather than dropping the file, and let the size stand.
            shutil.copy2(src, dest)
            linked += 1

    # -- files that are audio-shaped and are not ---------------------------
    made = []
    for suffix in (".mp3", ".flac", ".wav", ".m4a", ".aiff"):
        p = broken / f"zero-length{suffix}"
        p.write_bytes(b"")
        made.append(p)
    # An empty AVAudioFile open is the documented fd-strand hazard; 300 of them
    # meet a 256 soft limit, so the corpus carries enough to reach it under a
    # run that keeps retrying.
    for i in range(24):
        p = broken / f"zero-length-{i:02d}.flac"
        p.write_bytes(b"")
        made.append(p)

    p = broken / "text-pretending.mp3"
    p.write_bytes(b"this is not an mp3\n" * 512)
    made.append(p)

    p = broken / "png-pretending.flac"
    p.write_bytes(b"\x89PNG\r\n\x1a\n" + os.urandom(64 * 1024))
    made.append(p)

    p = broken / "random-bytes.wav"
    p.write_bytes(os.urandom(256 * 1024))
    made.append(p)

    # A RIFF header claiming a data chunk far larger than the file.
    p = broken / "lying-riff-header.wav"
    p.write_bytes(b"RIFF" + struct.pack("<I", 0x7FFFFFFF) + b"WAVEfmt " +
                  struct.pack("<IHHIIHH", 16, 1, 2, 44100, 176400, 4, 16) +
                  b"data" + struct.pack("<I", 0x7FFFFF00) + os.urandom(8192))
    made.append(p)

    # An ID3v2 header announcing a 200 MB tag on a 4 KB file: the size is a
    # synchsafe integer, so a parser that reads it as a plain one is off by a
    # factor of two before it even allocates.
    tag_size = bytes([0x7F, 0x7F, 0x7F, 0x7F])
    p = broken / "enormous-id3-tag.mp3"
    p.write_bytes(b"ID3\x04\x00\x00" + tag_size + os.urandom(4096))
    made.append(p)

    picks = sources[:]
    rng.shuffle(picks)
    for index, src in enumerate(picks[:6]):
        truncate_copy(src, broken / f"truncated-{index}{src.suffix}", 8 * 1024)
    for index, src in enumerate(picks[6:10]):
        truncate_copy(src, broken / f"header-only-{index}{src.suffix}", 512)
    for index, src in enumerate(picks[10:14]):
        corrupt_copy(src, broken / f"scrambled-frames-{index}{src.suffix}", rng)

    # A directory that looks like a track, and a self-referential symlink that
    # looks like one: both reach the open funnel's path handling rather than any
    # decoder.
    (broken / "actually-a-directory.flac").mkdir()
    (broken / "actually-a-directory.flac" / "inside.txt").write_text("not audio\n")
    try:
        os.symlink(broken / "symlink-loop.flac", broken / "symlink-loop.flac")
    except OSError:
        pass
    (out / "empty folder").mkdir()

    # -- playlists that point nowhere --------------------------------------
    (broken / "dangling.m3u").write_text(
        "#EXTM3U\n#EXTINF:1,Nothing\n./does-not-exist.flac\n"
        "C:\\Windows\\Absolute\\Path.wav\n../../../../etc/passwd\n"
        "zero-length.flac\n")
    (broken / "garbage.cue").write_text(
        'REM this is not really a cue sheet\nFILE "missing.wav" WAVE\n'
        "  TRACK 01 AUDIO\n    INDEX 01 99:99:99\n" + "X" * 4096 + "\n")
    if sources:
        # A cue naming a file that IS there, so the entry rescues run against a
        # real target rather than always failing at the first rung.
        real = good / f"000 {sources[0].name}"
        (good / "real.cue").write_text(
            f'FILE "{real.name}" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n'
            "  TRACK 02 AUDIO\n    INDEX 01 03:00:00\n")

    # -- names the shell and the path handling both have to survive --------
    awkward = [
        "quote'in name.flac", 'double"quote.flac', "spaces   everywhere.flac",
        "-leading-dash.flac", "emoji 🎧🔊.flac", "ünïcödé nörmalizatiön.flac",
        "日本語のファイル.flac", ("very-" * 40) + "long.flac",
        "dot.in.the.middle.v2.final.flac", "tab\tinside.flac",
        "%s %d %n percent.flac", "..dots.flac",
    ]
    if sources:
        model = sources[0]
        for name in awkward:
            dest = names / name
            try:
                truncate_copy(model, dest, 512 * 1024)
            except OSError:
                pass

    # -- covers the folder-art resolver must decline quietly ----------------
    for index, src in enumerate(picks[14:20]):
        folder = art / f"album {index:02d}"
        folder.mkdir()
        try:
            os.link(src, folder / src.name)
        except OSError:
            shutil.copy2(src, folder / src.name)
    albums = sorted(p for p in art.iterdir() if p.is_dir())
    if albums:
        (albums[0] / "cover.jpg").write_bytes(b"")
        if len(albums) > 1:
            (albums[1] / "cover.jpg").write_bytes(os.urandom(128 * 1024))
        if len(albums) > 2:
            (albums[2] / "cover.jpg").mkdir()
        if len(albums) > 3:
            try:
                os.mkfifo(albums[3] / "cover.jpg")
            except OSError:
                pass
        if len(albums) > 4:
            # 64 MB of JPEG-headed noise: the bounded decode's job is to refuse
            # it without the resolver ever holding it in memory.
            with open(albums[4] / "folder.jpg", "wb") as fh:
                fh.write(b"\xff\xd8\xff\xe0")
                for _ in range(64):
                    fh.write(os.urandom(1024 * 1024))

    total = sum(f.stat().st_size for f in out.rglob("*") if f.is_file() and not f.is_symlink())
    print(f"{linked} real tracks hard-linked, {len(list(broken.iterdir()))} broken entries, "
          f"{len(awkward)} awkward names, {len(albums)} art folders")
    print(f"corpus: {out}  ({total // (1024 * 1024)} MB of new bytes)")


if __name__ == "__main__":
    main()
