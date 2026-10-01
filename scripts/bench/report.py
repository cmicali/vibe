"""The benchmark's charts and the table and charts atop docs/performance.md, from results.json.

One SVG per question, versions along x, one y-axis each, at most four series,
light and dark from the SVG's own media query. Hand-written SVG: no plotting
dependency to install.
"""
import html
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PERF = ROOT / 'docs/performance'
PAGE = ROOT / 'docs/performance.md'
BEGIN, END = '<!-- performance:begin -->', '<!-- performance:end -->'

# (file, title, unit, [(metric key, series label)], decimals)
CHARTS = [
    ('startup', 'App startup', 'ms', [
        ('launch_warm_window_ms', 'Window shown'),
        ('launch_warm_ready_ms', 'Ready'),
        ('launch_cold_window_ms', 'First launch')], 0),
    ('time-to-play', 'Time to play a file never opened before', 'ms', [
        ('ttp_ms.mp3-320', 'First after launch'),
        ('ttp_ms.aac-256', 'Switch to AAC'),
        ('ttp_ms.flac-16-44', 'Switch to FLAC'),
        ('ttp_ms.flac-24-192', 'Switch to 24/192')], 0),
    ('seek', 'Seek latency', 'ms', [
        ('seek_ms.mp3-v0', 'MP3 VBR'),
        ('seek_ms.aac-256', 'AAC 256k'),
        ('seek_ms.flac-24-192', 'FLAC 24/192')], 0),
    ('long-mp3', 'Long MP3s: open and seek', 'ms', [
        ('ttp_ms.mp3-v0-60min', 'Open, 60 min VBR'),
        ('ttp_ms.mp3-v0-noxing', 'Open, no Xing'),
        ('seek_ms.mp3-v0-60min', 'Seek, 60 min VBR'),
        ('seek_ms.mp3-v0-noxing', 'Seek, no Xing')], 0),
    ('playback-cpu', 'Playback CPU', '% of one core', [
        ('play_cpu_pct.mp3-320', 'MP3 320k'),
        ('play_cpu_pct.flac-16-44', 'FLAC 16/44.1'),
        ('play_cpu_pct.flac-24-192', 'FLAC 24/192'),
        ('play_cpu_pct.fx', '24/192 + all FX')], 1),
    ('resampler-cpu', 'Playback CPU, resampled to 48 kHz', '% of one core', [
        ('play_cpu_pct.flac-24-88', 'From 88.2 kHz'),
        ('play_cpu_pct.flac-24-176', 'From 176.4 kHz'),
        ('play_cpu_pct.flac-24-352', 'From 352.8 kHz'),
        ('play_cpu_pct.flac-16-22-mono', 'From 22.05 mono')], 1),
    ('pitch-cpu', 'Playback CPU, pitch fader at full throw', '% of one core', [
        ('play_cpu_pct.pitch.flac-24-192', 'FLAC 24/192, +8%'),
        ('play_cpu_pct.pitch.mp3-320', 'MP3 320k, -8%'),
        ('play_cpu_pct.mp3-320-48k', 'MP3 48 kHz, no pitch')], 1),
    ('waveform', 'Waveform + tempo analysis, 3 min file', 'ms', [
        ('waveform_ms.mp3-320', 'MP3 320k'),
        ('waveform_ms.flac-16-44', 'FLAC 16/44.1'),
        ('waveform_ms.flac-24-192', 'FLAC 24/192')], 0),
    ('waveform-long', 'Waveform + tempo analysis, long files', 's', [
        ('waveform_ms.mp3-320-60min', 'MP3 320k, 60 min'),
        ('waveform_ms.flac-24-352', 'FLAC 24/352.8, 1 min')], 1),
    ('library', '600-file library: open and metadata scan', 's', [
        ('library_list_ms', 'Rows listed'),
        ('library_scan_cold_ms', 'Scan, cold cache'),
        ('library_scan_warm_ms', 'Scan, warm cache'),
        ('library_scan_cpu_s', 'Scan CPU time')], 2),
    ('memory', 'Memory footprint', 'MB', [
        ('idle_footprint_mb', 'Idle'),
        ('playback_footprint_mb', 'After playback'),
        ('library_footprint_mb', 'Library loaded'),
        ('peak_footprint_mb', 'Peak')], 0),
    ('idle', 'Background cost', '% of one core', [
        ('idle_cpu_pct', 'Idle, empty'),
        ('paused_cpu_pct', 'Paused')], 2),
    ('playback-energy', 'Playback energy', 'mW', [
        ('play_power_mw.mp3-320', 'MP3 320k'),
        ('play_power_mw.flac-16-44', 'FLAC 16/44.1'),
        ('play_power_mw.flac-24-192', 'FLAC 24/192'),
        ('play_power_mw.fx', '24/192 + all FX')], 1),
    ('playback-work', 'Playback work, instructions retired', 'millions a second', [
        ('play_minstr_per_s.mp3-320', 'MP3 320k'),
        ('play_minstr_per_s.flac-16-44', 'FLAC 16/44.1'),
        ('play_minstr_per_s.flac-24-192', 'FLAC 24/192')], 0),
    ('wakeups', 'Wakeups', 'a second', [
        ('play_wakeups_per_s.mp3-320', 'Playing MP3'),
        ('play_wakeups_per_s.flac-24-192', 'Playing FLAC 24/192'),
        ('paused_wakeups_per_s', 'Paused'),
        ('idle_wakeups_per_s', 'Idle, empty')], 0),
]

