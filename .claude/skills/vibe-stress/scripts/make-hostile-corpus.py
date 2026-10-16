#!/usr/bin/env python3
"""Build a corpus of files the open path is entitled to refuse, mixed with real ones.

Broken files a real folder hands the app by accident (a half-finished download,
a rip that died, a cover that is a directory) interleaved with real tracks, so
the run keeps changing tracks between a file that decodes and one that cannot:
the interesting failures are in the transition.

The real half is HARD LINKED: no space cost, and a path inside the corpus root
keeps the sandbox grant working where a symlink out of it would not.

"malformed audio" holds one file per damage shape AudioFileHandleFuzzTests
mutates, each named <source>-<shape>, made from small WAV, AIFF, RF64, W64,
FLAC, MP3 and MS ADPCM sources written here: truncation in the header and
mid-frame, flipped header and frame bytes, chunk and block sizes of 0,
0xFFFFFFFF, past the end and odd, a duplicated chunk, fmt after the data,
extreme rates and counts, a sync word planted mid-frame, a seek table past the
end, and the dr_wav fixes' shapes (COMM of 23, odd or more than 18 bytes, the
COMM, ds64 and fact counts past the data, an MS ADPCM table cut short or of no
pairs).

    make-hostile-corpus.py --source ~/Music/big [--out build/hostile-corpus] [--real 60]

Nothing here writes to --source, and no op profile includes convert_to_flac,
the only verb that writes beside a source file.
"""

import argparse
import os
import pathlib
import random
import shutil
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from stress import AUDIO_SUFFIXES  # noqa: E402


def pick_sources(source: pathlib.Path, rng, want):
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
    """Header intact, frames scrambled: accepted and started, then failing
    mid-decode with a track already playing off it."""
    with open(src, "rb") as fh:
        data = bytearray(fh.read(keep_bytes))
    if len(data) > 40000:
        for _ in range(2000):
            index = rng.randrange(32768, len(data))
            data[index] = rng.randrange(256)
    dest.write_bytes(bytes(data))


