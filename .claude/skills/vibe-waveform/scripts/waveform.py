#!/usr/bin/env python3
"""The vibe-waveform probe: a real file's waveform, decoded by the production
loader and drawn by the production renderer as the iOS scrubber lays it out.
It runs VibeBenchComponents --waveform, which perf.py builds at any ref.

    waveform.py draw FILE [--ref REF] PROBE-OPTIONS...
    waveform.py compare FILE --out OUT.png [--base REF] [--head REF] PROBE-OPTIONS...
    waveform.py options                     the probe's own options

draw runs the probe once: at REF, or the working tree. compare draws the same
view at BASE (default main) and HEAD (default the working tree) and stacks
them in OUT.png, base on top. Each side's own output follows its label. With
--deliveries DIR, compare writes DIR/base and DIR/head, and each side's
deliveries are tiled top to bottom in DIR/<side>.png.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'vibe-perf/scripts'))
import perf  # noqa: E402  builds VibeBenchComponents at a ref


def option(args, name, default=None):
    """Removes `name VALUE` from args and answers VALUE."""
    if name in args:
        i = args.index(name)
        value = args[i + 1]
        del args[i:i + 2]
        return value
    return default


def probe(ref, file, args):
    binary = perf.build(ref)
    return subprocess.run([str(binary), '--waveform', file, *args]).returncode


def tile(directory, out):
    """The directory's NNN.png pictures, top to bottom, in one picture."""
    frames = sorted(Path(directory).glob('[0-9][0-9][0-9].png'))
    if not frames:
        return
    inputs = [arg for frame in frames for arg in ('-i', str(frame))]
    stack = f'vstack=inputs={len(frames)}' if len(frames) > 1 else 'null'
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', *inputs, '-filter_complex', stack, str(out)], check=True)


def main(argv):
    if not argv or argv[0] not in ('draw', 'compare', 'options'):
        print(__doc__)
        return 64
    command, args = argv[0], argv[1:]
    if command == 'options':
        return probe(None, '--help', [])
    if not args:
        print(__doc__)
        return 64
    file, args = args[0], args[1:]
    if command == 'draw':
        return probe(option(args, '--ref'), file, args)
    out = option(args, '--out')
    if not out:
        sys.exit('compare needs --out')
    base, head = option(args, '--base', 'main'), option(args, '--head')
    deliveries = option(args, '--deliveries')
    sides = []
    for label, ref in (('base', base), ('head', head)):
        picture = Path(out).with_name(f'{Path(out).stem}-{label}.png')
        side = [*args, '--out', str(picture)]
        if deliveries:
            side += ['--deliveries', str(Path(deliveries) / label)]
        print(f'== {label}: {ref or "working tree"}', flush=True)
        if probe(ref, file, side):
            return 1
        if deliveries:
            tile(Path(deliveries) / label, Path(deliveries) / f'{label}.png')
        sides.append(picture)
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', str(sides[0]), '-i', str(sides[1]),
                    '-filter_complex', 'vstack=inputs=2', out], check=True)
    print(f'{out}: base on top, head below')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
