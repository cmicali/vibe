#!/usr/bin/env python3
"""Vibe's performance benchmark: one suite, run unchanged against every version.

    bench.py app [<label>[=<ref>] ...]   the app suite at those versions, stored in
                                         results.json, the page redrawn; no labels
                                         is every version already there
    bench.py all [<label>[=<ref>] ...]   the app suite, then the component benchmarks
    bench.py build <label>=<ref> ...     build versions (scripts/bench/build-version.sh)
    bench.py report                      the charts and table atop docs/performance.md

A label is a release, `1.15` for tag v1.15; `=<ref>` measures any other commit.
A label with no v<label> tag yet is stored and charted as "<label> pre-release".

    --reps N    repetitions per scenario, median taken (default 5)
    --idle P    whole-machine idle % to wait for before each scenario (default 80)

The suite drives each version's own macOS app through the debug command channel
and reads the process from outside (proc_pid_rusage, the window server), so
the same numbers mean the same thing in every version; results.json's `app`
section. `all` also runs the vibe-perf skill's component benchmarks at each
version (`perf.py releases`, which owns that half of the page and also runs
alone) into its `components` section. What each metric is, and how it is
taken, is docs/performance.md; the traps are here.

TRAP: numbers are only comparable from one machine and one corpus. results.json
records both, and `report` refuses to chart a version measured elsewhere;
after a machine change, run every version again (`all` with no labels).
"""
import ctypes
import hashlib
import json
import os
import platform
import plistlib
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT / 'build/bench'
CORPUS = BENCH / 'corpus'
PERF = ROOT / 'docs/performance'
RESULTS = PERF / 'results.json'
SUITE_VERSION = 1

# ---------------------------------------------------------------- corpus

FLAC_16 = ['-c:a', 'flac', '-sample_fmt', 's16']
FLAC_24 = ['-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24']
MP3_320 = ['-c:a', 'libmp3lame', '-b:a', '320k']
MP3_V0 = ['-c:a', 'libmp3lame', '-q:a', '0']


def play_file(rate, codec, ext, seconds=180, art=True, channels=2):
    return {'rate': rate, 'codec': codec, 'ext': ext, 'seconds': seconds, 'art': art, 'channels': channels}


# Opened in this order in one app. The first is the first play after launch;
# every other open is a track switch from a playing file. The built-in
# speakers run at 48 kHz, so every other rate is resampled, 44.1 kHz included.
PLAY_FILES = {
    'mp3-320': play_file(44100, MP3_320, 'mp3'),
    'mp3-v0': play_file(44100, MP3_V0, 'mp3'),
    'aac-256': play_file(44100, ['-c:a', 'aac_at', '-b:a', '256k'], 'm4a'),
    'flac-16-44': play_file(44100, FLAC_16, 'flac'),
    'flac-24-96': play_file(96000, FLAC_24, 'flac'),
    'flac-24-192': play_file(192000, FLAC_24, 'flac'),
    'wav-24-96': play_file(96000, ['-c:a', 'pcm_s24le'], 'wav', art=False),
    # MP3 at its worst: an hour long, and VBR with no Xing header, so no
    # seek table and no frame count; and at 48 kHz, the one MP3 not resampled.
    'mp3-320-48k': play_file(48000, MP3_320, 'mp3'),
    'mp3-320-60min': play_file(44100, MP3_320, 'mp3', seconds=3600),
    'mp3-v0-60min': play_file(44100, MP3_V0, 'mp3', seconds=3600),
    'mp3-v0-noxing': play_file(44100, MP3_V0 + ['-write_xing', '0'], 'mp3', seconds=600),
    # The resampler at awkward ratios: 44.1 kHz family into 48, up to 7.35:1
    # down (DXD), and 22.05 kHz mono up.
    'flac-24-88': play_file(88200, FLAC_24, 'flac'),
    'flac-24-176': play_file(176400, FLAC_24, 'flac'),
    'flac-24-352': play_file(352800, FLAC_24, 'flac', seconds=60),
    'flac-16-22-mono': play_file(22050, FLAC_16, 'flac', channels=1),
}
SEEK_FILES = ['mp3-v0', 'aac-256', 'flac-24-192', 'mp3-320-60min', 'mp3-v0-60min', 'mp3-v0-noxing']
SEEKS_PER_FILE = 40
WAVEFORM_FILES = ['mp3-320', 'flac-16-44', 'flac-24-192', 'mp3-320-60min', 'flac-24-352']
FX_FILE = 'flac-24-192'
# The pitch fader's varispeed at full throw: a non-integer ratio on top of the
# rate conversion. (file, percent)
PITCH_CASES = [('flac-24-192', 8), ('mp3-320', -8)]
LIBRARY_ALBUMS, LIBRARY_TRACKS, LIBRARY_SECONDS = 30, 20, 30


