#!/usr/bin/env python3
"""Build a corpus of cue sheets, valid and invalid, around real audio.

A sheet turns one file into many rows, each a window the player treats as the
whole track, so the interesting failures are a window the file does not reach,
a sheet that resolves nothing, and two rows of one file racing each other.
This lays every sheet shape the reader accepts or refuses beside real images:

    sidecar-exact/       real album images, each with a sheet naming it exactly
    sidecar-real/        real sheets as downloaded: the FILE names a file that is
                         not there, so the named-like-the-sheet rung resolves it
    sidecar-multifile/   real per-track sheets whose files are all missing: the
                         sheet claims nothing and the image plays whole
    multifile-real/      real per-track sheets whose tracks ARE there, under
                         another spelling (a Windows subfolder, .wav for .flac)
    multifile-exact/     one FILE per track, each named exactly
    multi-image/         one sheet over two album images, many windows in each,
                         and one mixing an image's windows with whole tracks
    eac-per-track/       one sheet over several real track files, pregaps in
                         the file before (EAC's noncompliant layout)
    variants/            one image and every sheet shape beside it: encodings,
                         line endings, path spellings, junk, empty windows,
                         windows past the end, an unplayable image, ...
    embedded/            FLAC images carrying their own sheet: the binary
                         CUESHEET block and foobar's CUESHEET= comment, valid,
                         corrupt, single-track, past the end, under the size gate
    m3u/                 saved playlists with #VIBE-CUE rows, valid and malformed
    plain/               ordinary tracks, so a run keeps crossing to a plain file

Real files are HARD LINKED (no space; a path inside the corpus keeps the
sandbox grant working). An embedded variant that only rewrites the trailing
PADDING block is an APFS clone (`cp -c`) changed in place, so it costs a few
kilobytes; the comment variant needs its metadata grown and is a full copy.

    make-cue-corpus.py --source ~/Music/big [--out build/cue-corpus] [--plain 30]

Nothing here writes to --source.
"""

import argparse
import os
import pathlib
import random
import re
import shutil
import struct
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from stress import AUDIO_SUFFIXES  # noqa: E402

EMBEDDED_MINIMUM = 100 * 1024 * 1024    # NSURLUtil's kVibeEmbeddedCueMinimumBytes
CD_FRAMES = 75


# --------------------------------------------------------------------------
# Source discovery
# --------------------------------------------------------------------------

def walk(source):
    for dirpath, dirnames, filenames in os.walk(source):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        yield pathlib.Path(dirpath), sorted(f for f in filenames if not f.startswith("."))


def read_text(path):
    data = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-16", "latin-1"):
        try:
            text = data.decode(encoding)
            if "TRACK" in text.upper():
                return text
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")


def index01_frames(text):
    """INDEX 01 starts of each AUDIO track, in CD frames, in sheet order."""
    starts = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].upper() == "INDEX" and parts[1] == "01":
            mm, ss, ff = (parts[2].split(":") + ["0", "0"])[:3]
            try:
                starts.append((int(mm) * 60 + int(ss)) * CD_FRAMES + int(ff))
            except ValueError:
                pass
    return starts


def find_pairs(source):
    """(sheet, image): an image named like its sheet, single FILE or many."""
    single, multi = [], []
    for here, names in walk(source):
        for name in names:
            if not name.lower().endswith(".cue"):
                continue
            sheet = here / name
            image = sheet.with_suffix(".flac")
            if not image.exists() or image.stat().st_size < EMBEDDED_MINIMUM:
                continue
            text = read_text(sheet)
            files = sum(1 for line in text.splitlines() if line.strip().upper().startswith("FILE"))
            starts = index01_frames(text)
            if len(starts) < 3:
                continue
            (single if files == 1 else multi).append((sheet, image, text, starts))
    return single, multi


