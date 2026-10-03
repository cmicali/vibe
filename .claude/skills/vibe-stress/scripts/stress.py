#!/usr/bin/env python3
"""Seeded stress and fuzz driver for the running Vibe app.

It drives the debug command channel with weighted random operations against a
corpus of real audio files, and checks four oracles between batches:

  liveness    the app still answers          (the channel is served on the main
                                              queue, so a timeout whose recovery
                                              probe is ALSO slow is a main-thread
                                              stall; one that probes clean was a
                                              slow verb)
  consistency check_consistency has no       (re-checked after a settle, since a
              surviving violations           render can lag its state change)
  health      dump_health has not grown      (footprint, live heap, fds, threads,
              without bound                   ports, windows, views, layers,
                                              hosted units, pending counters)
  crash       the process is still alive     (and no fresh .ips landed)

The seed is printed at the start and `--seed N` regenerates the run's ops only
as far as the app answers the same: row selections, file-drop coordinates and
theme and menu picks read live state (playlist length, window size, the
installed themes and menu items). Every op is journaled as NDJSON; `--replay`
reruns a journal verbatim, the one exact reproduction, and `--shrink`
delta-debugs a failing one to a minimal run-script.sh repro.

    stress.py --corpus ~/Music/big --iterations 2000
    stress.py --corpus ~/Music/big --replay run.ndjson
    stress.py --corpus ~/Music/big --shrink run.ndjson

It launches through vibe-debug's launch.sh, so the app runs off the audio
hardware (--no-audio-hw --silent); VIBE_AUDIBLE=1 or =silent overrides.

No profile sends convert_to_flac: it writes beside the source and can trash
the original, and the corpus is the user's real music.
"""

import argparse
import contextlib
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
# Under build/: gitignored and removed by `make clean`, unlike the CWD, which
# for `make stress` is the repo root.
DEFAULT_OUTPUT_DIR = REPO / "build/stress"
# vibe-debug's launcher, not a copy: the launch rules (sandbox grant,
# off-hardware flags, wrong-binary warning) must not drift into two versions.
LAUNCH_SH = Path(__file__).resolve().parents[2] / "vibe-debug/scripts/launch.sh"
CRASH_DIR = Path.home() / "Library/Logs/DiagnosticReports"

CLIENT_LAUNCH_RETRIES = 4   # see Channel.run

# The subprocess timeout must stay above the client's own per-verb wait (the
# command table's clientTimeout: 5s by default, file_cache 60s, quiesce 20s),
# or a verb still working reads as an unresponsive app. A 7-minute MP3 takes
# ~30s through file_cache in a -O0 build.
VERB_TIMEOUTS = {"file_cache": 90, "quiesce": 40}

# A recovery probe slower than this after a timed-out op makes it a
# main-thread stall rather than a slow verb. Ordinary probe latency is ~110ms.
STALL_PROBE_MS = 2000

# PlayableExtensions.ordered, in its order: the cue reader probes a missing
# FILE's other spellings in it, and make-cue-corpus.py resolves them the same
# way. The runner tests hold this to the source.
AUDIO_SUFFIXES = (".wav", ".wave", ".bwf", ".w64", ".aif", ".aiff", ".flac", ".caf",
                  ".m4a", ".mp4", ".qta", ".m4b", ".m4r", ".aac", ".adts",
                  ".ogg", ".oga", ".opus", ".mp3", ".mp2")
PLAYLIST_SUFFIXES = {".m3u", ".m3u8", ".cue"}   # PlaylistFile.isPlaylistExtension:

# TRAP: raw input can start native file and window drags, so unattended runs
# send only app-owned actions. require_command fails closed on anything else,
# old journals included.
COMMAND_VERBS = set("""
append block_main burst check_consistency clear_caches clear_cloud_trace
click_menu dump_audio_loading dump_cloud_health dump_cloud_trace dump_health
dump_menu dump_metadata_progress dump_row_loading dump_state dump_theme dump_view_tree
file_cache file_clear_cache file_drag_drop file_drag_end file_drag_hover hang_open
import_theme next open play_index play_pause select_rows remove_selected previous
quiesce quit redo remove_theme reorder_begin reorder_cancel reorder_drop reorder_update
seek set_analysis set_appearance set_audio_loading set_equalizer_mode set_fake_cloud
set_folder_art set_pause_at_track_end set_pitch set_theme set_window_width settings_close
skip_back skip_back_more skip_back_most skip_forward skip_forward_more skip_forward_most
sleep toggle_low_kill toggle_pitch_panel toggle_size undo
low_kill_boost_on low_kill_boost_off reverb_send_on reverb_send_off
delay_send_on delay_send_off short_delay_send_on short_delay_send_off
""".split())
MENU_IDS = set("""
menu_play menu_next_track menu_previous_track menu_skip_forward menu_skip_forward_more
menu_skip_forward_most menu_skip_back menu_skip_back_more menu_skip_back_most
menu_fx_low_kill menu_fx_low_kill_boost menu_fx_reverb menu_fx_delay menu_fx_short_delay
pitch_range_8 pitch_range_16 menu_show_playlist menu_show_pitch menu_show_file_info
menu_play_selected menu_edit_select_all menu_edit_remove_from_playlist menu_edit_undo menu_edit_redo
""".split())
GESTURE_TESTS = ("pitch-reset", "pitch-drag")


def require_command(argv, gesture_test=None):
    """Validate before any client launch, including every nested block_main."""
    if (not isinstance(argv, (list, tuple)) or not argv
            or any(not isinstance(a, str) or "\x00" in a for a in argv)):
        raise ValueError("command-only stress requires a nonempty string argument list")
    if argv == ["gesture_test", gesture_test, "isolated-desktop"] and gesture_test in GESTURE_TESTS:
        return
    while argv[0] == "block_main":
        if len(argv) == 2:
            return
        if len(argv) < 3:
            raise ValueError("block_main requires a duration")
        argv = argv[2:]
    if argv[0] not in COMMAND_VERBS:
        raise ValueError(f"command-only stress refuses {argv[0]!r}; use a named gesture test "
                         "on an isolated desktop for input testing")
    if argv[0] == "click_menu" and (len(argv) != 2 or argv[1] not in MENU_IDS):
        raise ValueError("command-only stress refuses this menu item")


def script_line(argv):
    """argv as one `script -` line, or None if it cannot be one.

    The script tokenizer groups quotes but has no escapes: an empty argument,
    or one with a quote, tab or line break (a filename newline would start
    another command), cannot be expressed.
    """
    if any(not a or any(c in a for c in "\"'\n\r\t") for a in argv):
        return None
    return " ".join(f'"{a}"' if " " in a else a for a in argv)


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
    """The channel client: one `Vibe --debug-cmd` process per op, or per batch.

    A client process costs ~80ms of fork/exec, dyld and sandbox container
    setup; run_batch pays it once per batch through the channel's script mode.
    """

    def __init__(self, app: Path, verbose=False, client_app: Path = None, gesture_test=None):
        # The channel is files in a shared container plus a notify wake-up, so
        # any build of the same source can drive any other. Under a sanitizer
        # that matters: 2.38s per op with a TSan client against 0.133s with a
        # plain one, driving the same TSan app. Opt-in, because builds from
        # different sources can skew the protocol.
        self.binary = (client_app or app) / "Contents/MacOS/Vibe"
        self.gesture_test = gesture_test
        # Off by default so the shrinker and --replay get each op's own timing.
        self.batch = False
        self.verbose = verbose
        if not self.binary.exists():
            sys.exit(f"no app at {app} — build first (make build CONFIG=Debug), or pass --app")

    def run(self, argv, timeout=30):
        """Returns (exit_code, parsed_json_or_None, elapsed_ms).

        TRAP: hundreds of quick launches of a sandboxed binary make libsecinit
        fail, SIGTRAPping the client in dyld before main(). A client killed by
        a signal with no output is therefore retried, not reported.
        """
        require_command(argv, self.gesture_test)
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
                # The client's own no-response code. Stall versus slow verb is
                # replay_ops' recovery probe's call.
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

        Batching loses the per-op process exit code; a reply's `error` stands
        in for it. The script stops at its first failing or unanswered command,
        so the stream comes back SHORT and the caller runs the rest one at a
        time, where a hang gets its own timeout and stall diagnosis.

        Returns [(exit_code, payload)] as far as the stream got, or None if the
        batch cannot be expressed as script lines.
        """
        for argv in argv_list:
            require_command(argv)
        lines = [script_line(argv) for argv in argv_list]
        if None in lines:
            return None
        try:
            # TRAP: the client's printf is block-buffered into a pipe, so a
            # client killed at the timeout loses every reply it had printed
            # and the caller re-sends ops that already ran. NSUnbufferedIO
            # makes Foundation unbuffer stdout: each reply lands as it is made.
            proc = subprocess.run(
                [str(self.binary), "--debug-cmd", "script", "-"],
                input="\n".join(lines) + "\n",
                capture_output=True, text=True, timeout=timeout,
                env={**os.environ, "NSUnbufferedIO": "YES"},
            )
            out = proc.stdout
        except subprocess.TimeoutExpired as expired:
            # The replies so far say where the caller resumes one at a time.
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

    TRAP: never `sample Vibe` by name. The CLI client is the app binary, so the
    name also matches every in-flight `--debug-cmd`, whose polling stack reads
    as a hang, and the iOS Simulator's Vibe. Filtered here by argv.
    """
    found = subprocess.run(["pgrep", "-x", "Vibe"], capture_output=True, text=True)
    for pid in found.stdout.split():
        listing = subprocess.run(["ps", "-o", "command=", "-p", pid],
                                 capture_output=True, text=True)
        if "--debug-cmd" not in listing.stdout and "CoreSimulator" not in listing.stdout:
            return int(pid)
    return None