def ffmpeg(*args):
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args], check=True)


def resolve(ref):
    """The commit a ref names."""
    return subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--verify', ref + '^{commit}'],
                          capture_output=True, text=True, check=True).stdout.strip()


def option(args, flag, default=None, kind=str):
    """Takes `flag value` out of args: the value, or default when it is absent."""
    if flag in args:
        i = args.index(flag)
        value = kind(args[i + 1])
        del args[i:i + 2]
        return value
    return default


def switch(args, flag):
    """Takes a bare flag out of args: whether it was there."""
    if flag in args:
        args.remove(flag)
        return True
    return False


def play_source(rate, seconds, channels):
    """Broadband worst case: decorrelated pink noise under a 120 BPM kick, so
    lossless files barely compress and the BPM analyzer has a beat to find."""
    kick = "0.6*sin(2*PI*55*t)*exp(-18*mod(t,0.5))"
    noise = [f'anoisesrc=d={seconds}:c=pink:r={rate}:a=0.2:s={seed}' for seed in (7, 11)[:channels]]
    inputs = [arg for source in noise for arg in ('-f', 'lavfi', '-i', source)]
    inputs += ['-f', 'lavfi', '-i', f"aevalsrc='{'|'.join([kick] * channels)}':s={rate}:d={seconds}"]
    if channels == 1:
        return inputs + ['-filter_complex', '[0][1]amix=inputs=2:normalize=0[a]'], 2
    return inputs + ['-filter_complex',
                     '[0][1]join=inputs=2:channel_layout=stereo[n];[n][2]amix=inputs=2:normalize=0[a]'], 3


def cover(path, size, hue):
    ffmpeg('-f', 'lavfi', '-i', f'testsrc2=s={size}x{size}:d=1', '-vf', f'hue=h={hue}',
           '-frames:v', '1', '-q:v', '3', str(path))


def make_corpus():
    """Deterministic, and never regenerated over an existing file: the corpus
    hash in results.json is what makes two runs comparable."""
    play = CORPUS / 'play'
    library = CORPUS / 'library'
    play.mkdir(parents=True, exist_ok=True)
    art = CORPUS / 'cover-1000.jpg'
    if not art.exists():
        cover(art, 1000, 0)
    for name, spec in PLAY_FILES.items():
        out = play_path(name)
        if out.exists():
            continue
        print(f'corpus: {out.name}', flush=True)
        tmp = out.with_suffix('.tmp.' + spec['ext'])
        inputs, art_input = play_source(spec['rate'], spec['seconds'], spec['channels'])
        maps = ['-map', '[a]']
        if spec['art']:
            inputs += ['-i', str(art)]
            maps += ['-map', f'{art_input}:v', '-c:v', 'copy', '-disposition:v', 'attached_pic']
        tags = ['-metadata', f'title=Bench {name}', '-metadata', 'artist=Vibe Bench', '-metadata', 'album=Corpus']
        ffmpeg(*inputs, *maps, '-ar', str(spec['rate']), '-ac', str(spec['channels']), *spec['codec'], *tags, str(tmp))
        tmp.rename(out)
    if not (library / '.complete').exists():
        shutil.rmtree(library, ignore_errors=True)
        formats = [('mp3', ['-c:a', 'libmp3lame', '-q:a', '2']), ('flac', ['-c:a', 'flac', '-sample_fmt', 's16']),
                   ('m4a', ['-c:a', 'aac_at', '-b:a', '192k'])]
        for album in range(LIBRARY_ALBUMS):
            print(f'corpus: library album {album + 1}/{LIBRARY_ALBUMS}', flush=True)
            ext, codec = formats[album % 3]
            folder = library / f'Artist {album // 3 + 1:02d}' / f'Album {album + 1:02d}'
            folder.mkdir(parents=True)
            album_art = folder / '.cover.jpg'
            cover(album_art, 600, album * 12)
            base = folder / f'.base.{ext}'
            f0, f1 = 110 * 2 ** (album % 12 / 12), 165 * 2 ** (album % 7 / 12)
            ffmpeg('-f', 'lavfi', '-i', f"aevalsrc='0.3*sin(2*PI*{f0:.3f}*t)+0.2*sin(2*PI*{f1:.3f}*t)|"
                   f"0.3*sin(2*PI*{f0:.3f}*t)+0.2*sin(2*PI*{f1 * 1.5:.3f}*t)':s=44100:d={LIBRARY_SECONDS}",
                   *codec, str(base))
            for track in range(LIBRARY_TRACKS):
                ffmpeg('-i', str(base), '-i', str(album_art), '-map', '0:a', '-map', '1:v', '-c', 'copy',
                       '-disposition:v', 'attached_pic',
                       '-metadata', f'title=Track {track + 1:02d} of Album {album + 1:02d}',
                       '-metadata', f'artist=Artist {album // 3 + 1:02d}',
                       '-metadata', f'album=Album {album + 1:02d}', '-metadata', f'track={track + 1}',
                       '-metadata', f'TBPM={100 + album}' if ext == 'mp3' else f'bpm={100 + album}',
                       str(folder / f'{track + 1:02d} Track {track + 1:02d}.{ext}'))
            base.unlink()
            album_art.unlink()
        (library / '.complete').write_text('')
    return corpus_hash()


