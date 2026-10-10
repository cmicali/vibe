#!/usr/bin/env python3
"""The vibe-perf micro-benchmark driver: build Tests/BenchComponents's VibeBenchComponents at any ref,
run it over a fixed corpus, and compare two refs.

    perf.py corpus                         the corpus (the app suite's, plus a few formats)
    perf.py build [REF]                    VibeBenchComponents for REF (default: the working tree)
    perf.py run [REF] [--filter RE] [--reps N] [--json OUT]
    perf.py compare BASE [HEAD] [--filter RE] [--reps N] [--rounds R] [--md OUT]
    perf.py list                           the benchmark names
    perf.py releases [LABEL[=REF] ...] [--reps N] [--new-machine]
                                           the performance page's component charts:
                                           each release (default: every one in
                                           docs/performance/results.json), redrawn;
                                           a LABEL with no vLABEL tag is a pre-release

REF is any git ref, or bin:<path> for a VibeBenchComponents built some other way (a
build-setting experiment); HEAD defaults to the working tree, uncommitted edits
included. A ref older than the harness gets the working tree's Tests/BenchComponents and
VibeBenchComponents target grafted on, so every ref runs the same suite.

compare alternates the two binaries ROUNDS times (default 3), REPS repetitions
each (default 3), so drift in the machine's load lands on both sides; the table
is the median of every sample. Instructions retired are the steady number
(load and clocks barely move them); wall and CPU time are what users feel but
move with whatever else the Mac runs.
"""
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'scripts/bench'))
import bench  # noqa: E402  the app benchmarks' corpus, results.json and shared helpers
from bench import option, resolve  # noqa: E402

PERF = ROOT / 'build/bench-components'
CORPUS = ROOT / 'build/bench/corpus'
EXTRA = CORPUS / 'extra'


def sh(*args, **kw):
    return subprocess.run(args, check=True, **kw)


# Formats the app suite's corpus leaves out, from its flac-16-44 so the content
# matches: the decoders dr_wav and Apple's other readers take.
EXTRAS = {
    'wav-16-44.wav': ['-c:a', 'pcm_s16le'],
    'aiff-16-44.aiff': ['-c:a', 'pcm_s16be'],
    'alac-16-44.m4a': ['-c:a', 'alac', '-sample_fmt', 's16p'],
    'opus.opus': ['-c:a', 'libopus', '-b:a', '160k'],
    'vorbis.ogg': ['-c:a', 'vorbis', '-strict', 'experimental', '-q:a', '6'],
}


def corpus():
    """The app suite's corpus plus EXTRAS; answers the corpus's hash."""
    bench.make_corpus()
    EXTRA.mkdir(parents=True, exist_ok=True)
    source = CORPUS / 'play/flac-16-44.flac'
    for name, codec in EXTRAS.items():
        out = EXTRA / name
        if not out.exists():
            print(f'corpus: {name}', flush=True)
            bench.ffmpeg('-i', str(source), '-map', '0:a', *codec, str(out))
    return bench.corpus_hash(extra=True)