def resolve_beside(sheet_dir, name):
    """The FILE the reader would find by its basename or another extension."""
    base = sheet_dir / pathlib.PureWindowsPath(name).name
    if base.exists():
        return base
    for suffix in AUDIO_SUFFIXES:
        if base.with_suffix(suffix).exists():
            return base.with_suffix(suffix)
    return None


def find_resolvable_multifile(source):
    """(sheet, its resolved files): per-track sheets whose every FILE is there."""
    found = []
    for here, names in walk(source):
        for name in names:
            if not name.lower().endswith(".cue"):
                continue
            text = read_text(here / name)
            files = [m.group(1) or m.group(2).strip() for m in re.finditer(
                r'(?im)^\s*FILE\s+(?:"([^"]*)"|(.+?))\s+\w+\s*$', text)]
            if len(files) < 3:
                continue
            resolved = [resolve_beside(here, f) for f in files]
            if all(resolved):
                found.append((here / name, resolved))
    return found


def find_track_folder(source, rng):
    """A folder of four or more real FLAC or WAV tracks, for the per-track sheet."""
    candidates = []
    for here, names in walk(source):
        tracks = [here / n for n in names if pathlib.Path(n).suffix.lower() in {".flac", ".wav"}
                  and (here / n).stat().st_size < EMBEDDED_MINIMUM
                  and (here / n).stat().st_size > 8 * 1024 * 1024]
        if len(tracks) >= 4:
            candidates.append(tracks[:4])
    return rng.choice(candidates) if candidates else None


def find_plain(source, rng, want):
    pool = [here / n for here, names in walk(source) for n in names
            if pathlib.Path(n).suffix.lower() in AUDIO_SUFFIXES
            and (here / n).stat().st_size < EMBEDDED_MINIMUM]
    rng.shuffle(pool)
    return pool[:want]


# --------------------------------------------------------------------------
# FLAC metadata
# --------------------------------------------------------------------------

def flac_blocks(path):
    """[(type, header offset, length, last)] and STREAMINFO's rate and samples."""
    blocks, rate, samples = [], 0, 0
    with open(path, "rb") as fh:
        head = fh.read(10)
        start = 0
        if head[:3] == b"ID3":
            start = 10 + ((head[6] & 0x7F) << 21 | (head[7] & 0x7F) << 14
                          | (head[8] & 0x7F) << 7 | (head[9] & 0x7F))
        fh.seek(start)
        if fh.read(4) != b"fLaC":
            return None
        while True:
            at = fh.tell()
            header = fh.read(4)
            if len(header) < 4:
                break
            kind, length, last = header[0] & 0x7F, int.from_bytes(header[1:4], "big"), bool(header[0] & 0x80)
            if kind == 0:
                info = fh.read(length)
                rate = (info[10] << 12) | (info[11] << 4) | (info[12] >> 4)
                samples = ((info[13] & 0x0F) << 32) | int.from_bytes(info[14:18], "big")
            else:
                fh.seek(length, 1)
            blocks.append((kind, at, length, last))
            if last:
                break
    return blocks, rate, samples


def cuesheet_block(rate, total, track_offsets, *, non_audio=(), count_override=None):
    """A binary CUESHEET body: one INDEX 01 per track, then the lead-out."""
    body = bytearray(128)                                    # media catalog
    body += struct.pack(">Q", 88200)                         # lead-in
    body += bytes([0x80]) + bytes(258)                       # is-CD, reserved
    tracks = len(track_offsets) + 1
    body.append(count_override if count_override is not None else tracks)
    for number, offset in enumerate(track_offsets, start=1):
        body += struct.pack(">Q", offset) + bytes([number]) + bytes(12)
        body += bytes([0x80 if number in non_audio else 0]) + bytes(13)
        body += bytes([1]) + struct.pack(">Q", 0) + bytes([1]) + bytes(3)
    body += struct.pack(">Q", total) + bytes([170]) + bytes(12) + bytes(14) + bytes([0])
    return bytes(body)