def app_is_running():
    return app_pid() is not None


# TRAP: these settings gate whole subsystems and persist in NSUserDefaults, so
# a run inherits the last run's final toggle, and with one off it passes over
# code it never entered. Forced on at launch and printed in the header;
# teardown puts back the user's own values, so the next run forces them again.
FEATURE_SETTINGS = {
    "folderArt": ["set_folder_art", "on"],
    "analyzeBPM": ["set_analysis", "bpm", "on"],
    "analyzeKey": ["set_analysis", "key", "on"],
}


def describe_feature_settings(channel) -> str:
    parts = []
    for key, argv in FEATURE_SETTINGS.items():
        code, payload, _ = channel.run(argv)
        ok = code == 0 and isinstance(payload, dict) and payload.get("ok")
        parts.append(f"{key}={argv[-1]}" if ok else f"{key}=UNKNOWN (could not set)")
    return ", ".join(parts)


def on_off(value):
    return "on" if value else "off"


PITCH_PANEL_WIDTH = 96   # kPitchPanelWidth, outside set_window_width's body width


def window_restore(before):
    width, height = (float(n) for n in re.findall(r"-?[\d.]+", before["windowFrame"])[2:4])
    panel = PITCH_PANEL_WIDTH if before.get("pitchPanelShown") else 0
    return ["set_window_width", f"{width - panel:g}", f"{height:g}"]


# TRAP: the store a run moves is the user's real one, since the sandbox
# container is shared with the installed app. Every persisted value an op can
# move needs its command here, given the starting snapshot; teardown reports
# any other key that moved as STILL CHANGED. It sends one only for a key that
# moved, re-reading after each, so a toggle restores by being sent again.
# Order matters: the theme first, since an apply carries the waveform style
# and theme and can pin the appearance (a single-mode theme outranks
# windowAppearance); the window's frame last, since the panels move it.
SETTING_RESTORERS = {
    "activeTheme": lambda b: ["set_theme", b["activeTheme"]],
    "windowAppearance": lambda b: ["set_appearance", b["windowAppearance"]],
    "pauseAtTrackEnd": lambda b: ["set_pause_at_track_end", on_off(b["pauseAtTrackEnd"])],
    "folderArt": lambda b: ["set_folder_art", on_off(b["folderArt"])],
    "analyzeBPM": lambda b: ["set_analysis", "bpm", on_off(b["analyzeBPM"])],
    "analyzeKey": lambda b: ["set_analysis", "key", on_off(b["analyzeKey"])],
    "pitchRange": lambda b: ["click_menu", f"pitch_range_{b['pitchRange']}"],
    "playlistShown": lambda b: ["click_menu", "menu_show_playlist"],
    "pitchPanelShown": lambda b: ["toggle_pitch_panel"],
    "windowFrame": window_restore,
}


def current_settings(channel):
    """dump_state.settings plus the main window's frame, which NSWindow
    autosaves to the same store; None when the app does not answer."""
    code, state, _ = channel.run(["dump_state"], timeout=20)
    if code != 0 or not isinstance(state, dict):
        return None
    settings = dict(state.get("settings") or {})
    settings["windowFrame"] = (state.get("window") or {}).get("frame")
    return settings


def user_settings_restore(channel, before, imported_themes, corpus, app):
    """Put back what the run moved, pass or fail, and print one line saying
    what — including any key still off its starting value."""
    relaunched = ""
    if before and app_pid() is None:
        # A crash or an exit left the store as the run moved it.
        try:
            launch(corpus, app)
            relaunched = "relaunched to restore; "
        except SystemExit as error:
            print(f"settings: NOT restored, relaunch failed: {error}", file=sys.stderr)
            return
    now = current_settings(channel) if before else None
    if now is None:
        print("settings: NOT restored — "
              + ("the app is not answering" if before else "no starting snapshot")
              + f"; {len(imported_themes)} imported themes remain", file=sys.stderr)
        return
    channel.run(["reorder_cancel"])
    # Imports first: each is a persisted user theme, and one left behind
    # changes the next run's theme list and so the op sequence its seed draws.
    # remove_theme falls back to vibe when the removed theme is active.
    removed = sum(channel.run(["remove_theme", str(identifier)])[0] == 0
                  for identifier in imported_themes)
    restored = []
    now = current_settings(channel) or now
    for key, restorer in SETTING_RESTORERS.items():
        if before.get(key) is not None and now.get(key) != before[key]:
            channel.run(restorer(before))
            restored.append(f"{key}={before[key]}")
            now = current_settings(channel) or now
    left = [f"{key} {before[key]!r} -> {now.get(key)!r}"
            for key in sorted(before) if now.get(key) != before[key]]
    line = (f"settings: {relaunched}removed {removed}/{len(imported_themes)} imported themes, "
            f"restored {', '.join(restored) or 'nothing (none moved)'}")
    if left:
        print(f"{line}; STILL CHANGED: {'; '.join(left)}", file=sys.stderr)
    else:
        print(f"{line}; the store matches the start")


@contextlib.contextmanager
def user_settings_preserved(channel, corpus: Path, app: Path):
    """Snapshot the settings before the run forces any, and restore them on
    every exit Python sees (SIGTERM and SIGHUP raise KeyboardInterrupt; see
    main). Yields the list the run appends imported theme ids to."""
    before = current_settings(channel)
    imported_themes = []
    try:
        yield imported_themes
    finally:
        user_settings_restore(channel, before, imported_themes, corpus, app)


def launch(corpus: Path, app: Path):
    """Relaunch and wait until the app answers.

    TRAP: the corpus grant comes from this launch. Handing the folder to
    `open -a` (launch.sh) is what bookmarks it; a direct-exec launch cannot
    read argv paths under the sandbox. The grant persists, so later channel
    `open`s inside the corpus are readable.
    """
    env = dict(os.environ, VIBE_APP=str(app))
    result = subprocess.run(
        [str(LAUNCH_SH), str(corpus)], capture_output=True, text=True, env=env
    )
    if result.returncode != 0:
        sys.exit(f"launch failed: {result.stderr.strip()}")
    if "warning:" in result.stderr:
        print(f"  {result.stderr.strip()}", file=sys.stderr)
    assert_running_binary(app)


def assert_running_binary(app: Path):
    """Exit unless the running GUI instance is the binary that was asked for.

    TRAP: `open -a <path>` resolves by BUNDLE ID, not path, and every build is
    com.commonwealthrecordings.Vibe, so VIBE_APP (handed to `open -a` by
    launch.sh) does not pin the build. A sanitizer run on the plain build
    would report a clean pass over an uninstrumented binary.
    """
    wanted = (app / "Contents/MacOS/Vibe").resolve()
    pid = app_pid()
    if pid is None:
        sys.exit("launch reported success but no GUI instance is running")
    listing = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)],
                             capture_output=True, text=True)
    running = Path(listing.stdout.strip())
    if running != wanted:
        sys.exit(f"WRONG BINARY: asked for {wanted}, LaunchServices launched {running}.\n"
                 f"  Re-register the one you want and try again:\n"
                 f"  /System/Library/Frameworks/CoreServices.framework/Versions/Current"
                 f"/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
                 f" -f {app}")
    print(f"binary: {running}")


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

# An op is (name, argv, tolerated_error_substrings): errors the app is right
# to return for a randomly chosen argument, which are not findings.

# Correct refusals of paths a hostile corpus holds (a symlink loop, a
# zero-length file, a name that no longer resolves). They stay journaled with
# their exit codes, so a refusal of a file that IS there is still visible.
PATH_REFUSALS = [
    "no file or directory", "expects an existing file", "no such file",
    "could not", "failed",
]

# `still in progress` is a conversion undo/redo still settling.
UNDO_REFUSALS = ["nothing to undo", "nothing to redo", "still in progress"]