def corpus_hash(extra=False):
    """The app benchmarks' corpus; with `extra`, the component benchmarks' too
    (perf.py adds extra/). Each suite hashes only its own files, so a run that
    creates extra/ midway cannot change the app benchmarks' hash under them."""
    digest = hashlib.sha256()
    for path in sorted(CORPUS.rglob('*')):
        if not extra and path.relative_to(CORPUS).parts[0] == 'extra':
            continue
        if path.is_file() and not path.name.startswith('.'):
            digest.update(f'{path.relative_to(CORPUS)}:{path.stat().st_size}\n'.encode())
    return digest.hexdigest()[:16]


def play_path(name):
    return CORPUS / 'play' / f'{name}.{PLAY_FILES[name]["ext"]}'


def library_count():
    return sum(1 for p in (CORPUS / 'library').rglob('*') if p.is_file() and not p.name.startswith('.'))

# ---------------------------------------------------------------- process

libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
libc.notify_post.argtypes = [ctypes.c_char_p]
libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libc.clock_gettime_nsec_np.argtypes = [ctypes.c_int]
libc.clock_gettime_nsec_np.restype = ctypes.c_uint64
CLOCK_UPTIME_RAW = 8


def uptime_ns():
    """The probe's clock, so its launch stamps and these compare.

    TRAP: not time.monotonic_ns(). Its origin depends on the Python: the
    Xcode/system 3.9 counts from its own process start, so an interval from a
    probe stamp came out as minus the machine's awake time since boot."""
    return libc.clock_gettime_nsec_np(CLOCK_UPTIME_RAW)


class MachTimebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


_timebase = MachTimebase()
libc.mach_timebase_info(ctypes.byref(_timebase))
MACH_NS = _timebase.numer / _timebase.denom

# rusage_info_v6, as uint64s after the 16-byte uuid (sys/resource.h).
RU_USER, RU_SYSTEM, RU_IDLE_WKUPS, RU_INTERRUPT_WKUPS = 0, 1, 2, 3
RU_FOOTPRINT, RU_LIFETIME_MAX_FOOTPRINT, RU_INSTRUCTIONS, RU_ENERGY_NJ = 7, 28, 29, 40


def rusage(pid):
    buf = (ctypes.c_uint64 * 64)()
    if libc.proc_pid_rusage(pid, 6, buf) != 0:
        raise ProcessLookupError(pid)
    words = list(buf)[2:]  # the uuid
    return {
        't': uptime_ns(),
        # TRAP: the CPU times are mach absolute units, not ns, on Apple silicon.
        'cpu_ns': (words[RU_USER] + words[RU_SYSTEM]) * MACH_NS,
        'wakeups': words[RU_IDLE_WKUPS] + words[RU_INTERRUPT_WKUPS],
        'footprint': words[RU_FOOTPRINT],
        'max_footprint': words[RU_LIFETIME_MAX_FOOTPRINT],
        'instructions': words[RU_INSTRUCTIONS],
        'energy_nj': words[RU_ENERGY_NJ],
    }


def usage_between(a, b):
    seconds = (b['t'] - a['t']) / 1e9
    return {
        'cpu_pct': 100 * (b['cpu_ns'] - a['cpu_ns']) / 1e9 / seconds,
        'wakeups_per_s': (b['wakeups'] - a['wakeups']) / seconds,
        'minstr_per_s': (b['instructions'] - a['instructions']) / 1e6 / seconds,
        'power_mw': (b['energy_nj'] - a['energy_nj']) / 1e6 / seconds,
    }


def measure_usage(pid, seconds):
    a = rusage(pid)
    time.sleep(seconds)
    return usage_between(a, rusage(pid))


def wait_quiet(pid, below_pct=15.0, windows=4, limit=30.0):
    """Until the process has used under below_pct of a core for `windows`
    consecutive quarter seconds: background analysis has finished. The bar is
    low because analysis of a long file can run well under half a core, while
    no version's steady playback reaches 10%."""
    start, calm = time.monotonic(), 0
    while time.monotonic() - start < limit:
        calm = calm + 1 if measure_usage(pid, 0.25)['cpu_pct'] < below_pct else 0
        if calm >= windows:
            return True
    return False