# The in-process charts, from results.json's `perf` section (VibePerf, the
# vibe-perf skill's suite, grafted onto each version's own code). A series is
# (benchmark, measure, label); the measures are below. A benchmark a version
# cannot build is absent there.
PERF_CHARTS = [
    ('perf-decode', 'Decoding, CPU per minute of audio', 'ms', [
        ('decode.mp3-320', 'cpu_per_minute', 'MP3 320k'),
        ('decode.aac-256', 'cpu_per_minute', 'AAC 256k'),
        ('decode.flac-16-44', 'cpu_per_minute', 'FLAC 16/44.1'),
        ('decode.flac-24-192', 'cpu_per_minute', 'FLAC 24/192')], 1),
    ('perf-open', 'Opening a file', 'ms', [
        ('open.mp3-320', 'cpu_per_unit', 'MP3 320k'),
        ('open.aac-256', 'cpu_per_unit', 'AAC 256k'),
        ('open.flac-16-44', 'cpu_per_unit', 'FLAC 16/44.1'),
        ('open.wav-24-96', 'cpu_per_unit', 'WAV 24/96')], 2),
    ('perf-seek', 'Seeking, and the first read after it', 'ms', [
        ('seek.mp3-320', 'cpu_per_unit', 'MP3 320k'),
        ('seek.aac-256', 'cpu_per_unit', 'AAC 256k'),
        ('seek.flac-16-44', 'cpu_per_unit', 'FLAC 16/44.1'),
        ('seek.flac-24-192', 'cpu_per_unit', 'FLAC 24/192')], 2),
    ('perf-waveform', 'Waveform, tempo and key for a new track, 3 min file', 'ms', [
        ('waveform+bpm+key.mp3-320', 'wall', 'MP3 320k'),
        ('waveform+bpm+key.aac-256', 'wall', 'AAC 256k'),
        ('waveform+bpm+key.flac-16-44', 'wall', 'FLAC 16/44.1'),
        ('waveform+bpm+key.flac-24-192', 'wall', 'FLAC 24/192')], 0),
    ('perf-analysis', 'Tempo and key analysis, CPU per minute of audio', 'ms', [
        ('bpm.flac-16-44', 'cpu_per_minute', 'Tempo, 44.1 kHz'),
        ('key.flac-16-44', 'cpu_per_minute', 'Key, 44.1 kHz'),
        ('bpm.flac-24-96', 'cpu_per_minute', 'Tempo, 96 kHz'),
        ('key.flac-24-96', 'cpu_per_minute', 'Key, 96 kHz')], 1),
    ('perf-metadata', 'Reading a file\'s tags and cover art', 'ms per file', [
        ('metadata.mp3-320', 'wall_per_unit', 'MP3, 1000 px cover'),
        ('metadata.flac-16-44', 'wall_per_unit', 'FLAC, 1000 px cover'),
        ('metadata.aac-256', 'wall_per_unit', 'AAC, 1000 px cover'),
        ('metadata.library-mp3', 'wall_per_unit', 'Library MP3, 600 px')], 2),
    ('perf-disk-cache', 'The metadata and waveform disk cache', 'µs per entry', [
        ('pincache.hit-300', 'us_per_unit', 'Hit'),
        ('pincache.write-300', 'us_per_unit', 'Write'),
        ('pincache.write-300-at-limit', 'us_per_unit', 'Write, cache full'),
        ('pincache.open-2000', 'us_per_unit', 'Launch')], 0),
    ('perf-library', 'Large libraries', 's', [
        ('scan.sweep-5k', 'wall_s', 'Metadata sweep, 5,000 files'),
        ('m3u.resolve-10k', 'wall_s', 'M3U, 10,000 entries'),
        ('walk.10k-name', 'wall_s', 'Folder, 10,000 files'),
        ('playlist-edit.100k-head', 'wall_s', '20 edits, 100,000 rows')], 2),
]