def write_into_padding(image, out, payload_kind, payload):
    """Clone the image and turn its trailing PADDING into payload + padding."""
    parsed = flac_blocks(image)
    if not parsed:
        return False
    blocks = parsed[0]
    kind, at, length, last = blocks[-1]
    if kind != 1 or length < len(payload) + 4:
        return False
    subprocess.run(["cp", "-c", str(image), str(out)], check=True)
    with open(out, "r+b") as fh:
        fh.seek(at)
        fh.write(bytes([payload_kind]) + len(payload).to_bytes(3, "big") + payload)
        rest = length - len(payload) - 4
        fh.write(bytes([0x80 | 1]) + rest.to_bytes(3, "big") + bytes(rest))
    return True


def write_with_comment(image, out, comment):
    """A full copy whose VORBIS_COMMENT gains one more comment."""
    parsed = flac_blocks(image)
    if not parsed:
        return False
    blocks = parsed[0]
    with open(image, "rb") as src, open(out, "wb") as dst:
        first = blocks[0][1]
        dst.write(src.read(first))                           # ID3, if any, and fLaC
        for i, (kind, at, length, _) in enumerate(blocks):
            src.seek(at + 4)
            body = src.read(length)
            if kind == 4:
                vendor = struct.unpack("<I", body[:4])[0]
                count_at = 4 + vendor
                count = struct.unpack("<I", body[count_at:count_at + 4])[0]
                extra = comment.encode("utf-8")
                body = (body[:count_at] + struct.pack("<I", count + 1) + body[count_at + 4:]
                        + struct.pack("<I", len(extra)) + extra)
            flag = 0x80 if i == len(blocks) - 1 else 0
            dst.write(bytes([flag | kind]) + len(body).to_bytes(3, "big") + body)
        src.seek(blocks[-1][1] + 4 + blocks[-1][2])
        shutil.copyfileobj(src, dst, 8 * 1024 * 1024)
    return True


# --------------------------------------------------------------------------
# Sheets
# --------------------------------------------------------------------------

def stamp(frames):
    return f"{frames // (60 * CD_FRAMES):02d}:{frames // CD_FRAMES % 60:02d}:{frames % CD_FRAMES:02d}"


def sheet(file_line, starts, *, titles=True, eol="\n", performer="Vibe Stress", index_fmt=stamp,
          extra_per_track=""):
    lines = [f'PERFORMER "{performer}"', 'TITLE "Cue corpus"', file_line]
    for n, start in enumerate(starts, start=1):
        lines.append(f"  TRACK {n:02d} AUDIO")
        if titles:
            lines.append(f'    TITLE "Row {n}"')
        if extra_per_track:
            lines.append(extra_per_track)
        lines.append(f"    INDEX 01 {index_fmt(start)}")
    return eol.join(lines) + eol


