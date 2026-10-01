#!/usr/bin/env python3
"""Buffer underruns on real hardware, the measurement behind issue #120:

    underrun.py [REF]                                     (make bench-underrun)

A: steady playback of every bench file, 15 s each.
B: the same files' heaviest four under full CPU load (one `yes` per core).
C: decoder stalls of growing length at random moments (`block_decoder`, which
   holds every decode turn as a stalled read would), five per length, to find
   how long a stalled read the rings ride through.

Each row is the current voice's underrun frames (dump_audio_path's bus stage)
and the output's dropped IO cycles (dump_health). REF, default HEAD, is built
as bench.py builds a release (the VibeBenchApp process, its own bundle ID and
channel), so it never touches a running Vibe; it needs block_decoder, so a ref
from before it cannot run C. Silent, on the built-in speakers. Every row is
printed as it lands and all of them kept in build/bench/underrun.json."""
import json
import os
import random
import subprocess
import sys
import time

import bench

LABEL = 'underrun'
OUT = bench.BENCH / 'underrun.json'
HOLDS = [0.25, 0.5, 0.6, 0.7, 0.8, 1.0, 1.25, 1.5, 2.0]
TRIALS = 5
STALL_FILES = ['mp3-320', 'flac-24-192']
LOAD_FILES = ['mp3-320', 'aac-256', 'flac-24-192', 'flac-24-352']


def bus(app):
    stages = app.command('dump_audio_path')[0]['stages']
    return next(s for s in stages if s['stage'] == 'bus')


def health(app):
    return app.command('dump_health')[0]['app']


def play(app, name):
    if bench.time_to_play(app, bench.play_path(name)) is None:
        raise RuntimeError(f'{name} did not play')


def steady(app, names, seconds, tag):
    rows = []
    for name in names:
        play(app, name)
        time.sleep(2)
        u0, h0 = bus(app)['underrunFrames'], health(app)
        time.sleep(seconds)
        b, h1 = bus(app), health(app)
        row = {'file': name, 'tag': tag, 'seconds': seconds, 'rate': b['sampleRate'],
               'underrunFrames': b['underrunFrames'] - u0,
               'outputDropouts': h1['outputDropouts'] - h0['outputDropouts'],
               'renderMaxMicros': h1['renderMaxMicros'], 'renderMeanMicros': h1['renderMeanMicros']}
        rows.append(row)
        print(json.dumps(row), flush=True)
    return rows


def stalls(app, rng):
    rows = []
    for name in STALL_FILES:
        for hold in HOLDS:
            play(app, name)
            time.sleep(3)  # rings full
            for trial in range(TRIALS):
                time.sleep(rng.uniform(0.3, 2.0))  # a random point in the refill cycle
                u0 = bus(app)['underrunFrames']
                app.command('block_decoder', hold)
                time.sleep(hold + 1.5)
                b = bus(app)
                frames = b['underrunFrames'] - u0
                row = {'file': name, 'hold': hold, 'trial': trial, 'rate': b['sampleRate'],
                       'underrunFrames': frames, 'underrunMs': round(frames / b['sampleRate'] * 1000, 1)}
                rows.append(row)
                print(json.dumps(row), flush=True)
    return rows


def main(argv):
    ref = argv[0] if argv else 'HEAD'
    bench.make_corpus()
    bench.ensure_probe()
    commit = bench.resolve(ref)
    stamp = bench.BENCH / 'apps' / LABEL / 'commit'
    if not bench.app_executable(LABEL).exists() or not stamp.exists() or stamp.read_text().strip() != commit:
        bench.build(LABEL, commit)
    results = {'ref': ref, 'commit': commit, 'machine': bench.machine()}
    (bench.BENCH / 'homes').mkdir(parents=True, exist_ok=True)
    home = bench.fresh_home()
    app = bench.App(LABEL, home)
    load = []
    try:
        print('A: steady', flush=True)
        results['steady'] = steady(app, list(bench.PLAY_FILES), 15, 'steady')
        print('B: under load', flush=True)
        load = [subprocess.Popen(['yes'], stdout=subprocess.DEVNULL) for _ in range(os.cpu_count())]
        time.sleep(2)
        results['load'] = steady(app, LOAD_FILES, 20, 'load')
        for proc in load:
            proc.kill()
        load = []
        time.sleep(3)
        print('C: stalls', flush=True)
        results['stalls'] = stalls(app, random.Random(7))
    finally:
        for proc in load:
            proc.kill()
        app.stop()
        OUT.write_text(json.dumps(results, indent=1))
    print('\n| file | stall | underran | silence, ms |\n| --- | ---: | ---: | --- |')
    for name in STALL_FILES:
        for hold in HOLDS:
            ms = [r['underrunMs'] for r in results['stalls'] if r['file'] == name and r['hold'] == hold]
            print(f'| {name} | {hold:.2f} s | {sum(1 for m in ms if m > 0)} of {len(ms)} | {ms} |')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