def perf_value(bench, measure):
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


def perf_entry(entry):
    """A perf entry in the shape chart_svg reads: one metric per series key."""
    metrics = {f'{name}|{measure}': perf_value(entry['benches'].get(name), measure)
               for _, _, _, series, _ in PERF_CHARTS for name, measure, _ in series}
    return {'metrics': {k: v for k, v in metrics.items() if v is not None}}
SECONDS = {'library_list_ms', 'library_scan_cold_ms', 'library_scan_warm_ms',
           'waveform_ms.mp3-320-60min', 'waveform_ms.flac-24-352'}

SWITCH_KEYS = ['ttp_ms.mp3-v0', 'ttp_ms.aac-256', 'ttp_ms.flac-16-44', 'ttp_ms.flac-24-96',
               'ttp_ms.flac-24-192', 'ttp_ms.wav-24-96']
SEEK_KEYS = ['seek_ms.mp3-v0', 'seek_ms.aac-256', 'seek_ms.flac-24-192']

# The reference categorical palette, fixed order: slot i is always series i.
LIGHT = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100']
DARK = ['#3987e5', '#d95926', '#199e70', '#c98500']

W, H = 720, 300
PAD_L, PAD_R, PAD_T, PAD_B = 56, 150, 44, 36


def value(entry, key):
    v = entry['metrics'].get(key)
    if v is None:
        return None
    return v / 1000 if key in SECONDS else v


def nice_axis(v):
    """(top, step): the smallest round step, 1/2/2.5/5 x 10^n, that covers v
    with some headroom in at most six ticks."""
    if v <= 0:
        return 1, 0.25
    for m in range(-3, 8):
        for s in (1, 2, 2.5, 5):
            step = s * 10 ** m
            n = math.ceil(v * 1.05 / step)
            if n <= 6:
                return n * step, step
    return v, v


def tick_decimals(step):
    """Just enough decimals that every tick prints exactly: 2.5 never as 2."""
    for decimals in range(4):
        if abs(round(step, decimals) - step) < 1e-9:
            return decimals
    return 3


def fmt(v, decimals):
    return f'{v:,.{decimals}f}'