def system_idle_pct():
    """Whole-machine idle over one second, as top reports it."""
    out = subprocess.run(['top', '-l', '2', '-n', '0', '-s', '1'], capture_output=True, text=True).stdout
    line = [l for l in out.splitlines() if l.startswith('CPU usage')][-1]
    return float(line.split(',')[-1].split('%')[0])


def wait_system_quiet(threshold, streak=3, limit=3600):
    """Until the machine has been at least `threshold` % idle for `streak`
    seconds running. Another workload inflates every number here, and on many
    cores it does so unevenly, which charts as a regression."""
    start, calm, waiting = time.monotonic(), 0, False
    while time.monotonic() - start < limit:
        idle = system_idle_pct()
        calm = calm + 1 if idle >= threshold else 0
        if calm >= streak:
            return idle
        if idle < threshold and not waiting:
            print(f'  waiting for a quiet system ({idle:.0f}% idle, want {threshold:.0f}%)', flush=True)
            waiting = True
    raise RuntimeError(f'system never went quiet in {limit}s')


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False

# ---------------------------------------------------------------- the app


class ChannelTimeout(Exception):
    pass


class App:
    """One running version. The executable is its own channel client, but its
    client polls every 50 ms and costs a process launch per command; this one
    speaks the same wire format (a JSON file in the channel directory, a
    notify_post, a reply file) and polls every 0.2 ms, so it can time the app."""

    def __init__(self, label, home):
        self.home = Path(home)
        # The channel's directory: build-version.sh points it here.
        self.tmp = self.home / 'channel'
        self.tmp.mkdir(parents=True, exist_ok=True)
        exe = app_executable(label)
        env = dict(os.environ, CFFIXED_USER_HOME=str(self.home), VIBE_DEBUG_TMPDIR=str(self.tmp) + '/')
        # The real output path, silent: the output unit drives the built-in
        # speakers' clock and --silent zeroes the samples after the meter.
        out = subprocess.run([str(BENCH / 'probe'), str(exe), '--silent', '--no-now-playing',
                              '-NSAppSleepDisabled', 'YES'],
                             env=env, capture_output=True, text=True, check=True)
        launch = json.loads(out.stdout)
        self.pid = launch['pid']
        if not launch['windowNs']:
            self.stop()
            raise RuntimeError('no window within 30 s')
        self.window_ms = (launch['windowNs'] - launch['t0']) / 1e6
        reply, _, received = self.command('dump_state', timeout=30, repost=True)
        self.ready_ms = (received - launch['t0']) / 1e6
        self.check_output(reply)

    def check_output(self, state):
        """Refuse to go on unless the app is bound to the built-in speakers
        with bit-perfect off, before any file can start the device: a wrong
        binding would start IO on whatever the system default is (AirPods).
        The saved device is applied asynchronously after launch, so the first
        reply can still show the default; allow it 5 s to settle."""
        speakers_id, deadline = speakers()[0], time.monotonic() + 5
        while True:
            player = state['player']
            bit_perfect = player.get('bitPerfect')
            if isinstance(bit_perfect, dict) and bit_perfect.get('enabled'):
                problem = 'bit-perfect output is on'
            elif player.get('outputDeviceId') != speakers_id:
                problem = f'bound to device {player.get("outputDeviceId")}, not the built-in speakers ({speakers_id})'
            else:
                return
            if time.monotonic() > deadline:
                self.stop()
                raise RuntimeError(problem)
            time.sleep(0.1)
            state = self.state()

    def command(self, *args, timeout=10.0, repost=False):
        """(reply, handled ns, received ns). repost: keep posting while waiting,
        for a command sent before the app has registered for the notification.

        Intervals start at `handled`, not at the send: the app deletes the
        command file as it starts on it, so the file's disappearance is the
        start of the app's own work, free of delivery and directory listing."""
        cid = str(uuid.uuid4()).upper()
        path = self.tmp / f'vibe-command-{cid}.json'
        reply_path = self.tmp / f'vibe-response-{cid}.txt'
        staging = self.tmp / f'.staging-{cid}'
        staging.write_text(json.dumps({'id': cid, 'args': [str(a) for a in args]}))
        staging.rename(path)
        sent = uptime_ns()
        libc.notify_post(b'com.vibe.debug.command')
        deadline = sent + timeout * 1e9
        handled, polls = None, 0
        while uptime_ns() < deadline:
            if handled is None and not path.exists():
                handled = uptime_ns()
            if reply_path.exists():
                received = uptime_ns()
                text = reply_path.read_text()
                reply_path.unlink()
                reply = json.loads(text)
                if 'error' in reply:
                    raise RuntimeError(f'{args[0]}: {reply["error"]}')
                return reply, handled or received, received
            polls += 1
            if repost and polls % 20 == 0:
                if not alive(self.pid):
                    raise RuntimeError('app exited')
                libc.notify_post(b'com.vibe.debug.command')
            time.sleep(0.0002)
        path.unlink(missing_ok=True)
        raise ChannelTimeout(f'{args[0]}: no reply in {timeout}s')

    def state(self):
        return self.command('dump_state')[0]

    def usage(self):
        return rusage(self.pid)

    def stop(self):
        if not alive(self.pid):
            return
        os.kill(self.pid, signal.SIGTERM)
        for _ in range(500):
            if not alive(self.pid):
                return
            time.sleep(0.01)
        os.kill(self.pid, signal.SIGKILL)
        while alive(self.pid):
            time.sleep(0.01)


