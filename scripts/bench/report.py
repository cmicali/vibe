"""The charts and the release table on docs/performance.md, from results.json.

One SVG per question, versions along x, at most four series. The drawing is
scripts/docs/charts.py, shared with docs/audio-quality.md. The page shows each
chart by file name in the section it belongs to, and write() names any chart
the page does not show.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.claude/skills/vibe-perf/scripts'))
sys.path.insert(0, str(ROOT / 'scripts/docs'))
import perf  # noqa: E402  the vibe-perf skill's: which in-process charts the page draws
from charts import line_chart, table  # noqa: E402

PERF = ROOT / 'docs/performance'
PAGE = ROOT / 'docs/performance.md'
BEGIN, END = '<!-- performance:begin -->', '<!-- performance:end -->'

# (file, title, unit, [(metric key, series label)], decimals). Series keep
# this order in the legend.
CHARTS = [
    ('time-to-play', 'Time to play a file never opened before', 'ms', [
        ('ttp_ms.mp3-320', 'First file after launch'),
        ('switch_mean', 'Track switch, mean of 6 formats'),
        ('ttp_ms.mp3-v0-noxing', 'Switch to an MP3 with no Xing header')], 0),
    ('seek', 'Seek latency', 'ms', [
        ('seek_ms.mp3-v0', 'MP3 V0'),
        ('seek_ms.aac-256', 'AAC 256k'),
        ('seek_ms.flac-24-192', 'FLAC 24/192'),
        ('seek_ms.mp3-v0-60min', 'MP3 V0, 60 minutes')], 0),
    ('playback-cpu', 'Playback CPU', '% of one core', [
        ('play_cpu_pct.mp3-320', 'MP3 320k'),
        ('play_cpu_pct.aac-256', 'AAC 256k'),
        ('play_cpu_pct.flac-16-44', 'FLAC 16/44.1'),
        ('play_cpu_pct.flac-24-192', 'FLAC 24/192')], 1),
    ('playback-cpu-extra', 'Playback CPU with effects, pitch and resampling', '% of one core', [
        ('play_cpu_pct.flac-24-192', 'FLAC 24/192'),
        ('play_cpu_pct.fx', 'FLAC 24/192 with every effect on'),
        ('play_cpu_pct.pitch.flac-24-192', 'FLAC 24/192 at +8% pitch'),
        ('play_cpu_pct.flac-24-352', 'FLAC 24/352.8, resampled')], 1),
    ('wakeups', 'CPU wakeups', 'a second', [
        ('play_wakeups_per_s.mp3-320', 'Playing'),
        ('paused_wakeups_per_s', 'Paused'),
        ('idle_wakeups_per_s', 'Idle, nothing loaded')], 0),
    ('background', 'CPU when not playing', '% of one core', [
        ('paused_cpu_pct', 'Paused'),
        ('idle_cpu_pct', 'Idle, nothing loaded')], 2),
    ('waveform', 'Waveform and tempo for a 3-minute file', 'ms', [
        ('waveform_ms.mp3-320', 'MP3 320k'),
        ('waveform_ms.flac-16-44', 'FLAC 16/44.1'),
        ('waveform_ms.flac-24-192', 'FLAC 24/192')], 0),
    ('library', 'A 600-file library', 's', [
        ('library_list_ms', 'Every row listed'),
        ('library_scan_cold_ms', 'Tags read, empty cache'),
        ('library_scan_warm_ms', 'Tags read, full cache')], 2),
    ('memory', 'Memory', 'MB', [
        ('idle_footprint_mb', 'Idle'),
        ('playback_footprint_mb', 'After playback'),
        ('peak_footprint_mb', 'Peak')], 0),
]
SECONDS = {'library_list_ms', 'library_scan_cold_ms', 'library_scan_warm_ms', 'waveform_ms.mp3-320-60min'}
SWITCH_KEYS = ['ttp_ms.mp3-v0', 'ttp_ms.aac-256', 'ttp_ms.flac-16-44', 'ttp_ms.flac-24-96',
               'ttp_ms.flac-24-192', 'ttp_ms.wav-24-96']
SEEK_KEYS = ['seek_ms.mp3-v0', 'seek_ms.aac-256', 'seek_ms.flac-24-192']

# Color follows the entity: a format keeps its slot in every chart. Any other
# series takes the lowest slot its chart leaves free.
SLOT = {'MP3 320k': 0, 'MP3 V0': 0, 'AAC 256k': 1, 'FLAC 16/44.1': 2, 'FLAC 24/192': 3, 'WAV 24/96': 4,
        'Playing': 0, 'Paused': 1, 'Idle, nothing loaded': 2}
UNITS = {'ms': 'Milliseconds', 's': 'Seconds', 'MB': 'Megabytes', '% of one core': 'Percent of one core',
         'a second': 'Per second', 'ms per file': 'Milliseconds per file', 'µs per entry': 'Microseconds per entry',
         'ms per frame': 'Milliseconds of CPU per frame'}

# (label, metric key, decimals): the release table.
SUMMARY = [
    ('App startup, ms', 'launch_warm_window_ms', 0),
    ('First file after launch, ms', 'ttp_ms.mp3-320', 0),
    ('Track switch, ms', 'switch_mean', 0),
    ('Seek, 3-minute files, ms', 'seek_mean', 0),
    ('Seek, 60-minute MP3, ms', 'seek_ms.mp3-v0-60min', 0),
    ('Playback CPU, MP3 320k, %', 'play_cpu_pct.mp3-320', 1),
    ('Playback CPU, FLAC 24/192, %', 'play_cpu_pct.flac-24-192', 1),
    ('Playback CPU, every effect on, %', 'play_cpu_pct.fx', 1),
    ('Playback CPU, +8% pitch, %', 'play_cpu_pct.pitch.flac-24-192', 1),
    ('Playback CPU, 24/352.8, %', 'play_cpu_pct.flac-24-352', 1),
    ('Wakeups while playing, a second', 'play_wakeups_per_s.mp3-320', 0),
    ('Waveform, 3-minute FLAC, ms', 'waveform_ms.flac-16-44', 0),
    ('Waveform, 60-minute MP3, s', 'waveform_ms.mp3-320-60min', 1),
    ('Library tag scan, s', 'library_scan_cold_ms', 2),
    ('Memory, idle, MB', 'idle_footprint_mb', 0),
    ('Memory, peak, MB', 'peak_footprint_mb', 0),
]


def value(entry, key):
    if key in ('switch_mean', 'seek_mean'):
        vals = [entry['metrics'][k] for k in (SWITCH_KEYS if key == 'switch_mean' else SEEK_KEYS)
                if k in entry['metrics']]
        return sum(vals) / len(vals) if vals else None
    v = entry['metrics'].get(key)
    if v is None:
        return None
    return v / 1000 if key in SECONDS else v


def slots(labels):
    taken = [SLOT.get(label) for label in labels]
    free = [s for s in range(8) if s not in taken]
    return [s if s is not None else free.pop(0) for s in taken]


def draw(name, title, unit, series, labels, entries, decimals):
    colors = slots([label for _, label in series])
    data = [(label, color, [value(e, key) for e in entries]) for (key, label), color in zip(series, colors)]
    svg = line_chart(title, f'{UNITS.get(unit, unit)}. Lower is better.', labels, data, decimals)
    (PERF / f'{name}.svg').write_text(svg)


def components_entry(entry):
    """A components entry in the shape value() reads: one metric per series key."""
    metrics = {f'{name}|{measure}': perf.page_value(entry['benches'].get(name), measure)
               for _, _, _, series, _ in perf.PAGE_CHARTS for name, measure, _ in series}
    return {'metrics': {k: v for k, v in metrics.items() if v is not None}}


def same_setup(entries, reference=None):
    """The entries measured on reference's machine and corpus, the newest
    entry's by default: the only ones a chart can compare."""
    reference = reference or max(entries.values(), key=lambda e: e['measured'])
    return {k: e for k, e in entries.items()
            if e['machine'] == reference['machine'] and e['corpus'] == reference['corpus']}