def link(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dst.exists():
        os.link(src, dst)
    return dst


def build(source, out, rng, plain_count):
    single, multi = find_pairs(source)
    if len(single) < 4:
        sys.exit(f"need at least 4 single-image sheet+FLAC pairs under {source}, found {len(single)}")
    rng.shuffle(single)
    rng.shuffle(multi)
    made = []

    # sidecar-exact: sheets rewritten to name their image exactly.
    for sheet_path, image, text, starts in single[:3]:
        d = out / "sidecar-exact"
        img = link(image, d / image.name)
        (d / sheet_path.name).write_text(sheet(f'FILE "{img.name}" WAVE', starts), encoding="utf-8")
        made.append(f"sidecar-exact/{sheet_path.name}")

    # sidecar-real: the downloaded sheet as-is, whatever its encoding and FILE line.
    for sheet_path, image, _, _ in single[3:6]:
        d = out / "sidecar-real"
        link(image, d / image.name)
        link(sheet_path, d / sheet_path.name)
        made.append(f"sidecar-real/{sheet_path.name}")

    # sidecar-multifile: per-track sheets whose track files are absent.
    for sheet_path, image, _, _ in multi[:2]:
        d = out / "sidecar-multifile"
        link(image, d / image.name)
        link(sheet_path, d / sheet_path.name)
        made.append(f"sidecar-multifile/{sheet_path.name}")

    # variants: one image, every sheet shape beside it.
    v_sheet, v_image, _, v_starts = single[0]
    v = out / "variants"
    img = link(v_image, v / "image.flac")
    link(v_image, v / "image with spaces.flac")
    parsed = flac_blocks(img)
    rate, samples = parsed[1], parsed[2]
    seconds = samples // rate if rate else 3600
    s = v_starts[:12]
    ok = f'FILE "image.flac" WAVE'
    variants = {
        "utf8-bom.cue": ("\ufeff" + sheet(ok, s)).encode("utf-8"),
        "utf16le-bom.cue": sheet(ok, s, performer="Bjørk Ünïcødé").encode("utf-16"),
        "utf16be-nobom.cue": sheet(ok, s).encode("utf-16-be"),
        "latin1-crlf.cue": sheet(ok, s, performer="Röyksopp", eol="\r\n").encode("latin-1"),
        "cr-only.cue": sheet(ok, s, eol="\r").encode(),
        "tabs.cue": sheet(ok, s).replace("  ", "\t").encode(),
        "unquoted-spaces.cue": sheet("FILE image with spaces.flac WAVE", s).encode(),
        "lowercase-keywords.cue": sheet(ok, s).lower().encode(),
        "windows-path.cue": sheet(r'FILE "C:\Rips\Album\image.flac" WAVE', s).encode(),
        "wrong-extension.cue": sheet('FILE "image.wav" WAVE', s).encode(),
        "relative-dotdot.cue": sheet('FILE "../variants/image.flac" WAVE', s).encode(),
        "absolute-path.cue": sheet(f'FILE "{img.resolve()}" WAVE', s).encode(),
        "repeated-file.cue": "\n".join(
            [ok + f"\n  TRACK {n:02d} AUDIO\n    INDEX 01 {stamp(t)}" for n, t in enumerate(s, 1)]).encode(),
        "mmss-only.cue": sheet(ok, s, index_fmt=lambda f: f"{f // (60 * CD_FRAMES):02d}:{f // CD_FRAMES % 60:02d}").encode(),
        "minutes-past-99.cue": sheet(ok, [0, 150 * 60 * CD_FRAMES, 200 * 60 * CD_FRAMES]).encode(),
        "pregaps.cue": sheet(ok, s, extra_per_track="    INDEX 00 00:00:00").encode(),
        "no-titles.cue": sheet(ok, s, titles=False).encode(),
        "rem-and-flags.cue": sheet(ok, s, extra_per_track='    REM COMPOSER "x"\n    FLAGS DCP\n    ISRC USABC1234567\n    PREGAP 00:02:00').encode(),
        "data-tracks.cue": (ok + "\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n"
                            + "".join(f"  TRACK {n:02d} AUDIO\n    INDEX 01 {stamp(t)}\n" for n, t in enumerate(s[1:], 2))).encode(),
        "single-track.cue": sheet(ok, [0]).encode(),
        "no-index.cue": (ok + "\n  TRACK 01 AUDIO\n  TRACK 02 AUDIO\n").encode(),
        "no-file-line.cue": sheet("REM no file", s).encode(),
        "thousand-rows.cue": sheet(ok, [n * CD_FRAMES for n in range(min(1000, max(2, seconds - 1)))], titles=False).encode(),
        "tiny-windows.cue": sheet(ok, list(range(0, 99))).encode(),
        "out-of-order.cue": sheet(ok, [0, 9000, 4500, 13500, 6000]).encode(),
        "duplicate-starts.cue": sheet(ok, [0, 4500, 4500, 4500, 9000]).encode(),
        "past-the-end.cue": sheet(ok, [0, 4500, (seconds + 60) * CD_FRAMES, (seconds + 120) * CD_FRAMES]).encode(),
        "all-past-the-end.cue": sheet(ok, [(seconds + 60) * CD_FRAMES, (seconds + 120) * CD_FRAMES]).encode(),
        "junk-index.cue": (ok + "\n  TRACK 01 AUDIO\n    INDEX 01 xx:yy:zz\n  TRACK 02 AUDIO\n    INDEX 01 -1:00:00\n"
                           + "  TRACK 03 AUDIO\n    INDEX 01 9999999999:00:00\n  TRACK 04 AUDIO\n    INDEX 01 05:00:00\n").encode(),
        "track-without-index.cue": (ok + "\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE \"lost\"\n"
                                    + "  TRACK 03 AUDIO\n    INDEX 01 03:00:00\n").encode(),
        "unterminated-quote.cue": sheet('FILE "image.flac WAVE', s).encode(),
        "missing-image.cue": sheet('FILE "gone.flac" WAVE', s).encode(),
        "unplayable-image.cue": sheet('FILE "image.ape" WAVE', s).encode(),
        "names-a-folder.cue": sheet('FILE "afolder" WAVE', s).encode(),
        "names-itself.cue": sheet('FILE "names-itself.cue" WAVE', s).encode(),
        "names-a-sheet.cue": sheet('FILE "utf8-bom.cue" WAVE', s).encode(),
        "garbage-text.cue": b"this is not a cue sheet\nat all\n\x00\x01\x02TRACK\n",
        "garbage-binary.cue": bytes(rng.randrange(256) for _ in range(4096)),
        "empty.cue": b"",
        "huge-line.cue": (ok + "\n  TRACK 01 AUDIO\n    TITLE \"" + "x" * 200_000 + "\"\n    INDEX 01 00:00:00\n").encode(),
    }
    (v / "afolder").mkdir(exist_ok=True)
    (v / "image.ape").write_bytes(b"MAC " + bytes(rng.randrange(256) for _ in range(65536)))
    for name, data in variants.items():
        (v / name).write_bytes(data)
    made += [f"variants/{n}" for n in variants]

    # eac-per-track: one sheet across real track files, pregaps before each.
    tracks = find_track_folder(source, rng)
    if tracks:
        d = out / "eac-per-track"
        # Each track's INDEX 00 sits in the file before its own, its INDEX 01
        # at the start of its own file.
        lines = ['PERFORMER "Vibe Stress"', 'TITLE "Per-track"']
        for n, track in enumerate(tracks, start=1):
            name = f"{n:02d}{track.suffix.lower()}"
            link(track, d / name)
            lines.append(f'FILE "{name}" WAVE')
            if n == 1:
                lines += ["  TRACK 01 AUDIO", '    TITLE "Track file 1"']
            lines.append("    INDEX 01 00:00:00")
            if n < len(tracks):
                lines += [f"  TRACK {n + 1:02d} AUDIO", f'    TITLE "Track file {n + 1}"',
                          "    INDEX 00 00:20:00"]
        (d / "per-track.cue").write_text("\n".join(lines) + "\n")
        made.append("eac-per-track/per-track.cue")

    # multifile-real: a downloaded per-track sheet whose tracks resolve by
    # another spelling; every copy of such a sheet in its folder comes along.
    real_multi = find_resolvable_multifile(source)
    exact_tracks = []
    if real_multi:
        first_dir = real_multi[0][0].parent
        d = out / "multifile-real"
        for sheet_path, resolved in real_multi:
            if sheet_path.parent != first_dir:
                continue
            link(sheet_path, d / sheet_path.name)
            for track in resolved:
                link(track, d / track.name)
            made.append(f"multifile-real/{sheet_path.name}")
            exact_tracks = exact_tracks or resolved
    # multifile-exact: one FILE per track, named exactly.
    if exact_tracks:
        d = out / "multifile-exact"
        lines = ['PERFORMER "Vibe Stress"', 'TITLE "One file per track"']
        for n, track in enumerate(exact_tracks, start=1):
            link(track, d / track.name)
            lines += [f'FILE "{track.name}" WAVE', f"  TRACK {n:02d} AUDIO",
                      f'    TITLE "File {n}"', "    INDEX 01 00:00:00"]
        (d / "one-file-per-track.cue").write_text("\n".join(lines) + "\n")
        made.append("multifile-exact/one-file-per-track.cue")

    # multi-image: one sheet across two album images, then images and whole
    # tracks in one sheet.
    d = out / "multi-image"
    (a_sheet, a_image, _, a_starts), (b_sheet, b_image, _, b_starts) = single[0], single[2]
    a = link(a_image, d / "disc-1.flac")
    b = link(b_image, d / "disc-2.flac")
    lines = ['PERFORMER "Vibe Stress"', 'TITLE "Two discs"', f'FILE "{a.name}" WAVE']
    number = 0
    for start in a_starts:
        number += 1
        lines += [f"  TRACK {number:02d} AUDIO", f'    TITLE "Disc 1 row {number}"', f"    INDEX 01 {stamp(start)}"]
    lines.append(f'FILE "{b.name}" WAVE')
    for i, start in enumerate(b_starts, start=1):
        number += 1
        lines += [f"  TRACK {number:02d} AUDIO", f'    TITLE "Disc 2 row {i}"', f"    INDEX 01 {stamp(start)}"]
    (d / "two-discs.cue").write_text("\n".join(lines) + "\n")
    made.append("multi-image/two-discs.cue")
    if exact_tracks:
        lines = ['PERFORMER "Vibe Stress"', 'TITLE "Image and tracks"', f'FILE "{a.name}" WAVE']
        for n, start in enumerate(a_starts[:5], start=1):
            lines += [f"  TRACK {n:02d} AUDIO", f"    INDEX 01 {stamp(start)}"]
        for n, track in enumerate(exact_tracks[:2], start=6):
            link(track, d / track.name)
            lines += [f'FILE "{track.name}" WAVE', f"  TRACK {n:02d} AUDIO", "    INDEX 01 00:00:00"]
        (d / "image-and-tracks.cue").write_text("\n".join(lines) + "\n")
        made.append("multi-image/image-and-tracks.cue")

    # embedded: images carrying their own sheet.
    e = out / "embedded"
    e.mkdir(parents=True, exist_ok=True)
    e_sheet, e_image, _, e_starts = single[1]
    parsed = flac_blocks(e_image)
    e_rate, e_samples = parsed[1], parsed[2]
    offsets = [round(f * e_rate / CD_FRAMES) // 588 * 588 for f in e_starts]
    embedded = {
        "binary-cuesheet.flac": (5, cuesheet_block(e_rate, e_samples, offsets)),
        "binary-with-data-track.flac": (5, cuesheet_block(e_rate, e_samples, offsets, non_audio={1})),
        "binary-single-track.flac": (5, cuesheet_block(e_rate, e_samples, offsets[:1])),
        "binary-past-the-end.flac": (5, cuesheet_block(e_rate, e_samples, offsets[:2] + [e_samples + 44100 * 60])),
        "binary-same-offsets.flac": (5, cuesheet_block(e_rate, e_samples, [offsets[1]] * 4)),
        "binary-truncated.flac": (5, cuesheet_block(e_rate, e_samples, offsets[:3], count_override=99)),
        "binary-garbage.flac": (5, bytes(rng.randrange(256) for _ in range(900))),
    }
    for name, (kind, payload) in embedded.items():
        if write_into_padding(e_image, e / name, kind, payload):
            made.append(f"embedded/{name}")
    # A sidecar beside an image with its own sheet: the sidecar's titles win the file.
    if (e / "binary-cuesheet.flac").exists():
        both = e / "both-sidecar-and-embedded.flac"
        subprocess.run(["cp", "-c", str(e / "binary-cuesheet.flac"), str(both)], check=True)
        (e / "both-sidecar-and-embedded.cue").write_text(
            sheet(f'FILE "{both.name}" WAVE', e_starts, performer="Sidecar Wins"))
        made.append("embedded/both-sidecar-and-embedded.cue")
    text_sheet = sheet('FILE "whatever.wav" WAVE', e_starts, performer="Embedded Text")
    if write_with_comment(e_image, e / "comment-cuesheet.flac", "CUESHEET=" + text_sheet):
        made.append("embedded/comment-cuesheet.flac")
    if write_with_comment(e_image, e / "comment-garbage.flac", "CUESHEET=\x00\x01 not a sheet TRACK INDEX"):
        made.append("embedded/comment-garbage.flac")
    # Under the size gate: never opened to look.
    small = [p for p in find_plain(source, rng, 400) if p.suffix.lower() == ".flac"]
    for candidate in small:
        parsed = flac_blocks(candidate)
        if not parsed or not parsed[1]:
            continue
        payload = cuesheet_block(parsed[1], parsed[2], [0, parsed[2] // 3 // 588 * 588])
        if write_into_padding(candidate, e / "small-under-gate.flac", 5, payload):
            made.append("embedded/small-under-gate.flac")
            break

    # m3u: saved playlists with #VIBE-CUE rows.
    m = out / "m3u"
    m.mkdir(parents=True, exist_ok=True)
    rel = "../variants/image.flac"
    sheet_url = (v / "utf8-bom.cue").resolve().as_uri()
    rows = "".join(f"#EXTINF:60,Row {n}\n#VIBE-CUE:{n},{a},{b},Row%20{n},Vibe%2C%20Stress,{sheet_url}\n{rel}\n"
                   for n, (a, b) in enumerate(zip(s, s[1:] + [0]), start=1))
    playlists = {
        "valid-rows.m3u": "#EXTM3U\n" + rows,
        "valid-rows.m3u8": "#EXTM3U\n" + rows,
        "malformed-rows.m3u": "#EXTM3U\n" + "".join(f"#VIBE-CUE:{p}\n{rel}\n" for p in [
            "1,2,3", "1,9000,4500,a,b,", "1,-5,10,a,b,", "x,y,z,%ZZ,%,", "1,0,0,,,",
            "1,99999999999999999999,0,a,b,", "1,4500,9000,a,b,http://example.com/x.cue",
            ",,,,,", "1,4500,9000,a,b,file:///nowhere/x.cue"]),
        "dangling-directive.m3u": f"#EXTM3U\n#VIBE-CUE:1,0,4500,a,b,\n#EXTINF:1,x\n#VIBE-CUE:2,4500,0,a,b,\n",
        "all-missing.m3u": "#EXTM3U\n../variants/gone-1.flac\n../variants/gone-2.flac\n",
        "lists-playlists.m3u": "#EXTM3U\n../variants/utf8-bom.cue\nvalid-rows.m3u\n",
        "mixed.m3u": "#EXTM3U\n" + rows + "../variants/gone.flac\n../embedded/binary-cuesheet.flac\n",
    }
    for name, text in playlists.items():
        (m / name).write_text(text)
    made += [f"m3u/{n}" for n in playlists]

    # plain: ordinary tracks.
    p = out / "plain"
    for i, track in enumerate(find_plain(source, rng, plain_count)):
        link(track, p / f"{i:02d} {track.name}")

    return made


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--out", default="build/cue-corpus", type=pathlib.Path)
    parser.add_argument("--plain", type=int, default=30)
    parser.add_argument("--seed", type=int, default=104)
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    out = args.out.resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    made = build(source, out, random.Random(args.seed), args.plain)
    size = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    print(f"{len(made)} sheets and sheet-carrying files, {sum(1 for _ in out.rglob('*') if _.is_file())} files, "
          f"{size >> 20} MB apparent")
    print(f"corpus: {out}")


if __name__ == "__main__":
    main()
