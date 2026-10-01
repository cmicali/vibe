#!/usr/bin/env python3
"""The vibe-perf micro-benchmark driver: build Tests/Perf's VibePerf at any ref,
run it over a fixed corpus, and compare two refs.

    perf.py corpus                         the corpus (make bench's, plus a few formats)
    perf.py build [REF]                    VibePerf for REF (default: the working tree)
    perf.py run [REF] [--filter RE] [--reps N] [--json OUT]
    perf.py compare BASE [HEAD] [--filter RE] [--reps N] [--rounds R] [--md OUT]
    perf.py list                           the benchmark names

REF is any git ref; HEAD defaults to the working tree, uncommitted edits
included. A ref older than the harness gets the working tree's Tests/Perf and
VibePerf target grafted on, so every ref runs the same suite.

compare alternates the two binaries ROUNDS times (default 3), REPS repetitions
each (default 3), so drift in the machine's load lands on both sides; the table
is the median of every sample. Instructions retired are the steady number
(load and clocks barely move them); wall and CPU time are what users feel but
move with whatever else the Mac runs.
"""
import json
import os
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
PERF = ROOT / 'build/perf'
CORPUS = ROOT / 'build/bench/corpus'
EXTRA = CORPUS / 'extra'


def sh(*args, **kw):
    return subprocess.run(args, check=True, **kw)


def ffmpeg(*args):
    sh('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args)


# Formats make bench's corpus leaves out, from its flac-16-44 so the content
# matches: the decoders dr_wav and Apple's other readers take.
EXTRAS = {
    'wav-16-44.wav': ['-c:a', 'pcm_s16le'],
    'aiff-16-44.aiff': ['-c:a', 'pcm_s16be'],
    'alac-16-44.m4a': ['-c:a', 'alac', '-sample_fmt', 's16p'],
    'opus.opus': ['-c:a', 'libopus', '-b:a', '160k'],
    'vorbis.ogg': ['-c:a', 'vorbis', '-strict', 'experimental', '-q:a', '6'],
}


def corpus():
    sys.path.insert(0, str(ROOT / 'scripts/bench'))
    import bench
    bench.make_corpus()
    EXTRA.mkdir(parents=True, exist_ok=True)
    source = CORPUS / 'play/flac-16-44.flac'
    for name, codec in EXTRAS.items():
        out = EXTRA / name
        if not out.exists():
            print(f'corpus: {name}', flush=True)
            tmp = out.with_name('tmp.' + name)
            ffmpeg('-i', str(source), '-map', '0:a', *codec, str(tmp))
            tmp.rename(out)


def resolve(ref):
    if ref is None:
        return None
    return subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--verify', ref + '^{commit}'],
                          check=True, capture_output=True, text=True).stdout.strip()


def graft(src):
    """Gives an older checkout the working tree's harness and target."""
    shutil.rmtree(src / 'Tests/Perf', ignore_errors=True)
    shutil.copytree(ROOT / 'Tests/Perf', src / 'Tests/Perf')
    project = (src / 'project.yml').read_text()
    if '\n  VibePerf:\n' in project:
        return
    current = (ROOT / 'project.yml').read_text()
    start = current.index('\n  # The micro-benchmark suite')
    end = current.index('\n  # Every shared subsystem minus its Mac/ half')
    anchor = '\n  # Every shared subsystem minus its Mac/ half'
    project = project.replace(anchor, current[start:end] + anchor, 1)
    s_start = current.index('  VibePerf:\n    build:')
    s_end = current.index('\n  VibeAudioTests:\n    build:')
    project = project.replace('schemes:\n', 'schemes:\n' + current[s_start:s_end] + '\n', 1)
    project = project.replace('          - "iOSDriver/**"', '          - "Perf/**"\n          - "iOSDriver/**"', 1)
    (src / 'project.yml').write_text(project)