SPEAKERS_UID = 'BuiltInSpeakerDevice'  # every Mac's built-in speakers; the name varies by model


def speakers():
    """(CoreAudio object ID, name) of the built-in speakers; the ID is what
    dump_state reports as the bound device."""
    out = subprocess.run([str(BENCH / 'probe'), '--device-id', SPEAKERS_UID], capture_output=True, text=True)
    device, _, name = out.stdout.strip().partition('\t')
    if not name:
        raise SystemExit('bench: this Mac has no built-in speakers to hold the app to')
    return int(device), name


BUNDLE_ID = 'com.commonwealthrecordings.Vibe.bench'


def reset_prefs():
    """Every scenario starts from these preferences and no others: the saved
    output device is the built-in speakers, with bit-perfect and exclusive
    output off for them (the same keys in every version; 1.8-1.11 have no
    bit-perfect and ignore those).

    TRAP: CFFIXED_USER_HOME moves caches but not preferences, which cfprefsd
    keeps in the real home, so they are reset here, through cfprefsd, for the
    bench builds' own bundle ID. Never point `defaults` at the shipping ID:
    for a sandboxed app's domain it reaches the user's own container."""
    subprocess.run(['defaults', 'delete', BUNDLE_ID], capture_output=True)
    seed = {
        'AudioPlayer.deviceUID': SPEAKERS_UID,
        'AudioPlayer.deviceName': speakers()[1],
        'AudioPlayer.outputModesByDeviceUID': {SPEAKERS_UID: {'bitPerfect': False, 'exclusive': False}},
        'AudioPlayer.allowBitPerfectOnAnyDevice': False,
    }
    subprocess.run(['defaults', 'import', BUNDLE_ID, '-'], input=plistlib.dumps(seed), check=True)


def fresh_home():
    reset_prefs()
    return tempfile.mkdtemp(prefix='vibe-bench-', dir=BENCH / 'homes')

# ---------------------------------------------------------------- scenarios


# TRAP: poll gently. dump_state runs on the app's main thread and a round trip
# is half a millisecond, so a tight loop is thousands of requests a second: it
# pins the main thread and 1.8, whose dump_state is heaviest, then takes tens
# of seconds to start a track or land a seek, measuring the benchmark instead
# of the app. Nothing is lost by it: the position is the output device's
# rendered audio, so a reply handled at T showing position P says rendering
# began at T - P, and every interval is back-dated that way.
POLL_S = 0.025


def time_to_play(app, path):
    """Open a file cold and time until audio renders from the device. A
    position larger than the time since the open is the previous track's."""
    _, start, _ = app.command('open', path)
    while True:
        time.sleep(POLL_S)
        reply, polled, _ = app.command('dump_state')
        position = reply['player']['position']
        elapsed = (polled - start) / 1e9
        if 0 < position < elapsed + 0.05:
            return max(0.0, (polled - start) / 1e6 - position * 1000)
        if elapsed > 60:
            print(f'  warning: {path.name} did not play within 60 s', flush=True)
            return None


def seek_latencies(app, duration, count, rng):
    """Seek, then time until audio renders past the target, back-dated by the
    position's lead over it. A seek that has not resumed in 15 s is a stall,
    None, and the run goes on."""
    latencies = []
    for _ in range(count):
        target = round(rng.uniform(5, duration - 15), 3)
        _, start, _ = app.command('seek', target)
        while True:
            time.sleep(POLL_S)
            reply, polled, _ = app.command('dump_state')
            position = reply['player']['position']
            elapsed = (polled - start) / 1e9
            if target < position < target + elapsed + 0.05:
                latencies.append(max(0.0, (polled - start) / 1e6 - (position - target) * 1000))
                break
            if elapsed > 15:
                print(f'  warning: seek to {target} did not resume within 15 s', flush=True)
                latencies.append(None)
                break
        time.sleep(0.2)
    return latencies


