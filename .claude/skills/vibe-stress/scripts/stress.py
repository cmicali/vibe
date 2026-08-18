#!/usr/bin/env python3
"""Seeded stress and fuzz driver for the running Vibe app.

It drives the debug command channel with weighted random operations against a
corpus of real audio files, and checks four oracles between batches:

  liveness    the app still answers          (the channel is delivered on the
                                              main queue, so a timeout whose
                                              recovery probe is ALSO slow is a
                                              main-thread stall; one that probes
                                              clean was just a slow verb)
  consistency check_consistency has no       (re-checked after a settle, since a
              surviving violations           render can lag its state change)
  health      dump_health has not grown      (footprint, fds, threads, windows,
              without bound                   views, engine nodes)
  crash       the process is still alive     (and no fresh .ips landed)

Every run is reproducible: the seed is printed at the start and `--seed N`
replays the identical op sequence. Every op is journaled as NDJSON, and
`--shrink` delta-debugs a failing journal down to a minimal repro you can paste
into run-script.sh.

    stress.py --corpus ~/Music/big --iterations 2000
    stress.py --corpus ~/Music/big --seed 48213 --replay run.ndjson
    stress.py --corpus ~/Music/big --shrink run.ndjson

It is built on the vibe-debug skill's command channel and launches through
that skill's launch.sh, so the app comes up off the audio hardware
(--no-audio-hw --silent) and a long soak never opens an output device. Set
VIBE_AUDIBLE=1 to override.

NOT included in any profile: convert_to_flac. It writes files beside the
source and can trash the original, and the corpus is the user's real music.
"""

import argparse
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
DEFAULT_APP = REPO / "build/DerivedData/Build/Products/Debug/Vibe.app"
# Journals, health series, stall samples and failure directories are build
# output, not source: they land under build/, which is already gitignored and
# which `make clean` removes. Writing them to the CWD instead would litter the
# repo root, since that is where `make stress` runs.
DEFAULT_OUTPUT_DIR = REPO / "build/stress"
# The launcher belongs to vibe-debug: this harness is built on that skill's
# command channel and deliberately does not carry its own copy of the launch
# rules, which are subtle (sandbox grants, off-hardware flags, stale-binary
# detection) and must not drift into two versions.
LAUNCH_SH = Path(__file__).resolve().parents[2] / "vibe-debug/scripts/launch.sh"
CRASH_DIR = Path.home() / "Library/Logs/DiagnosticReports"

# Attempts per channel command before a signal-killed client counts as a real
# failure; see Channel.run for why a sandboxed binary fails to launch at all.
CLIENT_LAUNCH_RETRIES = 4

# Verbs whose own in-app wait is longer than the 30s default, which must stay
# above it: a client timeout below the app's own deadline reports a verb that
# was still working as an unresponsive app. A 7-minute MP3 takes ~30s through
# file_cache in a -O0 debug build, and the app allows it 60.
VERB_TIMEOUTS = {"file_cache": 90, "convert_to_flac": 150, "quiesce": 40}

# A recovery probe slower than this, after a timed-out op, is what makes it a
# main-thread stall rather than a verb that outran its budget. Ordinary probe
# latency is ~110ms.
STALL_PROBE_MS = 2000

AUDIO_SUFFIXES = {".mp3", ".mp2", ".m4a", ".mp4", ".aac", ".flac", ".wav", ".aif", ".aiff"}
PLAYLIST_SUFFIXES = {".m3u", ".m3u8", ".pls"}

# Menu items that would wedge or kill the run: anything opening a modal panel
# (the channel cannot be served while one is up), quitting, hiding, or closing
# the window. Matched against both the item identifier and its action selector.
MENU_DENY = re.compile(
    r"quit|terminate|hide|unhide|close|open|save|print|help|about|"
    r"settings|preferences|minimi|zoom|convert",
    re.IGNORECASE,
)


class Failure(Exception):
    def __init__(self, kind, detail, op=None):
        super().__init__(f"{kind}: {detail}")
        self.kind = kind
        self.detail = detail
        self.op = op


# --------------------------------------------------------------------------
# Channel
# --------------------------------------------------------------------------


class Channel:
    """The channel client: one `Vibe --debug-cmd` invocation, or one per batch.

    The per-op cost was ~133ms, in two halves. The client used to sleep a fixed
    50ms BEFORE first checking for its response, so every command paid it in
    full whether or not the app had already answered — fixed in the client
    itself now (DebugClient.m) — leaving ~80ms of fork/exec, dyld and sandbox
    container setup. run_batch removes that half too, by running a whole batch
    in one process through the channel's script mode.

    Both halves matter most under a sanitizer, where the client pays the
    instrumented startup as well: see the client_app note below.
    """

    def __init__(self, app: Path, verbose=False, client_app: Path = None):
        # The client need not be the app under test. The channel is command and
        # response FILES in a shared container plus a Darwin notify wake-up, so
        # any build of the same source can drive any other — which matters
        # enormously under a sanitizer, where an instrumented client pays the
        # instrumented startup too: measured 2.38s per op with a TSan-built
        # client against 0.133s with a plain one, driving the same TSan app.
        #
        # Same source for both or the protocol can skew, which is why it is
        # opt-in rather than automatic.
        self.binary = (client_app or app) / "Contents/MacOS/Vibe"
        # Off by default so anything that needs each op's own timing — the
        # shrinker, a replay — gets it without asking.
        self.batch = False
        self.verbose = verbose
        if not self.binary.exists():
            sys.exit(f"no app at {app} — build first (make build CONFIG=Debug), or pass --app")

    def run(self, argv, timeout=30):
        """Returns (exit_code, parsed_json_or_None, elapsed_ms).

        A client killed by a signal before it produced any output never reached
        main(): launching hundreds of short-lived instances of a *sandboxed*
        binary makes libsecinit's container setup fail outright, which SIGTRAPs
        inside dyld's initializers. That is the harness outrunning the OS, not a
        Vibe defect, so it is retried rather than reported.
        """
        started = time.monotonic()
        code, out = 0, ""
        for attempt in range(CLIENT_LAUNCH_RETRIES):
            try:
                proc = subprocess.run(
                    [str(self.binary), "--debug-cmd", *argv],
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                )
                code, out = proc.returncode, proc.stdout
            except subprocess.TimeoutExpired:
                # Exit 1 here means only that this call ran out of time. Whether
                # the app was stalled or the verb was merely slow is decided by
                # the recovery probe in replay_ops, not here — see VERB_TIMEOUTS
                # for the verbs whose own wait outlasts the default.
                code, out = 1, ""
            if code >= 0 or out.strip():
                break
            time.sleep(0.25 * (attempt + 1))
        elapsed = int((time.monotonic() - started) * 1000)
        try:
            payload = json.loads(out) if out.strip() else None
        except json.JSONDecodeError:
            payload = None
        if self.verbose:
            print(f"    {' '.join(argv)} -> {code} {out.strip()[:120]}", file=sys.stderr)
        return code, payload, elapsed

    def run_batch(self, argv_list, timeout):
        """Run many commands in ONE client process, through script mode.

        Spawning a client per op costs ~80ms of fork/exec, dyld and sandbox
        container setup, and after the response-poll fix that is the whole
        per-op budget. Script mode reads a command list on stdin and prints one
        compact JSON reply per line, so a batch pays the setup once and each
        command costs only the app's own dispatch.

        What batching gives up is the per-op PROCESS exit code, and with it the
        timeout the stall oracle reads. Success and failure survive — every
        reply carries `error` when the verb failed — so only a hang is
        ambiguous, and a hang shows up as a SHORT reply stream. The caller
        re-runs from there one at a time, which is exactly where the stall
        diagnosis was wanted anyway.

        Returns [(exit_code, payload)] as far as the stream got, which may be
        shorter than argv_list, or None if the batch could not be expressed.
        """
        lines = []
        for argv in argv_list:
            # The channel's tokenizer groups quoted tokens but has no escapes,
            # so an argument containing a quote cannot be expressed. Rare enough
            # to hand back to the per-op path rather than mangle.
            if any('"' in a or "'" in a for a in argv):
                return None
            lines.append(" ".join(f'"{a}"' if " " in a else a for a in argv))
        try:
            proc = subprocess.run(
                [str(self.binary), "--debug-cmd", "script", "-"],
                input="\n".join(lines) + "\n",
                capture_output=True, text=True, timeout=timeout,
            )
            out = proc.stdout
        except subprocess.TimeoutExpired as expired:
            # Partial output still says how far it got, which is what the caller
            # needs in order to resume one at a time from the right op.
            raw = expired.stdout
            out = raw.decode() if isinstance(raw, bytes) else (raw or "")
        results = []
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                break
            results.append((2 if payload.get("error") is not None else 0, payload))
        return results