FX_ON_OFF = [
    "low_kill_boost", "reverb_send", "delay_send", "short_delay_send",
]

APPEARANCE_VALUES = ["light", "dark", "system"]
EQUALIZER_MODES = ["balanced", "activity", "spectrum"]
# set_audio_loading's three "safe" (non-diagnostic) keys, within
# AudioLoadingConfiguration.m's validation bounds: an out-of-range value is a
# `command` failure that ends the run on the harness's own bad argument.
AUDIO_LOADING_KEYS_LOCAL_PARSES = [1, 2, 4, 8, 16]
AUDIO_LOADING_KEYS = {
    "background": lambda rng: rng.choice([1, 1, 2, 3, 4]),
    "local-parses": lambda rng: rng.choice(AUDIO_LOADING_KEYS_LOCAL_PARSES),
    "prefetch-depth": lambda rng: rng.choice([0, 1]),
}

# Fields of AppTheme's serialized record, by group, for mutating a real dumped
# record: one built from scratch is refused by the JSON reader and never
# reaches the sanitizer, the gate worth hammering.
THEME_GROUPS = {
    "window": ["backgroundColorDark", "backgroundColorLight", "backgroundStyle",
               "cornerRadius", "tint", "mode"],
    "player": ["artistColorDark", "artistColorLight", "artistFontFace",
               "titleColorDark", "titleColorLight", "titleFontFace",
               "titleFontSize", "artistFontSize"],
    "info": ["colorDark", "colorLight", "fontFace", "fontSize",
             "timeColorDark", "timeColorLight"],
    "playlist": ["backgroundColorDark", "backgroundColorLight", "backgroundStyle",
                 "durationFontFace", "fontFace", "fontSize", "durationFontSize",
                 "playingRowColorDark", "playingRowColorLight",
                 "selectedRowColorDark", "selectedRowColorLight",
                 "showArtworkColumn", "showDurationColumn", "tint"],
    "waveform": ["gradient", "playedColorDark", "playedColorLight", "style",
                 "theme", "unplayedColorDark", "unplayedColorLight"],
}

# Values the sanitizer must clamp or reject; one reaching a renderer is the
# finding. The nonexistent font face sanitizes CLEAN (a face cannot be checked
# without asking the text system), so it is the one that reaches NSFont.
def THEME_HOSTILE(rng):
    return rng.choice([
        1e308, -1e308, 0, -1, 99999, 1e18, -0.0,
        "", " ", "#", "#ZZZZZZ", "#12345678901234", "not-a-color",
        "NoSuchFont-Regular-Xyzzy", "\x00", "\ufffd" * 40, "x" * 4096,
        True, False, None, [], {}, [1, 2, 3], {"nested": {"deeper": 1}},
        "single", "dual", "glass", "solid", "mono", "album_art", "orange",
        "basic", "detailed", "sonic_cirrus", "custom",
    ])


# Every accepted import is a persisted user theme until teardown removes it;
# uncapped, a long run would put tens of thousands in the store.
MAX_THEME_IMPORTS = 80