COLD_LAUNCHES, WARM_LAUNCHES = 3, 10


def scenario_launch(label, home, rep):
    """First launches, each into an empty home with reset prefs, and the idle
    cost after the first; then warm relaunches over one home."""
    out, colds = {}, []
    for launch in range(COLD_LAUNCHES):
        cold_home = home if launch == 0 else fresh_home()
        app = App(label, cold_home)
        try:
            colds.append((app.window_ms, app.ready_ms))
            if launch == 0:
                time.sleep(4)
                idle = measure_usage(app.pid, 5)
                out['idle_cpu_pct'] = idle['cpu_pct']
                out['idle_wakeups_per_s'] = idle['wakeups_per_s']
                out['idle_footprint_mb'] = app.usage()['footprint'] / 2 ** 20
        finally:
            app.stop()
            if launch:
                shutil.rmtree(cold_home, ignore_errors=True)
    out['launch_cold_window_ms'] = statistics.median(w for w, _ in colds)
    out['launch_cold_ready_ms'] = statistics.median(r for _, r in colds)
    windows, readies = [], []
    for _ in range(WARM_LAUNCHES):
        app = App(label, home)
        windows.append(app.window_ms)
        readies.append(app.ready_ms)
        app.stop()
    out['launch_warm_window_ms'] = statistics.median(windows)
    out['launch_warm_ready_ms'] = statistics.median(readies)
    return out


def scenario_playback(label, home, rep):
    """Every format opened cold: time to play, then steady playback cost once
    its analysis has finished, then seeks. Ends with the FX worst case and a
    paused idle."""
    out = {}
    rng = random.Random(1000 + rep)
    app = App(label, home)
    try:
        for name in PLAY_FILES:
            path = play_path(name)
            out[f'ttp_ms.{name}'] = time_to_play(app, path)
            if out[f'ttp_ms.{name}'] is None:
                continue
            if not wait_quiet(app.pid, limit=120):
                print(f'  warning: {name} never went quiet', flush=True)
            use = measure_usage(app.pid, 8)
            out[f'play_cpu_pct.{name}'] = use['cpu_pct']
            out[f'play_minstr_per_s.{name}'] = use['minstr_per_s']
            out[f'play_power_mw.{name}'] = use['power_mw']
            out[f'play_wakeups_per_s.{name}'] = use['wakeups_per_s']
            if name in SEEK_FILES:
                duration = app.state()['player']['duration']
                latencies = seek_latencies(app, duration, SEEKS_PER_FILE, rng)
                resumed = [v for v in latencies if v is not None]
                out[f'seek_ms.{name}'] = statistics.mean(resumed) if resumed else None
                out[f'seek_stalls.{name}'] = len(latencies) - len(resumed)
        app.command('open', play_path(FX_FILE))
        time.sleep(1)
        wait_quiet(app.pid, limit=120)
        for verb in ('reverb_send_on', 'delay_send_on', 'short_delay_send_on', 'toggle_low_kill'):
            app.command(verb)
        time.sleep(1)
        use = measure_usage(app.pid, 8)
        out['play_cpu_pct.fx'] = use['cpu_pct']
        out['play_power_mw.fx'] = use['power_mw']
        for verb in ('reverb_send_off', 'delay_send_off', 'short_delay_send_off', 'toggle_low_kill'):
            app.command(verb)
        for name, percent in PITCH_CASES:
            app.command('open', play_path(name))
            time.sleep(1)
            wait_quiet(app.pid, limit=120)
            app.command('set_pitch', percent)
            time.sleep(1)
            use = measure_usage(app.pid, 8)
            out[f'play_cpu_pct.pitch.{name}'] = use['cpu_pct']
            app.command('set_pitch', 0)
        app.command('play_pause')
        time.sleep(3)
        use = measure_usage(app.pid, 5)
        out['paused_cpu_pct'] = use['cpu_pct']
        out['paused_wakeups_per_s'] = use['wakeups_per_s']
        out['playback_footprint_mb'] = app.usage()['footprint'] / 2 ** 20
    finally:
        app.stop()
    return out


def scenario_waveform(label, home, rep):
    """A full decode + waveform + tempo analysis per file, cold."""
    out = {}
    app = App(label, home)
    try:
        for name in WAVEFORM_FILES:
            path = play_path(name)
            app.command('file_clear_cache', path)
            _, start, received = app.command('file_cache', path, timeout=120)
            out[f'waveform_ms.{name}'] = (received - start) / 1e6
    finally:
        app.stop()
    return out