def app_pid():
    """The GUI instance's pid, or None.

    The CLI client is the app binary, so `pgrep -x Vibe` also matches every
    in-flight `--debug-cmd` invocation. Sampling one of those yields a stack of
    the client polling for its own response, which looks like a hang and says
    nothing about the app — filter them out by argv.
    """
    found = subprocess.run(["pgrep", "-x", "Vibe"], capture_output=True, text=True)
    for pid in found.stdout.split():
        listing = subprocess.run(["ps", "-o", "command=", "-p", pid],
                                 capture_output=True, text=True)
        if "--debug-cmd" not in listing.stdout:
            return int(pid)
    return None


def app_is_running():
    return app_pid() is not None


# Settings that gate whole subsystems out of the run when off, and that persist
# in NSUserDefaults across runs — so a run inherits whatever the LAST one left,
# including a fuzzer's own random final toggle. With `useFolderArt` off the
# artwork accessors return before reaching the resolver, and the run reports a
# clean pass over code it never entered. Forced on at launch, and printed,
# because a silently disabled feature and a genuinely clean run look identical
# in the summary.
FEATURE_SETTINGS = {"folderArt": ("set_folder_art", "on")}


def describe_feature_settings(channel) -> str:
    parts = []
    for key, (verb, wanted) in FEATURE_SETTINGS.items():
        code, payload, _ = channel.run([verb, wanted])
        ok = code == 0 and isinstance(payload, dict) and payload.get("ok")
        parts.append(f"{key}={wanted}" if ok else f"{key}=UNKNOWN (could not set)")
    return ", ".join(parts)


def launch(corpus: Path, app: Path):
    """Relaunch and wait until the app answers.

    Passing the corpus directory to `open -a` is what grants sandbox access to
    it: FolderAccessManager bookmarks folders arriving through the open funnel,
    and the grant then persists, so later `--debug-cmd open` calls on files
    inside it are readable. A direct-exec launch cannot do this.
    """
    env = dict(os.environ, VIBE_APP=str(app))
    result = subprocess.run(
        [str(LAUNCH_SH), str(corpus)], capture_output=True, text=True, env=env
    )
    if result.returncode != 0:
        sys.exit(f"launch failed: {result.stderr.strip()}")
    if "warning:" in result.stderr:
        print(f"  {result.stderr.strip()}", file=sys.stderr)


# --------------------------------------------------------------------------
# Corpus
# --------------------------------------------------------------------------