def build(ref=None):
    """The binary for a ref, building it once per commit; None is the working
    tree, rebuilt every time (Xcode's own incremental build)."""
    sha = resolve(ref)
    if sha:
        out = PERF / 'bin' / sha / 'VibePerf'
        if out.exists():
            return out
        src = PERF / 'src' / sha
        if not src.exists():
            sh('git', '-C', str(ROOT), 'worktree', 'prune')
            sh('git', '-C', str(ROOT), 'worktree', 'add', '--detach', str(src), sha, stdout=subprocess.DEVNULL)
        graft(src)
        derived = PERF / 'dd' / sha
    else:
        src, derived = ROOT, ROOT / 'build/PerfDerivedData'
    print(f'build: VibePerf at {ref or "working tree"}', flush=True)
    lock = [str(ROOT / 'scripts/build-lock.sh')] if src == ROOT else []
    sh(*lock, 'xcodegen', 'generate', '--spec', str(src / 'project.yml'), '--project', str(src),
       stdout=subprocess.DEVNULL)
    log = derived.with_suffix('.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, 'w') as handle:
        result = subprocess.run([*lock, 'xcodebuild', '-project', str(src / 'Vibe.xcodeproj'), '-scheme', 'VibePerf',
                                 '-configuration', 'Release', '-derivedDataPath', str(derived), 'build'],
                                stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode:
        os.system(f'grep -E "error:|Undefined" "{log}" | head -20')
        sys.exit(f'build failed: {log}')
    binary = derived / 'Build/Products/Release/VibePerf'
    if sha:
        (PERF / 'bin' / sha).mkdir(parents=True, exist_ok=True)
        out = PERF / 'bin' / sha / 'VibePerf'
        shutil.copy2(binary, out)
        return out
    return binary


def run_binary(binary, filter_re, reps, json_out, quiet=False):
    args = [str(binary), '--corpus', str(CORPUS), '--reps', str(reps), '--json', str(json_out)]
    if filter_re:
        args += ['--filter', filter_re]
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL if quiet else None)
    return json.loads(Path(json_out).read_text())['benches']


def option(args, flag, default, kind=str):
    if flag in args:
        i = args.index(flag)
        value = kind(args[i + 1])
        del args[i:i + 2]
        return value
    return default


def pct(base, head):
    return (head - base) / base * 100 if base else 0.0


def compare(args):
    filter_re = option(args, '--filter', None)
    reps = option(args, '--reps', 3, int)
    rounds = option(args, '--rounds', 3, int)
    md = option(args, '--md', None)
    base_ref, head_ref = args[0], (args[1] if len(args) > 1 else None)
    corpus()
    base_bin, head_bin = build(base_ref), build(head_ref)
    samples = {'base': {}, 'head': {}}
    PERF.mkdir(parents=True, exist_ok=True)
    for r in range(rounds):
        for side, binary in (('base', base_bin), ('head', head_bin)):
            print(f'round {r + 1}/{rounds}: {side}', flush=True)
            got = run_binary(binary, filter_re, reps, PERF / f'{side}.json', quiet=True)
            for name, bench in got.items():
                entry = samples[side].setdefault(name, {k: [] for k in ('wall_ms', 'cpu_ms', 'instructions', 'cycles')})
                entry['unit'], entry['units'] = bench['unit'], bench['units']
                for key in ('wall_ms', 'cpu_ms', 'instructions', 'cycles'):
                    entry[key] += bench[key]
    head_label = head_ref or 'working tree'
    lines = [f'VibePerf: {base_ref} → {head_label}, {rounds} rounds × {reps} reps, medians', '',
             '| benchmark | Minstr base | Minstr head | Δ instr | CPU ms base | CPU ms head | Δ CPU | wall ms base | wall ms head | Δ wall |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for name in sorted(set(samples['base']) & set(samples['head'])):
        b, h = samples['base'][name], samples['head'][name]
        bi, hi = statistics.median(b['instructions']) / 1e6, statistics.median(h['instructions']) / 1e6
        bc, hc = statistics.median(b['cpu_ms']), statistics.median(h['cpu_ms'])
        bw, hw = statistics.median(b['wall_ms']), statistics.median(h['wall_ms'])
        lines.append(f'| {name} | {bi:.1f} | {hi:.1f} | {pct(bi, hi):+.1f}% | {bc:.1f} | {hc:.1f} | {pct(bc, hc):+.1f}% '
                     f'| {bw:.1f} | {hw:.1f} | {pct(bw, hw):+.1f}% |')
    text = '\n'.join(lines) + '\n'
    print(text)
    (PERF / 'last-compare.json').write_text(json.dumps(samples))
    if md:
        Path(md).write_text(text)


def main(argv):
    if not argv or argv[0] not in ('corpus', 'build', 'run', 'compare', 'list'):
        print(__doc__)
        return 64
    command, args = argv[0], argv[1:]
    if command == 'corpus':
        corpus()
    elif command == 'build':
        print(build(args[0] if args else None))
    elif command == 'list':
        subprocess.run([str(build(None)), '--list'], check=True)
    elif command == 'run':
        filter_re = option(args, '--filter', None)
        reps = option(args, '--reps', 5, int)
        json_out = option(args, '--json', str(PERF / 'run.json'))
        corpus()
        PERF.mkdir(parents=True, exist_ok=True)
        run_binary(build(args[0] if args else None), filter_re, reps, json_out)
    else:
        compare(args)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