def scan(app, folder, count):
    before = app.usage()
    _, start, _ = app.command('open', folder)
    listed = None
    while True:
        time.sleep(0.025)
        if listed is None:
            reply, polled, _ = app.command('dump_state')
            if reply['playlist']['count'] >= count:
                listed = (polled - start) / 1e6
            continue
        progress, polled, _ = app.command('dump_metadata_progress')
        if progress['attempted'] >= count:
            after = app.usage()
            return listed, (polled - start) / 1e6, (after['cpu_ns'] - before['cpu_ns']) / 1e9
        if (polled - start) / 1e9 > 300:
            raise RuntimeError(f'scan stuck at {progress}')


def scenario_library(label, home, rep):
    """Open a 600-file library folder: rows listed, every row's metadata read.
    Cold into an empty cache, then warm in a relaunch over the same cache."""
    out = {}
    folder, count = CORPUS / 'library', library_count()
    app = App(label, home)
    try:
        listed, scanned, cpu = scan(app, folder, count)
        out['library_list_ms'] = listed
        out['library_scan_cold_ms'] = scanned
        out['library_scan_cpu_s'] = cpu
        wait_quiet(app.pid)
        use = app.usage()
        out['library_footprint_mb'] = use['footprint'] / 2 ** 20
        out['peak_footprint_mb'] = use['max_footprint'] / 2 ** 20
    finally:
        app.stop()
    app = App(label, home)
    try:
        _, scanned, _ = scan(app, folder, count)
        out['library_scan_warm_ms'] = scanned
    finally:
        app.stop()
    return out


SCENARIOS = [scenario_launch, scenario_playback, scenario_waveform, scenario_library]

# ---------------------------------------------------------------- driver


def machine():
    def sysctl(name):
        return subprocess.run(['sysctl', '-n', name], capture_output=True, text=True).stdout.strip()
    xcode = subprocess.run(['xcodebuild', '-version'], capture_output=True, text=True).stdout.split('\n')[0]
    return {'chip': sysctl('machdep.cpu.brand_string'), 'cores': int(sysctl('hw.ncpu')),
            'memory_gb': int(sysctl('hw.memsize')) // 2 ** 30, 'macos': platform.mac_ver()[0], 'xcode': xcode}


def load_results():
    if RESULTS.exists():
        return json.loads(RESULTS.read_text())
    return {'suite': SUITE_VERSION, 'app': {}}


def save_results(results):
    PERF.mkdir(parents=True, exist_ok=True)
    for section in ('app', 'components'):
        if section in results:
            results[section] = dict(sorted(results[section].items(), key=lambda kv: version_key(kv[0])))
    RESULTS.write_text(json.dumps(results, indent=2) + '\n')


def version_key(label):
    return tuple(int(p) for p in label.split('.'))


def prerelease(label):
    """No v<label> tag yet: numbers from code that has not shipped as that
    release, charted as such until a run at the tag replaces them."""
    return subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--verify', '--quiet', f'refs/tags/v{label}'],
                          capture_output=True).returncode != 0


def app_executable(label):
    return BENCH / 'apps' / label / 'Vibe.app/Contents/MacOS/VibeBenchApp'


def build(label, ref):
    subprocess.run([str(ROOT / 'scripts/bench/build-version.sh'), label, ref], check=True)


def ensure_probe():
    probe = BENCH / 'probe'
    source = ROOT / 'scripts/bench/probe.swift'
    if not probe.exists() or probe.stat().st_mtime < source.stat().st_mtime:
        BENCH.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-O', str(source), '-o', str(probe)], check=True)


def run_version(label, ref, reps, corpus, idle):
    if not app_executable(label).exists():  # a build from before the process was VibeBenchApp lacks it
        build(label, ref)
    commit = (BENCH / 'apps' / label / 'commit').read_text().strip()
    (BENCH / 'homes').mkdir(parents=True, exist_ok=True)
    samples = {}
    for rep in range(reps):
        for scenario in SCENARIOS:
            samples.setdefault('system_idle_pct', []).append(wait_system_quiet(idle))
            home = fresh_home()
            started = time.monotonic()
            try:
                values = scenario(label, home, rep)
            except (RuntimeError, ChannelTimeout, ProcessLookupError) as error:
                # One version misbehaving costs that repetition, not the run.
                print(f'  warning: {label} {scenario.__name__[9:]} failed: {error}', flush=True)
                values = {}
            finally:
                shutil.rmtree(home, ignore_errors=True)
            print(f'{label} rep {rep + 1}/{reps} {scenario.__name__[9:]}: {time.monotonic() - started:.0f}s', flush=True)
            for key, value in values.items():
                samples.setdefault(key, []).append(value)
    metrics = {key: round(statistics.median(v for v in values if v is not None), 3)
               for key, values in samples.items() if any(v is not None for v in values)}
    return {'ref': ref, 'commit': commit, 'prerelease': prerelease(label), 'measured': time.strftime('%Y-%m-%d'),
            'reps': reps, 'corpus': corpus, 'machine': machine(), 'metrics': metrics,
            'samples': {k: [None if v is None else round(v, 3) for v in vs] for k, vs in samples.items()}}