class OpGenerator:
    def __init__(self, rng, corpus_files, corpus_playlists, corpus_dirs, menu_ids,
                 profile, themes=(), theme_base=None):
        self.rng = rng
        self.files = corpus_files
        self.playlists = corpus_playlists
        self.dirs = corpus_dirs
        self.menu_ids = menu_ids
        self.themes = list(themes)
        self.theme_base = theme_base
        self.theme_imports = 0
        self.window = (900.0, 400.0)  # synthetic file-drop coordinates only
        self.playlist_count = len(corpus_files)
        self.weights = effective_weights(profile)
        self.kinds = [k for k, w in self.weights.items() if w > 0]
        self.kind_weights = [self.weights[k] for k in self.kinds]

    def note_state(self, state):
        self.playlist_count = state.get("playlist", {}).get("count", self.playlist_count)
        # NSStringFromRect: "{{x, y}, {w, h}}"
        frame_string = state.get("window", {}).get("frame")
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
        return [("open_file", ["open", str(self.rng.choice(self.files))], PATH_REFUSALS)]

    def op_open_dir(self):
        if not self.dirs:
            return self.op_open_file()
        return [("open_dir", ["open", str(self.rng.choice(self.dirs))], PATH_REFUSALS)]

    def op_open_playlist(self):
        if not self.playlists:
            return self.op_open_file()
        return [("open_playlist", ["open", str(self.rng.choice(self.playlists))], PATH_REFUSALS)]

    def op_open_burst(self):
        """Opens on top of each other, so waveform, BPM, key and metadata
        deliveries land after the track has changed."""
        if not self.files:
            return self.op_transport()
        n = self.rng.randint(2, 4)
        return [
            ("open_burst", ["open", str(self.rng.choice(self.files))], PATH_REFUSALS)
            for _ in range(n)
        ]

    def op_cache_churn(self):
        if not self.files:
            return self.op_transport()
        path = str(self.rng.choice(self.files))
        return [
            ("file_clear_cache", ["file_clear_cache", path], PATH_REFUSALS),
            ("file_cache", ["file_cache", path], PATH_REFUSALS),
        ]

    def op_clear_caches(self):
        return [("clear_caches", ["clear_caches"], [])]

    def op_cloud_churn(self):
        """Re-arm the fake provider mid-run, sometimes uninstalling first.

        The uninstall/reinstall edges swap the dataless probe and transfer
        block under in-flight workers: the one way this seam could deadlock
        rather than misreport. Never 100% cloudy: the local files prove the
        cloud path has not slowed them.

        Scarce capacity is what makes the foreground hold observable: at
        capacity=0 (unlimited) no background download ever delays a
        foreground one. Install resets capacity to 1.
        """
        seconds = f"{self.rng.uniform(0.6, 1.6):.2f}"
        percent = self.rng.choice([30, 50, 80])
        # Mostly scarce; 0 (unlimited) stays in the mix for comparison.
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
        """Land on an arbitrary row, where no prefetch or neighborhood rank
        has prepared anything (next/previous only reach the adjacent track).

        Drawn against a ceiling, not the live length: out of range is a no-op,
        cheaper than a dump_state per jump.
        """
        return [("playlist_jump", ["play_index", str(self.rng.randrange(0, 400))], [])]

    def op_burst(self):
        """Hundreds of track changes in-process, one per main-queue turn: a
        rate the channel cannot reach (~80ms per op, ~2.4s under TSan).

        Right after an open, so it contends with the sweep's live stage-1
        workers rather than a settled app.
        """
        folder = str(self.rng.choice(self.dirs)) if self.dirs else None
        jumps = self.rng.choice([120, 300, 600])
        ops = []
        if folder:
            ops.append(("open_dir", ["open", folder], []))
        ops.append(("burst", ["burst", str(jumps), str(self.rng.randrange(1, 1 << 30))], []))
        return ops

    def op_seek(self):
        # Unreasonable values too: one that escapes the player's clamp is the
        # finding.
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
        """Hold an effect across a track change through controller actions."""
        name = self.rng.choice(FX_ON_OFF)
        ops = [("fx", [f"{name}_on"], [])]
        if self.rng.random() < 0.5:
            ops.append(("transport", ["next"], []))
        if self.rng.random() < 0.7:
            ops.append(("fx", [f"{name}_off"], []))
        return ops

    # -- window and UI ------------------------------------------------------

    def op_window(self):
        return [("window", [self.rng.choice(["toggle_size", "toggle_pitch_panel"])], [])]

    def op_resize(self):
        width = self.rng.choice([
            self.rng.randint(300, 2400),
            self.rng.randint(1, 300),
            self.rng.randint(2400, 6000),
        ])
        return [("resize", ["set_window_width", str(width)], [])]

    def point(self):
        """Coordinates for direct file-drop delegate calls, never mouse events."""
        return tuple(round(self.rng.uniform(0, size), 1) for size in self.window)

    def op_file_drag_drop(self):
        if not self.files:
            return self.op_transport()
        x, y = self.point()
        ops = [("file_drag_hover", ["file_drag_hover", str(x), str(y)], [])]
        if self.rng.random() < 0.6:
            ops.append(("file_drag_drop",
                        ["file_drag_drop", str(x), str(y), str(self.rng.choice(self.files))], PATH_REFUSALS))
        else:
            ops.append(("file_drag_end", ["file_drag_end"], []))
        return ops

    def op_append(self):
        """Extend the playlist instead of replacing it: append's own contract
        (no cursor touch, FIFO prefetch behind a same-turn play), which a
        random file_drag_drop reaches only by coordinate luck."""
        if not self.files:
            return self.op_transport()
        return [("append", ["append", str(self.rng.choice(self.files))], PATH_REFUSALS)]

    def op_end_of_track(self):
        """Flip On track end mid-play: the write's live effect re-parks or
        drops an already-armed gapless successor, a race only a mid-play flip
        reaches."""
        return [("end_of_track",
                 ["set_pause_at_track_end", self.rng.choice(["on", "off"])], [])]

    def op_analysis_flip(self):
        """Flip a decode-pass analyzer under in-flight loads: the decode reads
        the setting when it starts, so a flip varies which deliveries the next
        track change must drop."""
        return [("analysis_flip",
                 ["set_analysis", self.rng.choice(["bpm", "key"]),
                  self.rng.choice(["on", "off"])], [])]

    def op_reorder_begin(self):
        """Start a synthetic row-reorder drag and leave it OPEN, so whatever
        the scheduler deals next (an open, a removal, a burst) lands inside a
        live drag session. The next begin cancels a leftover one. Rows are
        drawn against a ceiling for playlist_jump's reason; out of range is a
        tolerated refusal.
        """
        rows = {self.rng.randrange(0, 24) for _ in range(self.rng.choice([1, 1, 2, 3]))}
        return [("reorder_begin", ["reorder_begin", *map(str, sorted(rows))],
                 ["not draggable"])]

    def op_reorder_finish(self):
        """Probe a slot, then drop or cancel whatever drag session is live.
        With none, these are tolerated refusals that exercise the guard."""
        roll = self.rng.random()
        if roll < 0.15:
            return [("reorder_cancel", ["reorder_cancel"], ["no reorder session"])]
        ops = []
        if roll < 0.55:
            ops.append(("reorder_update",
                        ["reorder_update", str(self.rng.randrange(0, 26))],
                        ["no reorder session"]))
        ops.append(("reorder_drop",
                    ["reorder_drop", str(self.rng.randrange(0, 26))],
                    ["no reorder session"]))
        return ops

    def op_menu(self):
        if not self.menu_ids:
            return self.op_window()
        return [("menu", ["click_menu", self.rng.choice(self.menu_ids)], ["disabled"])]

    def op_undo(self):
        verb = self.rng.choice(["undo", "redo"])
        return [(verb, [verb], ["nothing to undo", "nothing to redo", "still in progress"])]

    def op_folder_art(self):
        """Flip folder art off and straight back on under whatever is in
        flight, landing the invalidate between a resolve claiming a directory
        and its result arriving.

        Always back on: a uniform on/off choice would park the feature OFF for
        half the run, and with it off the accessors never reach the resolver
        (the FEATURE_SETTINGS trap).
        """
        ops = [("folder_art", ["set_folder_art", "off"], []),
               ("folder_art", ["set_folder_art", "on"], [])]
        if self.rng.random() < 0.25:
            # Sometimes a settle between the edges, so resolves and decodes are
            # genuinely in flight rather than only between two round trips.
            ops.insert(1, ("settle", ["sleep", f"{self.rng.uniform(0.05, 0.4):.2f}"], []))
        return ops

    def op_settle(self):
        return [("settle", ["sleep", f"{self.rng.uniform(0.05, 0.8):.2f}"], [])]

    # -- main-thread ordering -----------------------------------------------

    def op_block_main(self):
        """Hold main, then run a shared verb on the SAME turn.

        The channel's intake is on the main queue, so a worker's callback to
        main always beats a command sent after it; two ordinary ops can never
        stage "the callback landed while a handler was underway". The hold
        parks those deliveries behind the chained verb. The app caps it at 5s;
        1.2 keeps a batch moving while outlasting a decode's delivery cadence.
        block_main chains only shared verbs (DebugCommonVerbs.m).
        """
        seconds = f"{self.rng.uniform(0.05, 1.2):.2f}"
        then = self.rng.choice([
            ["play_index", str(self.rng.randrange(0, 400))],
            ["play_index", str(self.rng.randrange(0, 400))],
            ["seek", f"{self.rng.uniform(-60, 600):.2f}"],
            ["burst", str(self.rng.choice([40, 120, 300])),
             str(self.rng.randrange(1, 1 << 30))],
            ["clear_caches"],
            ["set_equalizer_mode", self.rng.choice(EQUALIZER_MODES)],
            ["dump_state"],
        ])
        return [("block_main", ["block_main", seconds, *then], [])]

    # -- configuration churn under load -------------------------------------

    def op_audio_loading(self):
        """Move the loading knobs mid-decode. A change applies to new
        admissions, loaders and prefetch decisions, NEVER to live work; this
        finds a knob that reaches back. `defaults` keeps the run from parking
        in one corner of the space.
        """
        if self.rng.random() < 0.2:
            return [("audio_loading", ["set_audio_loading", "defaults"], [])]
        keys = self.rng.sample(sorted(AUDIO_LOADING_KEYS),
                               self.rng.randint(1, len(AUDIO_LOADING_KEYS)))
        argv = ["set_audio_loading"] + [f"{k}={AUDIO_LOADING_KEYS[k](self.rng)}" for k in keys]
        return [("audio_loading", argv, [])]

    def op_equalizer_mode(self):
        """Replace the render's meter stage, invalidating its publication and
        partial window, ideally on a track change or an output rebuild."""
        return [("equalizer_mode",
                 ["set_equalizer_mode", self.rng.choice(EQUALIZER_MODES)], [])]

    # The waveform style is a theme field: op_theme and op_theme_import swap
    # the renderer, so there is no separate style op.

    def op_appearance(self):
        """Flip light/dark live. The re-resolved palette takes the artwork
        color from the artwork install path, so a flip between a delivery and
        its install tests the waveform-theme guarantee."""
        return [("appearance", ["set_appearance", self.rng.choice(APPEARANCE_VALUES)], [])]

    # -- themes -------------------------------------------------------------

    def op_theme(self):
        """Apply a whole theme, the app's widest settings edit, while decodes
        and artwork installs are in flight.

        Half the time with an appearance flip: a single-mode theme outranks
        the window's appearance setting, and the two only disagree when both
        move.
        """
        if not self.themes:
            return self.op_appearance()
        ops = [("theme", ["set_theme", self.rng.choice(self.themes)], ["unknown theme"])]
        if self.rng.random() < 0.5:
            ops.append(("appearance", ["set_appearance", self.rng.choice(APPEARANCE_VALUES)], []))
        return ops

    def op_theme_import(self):
        """Import a MUTATED real record, then usually apply it: a value the
        sanitizer let through does nothing until a renderer is handed it."""
        if not self.theme_base or self.theme_imports >= MAX_THEME_IMPORTS:
            return self.op_theme()
        record = json.loads(json.dumps(self.theme_base))
        record["name"] = f"fuzz-{self.theme_imports}"
        for _ in range(self.rng.randint(1, 4)):
            group = self.rng.choice(sorted(THEME_GROUPS))
            field = self.rng.choice(THEME_GROUPS[group])
            record.setdefault(group, {})
            if isinstance(record[group], dict):
                record[group][field] = THEME_HOSTILE(self.rng)
        if self.rng.random() < 0.15:
            # The envelope: a version the reader must refuse, a non-string name.
            record[self.rng.choice(["version", "name"])] = THEME_HOSTILE(self.rng)
        self.theme_imports += 1
        blob = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
        ops = [("theme_import", ["import_theme", blob], ["not a theme"])]
        if self.rng.random() < 0.7:
            # A hostile `name` is safe inside the JSON body but not as argv:
            # execve cannot carry a NUL, and the ValueError kills the harness.
            name = record.get("name")
            safe = (isinstance(name, str) and name and "\x00" not in name
                    and len(name) < 256)
            ops.append(("theme", ["set_theme", name if safe else "vibe"],
                        ["unknown theme"]))
        return ops

    # -- playlist structure -------------------------------------------------

    def op_select_rows(self):
        # Resolved against the table when the op runs: "current" follows jumps
        # earlier in the batch, and stale rows past the end are ignored.
        if self.rng.random() < 0.2:
            rows = ["all"]
        else:
            rows = list(map(str, sorted({self.rng.randrange(max(1, self.playlist_count))
                                        for _ in range(self.rng.randint(1, 6))})))
            if self.rng.random() < 0.5:
                rows.append("current")
        return [("select_rows", ["select_rows", *rows], [])]

    def op_remove_selected(self):
        ops = self.op_select_rows()
        ops.append(("remove_selected", ["remove_selected"], []))
        if self.rng.random() < 0.6:
            ops.append(("undo", ["undo"], UNDO_REFUSALS))
            if self.rng.random() < 0.5:
                ops.append(("redo", ["redo"], UNDO_REFUSALS))
        return ops

    def op_playlist_move(self):
        ops = self.op_reorder_begin() + self.op_reorder_finish()
        if self.rng.random() < 0.5:
            ops.append(("undo", ["undo"], UNDO_REFUSALS))
            if self.rng.random() < 0.4:
                ops.append(("redo", ["redo"], UNDO_REFUSALS))
        return ops

    def op_undo_storm(self):
        """Walk the undo stack both ways: the table reconciles each edit with
        precise row operations, so an off-by-one shows only once several
        edits have stacked."""
        verbs = [self.rng.choice(["undo", "undo", "redo"])
                 for _ in range(self.rng.randint(2, 8))]
        return [(v, [v], UNDO_REFUSALS) for v in verbs]

    def op_resize_storm(self):
        """Several width changes back to back. The waveform's bar count
        follows the drawn width, and a count change mid-picture resamples in
        the morph engine; a storm lands two inside one morph, and the extremes
        reach both clamps (2 bars, the per-style cap)."""
        widths = [self.rng.choice([
            self.rng.randint(300, 2400),
            self.rng.randint(1, 300),
            self.rng.randint(2400, 6000),
        ]) for _ in range(self.rng.randint(2, 6))]
        return [("resize", ["set_window_width", str(w)], []) for w in widths]