def chart_svg(title, unit, series, labels, entries, decimals):
    data = [[value(e, key) for e in entries] for key, _ in series]
    present = [v for row in data for v in row if v is not None]
    top, step = nice_axis(max(present) if present else 1)
    ticks = round(top / step)
    plot_w, plot_h = W - PAD_L - PAD_R, H - PAD_T - PAD_B
    n = len(labels)

    def x(i):
        return PAD_L + (plot_w * (i + 0.5) / n)

    def y(v):
        return PAD_T + plot_h * (1 - v / top)

    style = ['.bg{fill:#fcfcfb}.t{fill:#0b0b0b}.m{fill:#52514e}.g{stroke:#e4e3df}.a{stroke:#b9b8b2}']
    style += [f'.s{i}{{stroke:{c};fill:{c}}}' for i, c in enumerate(LIGHT)]
    dark = ['.bg{fill:#1a1a19}.t{fill:#ffffff}.m{fill:#c3c2b7}.g{stroke:#2f2f2d}.a{stroke:#555550}']
    dark += [f'.s{i}{{stroke:{c};fill:{c}}}' for i, c in enumerate(DARK)]
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
           f'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif" role="img" '
           f'aria-label="{html.escape(title)}">',
           f'<style>{"".join(style)}@media (prefers-color-scheme:dark){{{"".join(dark)}}}'
           '.l{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round}</style>',
           f'<rect class="bg" width="{W}" height="{H}" rx="8"/>',
           f'<text class="t" x="{PAD_L}" y="24" font-size="15" font-weight="600">{html.escape(title)}</text>',
           f'<text class="m" x="{PAD_L}" y="{PAD_T - 6}" font-size="11">{html.escape(unit)}</text>']
    for k in range(ticks + 1):
        v = step * k
        yy = y(v)
        out.append(f'<line class="{"a" if k == 0 else "g"}" x1="{PAD_L}" x2="{PAD_L + plot_w}" y1="{yy:.1f}" y2="{yy:.1f}"/>')
        out.append(f'<text class="m" x="{PAD_L - 8}" y="{yy + 4:.1f}" font-size="11" text-anchor="end">'
                   f'{fmt(v, tick_decimals(step))}</text>')
    for i, label in enumerate(labels):
        out.append(f'<text class="m" x="{x(i):.1f}" y="{H - PAD_B + 18}" font-size="11" text-anchor="middle">'
                   f'{html.escape(label)}</text>')
    ends = []
    for s, row in enumerate(data):
        points = [(x(i), y(v), v) for i, v in enumerate(row) if v is not None]
        if not points:
            continue
        path = ' '.join(f'{"M" if j == 0 else "L"}{px:.1f},{py:.1f}' for j, (px, py, _) in enumerate(points))
        out.append(f'<path class="l s{s}" d="{path}"/>')
        for px, py, v in points:
            out.append(f'<circle class="s{s}" cx="{px:.1f}" cy="{py:.1f}" r="4" stroke="none">'
                       f'<title>{html.escape(series[s][1])}: {fmt(v, decimals)} {html.escape(unit)}</title></circle>')
        ends.append([points[-1][1], s, points[-1][2]])
    # Direct labels at the line ends, nudged apart so none overlap, and kept
    # inside the plot: pushed down first, then back up from the bottom.
    ends.sort()
    gap, bottom = 28, PAD_T + plot_h + 4
    for k in range(1, len(ends)):
        ends[k][0] = max(ends[k][0], ends[k - 1][0] + gap)
    if ends and ends[-1][0] > bottom:
        ends[-1][0] = bottom
        for k in range(len(ends) - 2, -1, -1):
            ends[k][0] = min(ends[k][0], ends[k + 1][0] - gap)
    for yy, s, v in ends:
        lx = PAD_L + plot_w + 12
        out.append(f'<rect class="s{s}" x="{lx}" y="{yy - 9:.1f}" width="10" height="3" rx="1.5" stroke="none"/>')
        out.append(f'<text class="t" x="{lx + 16}" y="{yy - 4:.1f}" font-size="11">{html.escape(series[s][1])}</text>')
        out.append(f'<text class="m" x="{lx + 16}" y="{yy + 9:.1f}" font-size="11">{fmt(v, decimals)}</text>')
    out.append('</svg>')
    return '\n'.join(out) + '\n'


def comparable(results, section='versions'):
    """The versions measured on the newest entry's machine and corpus."""
    versions = results.get(section, {})
    if not versions:
        return {}
    newest = max(versions.values(), key=lambda e: e['measured'])
    same = {k: e for k, e in versions.items()
            if e['machine'] == newest['machine'] and e['corpus'] == newest['corpus']}
    for label in versions.keys() - same.keys():
        print(f'report: leaving out {label} ({section}), measured on another machine or corpus; bench.py rerun')
    return same