def app_version(ref):
    """The version the app at REF calls itself (project.yml's MARKETING_VERSION)."""
    spec = subprocess.run(['git', '-C', str(ROOT), 'show', f'{ref}:project.yml'],
                          capture_output=True, text=True, check=True).stdout
    return re.search(r'MARKETING_VERSION:\s*"?([\d.]+)', spec).group(1)


def check_history(results, section, targets, corpus, new_machine):
    """Refuses a run that would silently take versions off the page. The page
    charts only versions measured on the newest entry's setup (report.py's
    same_setup), so a run on another Mac, or the same Mac after a macOS or
    Xcode update, drops every version it does not rerun. Rerunning all of
    them, or --new-machine, is the way through."""
    import report
    entries = results.get(section, {})
    if not entries or new_machine:
        return
    here = {'machine': machine(), 'corpus': corpus}
    remeasured = {label for label, _ in targets}
    after = {label: here if label in remeasured else entry for label, entry in entries.items()}
    dropped = sorted(entries.keys() - report.same_setup(after, here).keys(), key=version_key)
    if not dropped:
        return
    newest = max(entries.values(), key=lambda e: e['measured'])
    there = newest['machine']
    diffs = [f'  {key}: {there.get(key)} in the history, {here["machine"].get(key)} here'
             for key in sorted(set(there) | set(here['machine'])) if there.get(key) != here['machine'].get(key)]
    if newest['corpus'] != corpus:
        diffs.append(f'  corpus: {newest["corpus"]} in the history, {corpus} here (ffmpeg makes it per machine)')
    raise SystemExit(
        f'refusing: the {section} history was measured elsewhere, and this run would take '
        f'{", ".join(dropped)} off the page.\n' + '\n'.join(diffs) + '\n'
        f'Run it on the Mac that matches, or rerun every version here (no VERSIONS), '
        f'or pass ARGS="--new-machine" to start the {section} history on this Mac.')


def parse_targets(args, results, sections=('app', 'components')):
    """(label, ref) for each argument, or for every version already in those
    sections when there are none. `1.15` is that release: tag v1.15 once it
    exists, so a rerun replaces a pre-release, else the ref stored for it.
    `1.15=<ref>` is that label at any commit, and a bare ref (`HEAD`) is
    labelled with the version its own project.yml declares."""
    known = {}
    for section in reversed(sections):
        known.update({label: entry['ref'] for label, entry in results.get(section, {}).items()})

    def release_ref(label):
        return known.get(label, f'v{label}') if prerelease(label) else f'v{label}'
    if not args:
        return [(label, release_ref(label)) for label in sorted(known, key=version_key)]
    targets = []
    for arg in args:
        label, _, ref = arg.partition('=')
        if not ref and not re.fullmatch(r'\d+(\.\d+)+', label):
            label, ref = app_version(label), resolve(label)
        targets.append((label, ref or release_ref(label)))
    return targets


def main(argv):
    if not argv or argv[0] not in ('app', 'all', 'build', 'report', 'corpus'):
        print(__doc__)
        return 64
    command, args = argv[0], argv[1:]
    new_machine = switch(args, '--new-machine')
    reps, idle = option(args, '--reps', 5, int), option(args, '--idle', 80.0, float)
    results = load_results()
    if command == 'report':
        import report
        report.write(results)
        return 0
    if command == 'build':
        for label, ref in parse_targets(args, results):
            build(label, ref)
        return 0
    corpus = make_corpus()
    if command == 'corpus':
        print(corpus)
        return 0
    sys.path.insert(0, str(ROOT / '.claude/skills/vibe-perf/scripts'))
    import perf
    targets = parse_targets(args, results, ('app',) if command == 'app' else ('app', 'components'))
    check_history(results, 'app', targets, corpus, new_machine)
    if command == 'all':
        check_history(results, 'components', targets, perf.corpus(), new_machine)
    ensure_probe()
    for label, ref in targets:
        results.setdefault('app', {})[label] = run_version(label, ref, reps, corpus, idle)
        save_results(results)
        if command == 'app':
            continue
        try:
            results.setdefault('components', {})[label] = perf.measure_release(label, ref, reps)
            save_results(results)
        except (SystemExit, subprocess.CalledProcessError) as error:
            print(f'  warning: {label}: the component benchmarks failed: {error}', flush=True)
    import report
    report.write(results)
    return 0


if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).parent))
    sys.exit(main(sys.argv[1:]))