def features(src):
    """VibeBenchComponentsFeatures.h for a checkout: what its sources have, as VibeBenchComponents.h
    lists the questions. Every grafted checkout gets one, whatever its age."""
    def find(name):
        return next((src / 'Vibe').rglob(name), None)
    handle, loader, levels = find('AudioFileHandle.h'), find('AudioWaveformLoader.h'), find('AudioLevelAnalyzer.h')
    waveform, three_band = find('AudioWaveform.h'), find('ThreeBandWaveformRenderer.h')
    metadata = list((src / 'Vibe').rglob('AudioTrackMetadata*.h'))
    flags = {
        'VIBE_BENCH_COMPONENTS_FILE_HANDLE': handle is not None,
        'VIBE_BENCH_COMPONENTS_FILE_HANDLE_COMMON_FORMAT': handle is not None and re.search(
            r'initForReading:\(NSURL \*\)url\s+commonFormat:', handle.read_text()) is not None,
        'VIBE_BENCH_COMPONENTS_AVF_WAVEFORM_LOADER': find('AVFAudioWaveformLoader.h') is not None,
        'VIBE_BENCH_COMPONENTS_ANALYSIS_PROVIDER': loader is not None and 'analysisProvider' in loader.read_text(),
        'VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE': loader is not None and 'VibeWaveformAnalysis analysis;' in loader.read_text(),
        'VIBE_BENCH_COMPONENTS_METADATA_DISPLAY_ART': any('displayArtData' in h.read_text() for h in metadata),
        'VIBE_BENCH_COMPONENTS_LEVELS_SUMMARIZE': levels is not None and 'VibeAudioLevelAnalyzerSummarize' in levels.read_text(),
        'VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS': waveform is not None and 'AudioWaveformBandSplit' in waveform.read_text(),
        'VIBE_BENCH_COMPONENTS_WAVEFORM_SPECTRUM': three_band is not None and 'SpectrumWaveformRenderer' in three_band.read_text(),
    }
    lines = ['// Written by perf.py from this checkout\'s sources; see VibeBenchComponents.h.']
    lines += [f'#define {name} {int(value)}' for name, value in flags.items()]
    (src / 'Tests/BenchComponents/VibeBenchComponentsFeatures.h').write_text('\n'.join(lines) + '\n')
    return flags


# The app target's settings a command-line tool must not inherit.
TOOL_DROPS = ('ASSETCATALOG_COMPILER_APPICON_NAME', 'ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS',
              'CODE_SIGN_ENTITLEMENTS', 'COMBINE_HIDPI_IMAGES', 'ENABLE_USER_SELECTED_FILES', 'INFOPLIST_FILE',
              'LD_RUNPATH_SEARCH_PATHS', 'PROVISIONING_PROFILE_SPECIFIER')


def tool_spec(src, dumped):
    """The checkout's own spec, written to `dumped`, with one target,
    VibeBenchComponents: its app target's sources and settings as that version
    had them, but main.m and the resources, built as a tool. Derived, never
    kept beside the app's, so it cannot drift from it and the source layout of
    any version (1.8's was flat) carries over. Its project is
    VibeBenchComponents.xcodeproj beside the sources, so $(SRCROOT) holds and
    the app's own project is left alone."""
    dumped.parent.mkdir(parents=True, exist_ok=True)
    sh('xcodegen', 'dump', '--type', 'json', '--spec', str(src / 'project.yml'), '--project-root', str(src),
       '--file', str(dumped), '--quiet')
    spec = json.loads(dumped.read_text())
    app = spec['targets']['Vibe']

    def path_of(source):
        return source if isinstance(source, str) else source.get('path', '')
    sources = [s for s in app['sources'] if path_of(s) != 'main.m' and not path_of(s).startswith('Resources')]
    sources.append({'path': 'Tests/BenchComponents', 'excludes': ['**/*.md', '**/*.py']})
    settings = json.loads(json.dumps(app.get('settings', {})))
    for block in [settings.get('base', {})] + list(settings.get('configs', {}).values()):
        for key in TOOL_DROPS:
            block.pop(key, None)
    settings.setdefault('base', {}).update({
        'PRODUCT_NAME': 'VibeBenchComponents', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.commonwealthrecordings.VibeBenchComponents',
        'ARCHS': 'arm64', 'ONLY_ACTIVE_ARCH': 'YES', 'CODE_SIGN_IDENTITY': '-',
        'ENABLE_APP_SANDBOX': 'NO', 'ENABLE_HARDENED_RUNTIME': 'NO', 'GCC_TREAT_WARNINGS_AS_ERRORS': 'NO'})
    tool = {'type': 'tool', 'platform': 'macOS', 'sources': sources, 'settings': settings,
            'dependencies': [d for d in app.get('dependencies', []) if 'sdk' in d]}
    if app.get('preBuildScripts'):
        tool['preBuildScripts'] = app['preBuildScripts']
    spec['name'] = 'VibeBenchComponents'
    spec['targets'] = {'VibeBenchComponents': tool}
    spec.pop('aggregateTargets', None)
    spec['schemes'] = {'VibeBenchComponents': {'build': {'targets': {'VibeBenchComponents': ['run']}},
                                    'run': {'config': 'Release'}, 'profile': {'config': 'Release'}}}
    dumped.write_text(json.dumps(spec, indent=1))
    return dumped