def malformed_audio(folder: pathlib.Path, rng):
    """One file per damage shape of AudioFileHandleFuzzTests, named by it."""
    frames, rate = 22050, 44100
    pcm = bytes(rng.randrange(256) for _ in range(frames * 4))  # 16-bit stereo noise

    def chunk(tag, body, big=False):
        return tag + struct.pack(">I" if big else "<I", len(body)) + body + (b"\0" if len(body) & 1 else b"")

    fmt16 = struct.pack("<HHIIHH", 1, 2, rate, rate * 4, 4, 16)
    wav = b"RIFF" + struct.pack("<I", 4 + 24 + 8 + len(pcm)) + b"WAVE" + chunk(b"fmt ", fmt16) + chunk(b"data", pcm)

    def ext80(value):
        exponent = value.bit_length() - 1
        return struct.pack(">HQ", 16383 + exponent, value << (63 - exponent))

    comm = struct.pack(">hIh", 2, frames, 16) + ext80(rate)
    big = b"".join(pcm[i + 1:i + 2] + pcm[i:i + 1] for i in range(0, len(pcm), 2))
    ssnd = struct.pack(">II", 0, 0) + big
    aiff = b"FORM" + struct.pack(">I", 4 + 26 + 8 + len(ssnd)) + b"AIFF" + chunk(b"COMM", comm, True) + chunk(b"SSND", ssnd, True)

    ds64 = struct.pack("<QQQI", 0, len(pcm), frames, 0)
    rf64 = b"RF64\xff\xff\xff\xffWAVE" + chunk(b"ds64", ds64) + chunk(b"fmt ", fmt16) + b"data\xff\xff\xff\xff" + pcm
    rf64 = rf64[:20] + struct.pack("<Q", len(rf64) - 8) + rf64[28:]

    guid = b"\xf3\xac\xd3\x11\x8c\xd1\x00\xc0\x4f\x8e\xdb\x8a"
    def w64chunk(tag, body):
        return tag + guid + struct.pack("<Q", 24 + len(body)) + body + b"\0" * (-len(body) % 8)
    w64body = b"wave" + guid + w64chunk(b"fmt ", fmt16) + w64chunk(b"data", pcm)
    w64 = b"riff\x2e\x91\xcf\x11\xa5\xd6\x28\xdb\x04\xc1\x00\x00" + struct.pack("<Q", 24 + len(w64body)) + w64body

    # MS ADPCM: the standard seven coefficient pairs, 512-byte blocks of noise.
    coefficients = [(256, 0), (512, -256), (0, 0), (192, 64), (240, 0), (460, -208), (392, -232)]
    msfmt = struct.pack("<HHIIHHHHH", 2, 2, rate, rate * 512 // 500, 512, 4, 32, 500, 7)
    msfmt += b"".join(struct.pack("<hh", a, b) for a, b in coefficients)
    blocks = bytearray()
    for _ in range(40):
        block = bytearray(rng.randrange(256) for _ in range(512))
        block[0] = block[1] = rng.randrange(7)
        blocks += block
    msadpcm = b"RIFF" + struct.pack("<I", 4 + 8 + len(msfmt) + 12 + 8 + len(blocks)) + b"WAVE" + chunk(b"fmt ", msfmt) \
        + chunk(b"fact", struct.pack("<I", 40 * 500)) + chunk(b"data", bytes(blocks))

    # FLAC: STREAMINFO, then VERBATIM 16-bit stereo frames of 4096.
    def crc(data, poly, width):
        value = 0
        for byte in data:
            value ^= byte << (width - 8)
            for _ in range(8):
                value = ((value << 1) ^ poly) if value & (1 << (width - 1)) else value << 1
                value &= (1 << width) - 1
        return value
    flac_frames = []
    for number, start in enumerate(range(0, frames, 4096)):
        n = min(4096, frames - start)
        head = bytes([0xFF, 0xF8, 0x79, 0x18, number]) + (n - 1).to_bytes(2, "big")
        head += bytes([crc(head, 0x07, 8)])
        body = bytearray()
        for channel in range(2):
            body.append(0x02)  # VERBATIM
            for f in range(start, start + n):
                body += pcm[f * 4 + channel * 2:f * 4 + channel * 2 + 2][::-1]
        frame = head + bytes(body)
        flac_frames.append(frame + crc(frame, 0x8005, 16).to_bytes(2, "big"))
    info = struct.pack(">HH", 4096, 4096) + b"\0" * 6 + ((rate << 44) | (1 << 41) | (15 << 36) | frames).to_bytes(8, "big") + b"\0" * 16
    flac = b"fLaC\x80\x00\x00\x22" + info + b"".join(flac_frames)

    # MP3: an Info frame, then silent MPEG-1 Layer III frames of 417 bytes.
    info_frame = bytearray(417)
    info_frame[:4] = b"\xff\xfb\x90\x64"
    info_frame[36:40] = b"Info"
    info_frame[40:48] = struct.pack(">II", 7, 60)
    info_frame[48:52] = struct.pack(">I", 61 * 417)
    info_frame[52:152] = bytes(range(0, 250, 2)[:100])
    mp3 = bytes(info_frame) + (b"\xff\xfb\x90\x64" + b"\0" * 413) * 60

    sources = {"wav": (wav, ".wav", 44), "aiff": (aiff, ".aiff", 54), "rf64": (rf64, ".wav", 80),
               "w64": (w64, ".w64", 128), "flac": (flac, ".flac", 42), "mp3": (mp3, ".mp3", 417),
               "msadpcm": (msadpcm, ".wav", 90)}

    def put(data, at, value, width, big_endian=False):
        data[at:at + width] = value.to_bytes(width, "big" if big_endian else "little")

    for name, (source, suffix, audio) in sources.items():
        big_endian = name in ("aiff", "flac", "mp3")
        # Each container's data chunk size field (FLAC: the STREAMINFO block
        # length, MP3: the Info frame's frame count).
        size_at = {"wav": 40, "aiff": 42, "rf64": 76, "w64": 96, "flac": 5, "mp3": 44, "msadpcm": 86}[name]
        width = {"w64": 8, "flac": 3}.get(name, 4)
        shapes = {}
        shapes["truncated-in-header"] = source[:audio // 2]
        shapes["truncated-mid-frame"] = source[:audio + (len(source) - audio) // 2 + 3]
        for shape, region in (("flipped-header", (0, audio)), ("flipped-frames", (audio, len(source)))):
            data = bytearray(source)
            for _ in range(8):
                data[rng.randrange(*region)] ^= 1 << rng.randrange(8)
            shapes[shape] = data
        for shape, value in (("size-zero", 0), ("size-max", (1 << (8 * width)) - 1),
                             ("size-past-end", min(len(source) * 4, (1 << (8 * width)) - 1)), ("size-odd", 1001)):
            data = bytearray(source)
            put(data, size_at, value, width, big_endian)
            shapes[shape] = data
        data = bytearray(source)
        data[audio + 101:audio + 105] = {"flac": b"\xff\xf8\x79\x18", "mp3": b"\xff\xfb\x90\x64"}.get(name, b"data")
        shapes["sync-mid-frame"] = data
        if name in ("wav", "msadpcm"):
            data = bytearray(source)
            put(data, 24, rng.choice([0, 1, 0xFFFFFFFF, 384001]), 4)
            shapes["extreme-rate"] = data
            fmt_end = 20 + struct.unpack_from("<I", source, 16)[0]
            shapes["duplicated-chunk"] = source[:fmt_end] + source[12:fmt_end] + source[fmt_end:]
            shapes["fmt-after-data"] = source[:12] + source[fmt_end:] + source[12:fmt_end]
        if name == "wav":
            fact = chunk(b"fact", struct.pack("<I", frames * 4))
            data = bytearray(source[:36] + fact + source[36:])
            put(data, 4, len(data) - 8, 4)
            shapes["fact-count-past-data"] = data
        if name == "msadpcm":
            for shape, count in (("table-cut-short", 200), ("table-of-no-pairs", 0)):
                data = bytearray(source)
                put(data, 40, count, 2)
                shapes[shape] = data
            data = bytearray(source)
            put(data, 78, 40 * 500 * 3, 4)  # the fact chunk's count
            shapes["fact-count-past-data"] = data
        if name == "aiff":
            data = bytearray(source)
            put(data, 22, frames * 3, 4, True)
            shapes["comm-count-past-data"] = data
            data = bytearray(source)
            put(data, 28, 0x7FFF, 2, True)
            shapes["extreme-rate"] = data
            for shape, size in (("comm-23-bytes", 23), ("comm-odd-size", 19), ("comm-longer-than-18", 26)):
                grown = source[:38] + b"\0" * (size + (size & 1) - 18) + source[38:]
                data = bytearray(grown)
                put(data, 16, size, 4, True)
                put(data, 4, len(data) - 8, 4, True)
                shapes[shape] = data
        if name == "rf64":
            data = bytearray(source)
            put(data, 36, frames * 5, 8)
            shapes["ds64-count-past-data"] = data
        if name == "flac":
            # STREAMINFO's packed word is at 18: 20 bits of rate, 3 of channels,
            # 5 of depth, then 36 of total samples.
            data = bytearray(source)
            data[18:20] = b"\xff\xff"
            data[20] |= 0xF0
            shapes["extreme-rate"] = data
            data = bytearray(source)
            data[20] |= 0x0F
            data[21:26] = b"\xff" * 5
            shapes["extreme-count"] = data
            points = b"".join(struct.pack(">QQH", k * 4096, len(source) * (k + 1), 4096) for k in range(4))
            shapes["seek-table-past-end"] = b"fLaC\x00\x00\x00\x22" + info + b"\x83" + len(points).to_bytes(3, "big") \
                + points + b"".join(flac_frames)
        if name == "mp3":
            data = bytearray(source)
            put(data, 48, 0xFFFFFFFF, 4, True)
            data[52:152] = b"\xff" * 100
            shapes["seek-table-past-end"] = data
            data = bytearray(source)
            put(data, 44, 0xFFFFFFFF, 4, True)
            shapes["extreme-count"] = data
        for shape, data in shapes.items():
            (folder / f"{name}-{shape}{suffix}").write_bytes(bytes(data))
    return len(list(folder.iterdir()))


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
            # A different volume, or no hard links: copy instead.
            shutil.copy2(src, dest)
            linked += 1

    # -- files that are audio-shaped and are not ---------------------------
    made = []
    for suffix in (".mp3", ".flac", ".wav", ".m4a", ".aiff"):
        p = broken / f"zero-length{suffix}"
        p.write_bytes(b"")
        made.append(p)
    # Enough empty files that a retrying run which stranded a descriptor per
    # attempt would meet a 256 soft limit.
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

    # An ID3v2 header announcing a ~256 MB synchsafe tag on a 4 KB file; read
    # as a plain integer the size is ~2 GB.
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

    # Both reach the open funnel's path handling rather than any decoder.
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
        # A cue naming a file that IS there, so entry resolution can succeed.
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
            # 64 MB of JPEG-headed noise: the bounded decode must refuse it
            # without holding it in memory.
            with open(albums[4] / "folder.jpg", "wb") as fh:
                fh.write(b"\xff\xd8\xff\xe0")
                for _ in range(64):
                    fh.write(os.urandom(1024 * 1024))

    # Last, so the cases above draw the same random numbers as before.
    malformed = out / "malformed audio"
    malformed.mkdir()
    shapes = malformed_audio(malformed, rng)

    total = sum(f.stat().st_size for f in out.rglob("*") if f.is_file() and not f.is_symlink())
    print(f"{linked} real tracks hard-linked, {len(list(broken.iterdir()))} broken entries, "
          f"{len(awkward)} awkward names, {len(albums)} art folders, {shapes} malformed audio shapes")
    print(f"corpus: {out}  ({total // (1024 * 1024)} MB of new bytes)")


if __name__ == "__main__":
    main()