def scan_corpus(root: Path):
    files, playlists, dirs = [], [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        here = Path(dirpath)
        if here != root:
            dirs.append(here)
        for name in filenames:
            suffix = Path(name).suffix.lower()
            if suffix in AUDIO_SUFFIXES:
                files.append(here / name)
            elif suffix in PLAYLIST_SUFFIXES:
                playlists.append(here / name)
    return files, playlists, dirs


# --------------------------------------------------------------------------
# Op generation
# --------------------------------------------------------------------------

# An op is (name, argv, tolerated_error_substrings). A tolerated error is one
# the app is right to return for a randomly chosen argument — an empty undo
# stack, say — and is not a finding.

FX_ON_OFF = [
    "low_kill_boost", "reverb_send", "delay_send", "short_delay_send",
]
TRANSPORT_KEYS = ["space", "p", "left", "right", "up", "down"]
HELD_FX_KEYS = ["w", "e", "r", "t"]


class OpGenerator:
    def __init__(self, rng, corpus_files, corpus_playlists, corpus_dirs, menu_ids,
                 profile, exclusions=()):
        self.rng = rng
        self.files = corpus_files
        self.playlists = corpus_playlists
        self.dirs = corpus_dirs
        self.menu_ids = menu_ids
        self.exclusions = list(exclusions)
        self.window = (900.0, 400.0)
        self.weights = dict(PROFILES["base"])
        self.weights.update(PROFILES.get(profile, {}))
        self.kinds = [k for k, w in self.weights.items() if w > 0]
        self.kind_weights = [self.weights[k] for k in self.kinds]

    def note_window(self, frame_string):
        # NSStringFromRect: "{{x, y}, {w, h}}"
        nums = [float(n) for n in re.findall(r"-?\d+\.?\d*", frame_string or "")]
        if len(nums) == 4 and nums[2] > 0 and nums[3] > 0:
            self.window = (nums[2], nums[3])

    def next_ops(self):
        """One logical step, which may expand to several channel commands."""
        kind = self.rng.choices(self.kinds, self.kind_weights)[0]
        return getattr(self, f"op_{kind}")()

    # -- file loading -------------------------------------------------------

    def op_open_file(self):
        if not self.files:
            return self.op_transport()
        return [("open_file", ["open", str(self.rng.choice(self.files))], [])]

    def op_open_dir(self):
        if not self.dirs:
            return self.op_open_file()
        return [("open_dir", ["open", str(self.rng.choice(self.dirs))], [])]

    def op_open_playlist(self):
        if not self.playlists:
            return self.op_open_file()
        # A .m3u grants only itself, so its entries may be unreadable; that is
        # the app's business, not a driver failure.
        return [("open_playlist", ["open", str(self.rng.choice(self.playlists))], [])]

    def op_open_burst(self):
        """Opens landing on top of each other, with no settle between them.

        This is the documented hazard: waveform, BPM, key and metadata
        deliveries from the previous open arrive after the track has already
        changed, and every receiver has to match the delivered URL against the
        current one before applying it.
        """
        if not self.files:
            return self.op_transport()
        n = self.rng.randint(2, 4)
        return [
            ("open_burst", ["open", str(self.rng.choice(self.files))], [])
            for _ in range(n)
        ]

    def op_cache_churn(self):
        if not self.files:
            return self.op_transport()
        path = str(self.rng.choice(self.files))
        return [
            ("file_clear_cache", ["file_clear_cache", path], []),
            ("file_cache", ["file_cache", path], ["could not", "failed"]),
        ]

    def op_clear_caches(self):
        return [("clear_caches", ["clear_caches"], [])]

    def op_cloud_churn(self):
        """Re-arms the fake provider mid-run, and sometimes tears it out.

        The uninstall/reinstall edges are the point as much as the numbers: they
        swap the dataless probe and the transfer block out from under workers
        that are mid-flight, which is the one thing about the seam that could
        deadlock rather than merely misreport.

        Never 100% cloudy — the mixture is what proves the cloud machinery has
        not slowed the local path down.

        The CAPACITY is what makes this profile score the foreground hold at
        all. Unlimited capacity — the provider's default, and all this op used
        to arm — means a background download never actually delays a foreground
        one, so "the user's open outranks the sweep" has nothing to be true
        about: every transfer starts the moment it is asked for. One or two
        slots is the shape a real provider has, and the shape the hold, the
        stand-aside and the lane's ordering were all written for.
        """
        seconds = f"{self.rng.uniform(0.6, 1.6):.2f}"
        percent = self.rng.choice([30, 50, 80])
        # Weighted towards a scarce provider; 0 keeps the unbounded shape in the
        # mix so the two are compared rather than one simply replaced.
        capacity = self.rng.choice([1, 1, 2, 2, 0])
        argv = ["set_fake_cloud", seconds, str(percent), f"capacity={capacity}"]
        if self.rng.random() < 0.15:
            return [("cloud_off", ["set_fake_cloud", "0"], []),
                    ("cloud_on", argv, [])]
        return [("cloud_on", argv, [])]

    # -- transport ----------------------------------------------------------

    def op_transport(self):
        verb = self.rng.choice([
            "play_pause", "next", "previous",
            "skip_forward", "skip_forward_more", "skip_forward_most",
            "skip_back", "skip_back_more", "skip_back_most",
        ])
        return [("transport", [verb], [])]

    def op_playlist_jump(self):
        """Land on an arbitrary row, the way a listener picks a track.

        next/previous only ever walk to the adjacent track, which is the one
        case every prefetch and every neighborhood rank has already prepared
        for. A jump lands where the background sweep has not been, with
        neighbors nothing has fetched.

        The index is drawn against a generous ceiling rather than the live
        playlist length: out of range is a documented no-op, and asking for it
        costs one round trip while sparing the driver a dump_state per jump.
        """
        return [("playlist_jump", ["play_index", str(self.rng.randrange(0, 400))], [])]

    def op_burst(self):
        """Hundreds of track changes in-process, at main-queue rate.

        The channel cannot reach the rate a race needs: ~80ms per op against a
        plain build and ~2.4 SECONDS against a ThreadSanitizer one. `burst`
        moves the loop inside the app, where a jump lands every main-queue turn.

        Issued right after an open on purpose — that is when the sweep's four
        stage-1 workers are live, so the burst contends with real background
        work rather than a settled app.
        """
        folder = str(self.rng.choice(self.dirs)) if self.dirs else None
        jumps = self.rng.choice([120, 300, 600])
        ops = []
        if folder:
            ops.append(("open_dir", ["open", folder], []))
        ops.append(("burst", ["burst", str(jumps), str(self.rng.randrange(1, 1 << 30))], []))
        return ops

    def op_seek(self):
        # Deliberately unreasonable values as well as reasonable ones: the
        # player clamps, and a value that escapes the clamp is the finding.
        value = self.rng.choice([
            self.rng.uniform(0, 600),
            self.rng.uniform(-600, 0),
            0.0,
            self.rng.uniform(1e6, 1e9),
            -1.0,
        ])
        return [("seek", ["seek", f"{value:.3f}"], [])]

    def op_pitch(self):
        value = self.rng.choice([
            self.rng.uniform(-8, 8),
            self.rng.uniform(-100, 100),
            0.0,
        ])
        return [("set_pitch", ["set_pitch", f"{value:.3f}"], [])]

    # -- FX -----------------------------------------------------------------

    def op_fx(self):
        if self.rng.random() < 0.3:
            return [("fx", ["toggle_low_kill"], [])]
        name = self.rng.choice(FX_ON_OFF)
        state = self.rng.choice(["on", "off"])
        return [("fx", [f"{name}_{state}"], [])]

    def op_held_fx(self):
        """key_down without the matching key_up, sometimes across a track change.

        A momentary effect latched by a lost key_up is a real bug class and
        nothing else in the harness would produce one.
        """
        key = self.rng.choice(HELD_FX_KEYS)
        ops = [("key_down", ["key_down", key], [])]
        if self.rng.random() < 0.5:
            ops.append(("transport", ["next"], []))
        if self.rng.random() < 0.7:
            ops.append(("key_up", ["key_up", key], []))
        return ops

    def op_key(self):
        return [("key", ["key", self.rng.choice(TRANSPORT_KEYS)], [])]

    # -- window and UI ------------------------------------------------------

    def op_window(self):
        verb = self.rng.choice(["toggle_size", "toggle_pitch_panel"])
        return [("window", [verb], [])]

    def op_resize(self):
        width = self.rng.choice([
            self.rng.randint(300, 2400),
            self.rng.randint(1, 300),
            self.rng.randint(2400, 6000),
        ])
        return [("resize", ["set_window_width", str(width)], [])]

    def point(self):
        """A random window point outside the chrome buttons; see chrome_exclusion_rects."""
        w, h = self.window
        for _ in range(24):
            x = round(self.rng.uniform(0, w), 1)
            y = round(self.rng.uniform(0, h), 1)
            if not any(x0 <= x <= x1 and y0 <= y <= y1 for x0, y0, x1, y1 in self.exclusions):
                return x, y
        return round(w / 2, 1), round(h / 2, 1)

    def op_click(self):
        x, y = self.point()
        return [("click", ["click", str(x), str(y)], [])]

    def op_drag(self):
        pts = [*self.point(), *self.point()]
        return [("drag", ["drag", *[str(p) for p in pts]], [])]

    def op_drag_drop(self):
        if not self.files:
            return self.op_click()
        x, y = self.point()
        ops = [("drag_hover", ["drag_hover", str(x), str(y)], [])]
        if self.rng.random() < 0.6:
            ops.append(("drag_drop",
                        ["drag_drop", str(x), str(y), str(self.rng.choice(self.files))], []))
        else:
            ops.append(("drag_end", ["drag_end"], []))
        return ops

    def op_menu(self):
        if not self.menu_ids:
            return self.op_window()
        return [("menu", ["click_menu", self.rng.choice(self.menu_ids)], ["disabled", "no menu item"])]

    def op_undo(self):
        verb = self.rng.choice(["undo", "redo"])
        return [(verb, [verb], ["nothing to undo", "nothing to redo", "still in progress"])]

    def op_folder_art(self):
        """Flip the folder-artwork setting under whatever is in flight.

        The setting drops the resolver's decoded covers while the playlist is
        drawing cells off the same tables, and nothing else in the harness
        reaches that path. A rapid off/on pair is the shape that lands the
        invalidate between a resolve claiming a directory and its result
        arriving.
        """
        # Always back on: the setting persists in NSUserDefaults for the whole
        # run, so a uniform on/off choice parks the feature OFF for half the
        # ops, and with it off the accessors never reach the resolver. Off and
        # straight back on buys both invalidation edges, leaves the feature on
        # throughout, and leaves the user's setting where it started.
        ops = [("folder_art", ["set_folder_art", "off"], []),
               ("folder_art", ["set_folder_art", "on"], [])]
        if self.rng.random() < 0.25:
            # A settle between the edges, so an invalidate sometimes lands with
            # resolves and decodes genuinely in flight rather than only between
            # two channel round-trips.
            ops.insert(1, ("settle", ["sleep", f"{self.rng.uniform(0.05, 0.4):.2f}"], []))
        return ops

    def op_settle(self):
        return [("settle", ["sleep", f"{self.rng.uniform(0.05, 0.8):.2f}"], [])]


PROFILES = {
    "base": {
        "open_file": 14, "open_dir": 3, "open_playlist": 2, "open_burst": 6,
        "cache_churn": 2, "clear_caches": 1,
        "transport": 14, "seek": 8, "pitch": 5,
        "fx": 5, "held_fx": 4, "key": 4,
        "window": 3, "resize": 3, "click": 4, "drag": 2, "drag_drop": 3,
        "menu": 3, "undo": 1, "settle": 6, "folder_art": 1,
        "playlist_jump": 4, "burst": 0,
    },
    # Everything pointed at the open path and the async deliveries that race it.
    "loading": {
        "open_file": 30, "open_dir": 6, "open_burst": 20, "open_playlist": 4,
        "cache_churn": 6, "clear_caches": 2,
        "transport": 10, "seek": 4, "pitch": 1,
        "fx": 1, "held_fx": 1, "key": 1,
        "window": 1, "resize": 1, "click": 1, "drag": 0, "drag_drop": 2,
        "menu": 1, "undo": 0, "settle": 8, "folder_art": 2,
    },
    # The folder-artwork fallback: opens through all three resolve strategies
    # (a folder, a burst of files, a lone file), the playlist visible far more
    # often than elsewhere so cell draws pull thumbnails off the resolver
    # concurrently with the header's display-size load, and the setting flipped
    # underneath both. Pair it with a corpus built for it.
    "artwork": {
        "open_file": 20, "open_dir": 14, "open_burst": 16, "open_playlist": 6,
        "cache_churn": 3, "clear_caches": 3,
        "transport": 12, "seek": 2, "pitch": 0,
        "fx": 0, "held_fx": 0, "key": 2,
        "window": 10, "resize": 4, "click": 3, "drag": 0, "drag_drop": 4,
        "menu": 1, "undo": 0, "settle": 6, "folder_art": 10,
    },
    # The cloud path: files that are placeholders and take real time to arrive,
    # so the scan's serial cloud lane, the foreground-download hold, the
    # neighborhood re-ranking and the abandoned play and prefetch opens are all
    # live at once. Needs the fake provider armed, which --profile cloud does at
    # launch, and a corpus of BIG folders with real tags and embedded art —
    # make-cloud-corpus.py builds one.
    #
    # The weights are the opposite of `loading`'s, and the first version of this
    # profile got it exactly wrong by copying them. Opens are what this profile
    # must be SPARING with: the sweep is deferred until playback starts or two
    # seconds pass, and a replacement playlist drops the loader outright, so a
    # stream of opens 80ms apart means the sweep never runs and the lane this
    # profile exists to test is never even populated. Measured on the first
    # attempt: 11 downloads cancelled, 1 completed, cloudParsesPending never
    # above zero.
    #
    # So: heavy settle, so a sweep gets seconds to work through a folder; heavy
    # jumping, because landing on an arbitrary row is what moves the ranking and
    # raises the hold where nothing has prefetched; and clear_caches often,
    # because a cache hit means no parse and therefore no download to race.
    "cloud": {
        "open_file": 3, "open_dir": 8, "open_burst": 3, "open_playlist": 1,
        "cache_churn": 3, "clear_caches": 5, "cloud_churn": 4,
        "transport": 18, "seek": 6, "pitch": 0,
        "playlist_jump": 18, "burst": 12,
        "fx": 0, "held_fx": 0, "key": 1,
        "window": 1, "resize": 1, "click": 2, "drag": 0, "drag_drop": 1,
        "menu": 1, "undo": 0, "settle": 30, "folder_art": 1,
    },
    # No file loading at all: pure UI monkey against whatever is loaded.
    "ui": {
        "open_file": 0, "open_dir": 0, "open_playlist": 0, "open_burst": 0,
        "cache_churn": 0, "clear_caches": 0,
        "transport": 10, "seek": 8, "pitch": 10,
        "fx": 10, "held_fx": 8, "key": 8,
        "window": 8, "resize": 8, "click": 12, "drag": 6, "drag_drop": 0,
        "menu": 6, "undo": 1, "settle": 4,
    },
}


# --------------------------------------------------------------------------
# Oracles
# --------------------------------------------------------------------------


def check_liveness(channel, since=None):
    code, payload, _ = channel.run(["dump_state"], timeout=20)
    if code == 0 and payload:
        return payload
    if app_is_running():
        raise Failure("hang", "the app is running but stopped answering the channel "
                              "(the channel is served on the main thread)")
    # Gone with no crash report is not a crash: the app terminated cleanly, so
    # something in the op stream asked it to. Saying "crash" there sends you
    # hunting for a stack that was never written.
    if since is not None and not fresh_crash_reports(since):
        raise Failure("exit", "the app terminated cleanly — no crash report was written, "
                              "so an op quit it rather than crashing it")
    raise Failure("crash", "the app is gone")


def check_consistency(channel, settle=0.35):
    """A violation counts only if it survives a settle and a second sample.

    Several checks compare a rendered label against the state that should have
    produced it, and renderState runs from the updateUI funnel — so a state
    that flipped this runloop turn may legitimately not be drawn yet.
    """
    code, first, _ = channel.run(["check_consistency"], timeout=20)
    if code != 0 or first is None:
        check_liveness(channel)   # raises hang/crash; otherwise a transient miss
        return None
    if first.get("ok"):
        return None
    time.sleep(settle)
    code, second, _ = channel.run(["check_consistency"], timeout=20)
    if code != 0 or second is None or second.get("ok"):
        return None
    first_ids = {v["id"] for v in first.get("violations", [])}
    surviving = [v for v in second.get("violations", []) if v["id"] in first_ids]
    return surviving or None


PENDING_KEYS = ("metadataHolders", "metadataWaiters", "openResultsBuffered",
                "openBurstQueued", "retiredFades")

# dump_health's pending section also carries cloudParsesPending and
# cloudLaneHeld, and they are deliberately NOT scored here. Neither is a growth
# metric: a sweep of a cloud folder legitimately holds dozens of pending parses,
# and the lane is legitimately held for the whole of every foreground open, so
# a headroom over a min-of-first-three baseline would either never fire or fire
# constantly. Both are already covered where they mean something —
#   at rest: quiesce refuses to settle until both reach zero, and a
#            `settled: false` reply is a `pending` failure naming the counter;
#   mid-run: check_consistency's cloud.* checks, which test the CONDITIONS
#            (held with nothing playing, a background download inside a
#            foreground one) rather than the magnitudes.

# In-flight limits: sampled mid-run, so they have to tolerate a decode's worth
# of churn. Loose by necessity — see the resting limits below for the sensitive
# version of the same measurement.
GROWTH_LIMITS = {
    # path in dump_health -> (absolute headroom, human name)
    ("process", "footprintBytes"): (400 * 1024 * 1024, "memory footprint"),
    # Tightened from 200 once the metric started measuring descriptors rather
    # than the descriptor TABLE, which only ever grew (see
    # VibeOpenFileDescriptorCount). True counts sit in single digits at rest and
    # a few dozen mid-burst, so this is now a real detector rather than a number
    # that could not fire — and an fd leak IS a documented hazard here: a failed
    # AVAudioFile open against an empty file strands its descriptor, and 300 of
    # those meet a 256 soft limit.
    ("process", "fileDescriptors"): (64, "open file descriptors"),
    ("process", "threads"): (48, "threads"),
    ("process", "machPorts"): (2000, "mach ports"),
    ("ui", "windows"): (3, "windows"),
    ("ui", "views"): (400, "views"),
    ("ui", "layers"): (800, "layers"),
    ("app", "engineNodes"): (16, "engine nodes"),
    **{("pending", key): (8, f"pending {key}") for key in PENDING_KEYS},
}

# Resting limits, applied only to samples taken right after a `quiesce`. The
# app is back at a fixed idle state there — no track, empty playlist, nothing
# in flight — so the COUNTABLE metrics can be held tight enough to catch a slow
# leak the in-flight limits would never see.
#
# Every headroom below is set from measured ranges over loading-profile runs,
# not guessed:
#
#   views 47, windows 1, engine nodes 23, every pending counter 0 — dead
#   stable across runs, so these are the sensitive ones. Layers are NOT; see
#   the limit below.
#   threads 14-26 and fds 45-70 breathe with the loader pool and whether a
#   folder is open.
#   footprint 47-335 MB, and NOT accumulating: the same seed rests at 298 MB in
#   one run and 51 MB in another, and a run that sat at 313 MB dropped to 88 MB
#   two samples later. Concurrent decode and analyzer buffers dominate it and
#   their lifetimes are timing-dependent, so it is a gross-leak backstop here
#   rather than a sensitive signal. The counters above are where sensitivity
#   actually comes from.
#
#   mallocLiveBytes is the sensitive version of that footprint: bytes actually
#   allocated across every malloc zone, measured at ~19 MB where the footprint
#   read 203 MB. The gap is the allocator holding freed pages — quiesce calls
#   malloc_zone_pressure_relief, but it does NOT reliably give them back, which
#   is why the footprint above cannot be tightened and why this metric exists.
#   Read quiesce's `pressureRelief.releasedBytes` before believing any resting
#   footprint number.
RESTING_GROWTH_LIMITS = {
    ("process", "mallocLiveBytes"): (64 * 1024 * 1024, "resting live heap"),
    ("process", "footprintBytes"): (256 * 1024 * 1024, "resting memory footprint"),
    ("process", "fileDescriptors"): (8, "resting file descriptors"),
    ("process", "threads"): (24, "resting threads"),
    ("process", "machPorts"): (300, "resting mach ports"),
    ("ui", "windows"): (1, "resting windows"),
    ("ui", "views"): (40, "resting views"),
    # Views are the sensitive half of this pair; layers deliberately are not.
    # The resting layer count is bistable — ~101 and ~350-356 — and moves in
    # BOTH directions within a single run. Nothing app-level selects it: with
    # views pinned at 47 it is unmoved by row count (0 to 2208), window width
    # (400 to 3000pt), or quiesce; the pitch panel and playlist toggle are worth
    # 4 and 1 layers. It is AppKit's own glass and hosting-view machinery, so a
    # tight limit against a min-of-first-three baseline fires whenever a run
    # starts at the low plateau. Sized to clear that step; a real layer leak is
    # unbounded and clears it too.
    ("ui", "layers"): (320, "resting layers"),
    ("app", "engineNodes"): (4, "resting engine nodes"),
    **{("pending", key): (1, f"resting pending {key}") for key in PENDING_KEYS},
}


# Health samples to collect before the baseline is fixed. The first sample is
# a bad baseline on its own: the opening decode and its analyzers peak the
# footprint well above the resting level, and a peak baseline is a permissive
# one that hides the leak it was meant to catch.
BASELINE_SAMPLES = 3


def min_baseline(samples, limits=GROWTH_LIMITS):
    """Element-wise minimum across samples: the strictest honest baseline."""
    baseline = {}
    for section, key in limits:
        values = [s.get(section, {}).get(key) for s in samples]
        values = [v for v in values if v is not None]
        if values:
            baseline.setdefault(section, {})[key] = min(values)
    return baseline


# A single sample over the limit means nothing. Measured over a loading-profile
# run, the engine node count swings between 25 and 67 with no trend as retired
# crossfade pairs pile up and drain, and the footprint spikes past 350MB during
# a decode before falling back to ~120MB. Only a metric that stays over the
# limit for this many CONSECUTIVE samples is growth rather than churn.
GROWTH_CONFIRMATIONS = 3

# Resting samples are far rarer — one per --quiesce-every batches — so waiting
# for three of them would need most of a long run. Two is enough there, because
# the measurement itself is taken at a fixed idle state rather than mid-churn.
RESTING_CONFIRMATIONS = 2


def health_growth(baseline, current, streaks, limits=GROWTH_LIMITS,
                  confirmations=GROWTH_CONFIRMATIONS):
    """Returns the messages for metrics that have now been over-limit long enough.

    streaks is a caller-owned dict of consecutive over-limit counts per metric;
    a sample back under the limit resets that metric to zero. Pass the resting
    limits and a caller-owned streaks dict of their own to score the quiesced
    series separately.
    """
    findings = []
    # The footprint is a BACKSTOP, and on its own it is not evidence. It tracks
    # the allocator's and the VM's high-water mark rather than anything the app
    # retains, so it wanders in BOTH directions by hundreds of megabytes — one
    # measured resting series read 553, 494, 749, 606, 838 MB while the live
    # heap sat at 2.2 MB, byte-identical, with every pending counter at zero. A
    # sanitizer build inflates it further still, its shadow memory alone
    # clearing the limit on any long run.
    #
    # So it only counts when the live heap agrees. That keeps the gross-leak
    # backstop — a real one grows both — without the false failure the skill
    # otherwise tells every reader to expect and dismiss by hand.
    live_limit = limits.get(("process", "mallocLiveBytes"))
    live_was = baseline.get("process", {}).get("mallocLiveBytes")
    live_now = current.get("process", {}).get("mallocLiveBytes")
    live_grew = (live_limit is not None and live_was is not None and live_now is not None
                 and live_now - live_was > live_limit[0])

    for metric, (headroom, label) in limits.items():
        section, key = metric
        was = baseline.get(section, {}).get(key)
        now = current.get(section, {}).get(key)
        if was is None or now is None:
            continue
        if key == "footprintBytes" and not live_grew:
            streaks[metric] = 0
            continue
        if now - was > headroom:
            streaks[metric] = streaks.get(metric, 0) + 1
            if streaks[metric] >= confirmations:
                findings.append(f"{label} grew {was} -> {now} (limit +{headroom}) "
                                f"and stayed over for {streaks[metric]} samples")
        else:
            streaks[metric] = 0
    return findings


def quiesced_checkpoint(channel, samples, streaks, baseline, executed, verbose):
    """Quiesce, sample at rest, score against the tight limits.

    Returns (failure_or_None, baseline). A `settled: false` reply is itself a
    finding: work that will not unwind inside the app's own deadline is stuck,
    and the reply names the counter that held out.
    """
    code, reply, _ = channel.run(["quiesce"], timeout=40)
    if code != 0 or reply is None:
        check_liveness(channel)
        return None, baseline
    if not reply.get("settled"):
        stuck = {k: v for k, v in (reply.get("pending") or {}).items() if v}
        return Failure("pending", f"quiesce did not settle in "
                                  f"{reply.get('waitedSeconds', 0):.1f}s: {stuck}"), baseline

    code, health, _ = channel.run(["dump_health"], timeout=20)
    if code != 0 or not health:
        return None, baseline
    health["_ops"] = executed
    health["_resting"] = True
    samples.append(health)
    # A pressure relief that released nothing means the footprint just sampled
    # still carries the allocator's high-water mark, so the live heap beside it
    # is the number to read. Said once: it is a property of the run, not of the
    # sample.
    relief = reply.get("pressureRelief") or {}
    if relief.get("releasedBytes") == 0 and not streaks.get("_reliefWarned"):
        streaks["_reliefWarned"] = True
        print("  note: malloc_zone_pressure_relief released nothing — resting "
              "footprint carries the allocator high-water mark; read live heap")
    if verbose:
        pending = health.get("pending", {})
        print(f"  rest {executed:6d} ops   "
              f"{health['process'].get('footprintBytes', 0) // (1024 * 1024):5d} MB   "
              f"{health['process'].get('mallocLiveBytes', 0) // (1024 * 1024):4d} MB live   "
              f"{health['app'].get('engineNodes', '?')} nodes   pending {pending}")
    if baseline is None:
        if len(samples) >= RESTING_CONFIRMATIONS:
            return None, min_baseline(samples, RESTING_GROWTH_LIMITS)
        return None, None
    grew = health_growth(baseline, health, streaks, RESTING_GROWTH_LIMITS,
                         RESTING_CONFIRMATIONS)
    if grew:
        return Failure("resource", "at rest: " + "; ".join(grew)), baseline
    return None, baseline


def fresh_crash_reports(since):
    if not CRASH_DIR.is_dir():
        return []
    out = []
    for entry in CRASH_DIR.glob("Vibe*"):
        try:
            if entry.stat().st_mtime >= since:
                out.append(entry)
        except OSError:
            pass
    return out


# --------------------------------------------------------------------------
# Diagnostics
# --------------------------------------------------------------------------


def capture_diagnostics(channel, out_dir: Path, failure: Failure, since):
    # Cleared, not merged: the directory is named after the seed, so a re-run
    # of the same seed would otherwise leave last run's sample and screenshot
    # sitting beside this run's failure.txt, describing a different failure.
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    notes = [f"kind: {failure.kind}", f"detail: {failure.detail}"]
    if failure.op:
        notes.append(f"last op: {' '.join(failure.op)}")

    pid = app_pid()
    if failure.kind == "hang" and pid and shutil.which("sample"):
        target = out_dir / "sample.txt"
        # By pid, never by name: see app_pid.
        subprocess.run(["sample", str(pid), "5", "-file", str(target)],
                       capture_output=True, text=True)
        notes.append(f"main-thread sample (pid {pid}): {target}")

    for report in fresh_crash_reports(since):
        shutil.copy2(report, out_dir / report.name)
        notes.append(f"crash report: {report.name}")

    if app_is_running():
        # The cloud trace is the ONLY record of which transfer ran when and for
        # which role, and the cloud.* consistency checks report a count without
        # naming the files. A run that fires one of them and does not keep the
        # trace cannot be diagnosed at all afterwards: the app is gone and the
        # trace with it. Learned by losing exactly that on a 6,758-op run.
        for verb, name in (("dump_state", "state.json"),
                           ("dump_view_tree", "view-tree.json"),
                           ("dump_cloud_trace", "cloud-trace.json"),
                           ("dump_health", "health.json")):
            code, payload, _ = channel.run([verb], timeout=20)
            if code == 0 and payload:
                (out_dir / name).write_text(json.dumps(payload, indent=2))
        shot = out_dir / "screenshot.png"
        with open(shot, "wb") as fh:
            subprocess.run([str(channel.binary), "--debug-cmd", "dump_screenshot", "-"],
                           stdout=fh, stderr=subprocess.DEVNULL, timeout=30)

    (out_dir / "failure.txt").write_text("\n".join(notes) + "\n")
    return notes


# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------


def chrome_exclusion_rects(channel):
    """Top-left window-point rects the random clicker must never hit.

    The window draws its own close and minimize buttons as SymbolButtons in its
    top-left corner, and `closeApp:` is `[self close]` — which ends the run. A
    uniform random click finds them within a few hundred ops and the driver
    then reports a crash with no crash report to show for it, because the app
    exited perfectly cleanly.

    The buttons are direct subviews of the window-spanning content view, so
    their frames are already window coordinates; they only need the AppKit
    bottom-left origin flipped. The fallback rect covers the same corner in
    case the view tree is unreadable.
    """
    rects = [(0.0, 0.0, 72.0, 44.0)]
    code, tree, _ = channel.run(["dump_view_tree"], timeout=20)
    if code != 0 or not tree:
        return rects

    def parse(frame):
        nums = [float(n) for n in re.findall(r"-?\d+\.?\d*", frame or "")]
        return nums if len(nums) == 4 else None

    def walk(node, height):
        if node.get("class") == "SymbolButton":
            box = parse(node.get("frame"))
            if box:
                x, y, w, h = box
                top = height - y - h
                if top < 80 and x < 160:
                    rects.append((x - 6, top - 6, x + w + 6, top + h + 6))
        for child in node.get("subviews", []):
            walk(child, height)

    for window in tree.get("windows", []):
        box = parse(window.get("frame"))
        if box and window.get("contentView"):
            walk(window["contentView"], box[3])
    return rects


def collect_menu_ids(channel):
    code, payload, _ = channel.run(["dump_menu"], timeout=20)
    if code != 0 or not payload:
        return []
    ids = []

    def walk(items):
        for item in items:
            identifier = item.get("id")
            action = item.get("action") or ""
            if identifier and not MENU_DENY.search(identifier) and not MENU_DENY.search(action):
                ids.append(identifier)
            if item.get("items"):
                walk(item["items"])

    walk(payload.get("menu", []))
    return ids


def replay_ops(channel, ops, journal=None, check_every=0, stop_on_failure=True, stalls=None):
    """Run a list of (name, argv, tolerated) and return the failure, or None.

    stalls, when given, is {"dir", "count", "samples", "max"}: recoverable
    main-thread stalls are sampled and counted there rather than failing the
    run outright.
    """
    # One client process for the whole batch. Anything the batch could not
    # deliver — a hang, an unquotable argument — falls through to the per-op
    # loop, which resumes exactly where the reply stream stopped, so the op that
    # wedged still gets its own timeout and its own stall diagnosis.
    batched = {}
    if getattr(channel, "batch", False) and len(ops) > 1:
        budget = sum(VERB_TIMEOUTS.get(argv[0], 30) for _, argv, _ in ops)
        results = channel.run_batch([argv for _, argv, _ in ops], timeout=min(budget, 300))
        if results:
            batched = dict(enumerate(results))

    for i, (name, argv, tolerated) in enumerate(ops):
        if i in batched:
            code, payload = batched[i]
            elapsed = 0   # a batched op has no round trip of its own to time
        else:
            code, payload, elapsed = channel.run(argv, timeout=VERB_TIMEOUTS.get(argv[0], 30))
        entry = {"i": i, "op": name, "argv": argv, "exit": code, "ms": elapsed}
        if tolerated:
            # Journaled so replay and shrink apply the SAME rules. Without it,
            # `undo` on an empty stack is a pass when generated and a failure
            # when replayed — and the shrinker then happily minimizes any
            # journal down to that one benign op instead of the real bug.
            entry["tolerated"] = tolerated
        if code == 1:
            pid = app_pid()
            if pid is None:
                entry["failure"] = "no response, app gone"
                if journal:
                    journal.write(json.dumps(entry) + "\n")
                    journal.flush()
                return Failure("crash", f"the app died on `{' '.join(argv)}`", argv)
            # Still alive but silent: the channel is served on the main queue,
            # so it is stalled right now. Sample before probing, because a
            # probe that succeeds means the stall has already ended and the
            # stack is gone with it.
            sample_path = None
            if stalls is not None and shutil.which("sample"):
                stalls["samples"] += 1
                sample_path = stalls["dir"] / f"stall-{stalls['samples']:02d}.txt"
                sample_path.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(["sample", str(pid), "3", "-file", str(sample_path)],
                               capture_output=True, text=True)
            probe_started = time.monotonic()
            recovered = channel.run(["dump_state"], timeout=60)[0] == 0
            probe_ms = int((time.monotonic() - probe_started) * 1000)
            # A timeout whose follow-up probe answers at the usual latency was
            # never a main-thread stall: the verb outran its own budget while
            # the channel stayed live, which is what a big file does to
            # file_cache. The sample proves which one it was — an idle main
            # thread parked in mach_msg is a slow verb, not a wedge — so only a
            # probe that was itself slow counts against the stall budget.
            stalled = probe_ms > STALL_PROBE_MS
            entry["probeMs"] = probe_ms
            entry["failure"] = ("stall" if stalled else "slow") if recovered else "no response"
            if sample_path:
                entry["sample"] = str(sample_path)
            if journal:
                journal.write(json.dumps(entry) + "\n")
                journal.flush()
            if not recovered:
                return Failure("hang", f"no response to `{' '.join(argv)}`", argv)
            if stalls is not None and stalled:
                stalls["count"] += 1
            # A stall it came back from is a finding, not a wedge. One is
            # noise on a loaded machine; a run full of them is the bug.
            if stalls is not None and stalls["count"] > stalls["max"]:
                return Failure("hang",
                               f"{stalls['count']} main-thread stalls over 5s "
                               f"(samples in {stalls['dir']})", argv)
            continue
        if code == 2:
            message = str(payload.get("error", "")) if payload else "(unparseable reply)"
            if not any(t in message for t in tolerated):
                entry["failure"] = message
                if stop_on_failure:
                    if journal:
                        journal.write(json.dumps(entry) + "\n")
                        journal.flush()
                    return Failure("command", f"`{' '.join(argv)}` -> {message}", argv)
        elif code != 0:
            # Anything else is the client dying on a signal after its retries,
            # or a usage error (64) from a malformed op — never a pass.
            entry["failure"] = f"client exit {code}"
            if journal:
                journal.write(json.dumps(entry) + "\n")
                journal.flush()
            return Failure("client", f"`{' '.join(argv)}` -> client exit {code}", argv)
        if journal:
            journal.write(json.dumps(entry) + "\n")
            journal.flush()
        if check_every and (i + 1) % check_every == 0:
            violations = check_consistency(channel)
            if violations:
                ids = ", ".join(v["id"] for v in violations)
                return Failure("consistency", ids, argv)
    return None


def run(args):
    app = Path(args.app).expanduser().resolve() if args.app else DEFAULT_APP
    corpus = Path(args.corpus).expanduser().resolve()
    if not corpus.is_dir():
        sys.exit(f"corpus is not a directory: {corpus}")

    seed = args.seed if args.seed is not None else random.randrange(1, 2**31)
    rng = random.Random(seed)
    channel = Channel(app, verbose=args.verbose,
                      client_app=Path(args.client_app) if args.client_app else None)
    channel.batch = not args.no_batch

    files, playlists, dirs = scan_corpus(corpus)
    print(f"corpus: {len(files)} audio files, {len(playlists)} playlists, "
          f"{len(dirs)} subdirectories under {corpus}")
    if not files:
        sys.exit("no playable files found in the corpus")
    print(f"seed:   {seed}   (replay this run with --seed {seed})")

    started = time.time()
    launch(corpus, app)
    menu_ids = collect_menu_ids(channel)
    exclusions = chrome_exclusion_rects(channel)
    print(f"menu:   {len(menu_ids)} clickable items after the modal/quit denylist")
    print(f"clicks: avoiding {len(exclusions)} window-chrome rects (close/minimize)")
    print(f"settings: {describe_feature_settings(channel)}")

    if args.profile == "cloud":
        # Armed before the first op rather than as one: the profile's premise is
        # that an open is already a download, and a run that spent its first
        # batch against local files would be scoring a different app.
        #
        # 0.9s BASE, deliberately above the player's own 0.5s slow-open
        # threshold, so the slow-open UI — the loading state, the download fill,
        # the placeholder artwork — is exercised rather than skipped. It is NOT
        # what arms the foreground hold: that is taken at play submission, in
        # the player's pre-submit delegate edge, whatever the open costs.
        # Per-file times spread around the base with a slow and an
        # effectively-stuck tail; see VibeFakeCloud.
        #
        # capacity=1 from the start, for the reason op_cloud_churn spells out:
        # with an unlimited provider nothing ever waits on anything, and the
        # ordering this profile exists to score is unobservable.
        code, payload, _ = channel.run(
            ["set_fake_cloud", "0.9", str(args.cloud_percent), "capacity=1"])
        if code != 0 or not (payload or {}).get("installed"):
            sys.exit("cloud profile: could not arm the fake provider "
                     f"(exit {code}, reply {payload}) — needs a Debug build")
        print(f"cloud:  fake provider armed, {payload['percent']}% of files cloudy, "
              f"0.90s base with slow and stuck tails, {payload['capacity']} transfer slot")

    generator = OpGenerator(rng, files, playlists, dirs, menu_ids, args.profile, exclusions)
    journal_path = (Path(args.journal) if args.journal
                    else DEFAULT_OUTPUT_DIR / f"stress-{seed}.ndjson")
    # Everything else in the run — health series, stall samples, the failure
    # directory — derives from this parent, so one mkdir covers them all.
    journal_path.parent.mkdir(parents=True, exist_ok=True)
    stalls = {"dir": journal_path.parent / f"stress-{seed}-stalls", "count": 0,
              "samples": 0, "max": args.max_stalls}
    health_samples = []
    growth_streaks = {}
    baseline = None
    # The quiesced series: rarer, taken at a fixed idle state, and scored
    # against far tighter limits. This is where a slow leak actually shows.
    resting_samples = []
    resting_streaks = {}
    resting_baseline = None
    batches = 0
    failure = None
    executed = 0
    deadline = started + args.duration if args.duration else None

    with open(journal_path, "w") as journal:
        journal.write(json.dumps({
            "seed": seed, "profile": args.profile, "corpus": str(corpus),
            "app": str(app), "iterations": args.iterations, "batch": args.batch,
        }) + "\n")

        try:
            while executed < args.iterations:
                batch = []
                while len(batch) < args.batch and executed + len(batch) < args.iterations:
                    batch.extend(generator.next_ops())

                failure = replay_ops(channel, batch, journal=journal, stalls=stalls)
                executed += len(batch)
                if failure:
                    break

                state = check_liveness(channel, since=started)
                generator.note_window(state.get("window", {}).get("frame"))

                violations = check_consistency(channel)
                if violations:
                    failure = Failure("consistency",
                                      "; ".join(f"{v['id']}: {v['detail']}" for v in violations))
                    break

                code, health, _ = channel.run(["dump_health"], timeout=20)
                if code == 0 and health:
                    health["_ops"] = executed
                    health_samples.append(health)
                    if baseline is None:
                        if len(health_samples) >= BASELINE_SAMPLES:
                            baseline = min_baseline(health_samples)
                    else:
                        grew = health_growth(baseline, health, growth_streaks)
                        if grew:
                            failure = Failure("resource", "; ".join(grew))
                            break

                    if len(health_samples) % 5 == 0 or args.verbose:
                        footprint = health["process"].get("footprintBytes", 0) // (1024 * 1024)
                        print(f"  {executed:6d} ops   {footprint:5d} MB   "
                              f"{health['app'].get('engineNodes', '?')} nodes   "
                              f"{health['process'].get('fileDescriptors', '?')} fds")

                batches += 1
                if args.quiesce_every and batches % args.quiesce_every == 0:
                    failure, resting_baseline = quiesced_checkpoint(
                        channel, resting_samples, resting_streaks, resting_baseline,
                        executed, args.verbose)
                    if failure:
                        break
                    # quiesce empties the playlist, so the ui profile — which
                    # never opens anything — would spend the rest of the run
                    # driving an empty app.
                    if files:
                        channel.run(["open", str(rng.choice(files))])

                if deadline and time.time() > deadline:
                    print(f"  duration limit reached after {executed} ops")
                    break
        except Failure as caught:
            failure = caught
        except KeyboardInterrupt:
            print("\ninterrupted", file=sys.stderr)

    if health_samples or resting_samples:
        samples_path = journal_path.with_suffix(".health.ndjson")
        combined = sorted(health_samples + resting_samples, key=lambda s: s["_ops"])
        samples_path.write_text("".join(json.dumps(s) + "\n" for s in combined))
        print(f"health: {samples_path} ({len(health_samples)} in-flight, "
              f"{len(resting_samples)} at rest)")

    print(f"journal: {journal_path}")
    if stalls["count"]:
        print(f"stalls:  {stalls['count']} recoverable main-thread stalls over 5s, "
              f"sampled in {stalls['dir']}")

    if failure:
        out_dir = journal_path.parent / f"stress-{seed}-failure"
        notes = capture_diagnostics(channel, out_dir, failure, started)
        print(f"\nFAILED after {executed} ops: {failure.kind} — {failure.detail}")
        for note in notes[2:]:
            print(f"  {note}")
        print(f"  diagnostics: {out_dir}")
        print(f"  minimize:    {sys.argv[0]} --corpus {corpus} --shrink {journal_path}")
        return 1

    print(f"\nPASSED {executed} ops, no violations, no unbounded growth")
    return 0


# --------------------------------------------------------------------------
# Replay and shrink
# --------------------------------------------------------------------------


def load_journal(path: Path):
    ops = []
    with open(path) as fh:
        for line in fh:
            entry = json.loads(line)
            if "argv" in entry:
                ops.append((entry.get("op", "op"), entry["argv"], entry.get("tolerated", [])))
    return ops


def reproduces(channel, corpus, app, ops, resting_mb=0):
    """Fresh app, replay ops, run the oracles. True if it still fails.

    resting_mb turns this into a predicate for RESOURCE failures too: quiesce
    and fail when the at-rest footprint exceeds it. Without that the shrinker
    can only minimize crashes, hangs and consistency violations — and a retained
    allocation is exactly the kind of failure whose repro you most want cut
    down, since it only shows up after hundreds of ops.
    """
    launch(corpus, app)
    failure = replay_ops(channel, ops)
    if failure:
        return True
    try:
        check_liveness(channel)
    except Failure:
        return True
    if check_consistency(channel) is not None:
        return True
    if resting_mb:
        channel.run(["quiesce"], timeout=40)
        code, health, _ = channel.run(["dump_health"], timeout=20)
        if code == 0 and health:
            mb = health.get("process", {}).get("footprintBytes", 0) // (1024 * 1024)
            if mb > resting_mb:
                return True
    return False


def shrink(args):
    """Delta-debug the journal to a minimal op list that still fails.

    ddmin: split into n chunks, try removing each; on success shrink to that
    subset and reset, otherwise double n. Each candidate costs one relaunch,
    so expect a shrink to take minutes, not seconds.
    """
    app = Path(args.app).expanduser().resolve() if args.app else DEFAULT_APP
    corpus = Path(args.corpus).expanduser().resolve()
    channel = Channel(app, verbose=args.verbose,
                      client_app=Path(args.client_app) if args.client_app else None)
    ops = load_journal(Path(args.shrink))
    print(f"shrinking {len(ops)} ops from {args.shrink}")

    resting_mb = args.shrink_resting_mb
    if resting_mb:
        print(f"  predicate includes resting footprint > {resting_mb} MB")
    if not reproduces(channel, corpus, app, ops, resting_mb):
        sys.exit("the full journal does not reproduce a failure — nothing to shrink")

    n = 2
    while len(ops) >= 2:
        chunk = max(1, len(ops) // n)
        reduced = False
        for start in range(0, len(ops), chunk):
            candidate = ops[:start] + ops[start + chunk:]
            if not candidate:
                continue
            print(f"  trying {len(candidate)} ops…", flush=True)
            if reproduces(channel, corpus, app, candidate, resting_mb):
                ops = candidate
                n = max(2, n - 1)
                reduced = True
                break
        if not reduced:
            if n >= len(ops):
                break
            n = min(len(ops), n * 2)

    out = Path(args.shrink).with_suffix(".min.txt")
    out.write_text("".join(" ".join(argv) + "\n" for _, argv, _ in ops))
    print(f"\nminimal repro: {len(ops)} ops -> {out}")
    print("replay it with:")
    print(f"  .claude/skills/vibe-debug/scripts/run-script.sh /tmp/shots < {out}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", required=True,
                        help="directory of audio files to stress against")
    parser.add_argument("--app", help=f"path to Vibe.app (default {DEFAULT_APP})")
    parser.add_argument("--seed", type=int, help="replay a previous run's op sequence")
    parser.add_argument("--iterations", type=int, default=2000, help="ops to run (default 2000)")
    parser.add_argument("--duration", type=float, help="stop after this many seconds")
    parser.add_argument("--batch", type=int, default=25,
                        help="ops between oracle checks (default 25)")
    parser.add_argument("--quiesce-every", type=int, default=10,
                        help="batches between quiesced (at-rest) health samples, 0 to "
                             "disable (default 10). These carry the tight growth limits; "
                             "the in-flight samples cannot, because a decode swings the "
                             "footprint by hundreds of megabytes")
    parser.add_argument("--max-stalls", type=int, default=3,
                        help="recoverable >5s main-thread stalls tolerated (default 3); "
                             "each one is sampled either way")
    parser.add_argument("--profile", default="base", choices=sorted(PROFILES),
                        help="op weighting (default base)")
    parser.add_argument("--cloud-percent", type=int, default=60,
                        help="cloud profile only: share of the corpus behaving as "
                             "placeholders (default 60, deliberately MIXED — the local files "
                             "are there to prove the cloud machinery has not slowed them "
                             "down). 100 for an all-cloud folder.")
    parser.add_argument("--client-app",
                        help="app bundle to use as the channel CLIENT, when it should differ "
                             "from --app. For sanitizer runs: an instrumented client costs "
                             "~2.4s per op against ~0.13s for a plain one driving the same "
                             "instrumented app. Build both from the same source.")
    parser.add_argument("--no-batch", action="store_true",
                        help="one client process per op instead of one per batch. Slower; "
                             "only needed when every op's own timing matters.")
    parser.add_argument("--journal",
                        help=f"NDJSON journal path (default {DEFAULT_OUTPUT_DIR}/"
                             "stress-<seed>.ndjson; the health series, stall samples and "
                             "failure directory land beside it)")
    parser.add_argument("--replay", help="replay a journal verbatim instead of generating ops")
    parser.add_argument("--shrink", help="delta-debug a failing journal to a minimal repro")
    parser.add_argument("--shrink-resting-mb", type=int, default=0,
                        help="with --shrink, also treat an at-rest footprint above this "
                             "many MB as a reproduction, so a resource failure can be "
                             "minimized like a crash")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    signal.signal(signal.SIGINT, signal.default_int_handler)

    if args.shrink:
        return shrink(args)
    if args.replay:
        app = Path(args.app).expanduser().resolve() if args.app else DEFAULT_APP
        corpus = Path(args.corpus).expanduser().resolve()
        channel = Channel(app, verbose=args.verbose,
                          client_app=Path(args.client_app) if args.client_app else None)
        ops = load_journal(Path(args.replay))
        print(f"replaying {len(ops)} ops from {args.replay}")
        launch(corpus, app)
        failure = replay_ops(channel, ops, check_every=args.batch)
        if failure:
            print(f"FAILED: {failure.kind} — {failure.detail}")
            return 1
        violations = check_consistency(channel)
        if violations:
            print("FAILED: " + "; ".join(v["id"] for v in violations))
            return 1
        print("PASSED")
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
