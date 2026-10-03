#!/usr/bin/env python3
"""The app benchmarks on two refs, for a before/after of one change:

    app_compare.py BASE [HEAD] [--reps N] [--idle P]     (make bench-app-compare)

Builds each ref as bench.py builds a release (scripts/bench/build-version.sh,
the VibeBenchApp process), then runs every scenario on both, alternating by
repetition so drift in the machine lands on both sides. Prints a table of
medians and their change, and keeps every sample in
build/bench/app-compare.json. results.json and the performance page are not
touched: this is bench.py's suite pointed at a change, not at a release.

HEAD defaults to HEAD, BASE has no default; --reps defaults to 3 and --idle,
the whole-machine idle percent to wait for before each scenario, to 70."""
import json
import shutil
import statistics
import sys
import time

import bench

OUT = bench.BENCH / 'app-compare.json'


def built(label, ref):
    """The bench app for ref under label, rebuilt when it holds another commit."""
    commit = bench.resolve(ref)
    stamp = bench.BENCH / 'apps' / label / 'commit'
    if not bench.app_executable(label).exists() or not stamp.exists() or stamp.read_text().strip() != commit:
        bench.build(label, commit)
    return commit


def main(argv):
    args = list(argv)
    reps, idle = bench.option(args, '--reps', 3, int), bench.option(args, '--idle', 70.0, float)
    if not args or len(args) > 2:
        print(__doc__)
        return 64
    refs = {'compare-base': args[0], 'compare-head': args[1] if len(args) > 1 else 'HEAD'}
    bench.make_corpus()
    bench.ensure_probe()
    commits = {label: built(label, ref) for label, ref in refs.items()}
    (bench.BENCH / 'homes').mkdir(parents=True, exist_ok=True)
    samples = {label: {} for label in refs}
    for rep in range(reps):
        for label in refs:
            for scenario in bench.SCENARIOS:
                bench.wait_system_quiet(idle)
                home = bench.fresh_home()
                started = time.monotonic()
                try:
                    values = scenario(label, home, rep)
                except (RuntimeError, bench.ChannelTimeout, ProcessLookupError) as error:
                    print(f'  warning: {refs[label]} {scenario.__name__[9:]}: {error}', flush=True)
                    values = {}
                finally:
                    shutil.rmtree(home, ignore_errors=True)
                print(f'{refs[label]} rep {rep + 1}/{reps} {scenario.__name__[9:]}: '
                      f'{time.monotonic() - started:.0f}s', flush=True)
                for key, value in values.items():
                    samples[label].setdefault(key, []).append(value)
            medians = {label: {key: statistics.median(v for v in values if v is not None)
                               for key, values in s.items() if any(v is not None for v in values)}
                       for label, s in samples.items()}
            OUT.write_text(json.dumps({'refs': refs, 'commits': commits, 'machine': bench.machine(),
                                       'medians': medians, 'samples': samples}, indent=1))
    base, head = medians['compare-base'], medians['compare-head']
    print(f'\n| metric | {refs["compare-base"]} | {refs["compare-head"]} | change |\n| --- | ---: | ---: | ---: |')
    for key in sorted(base.keys() & head.keys()):
        change = f'{(head[key] - base[key]) / base[key] * 100:+.1f}%' if base[key] else ''
        print(f'| {key} | {base[key]:.3f} | {head[key]:.3f} | {change} |')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