# Why each profile weights what it does: references/profiles.md.
PROFILES = {
    "base": {
        "open_file": 14, "open_dir": 3, "open_playlist": 2, "open_burst": 6,
        "cache_churn": 2, "clear_caches": 1,
        "transport": 14, "seek": 8, "pitch": 5,
        "fx": 5, "held_fx": 4,
        "window": 3, "resize": 3, "file_drag_drop": 3,
        "menu": 3, "undo": 1, "settle": 6, "folder_art": 1,
        "playlist_jump": 4, "burst": 0,
        "reorder_begin": 3, "reorder_finish": 4,
        "append": 4, "end_of_track": 2, "analysis_flip": 2,
        "block_main": 2, "audio_loading": 2, "equalizer_mode": 2,
        "appearance": 2, "resize_storm": 2,
        "theme": 4, "theme_import": 1,
        "select_rows": 2, "remove_selected": 4, "playlist_move": 2,
        "undo_storm": 1,
    },
    # The open path and the async deliveries that race it.
    "loading": {
        "open_file": 30, "open_dir": 6, "open_burst": 20, "open_playlist": 4,
        "cache_churn": 6, "clear_caches": 2,
        "transport": 10, "seek": 4, "pitch": 1,
        "fx": 1, "held_fx": 1,
        "window": 1, "resize": 1, "file_drag_drop": 2,
        "menu": 1, "undo": 0, "settle": 8, "folder_art": 2,
        "reorder_begin": 2, "reorder_finish": 3, "remove_selected": 3,
        "append": 6, "end_of_track": 1, "analysis_flip": 3,
        "block_main": 6, "audio_loading": 4, "equalizer_mode": 1,
        "appearance": 2, "resize_storm": 2,
        "theme": 2,
    },
    # `loading` with the throttles off (in-app bursts, token settle), aimed at
    # a big local library.
    "hammer": {
        "open_file": 26, "open_dir": 8, "open_burst": 24, "open_playlist": 5,
        "cache_churn": 6, "clear_caches": 3,
        "transport": 16, "playlist_jump": 14, "burst": 10,
        "seek": 8, "pitch": 2,
        "fx": 2, "held_fx": 3,
        "window": 2, "resize": 2, "resize_storm": 8,
        "file_drag_drop": 3,
        "menu": 1, "undo": 0, "settle": 2, "folder_art": 4,
        "reorder_begin": 6, "reorder_finish": 8,
        "append": 8, "end_of_track": 3, "analysis_flip": 4,
        "block_main": 10, "audio_loading": 5, "equalizer_mode": 3,
        "appearance": 3,
        # Structural edits too: a removal whose replacement play is still
        # settling when the next open lands is a shape neither profile reaches
        # alone.
        "theme": 9, "theme_import": 2,
        "select_rows": 5, "remove_selected": 8, "playlist_move": 5,
        "undo_storm": 3,
    },
    # The folder-artwork fallback; pair it with make-hostile-corpus.py.
    "artwork": {
        "open_file": 20, "open_dir": 14, "open_burst": 16, "open_playlist": 6,
        "cache_churn": 3, "clear_caches": 3,
        "transport": 12, "seek": 2, "pitch": 0,
        "fx": 0, "held_fx": 0,
        "window": 10, "resize": 4, "file_drag_drop": 4,
        "menu": 1, "undo": 0, "settle": 6, "folder_art": 10,
        "reorder_begin": 2, "reorder_finish": 2, "remove_selected": 2,
        "append": 4, "end_of_track": 0, "analysis_flip": 1,
        "block_main": 4, "audio_loading": 2, "equalizer_mode": 0,
        "appearance": 6, "resize_storm": 3,
        "theme": 3,
    },
    # The fake provider's placeholders (armed at launch); pair it with
    # make-cloud-corpus.py. Opens must be SPARING: the sweep is deferred until
    # playback starts or two seconds pass and a replacement playlist drops the
    # loader, so opens 80ms apart never populate the cloud lane (measured: 11
    # downloads cancelled, 1 completed). Every nonzero weight below is a settle
    # not taken.
    "cloud": {
        "open_file": 3, "open_dir": 8, "open_burst": 3, "open_playlist": 1,
        "cache_churn": 3, "clear_caches": 5, "cloud_churn": 4,
        "transport": 18, "seek": 6, "pitch": 0,
        "playlist_jump": 18, "burst": 12,
        "fx": 0, "held_fx": 0,
        "window": 1, "resize": 1, "file_drag_drop": 1,
        "menu": 1, "undo": 0, "settle": 30, "folder_art": 1,
        # Moving the successor re-parks prefetch, retargeting a live transfer.
        "reorder_begin": 2, "reorder_finish": 2,
        # A removed row abandons queued scan work mid-transfer; a removed
        # current row supersedes a live foreground download.
        "remove_selected": 2,
        "append": 2, "end_of_track": 2, "analysis_flip": 1,
        # Holding main across a transfer's completion callback is the ordering
        # the foreground hold is written for.
        "block_main": 6, "audio_loading": 3, "equalizer_mode": 0,
        "appearance": 0, "resize_storm": 0,
        "theme": 0, "theme_import": 0,
        "select_rows": 0, "playlist_move": 0,
        "undo_storm": 0,
    },
    # Controller actions against whatever is loaded; opens nothing.
    "ui": {
        "open_file": 0, "open_dir": 0, "open_playlist": 0, "open_burst": 0,
        "cache_churn": 0, "clear_caches": 0,
        "transport": 10, "seek": 8, "pitch": 10,
        "fx": 10, "held_fx": 8,
        "window": 8, "resize": 8, "file_drag_drop": 0,
        "menu": 6, "undo": 1, "settle": 4,
        "reorder_begin": 5, "reorder_finish": 6, "remove_selected": 5,
        "append": 0, "end_of_track": 2, "analysis_flip": 0,
        "block_main": 4, "audio_loading": 0, "equalizer_mode": 6,
        "appearance": 6, "resize_storm": 10,
        "theme": 8,
    },
    # The theme record end to end (store, sanitizer, apply), with opens heavy
    # because what matters is what is in flight under an apply.
    "theme": {
        "open_file": 14, "open_dir": 6, "open_burst": 10, "open_playlist": 2,
        "cache_churn": 3, "clear_caches": 4,
        "transport": 10, "playlist_jump": 6, "seek": 3, "pitch": 0,
        "fx": 0, "held_fx": 0,
        "window": 4, "resize": 4, "file_drag_drop": 2,
        "menu": 2, "undo": 0, "settle": 6, "folder_art": 3,
        "block_main": 5, "audio_loading": 1, "equalizer_mode": 1,
        "theme": 32, "theme_import": 10,
        "appearance": 12, "resize_storm": 4,
        "select_rows": 3, "remove_selected": 2, "playlist_move": 2,
        "undo_storm": 1,
    },
    # Structural edits under enough transport to reach the shell funnel's
    # playing branches. Opens stay: only edit, open, undo makes a registered
    # undo stale.
    "playlist": {
        "open_file": 8, "open_dir": 8, "open_burst": 6, "open_playlist": 4,
        "cache_churn": 2, "clear_caches": 2,
        "transport": 16, "playlist_jump": 14, "burst": 4,
        "seek": 4, "pitch": 0,
        "fx": 0, "held_fx": 0,
        "window": 1, "resize": 3, "file_drag_drop": 3,
        "menu": 2, "undo": 2, "settle": 5, "folder_art": 1,
        "block_main": 6, "audio_loading": 2, "equalizer_mode": 1,
        "appearance": 2, "resize_storm": 2,
        "theme": 3, "theme_import": 1,
        "select_rows": 16, "remove_selected": 20, "playlist_move": 16,
        "undo_storm": 10,
    },
}


def effective_weights(profile):
    """The op weights a profile actually runs: base overlaid by the profile."""
    weights = dict(PROFILES["base"])
    weights.update(PROFILES.get(profile, {}))
    return weights


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
    # Gone without a report is a clean exit an op asked for, not a crash:
    # calling it one sends you hunting for a stack that was never written.
    if since is not None and not fresh_crash_reports(since):
        raise Failure("exit", "the app terminated cleanly — no crash report was written, "
                              "so an op quit it rather than crashing it")
    raise Failure("crash", "the app is gone")