def graft(src):
    """Gives a checkout the working tree's harness and its feature answers."""
    shutil.rmtree(src / 'Tests/BenchComponents', ignore_errors=True)
    shutil.copytree(ROOT / 'Tests/BenchComponents', src / 'Tests/BenchComponents', ignore=shutil.ignore_patterns('*.md', '*.py'))
    features(src)


def harness_digest():
    """The working tree's harness, so a cached binary is one built from it."""
    digest = hashlib.sha256()
    for path in sorted((ROOT / 'Tests/BenchComponents').rglob('*')):
        if path.is_file():
            digest.update(path.name.encode() + path.read_bytes())
    return digest.hexdigest()[:10]


# A benchmark file that cannot compile against an older version is left out of
# it, the core never: VibeBenchComponents.mm and VibeBenchComponents.h are the harness itself.
CORE = {'VibeBenchComponents.mm', 'VibeBenchComponents.h', 'VibeBenchComponentsFeatures.h'}


def build(ref=None):
    """The binary for a ref, building it once per commit; None is the working
    tree, rebuilt every time (Xcode's own incremental build); bin:<path> is a
    VibeBenchComponents built some other way, such as with other build settings."""
    if ref and ref.startswith('bin:'):
        return Path(ref[4:])
    sha = resolve(ref) if ref else None
    if sha:
        out = PERF / 'bin' / f'{sha}-{harness_digest()}' / 'VibeBenchComponents'
        if out.exists():
            return out
        src = PERF / 'src' / sha
        if not src.exists():
            sh('git', '-C', str(ROOT), 'worktree', 'prune')
            sh('git', '-C', str(ROOT), 'worktree', 'add', '--detach', str(src), sha, stdout=subprocess.DEVNULL)
        graft(src)
        derived = PERF / 'dd' / sha
    else:
        src, derived = ROOT, ROOT / 'build/BenchComponentsDerivedData'
    print(f'build: VibeBenchComponents at {ref or "working tree"}', flush=True)
    spec = tool_spec(src, derived.with_suffix('.json'))
    log = derived.with_suffix('.log')
    dropped = []
    while True:
        sh('xcodegen', 'generate', '--spec', str(spec), '--project', str(src), '--project-root', str(src),
           stdout=subprocess.DEVNULL)
        with open(log, 'w') as handle:
            # An older version's warnings are not this harness's to fix.
            result = subprocess.run(['xcodebuild', '-project', str(src / 'VibeBenchComponents.xcodeproj'),
                                     '-scheme', 'VibeBenchComponents', '-configuration', 'Release',
                                     '-derivedDataPath', str(derived),
                                     f'GCC_TREAT_WARNINGS_AS_ERRORS={"NO" if sha else "YES"}', 'build'],
                                    stdout=handle, stderr=subprocess.STDOUT)
        if not result.returncode:
            break
        failing = set(re.findall(r'Tests/BenchComponents/(VibeBenchComponents\w*\.mm):\d+:\d+: (?:fatal )?error:', log.read_text())) - CORE
        if not sha or not failing:
            os.system(f'grep -E "error:|Undefined" "{log}" | head -20')
            sys.exit(f'build failed: {log}')
        for name in failing:
            (src / 'Tests/BenchComponents' / name).unlink()
        dropped += sorted(failing)
    if dropped:
        print(f'build: {ref} cannot build {", ".join(dropped)}; its benchmarks are left out there', flush=True)
    binary = derived / 'Build/Products/Release/VibeBenchComponents'
    if sha:
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, out)
        return out
    return binary