def comparable(results, section='app'):
    """The versions measured on the newest entry's machine and corpus."""
    versions = results.get(section, {})
    if not versions:
        return {}
    same = same_setup(versions)
    for label in versions.keys() - same.keys():
        print(f'report: leaving out {label} ({section}), measured on another machine or corpus; run it again here')
    return same


def display_labels(versions):
    """A version measured before its tag existed is said to be one."""
    return [f'{label} pre-release' if entry.get('prerelease') else label for label, entry in versions.items()]


def machine(m):
    return f'an {m["chip"]} with {m["memory_gb"]} GB of memory and macOS {m["macos"]}'


def summary_svg(labels, entries):
    rows = []
    for label, key, decimals in SUMMARY:
        cells = []
        for e in entries:
            v = value(e, key)
            cells.append(None if v is None else (f'{v:,.{decimals}f}', round(v, decimals)))
        if any(cells):
            rows.append((label, cells, 'lower'))
    return table('Every release', 'The app benchmarks. Lower is better. In each row, green is the best release and '
                 'red the worst. A row whose releases differ by less than 3% has no color.',
                 [label.replace(' ', '\n', 1) for label in labels], rows, min_spread=0.03)


def write(results):
    versions = comparable(results)
    labels = display_labels(versions)
    entries = list(versions.values())
    if not entries:
        return
    PERF.mkdir(parents=True, exist_ok=True)
    drawn = []
    for name, title, unit, series, decimals in CHARTS:
        if any(value(e, key) is not None for e in entries for key, _ in series):
            draw(name, title, 's' if series[0][0] in SECONDS else unit, series, labels, entries, decimals)
            drawn.append(name)
    (PERF / 'summary.svg').write_text(summary_svg(labels, entries))
    sentence = f'The app benchmarks ran on {machine(entries[-1]["machine"])}.'
    components = comparable(results, 'components')
    if components:
        clabels = display_labels(components)
        centries = [components_entry(e) for e in components.values()]
        for name, title, unit, series, decimals in perf.PAGE_CHARTS:
            keyed = [(f'{bench}|{measure}', label) for bench, measure, label in series]
            if any(value(e, key) is not None for e in centries for key, _ in keyed):
                draw(name, title, unit, keyed, clabels, centries, decimals)
                drawn.append(name)
        cmachine = list(components.values())[-1]['machine']
        if cmachine == entries[-1]['machine']:
            sentence = f'Both suites ran on {machine(cmachine)}.'
        else:
            sentence += f' The component benchmarks ran on {machine(cmachine)}.'
    block = '\n'.join([BEGIN, '', sentence + ' A version marked pre-release was measured before its release '
                       'was tagged.', '', '![Every release](performance/summary.svg)', '', END])
    text = PAGE.read_text()
    if BEGIN not in text or END not in text:
        raise SystemExit(f'report: {PAGE} has lost its {BEGIN} / {END} markers')
    text = re.sub(re.escape(BEGIN) + '.*?' + re.escape(END), lambda _: block, text, flags=re.S)
    PAGE.write_text(text)
    for name in drawn:
        if f'performance/{name}.svg' not in text:
            print(f'report: docs/performance.md does not show {name}.svg; add it to the section it belongs to')
    print(f'report: {len(entries)} versions, {len(drawn)} charts')