def check_consistency(channel, settle=0.35):
    """A violation counts only if it survives a settle and a second sample:
    renderState runs from the updateUI funnel, so a state that flipped this
    runloop turn may legitimately not be drawn yet."""
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
                "openBurstQueued", "retiredFades", "priorityRecordsPending",
                "handleOpensInFlight")

# The `pending` counters scored as growth. priorityRecordsPending: at most one
# or two legitimately exist, and one outliving its play is a strand.
# handleOpensInFlight: an open that never returns cannot be cancelled, so each
# is admission capacity lost for good (the J8 wedged-open starvation).
#
# The rest of `pending` (cloudParsesPending, cloudLaneHeld,
# datalessProbesInFlight) legitimately swings mid-run, so it is not scored
# here: quiesce refuses to settle until every pending counter is zero, which
# fails the run as `pending`, and check_consistency's cloud.* checks test the
# conditions mid-run.

# In-flight limits: loose, since a mid-run sample carries a decode's churn.
# (section, key) in dump_health -> (absolute headroom, human name).
GROWTH_LIMITS = {
    # Mid-run the live heap read 26-52 MB across ~200 MB decodes; twice the
    # resting headroom. Without it health_growth never scores the footprint.
    ("process", "mallocLiveBytes"): (128 * 1024 * 1024, "live heap"),
    ("process", "footprintBytes"): (400 * 1024 * 1024, "memory footprint"),
    # Open descriptors: single digits at rest, a few dozen mid-burst. A leak
    # of 300 meets the 256 soft limit.
    ("process", "fileDescriptors"): (64, "open file descriptors"),
    ("process", "threads"): (48, "threads"),
    ("process", "machPorts"): (2000, "mach ports"),
    ("ui", "windows"): (3, "windows"),
    ("ui", "views"): (400, "views"),
    # Sized for the widest window: Sonic Cirrus draws two CALayers per bar at a
    # 4pt pitch, up to 1,024 bars, so 2,048 layers is a legitimate state
    # (measured: 2,844pt read 1,432). Views are the sensitive UI metric; a
    # real layer leak is unbounded and clears this too.
    ("ui", "layers"): (2400, "layers"),
    ("app", "hostedUnits"): (4, "hosted units"),
    # Cumulative; any refusal is an output unit's callback meeting a stuck
    # render.
    ("app", "renderRefusals"): (0, "render refusals"),
    **{("pending", key): (8, f"pending {key}") for key in PENDING_KEYS},
    # One holder per parse worker mid-sweep, and the audio_loading op raises
    # local-parses to 16 (AUDIO_LOADING_KEYS): a 220-row folder opened under
    # that setting held 16 for three samples while the sweep progressed. A
    # leak is unbounded, and the resting limit still requires zero.
    ("pending", "metadataHolders"): (max(AUDIO_LOADING_KEYS_LOCAL_PARSES), "pending metadataHolders"),
}

# Resting limits, for samples taken right after a `quiesce` (no track, empty
# playlist, nothing in flight), from measured loading-profile ranges: views 47,
# windows 1, hosted units flat and pending 0 are stable, so they are the
# sensitive ones; threads 14-26 breathe with the loader pool;
# footprint 47-335 MB wanders with the allocator (see health_growth), which is
# why mallocLiveBytes (~19 MB where the footprint read 203) is the heap signal.
RESTING_GROWTH_LIMITS = {
    ("process", "mallocLiveBytes"): (64 * 1024 * 1024, "resting live heap"),
    ("process", "footprintBytes"): (256 * 1024 * 1024, "resting memory footprint"),
    ("process", "fileDescriptors"): (8, "resting file descriptors"),
    ("process", "threads"): (24, "resting threads"),
    ("process", "machPorts"): (300, "resting mach ports"),
    ("ui", "windows"): (1, "resting windows"),
    ("ui", "views"): (40, "resting views"),
    # Not tight: AppKit's own resting layer count is bistable (~101 and
    # ~350-356, moving both ways within a run with views pinned at 47), and
    # quiesce keeps the last width and style, so Sonic Cirrus can rest ~2,048.
    ("ui", "layers"): (2400, "resting layers"),
    ("app", "hostedUnits"): (4, "resting hosted units"),
    ("app", "renderRefusals"): (0, "resting render refusals"),
    **{("pending", key): (1, f"resting pending {key}") for key in PENDING_KEYS},
}


# The first sample alone is a peak (the opening decode and analyzers), and a
# peak baseline hides the leak it was meant to catch.
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


# Consecutive over-limit samples before a metric counts as growth rather than
# churn: mid-run, retiredFades swings as crossfades overlap and the footprint
# spikes past 350MB during a decode. Resting samples are rarer (one per
# --quiesce-every batches) and taken at a fixed idle state, so two suffice.
GROWTH_CONFIRMATIONS = 3
RESTING_CONFIRMATIONS = 2


# --ignore-metric keys. The run header prints them: a relaxed run must not
# read like a strict one.
IGNORED_METRICS = set()