def run_binary(binary, filter_re, reps, json_out, quiet=False):
    """The run's samples by benchmark; empty when it measured nothing, since
    VibeBenchComponents then writes no JSON and a stale file must not pass for this run's."""
    json_out = Path(json_out)
    json_out.unlink(missing_ok=True)
    args = [str(binary), '--corpus', str(CORPUS), '--reps', str(reps), '--json', str(json_out)]
    if filter_re:
        args += ['--filter', filter_re]
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL if quiet else None)
    return json.loads(json_out.read_text())['benches'] if json_out.exists() else {}


def built(binary, filter_re):
    """The benchmark names a binary has: a ref that could not build a benchmark
    file lacks that file's."""
    args = [str(binary), '--list'] + (['--filter', filter_re] if filter_re else [])
    return set(subprocess.run(args, check=True, capture_output=True, text=True).stdout.split())



def medians(samples):
    """One benchmark's samples as medians: CPU and wall ms, millions of instructions."""
    return {'cpu_ms': statistics.median(samples['cpu_ms']), 'wall_ms': statistics.median(samples['wall_ms']),
            'minstr': statistics.median(samples['instructions']) / 1e6}


def pct(base, head):
    return (head - base) / base * 100 if base else 0.0


def compare(args):
    filter_re = option(args, '--filter', None)
    reps = option(args, '--reps', 3, int)
    rounds = option(args, '--rounds', 3, int)
    md = option(args, '--md', None)
    base_ref, head_ref = args[0], (args[1] if len(args) > 1 else None)
    corpus()
    head_label = head_ref or 'working tree'
    binaries = {'base': build(base_ref), 'head': build(head_ref)}
    names = {side: built(binary, filter_re) for side, binary in binaries.items()}
    matching = f' matching {filter_re}' if filter_re else ''
    if not names['base'] and not names['head']:
        sys.exit(f'compare: no benchmark{matching} at {base_ref} or {head_label}')
    for side, label in (('base', base_ref), ('head', head_label)):
        if not names[side]:
            print(f'compare: {label} built no benchmark{matching}; comparing what both sides have', flush=True)
    samples = {'base': {}, 'head': {}}
    PERF.mkdir(parents=True, exist_ok=True)
    for r in range(rounds):
        for side, binary in binaries.items():
            if not names[side]:
                continue
            print(f'round {r + 1}/{rounds}: {side}', flush=True)
            got = run_binary(binary, filter_re, reps, PERF / f'{side}.json', quiet=True)
            for name, bench in got.items():
                entry = samples[side].setdefault(name, {k: [] for k in ('wall_ms', 'cpu_ms', 'instructions', 'cycles')})
                entry['unit'], entry['units'] = bench['unit'], bench['units']
                for key in ('wall_ms', 'cpu_ms', 'instructions', 'cycles'):
                    entry[key] += bench[key]
    lines = [f'VibeBenchComponents: {base_ref} → {head_label}, {rounds} rounds × {reps} reps, medians', '',
             '| benchmark | Minstr base | Minstr head | Δ instr | CPU ms base | CPU ms head | Δ CPU | wall ms base | wall ms head | Δ wall |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for name in sorted(set(samples['base']) & set(samples['head'])):
        b, h = medians(samples['base'][name]), medians(samples['head'][name])
        bi, hi, bc, hc, bw, hw = b['minstr'], h['minstr'], b['cpu_ms'], h['cpu_ms'], b['wall_ms'], h['wall_ms']
        lines.append(f'| {name} | {bi:.1f} | {hi:.1f} | {pct(bi, hi):+.1f}% | {bc:.1f} | {hc:.1f} | {pct(bc, hc):+.1f}% '
                     f'| {bw:.1f} | {hw:.1f} | {pct(bw, hw):+.1f}% |')
    # No result: built, but skipped for a missing corpus file or FAILED on a timed-out wait.
    missing = [name for name in sorted(names['base'] | names['head'])
               if name not in samples['base'] or name not in samples['head']]
    if missing:
        lines += ['', 'Not compared:']
    for name in missing:
        reasons = [f'{side}: {"not built" if name not in names[side] else "no result"}'
                   for side in ('base', 'head') if name not in samples[side]]
        lines.append(f'- {name}: {", ".join(reasons)}')
    text = '\n'.join(lines) + '\n'
    print(text)
    (PERF / 'last-compare.json').write_text(json.dumps(samples))
    if md:
        Path(md).write_text(text)


# ---------------------------------------------------------------- every release
#
# The component charts on docs/performance.md: one entry per chart,
# (svg name, title, unit, [(benchmark, measure, legend)], decimals), at most
# four series; page_value says what each measure is. `releases` runs exactly
# these benchmarks at each version, and scripts/bench/report.py draws them.
PAGE_CHARTS = [
    ('components-decode', 'Decoding, CPU per minute of audio', 'ms', [
        ('decode.mp3-320', 'cpu_per_minute', 'MP3 320k'),
        ('decode.aac-256', 'cpu_per_minute', 'AAC 256k'),
        ('decode.flac-16-44', 'cpu_per_minute', 'FLAC 16/44.1'),
        ('decode.flac-24-192', 'cpu_per_minute', 'FLAC 24/192')], 1),
    ('components-open', 'Opening a file', 'ms', [
        ('open.mp3-320', 'cpu_per_unit', 'MP3 320k'),
        ('open.aac-256', 'cpu_per_unit', 'AAC 256k'),
        ('open.flac-16-44', 'cpu_per_unit', 'FLAC 16/44.1'),
        ('open.wav-24-96', 'cpu_per_unit', 'WAV 24/96')], 2),
    ('components-seek', 'Seeking, and the first read after it', 'ms', [
        ('seek.mp3-320', 'cpu_per_unit', 'MP3 320k'),
        ('seek.aac-256', 'cpu_per_unit', 'AAC 256k'),
        ('seek.flac-16-44', 'cpu_per_unit', 'FLAC 16/44.1'),
        ('seek.flac-24-192', 'cpu_per_unit', 'FLAC 24/192')], 2),
    ('components-waveform', 'Waveform, tempo and key for a new track, 3 min file', 'ms', [
        ('waveform+bpm+key.mp3-320', 'wall', 'MP3 320k'),
        ('waveform+bpm+key.aac-256', 'wall', 'AAC 256k'),
        ('waveform+bpm+key.flac-16-44', 'wall', 'FLAC 16/44.1'),
        ('waveform+bpm+key.flac-24-192', 'wall', 'FLAC 24/192')], 0),
    ('components-analysis', 'Tempo and key analysis, CPU per minute of audio', 'ms', [
        ('bpm.flac-16-44', 'cpu_per_minute', 'Tempo, 44.1 kHz'),
        ('key.flac-16-44', 'cpu_per_minute', 'Key, 44.1 kHz'),
        ('bpm.flac-24-96', 'cpu_per_minute', 'Tempo, 96 kHz'),
        ('key.flac-24-96', 'cpu_per_minute', 'Key, 96 kHz')], 1),
    ('components-pitch', 'The pitch fader\'s converter, CPU per minute of audio', 'ms', [
        ('pitch.-8', 'cpu_per_minute', '−8%'),
        ('pitch.+4', 'cpu_per_minute', '+4%'),
        ('pitch.+16', 'cpu_per_minute', '+16%')], 0),
    ('components-metadata', 'Reading a file\'s tags and cover art', 'ms per file', [
        ('metadata.mp3-320', 'wall_per_unit', 'MP3, 1000 px cover'),
        ('metadata.flac-16-44', 'wall_per_unit', 'FLAC, 1000 px cover'),
        ('metadata.aac-256', 'wall_per_unit', 'AAC, 1000 px cover'),
        ('metadata.library-mp3', 'wall_per_unit', 'Library MP3, 600 px')], 2),
    ('components-disk-cache', 'The metadata and waveform disk cache', 'µs per entry', [
        ('pincache.hit-300', 'us_per_unit', 'Hit'),
        ('pincache.write-300', 'us_per_unit', 'Write'),
        ('pincache.write-300-at-limit', 'us_per_unit', 'Write, cache full'),
        ('pincache.open-2000', 'us_per_unit', 'Launch')], 0),
    ('components-library', 'Large libraries', 's', [
        ('scan.sweep-5k', 'wall_s', 'Metadata sweep, 5,000 files'),
        ('m3u.resolve-10k', 'wall_s', 'M3U, 10,000 entries'),
        ('walk.10k-name', 'wall_s', 'Folder, 10,000 files'),
        ('playlist-edit.100k-head', 'wall_s', '20 edits, 100,000 rows')], 2),
]


def page_value(bench, measure):
    if not bench or not bench.get('units'):
        return None
    if measure == 'cpu_per_minute':  # units are the file's audio seconds
        return bench['cpu_ms'] / bench['units'] * 60
    if measure == 'cpu_per_unit':
        return bench['cpu_ms'] / bench['units']
    if measure == 'wall_per_unit':
        return bench['wall_ms'] / bench['units']
    if measure == 'us_per_unit':
        return bench['wall_ms'] / bench['units'] * 1000
    if measure == 'wall':
        return bench['wall_ms']
    return bench['wall_ms'] / 1000  # wall_s




def page_filter():
    names = sorted({name for *_, series, _ in PAGE_CHARTS for name, _, _ in series})
    return '^(' + '|'.join(re.sub(r'([.+])', r'\\\1', name) for name in names) + ')$'  # VibeBenchComponents' --filter is ECMAScript


def measure_release(label, ref, reps):
    """VibeBenchComponents at one version, built by build() with today's harness grafted
    on, the page's benchmarks only, REPS repetitions, medians: the entry for
    results.json's `components` section. A benchmark the version cannot build is
    absent from it, not zero."""
    corpus_hash = corpus()
    binary = build(ref)
    out = PERF / f'release-{label}.json'
    PERF.mkdir(parents=True, exist_ok=True)
    benches = run_binary(binary, page_filter(), reps, out, quiet=True)
    entries = {}
    for name, samples in benches.items():
        m = medians(samples)
        entries[name] = {'cpu_ms': round(m['cpu_ms'], 4), 'wall_ms': round(m['wall_ms'], 4),
                         'minstr': round(m['minstr'], 3), 'units': samples['units'], 'unit': samples['unit']}
    print(f'{label}: VibeBenchComponents, {len(entries)} benchmarks', flush=True)
    return {'ref': ref, 'commit': resolve(ref), 'prerelease': bench.prerelease(label),
            'measured': time.strftime('%Y-%m-%d'), 'reps': reps,
            'corpus': corpus_hash, 'machine': bench.machine(), 'harness': harness_digest(), 'benches': entries}


def releases(args):
    """The page's component charts: measure each version, store it in
    results.json, redraw docs/performance.md."""
    reps = option(args, '--reps', 5, int)
    new_machine = bench.switch(args, '--new-machine')
    results = bench.load_results()
    targets = bench.parse_targets(args, results)
    bench.check_history(results, 'components', targets, corpus(), new_machine)
    for label, ref in targets:
        results.setdefault('components', {})[label] = measure_release(label, ref, reps)
        bench.save_results(results)
    import report
    report.write(results)


def main(argv):
    if not argv or argv[0] not in ('corpus', 'build', 'run', 'compare', 'list', 'releases'):
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
    elif command == 'releases':
        releases(args)
    else:
        compare(args)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