def table(entries, labels):
    rows = [('App startup, window shown (ms)', 'launch_warm_window_ms', 0),
            ('Time to play, first file after launch (ms)', 'ttp_ms.mp3-320', 0),
            ('Time to play, track switch, mean of 6 formats (ms)', 'switch_mean', 0),
            ('Seek latency, 3 min files, mean of 3 formats (ms)', 'seek_mean', 0),
            ('Seek latency, 60 min VBR MP3 (ms)', 'seek_ms.mp3-v0-60min', 0),
            ('Seek latency, VBR MP3 without Xing (ms)', 'seek_ms.mp3-v0-noxing', 0),
            ('Playback CPU, MP3 320k (% core)', 'play_cpu_pct.mp3-320', 1),
            ('Playback CPU, FLAC 24/192 (% core)', 'play_cpu_pct.flac-24-192', 1),
            ('Playback CPU, FLAC 24/192 + FX (% core)', 'play_cpu_pct.fx', 1),
            ('Playback CPU, FLAC 24/352.8 (% core)', 'play_cpu_pct.flac-24-352', 1),
            ('Playback CPU, FLAC 24/192 at +8% pitch (% core)', 'play_cpu_pct.pitch.flac-24-192', 1),
            ('Waveform analysis, FLAC 16/44.1, 3 min (ms)', 'waveform_ms.flac-16-44', 0),
            ('Waveform analysis, MP3 320k, 60 min (s)', 'waveform_ms.mp3-320-60min', 1),
            ('Library metadata scan, cold (s)', 'library_scan_cold_ms', 2),
            ('Memory, idle (MB)', 'idle_footprint_mb', 0),
            ('Memory, peak (MB)', 'peak_footprint_mb', 0)]
    lines = ['| | ' + ' | '.join(labels) + ' |', '| --- |' + ' ---: |' * len(labels)]
    for name, key, decimals in rows:
        cells = []
        for e in entries:
            if key in ('switch_mean', 'seek_mean'):
                keys = SWITCH_KEYS if key == 'switch_mean' else SEEK_KEYS
                vals = [e['metrics'][k] for k in keys if k in e['metrics']]
                v = sum(vals) / len(vals) if vals else None
            else:
                v = value(e, key)
            cells.append('–' if v is None else fmt(v, decimals))
        if any(c != '–' for c in cells):
            lines.append(f'| {name} | ' + ' | '.join(cells) + ' |')
    return '\n'.join(lines)


def perf_section(results):
    """The in-process charts, under their own machine line: VibePerf's numbers
    are comparable only with each other, whatever machine the app ran on."""
    versions = comparable(results, 'perf')
    if not versions:
        return []
    labels = list(versions)
    entries = [perf_entry(versions[k]) for k in labels]
    lines = []
    for name, title, unit, series, decimals in PERF_CHARTS:
        keyed = [(f'{bench}|{measure}', label) for bench, measure, label in series]
        if not any(value(e, key) is not None for e in entries for key, _ in keyed):
            continue
        (PERF / f'{name}.svg').write_text(chart_svg(title, unit, keyed, labels, entries, decimals))
        lines.append(f'![{title}](performance/{name}.svg)')
    m = versions[labels[-1]]['machine']
    return ['', '### Inside the app', '',
            f'The in-process suite, VibePerf, built against each version\'s own code and run on one machine '
            f'({m["chip"]}, {m["memory_gb"]} GB, macOS {m["macos"]}): the code under each feature, without the app '
            'around it. A line that starts late is a benchmark of code that version does not have.', ''] + lines


def write(results):
    versions = comparable(results)
    labels = list(versions)
    entries = [versions[k] for k in labels]
    if not entries:
        return
    PERF.mkdir(parents=True, exist_ok=True)
    # A chart whose metrics no charted version has yet (a scenario newer than
    # the data) is left out rather than drawn as empty axes.
    charts = [c for c in CHARTS if any(value(e, key) is not None for e in entries for key, _ in c[3])]
    for name, title, unit, series, decimals in charts:
        svg = chart_svg(title, unit if series[0][0] not in SECONDS else 's', series, labels, entries, decimals)
        (PERF / f'{name}.svg').write_text(svg)
    m = entries[-1]['machine']
    section = [BEGIN, '',
               f'The same benchmark suite, run against every release on one machine ({m["chip"]}, '
               f'{m["memory_gb"]} GB, macOS {m["macos"]}); lower is better everywhere. '
               'What each number measures and how to run it is below the charts.', '',
               table(entries, labels), '']
    for name, title, *_ in charts:
        section.append(f'![{title}](performance/{name}.svg)')
    section += perf_section(results)
    section += ['', END]
    text = PAGE.read_text()
    block = '\n'.join(section)
    if BEGIN not in text or END not in text:
        raise SystemExit(f'report: {PAGE} has lost its {BEGIN} / {END} markers')
    PAGE.write_text(re.sub(re.escape(BEGIN) + '.*?' + re.escape(END), lambda _: block, text, flags=re.S))
    print(f'report: {len(entries)} versions, {len(charts)} charts')