def health_growth(baseline, current, streaks, limits=GROWTH_LIMITS,
                  confirmations=GROWTH_CONFIRMATIONS):
    """Messages for metrics over their limit for `confirmations` consecutive
    samples. streaks is caller-owned, one dict per scored series.
    """
    findings = []
    # The footprint counts only when the live heap also grew past its limit.
    # Alone it tracks the allocator's high-water mark and wanders both ways by
    # hundreds of MB (a resting series read 553, 494, 749, 606, 838 MB with
    # the live heap flat at 2.2 MB); a sanitizer's shadow memory inflates it
    # further. A real leak grows both.
    live_limit = limits.get(("process", "mallocLiveBytes"))
    live_was = baseline.get("process", {}).get("mallocLiveBytes")
    live_now = current.get("process", {}).get("mallocLiveBytes")
    live_grew = (live_limit is not None and live_was is not None and live_now is not None
                 and live_now - live_was > live_limit[0])

    for metric, (headroom, label) in limits.items():
        section, key = metric
        if key in IGNORED_METRICS:
            continue
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
    """Quiesce, sample at rest, score against the resting limits.

    Returns (failure_or_None, baseline). `settled: false` is itself a finding:
    work that did not unwind inside the app's deadline, named by counter.
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
    # Said once per run: it describes the allocator, not the sample.
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
              f"{health['app'].get('hostedUnits', '?')} units   pending {pending}")
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
    # Cleared: the directory is named after the seed, and a re-run's leftovers
    # would describe a different failure.
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    notes = [f"kind: {failure.kind}", f"detail: {failure.detail}"]
    if failure.op:
        notes.append(f"last op: {' '.join(failure.op)}")

    pid = app_pid()
    if failure.kind == "hang" and pid and shutil.which("sample"):
        target = out_dir / "sample.txt"
        subprocess.run(["sample", str(pid), "5", "-file", str(target)],
                       capture_output=True, text=True)
        notes.append(f"main-thread sample (pid {pid}): {target}")

    for report in fresh_crash_reports(since):
        shutil.copy2(report, out_dir / report.name)
        notes.append(f"crash report: {report.name}")

    if app_is_running():
        # The cloud trace is the only record of which transfer ran when and for
        # which role; the cloud.* checks name no files, and the trace dies
        # with the app.
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


def collect_themes(channel):
    """Every applicable theme id (View > Theme, so user themes too), and one
    real record to mutate from.

    The base record's fallback order is by fullness: a theme is a SPARSE
    record, Cupertino and Technical set every group, and Vibe is the empty
    record, whose mutation would fuzz one group per import.
    """
    ids, base = [], None
    code, payload, _ = channel.run(["dump_menu"], timeout=20)
    if code == 0 and payload:

        def walk(items):
            for item in items:
                identifier = item.get("id") or ""
                if identifier.startswith("view_theme_"):
                    ids.append(identifier[len("view_theme_"):])
                if item.get("items"):
                    walk(item["items"])

        walk(payload.get("menu", []))
    # The submenu fills only when opened, so dump_menu can miss it; the
    # built-ins guarantee something to apply.
    for built_in in ("vibe", "cupertino", "field", "glassy", "record_bin", "snake",
                     "sonic_cirrus", "tangerine", "technical"):
        if built_in not in ids:
            ids.append(built_in)
    for candidate in ("cupertino", "technical", "vibe"):
        code, payload, _ = channel.run(["dump_theme", candidate], timeout=20)
        if code == 0 and isinstance((payload or {}).get("theme"), dict):
            base = payload["theme"]
            break
    return ids, base


def collect_menu_ids(channel):
    code, payload, _ = channel.run(["dump_menu"], timeout=20)
    if code != 0 or not payload:
        raise ValueError("could not inspect the live menu; menu coverage is unknown")
    ids = []

    def walk(items):
        for item in items:
            identifier = item.get("id")
            # A submenu parent's AppKit-assigned submenuAction: reaches no
            # responder, so only its children are ops.
            has_submenu = "items" in item
            if (identifier and not has_submenu
                    and identifier in MENU_IDS):
                ids.append(identifier)
            if item.get("items"):
                walk(item["items"])

    walk(payload.get("menu", []))
    missing = MENU_IDS - set(ids)
    if missing:
        # FX items are absent when the chain is disabled; still named, so a
        # rename never silently erases coverage.
        print("WARNING: missing allowed menu IDs (not exercised): "
              + ", ".join(sorted(missing)), file=sys.stderr)
    return ids


def replay_ops(channel, ops, journal=None, check_every=0, stop_on_failure=True, stalls=None,
               imported_themes=None):
    """Run a list of (name, argv, tolerated) and return the failure, or None.

    stalls, when given, is {"dir", "count", "samples", "max"}: recoverable
    main-thread stalls are sampled and counted there instead of failing.

    imported_themes, when given, collects the `imported` identifier of every
    accepted import_theme reply, for teardown to remove. The reply is the
    authority: the store may rename, and a mutated record may carry no name.
    """
    # Whatever the batch did not deliver runs one op at a time from where the
    # reply stream stopped.
    for _, argv, _ in ops:
        require_command(argv)
    batched = {}
    if getattr(channel, "batch", False) and len(ops) > 1:
        budget = sum(VERB_TIMEOUTS.get(argv[0], 30) for _, argv, _ in ops)
        results = channel.run_batch([argv for _, argv, _ in ops], timeout=min(budget, 300))
        if results:
            batched = dict(enumerate(results))

    for i, (name, argv, tolerated) in enumerate(ops):
        if i in batched:
            code, payload = batched[i]
            elapsed = 0   # no round trip of its own
        else:
            code, payload, elapsed = channel.run(argv, timeout=VERB_TIMEOUTS.get(argv[0], 30))
        entry = {"i": i, "op": name, "argv": argv, "exit": code, "ms": elapsed}
        if (imported_themes is not None and argv[0] == "import_theme" and code == 0
                and isinstance(payload, dict) and payload.get("imported")
                and payload["imported"] not in imported_themes):
            imported_themes.append(payload["imported"])
        if tolerated:
            # Journaled so replay and shrink tolerate the same errors; otherwise
            # the shrinker minimizes any journal down to one benign refusal.
            entry["tolerated"] = tolerated
        if code == 1:
            pid = app_pid()
            if pid is None:
                entry["failure"] = "no response, app gone"
                if journal:
                    journal.write(json.dumps(entry) + "\n")
                    journal.flush()
                return Failure("crash", f"the app died on `{' '.join(argv)}`", argv)
            # Alive but silent. Sample before probing: a probe that succeeds
            # means any stall has ended and taken its stack with it.
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
            # A probe answering at the usual latency means the verb was slow
            # (file_cache on a big file), not main: only a slow probe counts.
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
            # One recovered stall is noise on a loaded machine; many are the bug.
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
            # A signal after the retries, or a usage error (64): never a pass.
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
    print(f"seed:   {seed}   (regenerate with --seed {seed}; --replay its journal for the exact ops)")

    started = time.time()
    launch(corpus, app)
    with user_settings_preserved(channel, corpus, app) as imported_themes:
        menu_ids = collect_menu_ids(channel)
        # Window restoration (NSQuitAlwaysKeepsWindows) reopens Settings if it was
        # open at quit: ~600 views in the baseline, or a false growth failure after
        # it. Close it before the first sample.
        channel.run(["settings_close"], timeout=20)
        themes, theme_base = collect_themes(channel)
        print(f"menu:   {len(menu_ids)} allowed app actions")
        print("input:  command-only (no pointer events, key events or activation)")
        print(f"settings: {describe_feature_settings(channel)}")
        base_name = 'from ' + str(theme_base.get('name')) if theme_base else 'UNAVAILABLE'
        print(f"themes: {len(themes)} applicable, base record {base_name}")
        if IGNORED_METRICS:
            print(f"RELAXED: not scoring {', '.join(sorted(IGNORED_METRICS))} "
                  f"— this run cannot report those")

        if args.profile == "cloud":
            # Armed before the first op, so the first batch's opens are downloads.
            # The 0.9s base sits above the player's 0.5s slow-open indicator delay,
            # so the loading UI is exercised; per-file times spread around it with
            # slow and stuck tails (VibeFakeCloud). capacity=1 is install's default
            # too, stated because the hold is unobservable without it (see
            # op_cloud_churn).
            code, payload, _ = channel.run(
                ["set_fake_cloud", "0.9", str(args.cloud_percent), "capacity=1"])
            if code != 0 or not (payload or {}).get("installed"):
                sys.exit("cloud profile: could not arm the fake provider "
                         f"(exit {code}, reply {payload}) — needs a Debug build")
            print(f"cloud:  fake provider armed, {payload['percent']}% of files cloudy, "
                  f"0.90s base with slow and stuck tails, {payload['capacity']} transfer slot")

        generator = OpGenerator(rng, files, playlists, dirs, menu_ids, args.profile,
                                themes=themes, theme_base=theme_base)
        journal_path = (Path(args.journal) if args.journal
                        else DEFAULT_OUTPUT_DIR / f"stress-{seed}.ndjson")
        # The health series, stall samples and failure directory all land here.
        journal_path.parent.mkdir(parents=True, exist_ok=True)
        stalls = {"dir": journal_path.parent / f"stress-{seed}-stalls", "count": 0,
                  "samples": 0, "max": args.max_stalls}
        health_samples = []
        growth_streaks = {}
        baseline = None
        # The quiesced series, scored against the tight resting limits.
        resting_samples = []
        resting_streaks = {}
        resting_baseline = None
        batches = 0
        failure = None
        interrupted = False
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

                    failure = replay_ops(channel, batch, journal=journal, stalls=stalls,
                                         imported_themes=imported_themes)
                    executed += len(batch)
                    if failure:
                        break

                    state = check_liveness(channel, since=started)
                    generator.note_state(state)

                    violations = check_consistency(channel)
                    if violations:
                        failure = Failure("consistency", "; ".join(
                            f"{v['id']}: {v['detail']}" for v in violations))
                        break

                    code, health, _ = channel.run(["dump_health"], timeout=20)
                    if code == 0 and health:
                        health["_ops"] = executed
                        # An open auxiliary window counts its subtree as views
                        # (Settings is ~600), failing the run on a window rather
                        # than a leak. No op opens Settings on purpose, so the
                        # note names the batch's ops to localize whatever did.
                        aux_views = (health.get("ui") or {}).get("views", 0)
                        if ((health.get("ui") or {}).get("visibleWindows", 1) > 1
                                and baseline is not None
                                and aux_views > baseline.get("ui", {}).get("views", 0) + 200):
                            journal.write(json.dumps({
                                "note": "auxiliary window open — closing",
                                "afterOp": executed,
                                "visibleWindows": health["ui"]["visibleWindows"],
                                "views": health["ui"].get("views"),
                                "recentOps": [o[0] for o in batch[-12:]],
                            }) + "\n")
                            journal.flush()
                            channel.run(["settings_close"], timeout=20)
                            code2, health2, _ = channel.run(["dump_health"], timeout=20)
                            if code2 == 0 and health2:
                                health = health2
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
                                  f"{health['app'].get('hostedUnits', '?')} units   "
                                  f"{health['process'].get('fileDescriptors', '?')} fds")

                    batches += 1
                    if args.quiesce_every and batches % args.quiesce_every == 0:
                        failure, resting_baseline = quiesced_checkpoint(
                            channel, resting_samples, resting_streaks, resting_baseline,
                            executed, args.verbose)
                        if failure:
                            break
                        # quiesce empties the playlist, and `ui` never opens one.
                        if files:
                            channel.run(["open", str(rng.choice(files))])

                    if deadline and time.time() > deadline:
                        print(f"  duration limit reached after {executed} ops")
                        break
            except Failure as caught:
                failure = caught
            except KeyboardInterrupt:
                interrupted = True

        if health_samples or resting_samples:
            samples_path = journal_path.with_suffix(".health.ndjson")
            combined = sorted(health_samples + resting_samples, key=lambda s: s["_ops"])
            samples_path.write_text("".join(json.dumps(s) + "\n" for s in combined))
            print(f"health: {samples_path} ({len(health_samples)} in-flight, "
                  f"{len(resting_samples)} at rest)")

        print(f"journal: {journal_path}")
        print(f"exercised: {describe_materialization_coverage(channel)}")
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

        if interrupted:
            # A killed run is not a pass: SIGTERM lands here too (see main).
            print(f"\nINTERRUPTED after {executed} ops, no violations so far")
            return 130
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
    for _, argv, _ in ops:
        require_command(argv)
    return ops


def reproduces(channel, corpus, app, ops, resting_mb=0, imported_themes=None):
    """Fresh app, replay ops, run the oracles. True if it still fails.

    resting_mb also counts an at-rest footprint above it as a failure, so a
    resource failure can be shrunk like a crash.
    """
    for _, argv, _ in ops:
        require_command(argv)
    launch(corpus, app)
    failure = replay_ops(channel, ops, imported_themes=imported_themes)
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

    ddmin over complements: split into n chunks and try dropping each; keep
    the first that still fails (n-1), otherwise double n. One relaunch per
    candidate, so a shrink takes minutes.
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
    launch(corpus, app)
    with user_settings_preserved(channel, corpus, app) as imported_themes:
        if not reproduces(channel, corpus, app, ops, resting_mb, imported_themes):
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
                if reproduces(channel, corpus, app, candidate, resting_mb,
                              imported_themes):
                    ops = candidate
                    n = max(2, n - 1)
                    reduced = True
                    break
            if not reduced:
                if n >= len(ops):
                    break
                n = min(len(ops), n * 2)

    out = Path(args.shrink).with_suffix(".min.txt")
    lines = []
    for _, argv, _ in ops:
        line = script_line(argv)
        if line is None:
            # Commented out so the script still runs; the repro is then not
            # exact, and says so.
            print(f"  warning: not expressible as a script line: {argv!r}")
            line = "# not expressible: " + json.dumps(argv)
        lines.append(line + "\n")
    out.write_text("".join(lines))
    print(f"\nminimal repro: {len(ops)} ops -> {out}")
    print("replay it with:")
    print(f"  .claude/skills/vibe-debug/scripts/run-script.sh /tmp/shots < {out}")
    return 0


def describe_materialization_coverage(channel) -> str:
    """What the run put through the loading path, pass or fail. A run with no
    handle opens covered none of it and would read like a pass; `NONE` says
    so, and is not a failure."""
    code, payload, _ = channel.run(["dump_health"], timeout=30)
    if code != 0 or not payload:
        return "unavailable (dump_health did not answer)"
    m = (payload or {}).get("materialization") or {}
    opens = m.get("handleOpensStarted", 0)
    ready = m.get("requestsReady", 0)
    refused = m.get("requestsAdmissionExhausted", 0)
    yielded = m.get("requestsYielded", 0)
    failed = m.get("requestsFailed", 0)
    parts = [f"{opens} handle opens" + (" [NONE — this run covered no stage 2]" if not opens else ""),
             f"{ready} requests ready",
             f"{failed} failed",
             f"{yielded} yielded",
             f"{refused} admission-refused"]
    # Not scored (a busy run has some), but a run where refusal dominates
    # mostly never did its work.
    if refused and ready and refused > ready:
        parts.append("WARN: more requests were refused than served")
    return ", ".join(parts)


def run_gesture_test(args):
    """One named gesture on an already running, isolated desktop app."""
    app = Path(args.app).expanduser().resolve() if args.app else DEFAULT_APP
    channel = Channel(app, verbose=args.verbose, gesture_test=args.gesture_test,
                      client_app=Path(args.client_app) if args.client_app else None)

    def command(argv):
        code, payload, _ = channel.run(argv)
        if code != 0 or not payload or payload.get("error"):
            raise ValueError(f"gesture test failed: {argv}: {payload}")
        return payload

    original = command(["dump_state"])
    shown = original["window"]["pitchPanelShown"]
    pitch = original["player"]["pitch"]
    try:
        if not shown:
            command(["toggle_pitch_panel"])
        command(["set_pitch", "3" if args.gesture_test == "pitch-reset" else "0"])
        reply = command(["gesture_test", args.gesture_test, "isolated-desktop"])
        if reply.get("hitView") != "PitchFaderView" or not reply.get("windowKey"):
            raise ValueError(f"gesture missed the named control: {reply}")
        deadline = time.monotonic() + 3
        while True:
            state = command(["dump_state"])
            value = state["player"]["pitch"]
            fader = state["ui"]["pitchFader"]
            changed = (abs(value) < 0.01 if args.gesture_test == "pitch-reset"
                       else 0.35 < value <= state["player"]["maxPitch"])
            if changed and abs(value - fader) < 0.01:
                print(f"PASSED {args.gesture_test}: player and fader pitch = {value}")
                return 0
            if time.monotonic() >= deadline:
                raise ValueError(f"gesture had no expected effect: player={value}, fader={fader}")
            time.sleep(0.05)
    finally:
        command(["set_pitch", str(pitch)])
        if command(["dump_state"])["window"]["pitchPanelShown"] != shown:
            command(["toggle_pitch_panel"])


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus",
                        help="directory of audio files to stress against")
    parser.add_argument("--gesture-test", choices=GESTURE_TESTS,
                        help="run one named gesture against the running app, outside stress/replay")
    parser.add_argument("--isolated-desktop", action="store_true",
                        help="assert the gesture test is on a dedicated test Mac or disposable VM")
    parser.add_argument("--app", help=f"path to Vibe.app (default {DEFAULT_APP})")
    parser.add_argument("--seed", type=int, help="seed the op generator (a run prints its own)")
    parser.add_argument("--iterations", type=int, default=2000, help="ops to run (default 2000)")
    parser.add_argument("--duration", type=float,
                        help="stop after this many seconds; --iterations still caps the "
                             "run, so raise both for a soak")
    parser.add_argument("--batch", type=int, default=25,
                        help="ops between oracle checks (default 25)")
    parser.add_argument("--quiesce-every", type=int, default=10,
                        help="batches between quiesced (at-rest) health samples, which "
                             "carry the tight growth limits; 0 disables (default 10)")
    parser.add_argument("--max-stalls", type=int, default=3,
                        help="recoverable main-thread stalls tolerated before failing "
                             "(default 3); each is sampled")
    parser.add_argument("--profile", default="base", choices=sorted(PROFILES),
                        help="op weighting (default base)")
    parser.add_argument("--cloud-percent", type=int, default=60,
                        help="cloud profile only: percent of files behaving as placeholders "
                             "(default 60; the local rest proves the cloud path has not "
                             "slowed them)")
    parser.add_argument("--client-app",
                        help="app bundle to run as the channel client instead of --app: a "
                             "plain client drives a sanitizer build at ~0.13s per op, not "
                             "~2.4s. Build both from the same source.")
    parser.add_argument("--no-batch", action="store_true",
                        help="one client process per op instead of per batch; slower, for "
                             "per-op timing")
    parser.add_argument("--journal",
                        help=f"NDJSON journal path (default {DEFAULT_OUTPUT_DIR}/"
                             "stress-<seed>.ndjson; the health series, stall samples and "
                             "failure directory land beside it)")
    parser.add_argument("--replay", help="replay a journal verbatim instead of generating ops")
    parser.add_argument("--shrink", help="delta-debug a failing journal to a minimal repro")
    parser.add_argument("--shrink-resting-mb", type=int, default=0,
                        help="with --shrink, also count an at-rest footprint above this "
                             "many MB as a reproduction")
    parser.add_argument("--ignore-metric", action="append", default=[],
                        metavar="NAME",
                        help="stop scoring one dump_health metric (fileDescriptors, "
                             "mallocLiveBytes, layers, ...), to stand down an ALREADY "
                             "diagnosed finding that masks what lies behind it. Repeatable; "
                             "printed in the run header.")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.gesture_test:
        if not args.isolated_desktop or args.replay or args.shrink:
            parser.error("--gesture-test requires --isolated-desktop and cannot replay or shrink")
        return run_gesture_test(args)
    if args.isolated_desktop:
        parser.error("--isolated-desktop is only for --gesture-test; it never unlocks raw input")
    if not args.corpus:
        parser.error("--corpus is required for stress, replay and shrink")
    IGNORED_METRICS.update(args.ignore_metric)

    signal.signal(signal.SIGINT, signal.default_int_handler)
    # Python's default for these exits without running a `finally`, so a
    # killed run (a timeout, `kill`, a closed terminal) would leave the user's
    # real settings and theme store as it moved them.
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    signal.signal(signal.SIGHUP, signal.default_int_handler)

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
        with user_settings_preserved(channel, corpus, app) as imported_themes:
            failure = replay_ops(channel, ops, check_every=args.batch,
                                 imported_themes=imported_themes)
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
    # stdout is usually redirected to a file, which Python block-buffers:
    # a soak's progress would stay invisible until it exits.
    sys.stdout.reconfigure(line_buffering=True)
    try:
        sys.exit(main())
    except ValueError as error:
        sys.exit(str(error))
