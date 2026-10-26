import argparse
import contextlib
import io
import json
import os
import random
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import stress  # noqa: E402


def generator(profile="base", corpus=Path("/corpus"), seed=7):
    files = [corpus / "album one" / "a track.flac", corpus / "b.wav"]
    return stress.OpGenerator(random.Random(seed), files, [], [corpus / "album one"],
                              sorted(stress.MENU_IDS), profile, corpus=corpus)


def health(ready=0, failed=0, completed=0, parses=0, lane=0, foreground=False,
           loading=False, running=0, holders=0):
    return {"pending": {"cloudParsesPending": parses, "cloudLaneHeld": lane,
                        "metadataHolders": holders},
            "app": {"playerLoading": loading},
            "materialization": {"requestsReady": ready, "requestsFailed": failed,
                                "handleOpensCompleted": completed,
                                "foregroundTransferActive": foreground,
                                "backgroundRunning": running}}


def state(count=10, resolved=4):
    return {"playlist": {"count": count, "resolvedRows": resolved}}


class CommandGateTests(unittest.TestCase):
    def test_new_verbs_pass_the_gate(self):
        for argv in (["open_url", "https://fake.vibe.test/a%20b.flac"],
                     ["open_url", "http://fake.local/b.wav"],
                     ["set_fake_http", "/corpus", "1.5"], ["set_fake_http", "off"],
                     ["fake_http_fault", "stall"], ["fake_http_fault", "off"],
                     ["set_slow_volume", "throttle", "65536"], ["set_slow_volume", "off"],
                     ["block_render", "1"], ["block_decoder", "1"], ["block_player", "1"],
                     ["settings_open", "audio"], ["dump_settings_ui"], ["settings_close"],
                     ["settings_click", "Show BPM", "toggle"], ["dump_equalizer"],
                     ["block_main", "0.1", "set_slow_volume", "off"]):
            with self.subTest(argv=argv):
                stress.require_command(argv)

    def test_raw_input_and_unsafe_arguments_stay_refused(self):
        for argv in (["click", "1", "2"], ["key", "q"], ["drag", "1", "2", "3", "4"],
                     ["block_main", "0.1", "mouse_down", "1", "2"],
                     ["settings_click", "Restore Defaults…"],
                     ["settings_click", "Restore Defaults…", "toggle"],
                     ["settings_click", "Bit-perfect output", "on"],
                     ["settings_click", "Convert menu", "on"],
                     ["settings_click", "Show BPM", "#3"],
                     ["settings_click", "search", "x"],
                     ["open_url", "https://example.com/a.mp3"],
                     ["open_url", "file:///etc/passwd"],
                     ["convert_to_flac", "keep"], ["settings_reveal", "Show BPM"]):
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                stress.require_command(argv)

    def test_every_settings_switch_has_a_gated_restorer(self):
        before = {key: True for _, _, key in stress.SETTINGS_SWITCHES}
        for pane, _, key in stress.SETTINGS_SWITCHES:
            with self.subTest(key=key):
                self.assertIn(pane, stress.SETTINGS_PANES)
                commands = stress.SETTING_RESTORERS[key](before)
                for argv in commands if isinstance(commands[0], list) else [commands]:
                    stress.require_command(argv)

    def test_switch_parents_are_switches_and_children_restore_first(self):
        keys = [key for _, _, key in stress.SETTINGS_SWITCHES]
        order = list(stress.SETTING_RESTORERS)
        for child, parents in stress.SETTINGS_PARENTS.items():
            self.assertIn(child, keys)
            for parent in parents:
                self.assertIn(parent, keys)
                self.assertLess(order.index(child), order.index(parent))

    def test_an_interrupted_settings_op_is_restored_despite_the_disabled_child(self):
        # The op flipped Show file info on and Show BPM off, then the run
        # ended before the unflips. The pane refuses a click on Show BPM
        # while Show file info is off, as the app does.
        before = {"showFileInfo": False, "showBPM": True, "windowFrame": None}
        store = {"showFileInfo": True, "showBPM": False, "windowFrame": None}
        names = {name: key for _, name, key in stress.SETTINGS_SWITCHES}

        def run(argv, **_):
            if argv[0] == "settings_click":
                key = names[argv[1]]
                parents = stress.SETTINGS_PARENTS.get(key, ())
                if not all(store[parent] for parent in parents if parent in store):
                    return 2, {"error": f"'{argv[1]}' is disabled"}, 0
                store[key] = argv[2] == "on"
            return 0, {}, 0
        channel = mock.Mock()
        channel.run.side_effect = run
        with mock.patch.object(stress, "app_pid", return_value=1), \
                mock.patch.object(stress, "current_settings", side_effect=lambda _: dict(store)), \
                contextlib.redirect_stdout(io.StringIO()):
            stress.user_settings_restore(channel, before, [], Path("c"), Path("a"))
        self.assertEqual(store, before)

    def test_launch_pins_the_app_to_english_unless_told_otherwise(self):
        envs = []
        with mock.patch.object(stress.subprocess, "run",
                               side_effect=lambda argv, **kw: envs.append(kw["env"]) or mock.Mock(returncode=0, stderr="")), \
                mock.patch.object(stress, "assert_running_binary"), \
                mock.patch.dict(stress.os.environ, {}, clear=False):
            stress.os.environ.pop("VIBE_LANGUAGE", None)
            stress.launch(Path("/c"), Path("/a"))
            stress.os.environ["VIBE_LANGUAGE"] = "de"
            stress.launch(Path("/c"), Path("/a"))
        self.assertEqual([env["VIBE_LANGUAGE"] for env in envs], ["en", "de"])

    def test_teardown_runs_multi_command_restorers_and_disarms(self):
        sent = []
        before = {"showBPM": True, "windowFrame": None}
        after = {"showBPM": False, "windowFrame": None}
        snapshots = iter([after, after, before, before])
        channel = mock.Mock()
        channel.run.side_effect = lambda argv, **_: sent.append(argv) or (0, {}, 0)
        with mock.patch.object(stress, "app_pid", return_value=1), \
                mock.patch.object(stress, "current_settings", side_effect=lambda _: next(snapshots)), \
                contextlib.redirect_stdout(io.StringIO()):
            stress.user_settings_restore(channel, before, [], Path("c"), Path("a"))
        for argv in stress.DISARM_COMMANDS:
            self.assertIn(list(argv), sent)
        self.assertIn(["settings_open", "appearance"], sent)
        self.assertIn(["settings_click", "Show BPM", "on"], sent)
        self.assertEqual(sent[-1], ["settings_close"])


class NewOperationTests(unittest.TestCase):
    def test_link_serves_the_corpus_and_clears_its_fault(self):
        gen = generator()
        for _ in range(60):
            ops = gen.op_link()
            argvs = [argv for _, argv, _ in ops]
            self.assertEqual(argvs[0][:2], ["set_fake_http", "/corpus"])
            url = next(argv[1] for argv in argvs if argv[0] == "open_url")
            self.assertTrue(url.startswith(stress.FAKE_HTTP_HOSTS))
            self.assertNotIn(" ", url)
            if any(argv[0] == "fake_http_fault" and argv[1] != "off" for argv in argvs):
                self.assertEqual(argvs[-1], ["fake_http_fault", "off"])
            for argv in argvs:
                stress.require_command(argv)

    def test_slow_volume_opens_under_the_fault_then_clears_it(self):
        gen = generator()
        for _ in range(30):
            argvs = [argv for _, argv, _ in gen.op_slow_volume()]
            self.assertEqual(argvs[0][0], "set_slow_volume")
            self.assertNotEqual(argvs[0][1], "off")
            self.assertEqual(argvs[1][0], "open")
            self.assertEqual(argvs[-1], ["set_slow_volume", "off"])

    def test_stall_stays_within_each_verbs_range_and_probes(self):
        gen = generator()
        for _ in range(60):
            argvs = [argv for _, argv, _ in gen.op_stall()]
            verb, seconds = argvs[0][0], float(argvs[0][1])
            self.assertTrue(0 < seconds <= stress.STALL_LIMITS[verb])
            self.assertEqual(argvs[1], ["dump_state"])
            self.assertEqual(argvs[-1], ["dump_state"])

    def test_settings_flips_each_switch_back(self):
        gen = generator()
        for _ in range(60):
            argvs = [argv for _, argv, _ in gen.op_settings()]
            self.assertEqual(argvs[0][0], "settings_open")
            clicks = [argv[1] for argv in argvs if argv[0] == "settings_click"]
            self.assertEqual(clicks, clicks[::-1])
            self.assertTrue(all(argv[2] == "toggle" for argv in argvs
                                if argv[0] == "settings_click"))
            # A switch under a parent the op switched off is refused as disabled.
            self.assertTrue(all({"is hidden", "is disabled"} <= set(tolerated)
                                for _, argv, tolerated in gen.op_settings() if argv[0] == "settings_click"))
            for argv in argvs:
                stress.require_command(argv)

    def test_profiles_weight_each_new_op_where_it_belongs(self):
        weights = {profile: stress.effective_weights(profile) for profile in stress.PROFILES}
        self.assertGreater(weights["base"]["link"], 0)
        for profile in ("loading", "hammer"):
            self.assertGreater(weights[profile]["slow_volume"], 0)
            self.assertGreater(weights[profile]["stall"], 0)
        self.assertGreater(weights["ui"]["settings"], 0)
        self.assertEqual(weights["ui"]["link"], 0)
        self.assertEqual(weights["cloud"]["link"], 0)
        self.assertEqual(weights["base"]["settings"], 0)


class DeadOpTests(unittest.TestCase):
    def test_warns_for_weighted_kinds_that_never_did_their_work(self):
        entries = [
            {"op": "link", "argv": ["set_fake_http", "/c"], "exit": 0},
            {"op": "link", "argv": ["open_url", "https://fake.vibe.test/a"], "exit": 0,
             "replyOk": False},
            {"op": "stall", "argv": ["block_render", "1"], "exit": 0},
            {"op": "slow_volume", "argv": ["set_slow_volume", "off"], "exit": 0},
            {"op": "settings", "argv": ["settings_click", "Show BPM", "toggle"], "exit": 2},
        ]
        weights = {"link": 2, "stall": 3, "slow_volume": 4, "settings": 1}
        warnings = "\n".join(stress.dead_op_warnings(entries, weights))
        for kind in ("link", "slow_volume", "settings"):
            self.assertIn(f"`{kind}`", warnings)
        self.assertNotIn("`stall`", warnings)
        self.assertEqual(stress.dead_op_warnings(entries, {"stall": 1}), [])

    def test_unweighted_kinds_are_not_warned(self):
        self.assertEqual(stress.dead_op_warnings([], {"link": 0}), [])


class ProgressOracleTests(unittest.TestCase):
    def samples(self, readings):
        return [stress.progress_sample(s, h) for s, h in readings]

    def test_flat_progress_with_demand_and_no_gate_is_stalled(self):
        readings = [(state(), health(ready=5))] * stress.PROGRESS_WINDOW
        self.assertIn("work stopped", stress.progress_stalled(self.samples(readings)))

    def test_fewer_samples_than_the_window_are_not_scored(self):
        readings = [(state(), health(ready=5))] * (stress.PROGRESS_WINDOW - 1)
        self.assertIsNone(stress.progress_stalled(self.samples(readings)))

    def test_any_movement_in_the_window_is_progress(self):
        for moved in (health(ready=6), health(ready=5, failed=1), health(ready=5, completed=1),
                      health(ready=5, parses=1)):
            readings = [(state(), health(ready=5))] * (stress.PROGRESS_WINDOW - 1) + [(state(), moved)]
            with self.subTest(moved=moved):
                self.assertIsNone(stress.progress_stalled(self.samples(readings)))
        readings = [(state(), health(ready=5))] * (stress.PROGRESS_WINDOW - 1) + [(state(resolved=5), health(ready=5))]
        self.assertIsNone(stress.progress_stalled(self.samples(readings)))

    def test_a_gate_excuses_the_window(self):
        for gated in (health(ready=5, foreground=True), health(ready=5, lane=1),
                      health(ready=5, loading=True), health(ready=5, running=1),
                      health(ready=5, holders=1)):
            readings = [(state(), health(ready=5))] * (stress.PROGRESS_WINDOW - 1) + [(state(), gated)]
            with self.subTest(gated=gated):
                self.assertIsNone(stress.progress_stalled(self.samples(readings)))

    def test_no_demand_is_not_scored(self):
        readings = [(state(resolved=10), health(ready=5))] * stress.PROGRESS_WINDOW
        self.assertIsNone(stress.progress_stalled(self.samples(readings)))
        readings = [(state(resolved=10), health(ready=5, parses=2))] * stress.PROGRESS_WINDOW
        self.assertIsNotNone(stress.progress_stalled(self.samples(readings)))


def play(position, url="/c/tone.wav", status="playing", buffering=False):
    return {"player": {"state": status, "position": position, "buffering": buffering},
            "currentTrack": {"url": url}}


def meter(publications, bands=(0.2, 0.1, 0, 0, 0), links=1, enabled=True):
    return {"levelsEnabled": enabled, "bands": list(bands),
            "audio": {"publications": publications}, "renderer": {"activeDisplayLinks": links}}


class EqualizerTests(unittest.TestCase):
    def test_reference_skips_names_that_may_be_silent(self):
        files = [Path("/c/silence.wav"), Path("/c/impulse.wav"), Path("/c/notes.txt"),
                 Path("/c/sweep.wav"), Path("/c/1000.wav")]
        self.assertEqual(stress.equalizer_reference(files), Path("/c/1000.wav"))
        self.assertIsNone(stress.equalizer_reference([Path("/c/silence.wav")]))

    def test_a_healthy_pair_scores_clean(self):
        self.assertEqual(stress.equalizer_finding(play(1.0), meter(10), play(1.8), meter(30)),
                         (True, None))

    def test_unscored_outside_the_defined_conditions(self):
        for pair in ((play(1.0, status="paused"), meter(10), play(1.8), meter(30)),
                     (play(1.0, buffering=True), meter(10), play(1.8), meter(30)),
                     (play(1.0), meter(10, links=0), play(1.8), meter(30)),
                     (play(1.0), meter(10, enabled=False), play(1.8), meter(30)),
                     (play(1.0), meter(10), play(1.8, url="/c/other.wav"), meter(30)),
                     (play(1.0), None, play(1.8), meter(30))):
            with self.subTest(pair=pair):
                self.assertEqual(stress.equalizer_finding(*pair), (False, None))

    def test_a_restart_between_the_samples_is_movement(self):
        # Repeat One wrapping a short reference: the same file, a smaller position.
        self.assertEqual(stress.equalizer_finding(play(2.6), meter(10), play(0.3), meter(30)),
                         (True, None))

    def test_findings(self):
        scored, finding = stress.equalizer_finding(play(1.0), meter(10), play(1.0), meter(30))
        self.assertTrue(scored)
        self.assertIn("position held", finding)
        _, finding = stress.equalizer_finding(play(1.0), meter(10), play(1.8), meter(10))
        self.assertIn("stopped publishing", finding)
        _, finding = stress.equalizer_finding(play(1.0), meter(10, bands=(0,) * 5),
                                              play(1.8), meter(30, bands=(0,) * 5))
        self.assertIn("zero bands", finding)


class SlopeTests(unittest.TestCase):
    MB = 1024 * 1024

    def series(self, heap=None, views=None, ports=None, n=12):
        heap = heap or [40 * self.MB] * n
        views = views or [300] * n
        ports = ports or [900] * n
        return [{"process": {"mallocLiveBytes": h, "machPorts": p}, "ui": {"views": v}}
                for h, v, p in zip(heap, views, ports)]

    def test_flat_and_noisy_series_pass(self):
        rng = random.Random(3)
        noisy = [40 * self.MB + rng.randint(-3 * self.MB, 3 * self.MB) for _ in range(12)]
        self.assertEqual(stress.resting_slope_findings(self.series(heap=noisy)), [])

    def test_a_steady_leak_fails_on_each_metric(self):
        findings = stress.resting_slope_findings(self.series(
            heap=[40 * self.MB + i * 2 * self.MB for i in range(12)],
            views=[300 + i for i in range(12)],
            ports=[900 + 8 * i for i in range(12)]))
        self.assertEqual(len(findings), 3, findings)
        self.assertTrue(any("resting mach ports" in f for f in findings))

    def test_one_bounded_step_is_not_a_slope(self):
        views = [300] * 6 + [330] * 6
        self.assertEqual(stress.resting_slope_findings(self.series(views=views)), [])

    def test_growth_under_the_floor_or_too_few_samples_is_not_scored(self):
        self.assertEqual(stress.resting_slope_findings(self.series(views=[300 + i for i in range(5)], n=5)), [])
        slow = [900 + i for i in range(12)]   # 11 ports in all, under the floor
        self.assertEqual(stress.resting_slope_findings(self.series(ports=slow)), [])

    def test_rates_are_the_resting_limits_over_a_long_run(self):
        for metric, (rate, floor, _) in stress.SLOPE_LIMITS.items():
            limit = stress.RESTING_GROWTH_LIMITS[metric][0]
            self.assertAlmostEqual(rate * stress.LONG_RUN_RESTING_SAMPLES, limit)
            self.assertAlmostEqual(floor * 8, limit)

    def test_ignored_metric_is_not_scored(self):
        with mock.patch.object(stress, "IGNORED_METRICS", {"machPorts"}):
            findings = stress.resting_slope_findings(self.series(ports=[900 + 8 * i for i in range(12)]))
        self.assertEqual(findings, [])


class PurgatoryTests(unittest.TestCase):
    LISTING = """
    COUNT      BYTES       AVG   CLASS_NAME                 TYPE    BINARY
    =====      =====       ===   ==========                 ====    ======
       96      23040     240.0   PlaylistRowView            ObjC    Vibe
       12       1152      96.0   PlaylistRowViewHelper      ObjC    Vibe
"""

    def test_names_the_known_cause_with_heap_evidence(self):
        note = stress.purgatory_note("playlist", "at rest: resting mach ports grew", lambda: self.LISTING)
        self.assertIn("96 PlaylistRowView", note)

    def test_absent_row_views_say_it_is_new(self):
        note = stress.purgatory_note("playlist", "resting mach ports grew", lambda: "   1 2 3 NSView ObjC AppKit")
        self.assertIn("NOT the known", note)

    def test_unreadable_heap_names_the_suspect(self):
        self.assertIn("suspected cause", stress.purgatory_note("playlist", "resting mach ports", lambda: None))

    def test_other_profiles_and_metrics_get_no_note_and_no_heap_read(self):
        def unread():
            raise AssertionError("heap read for a failure of another shape")
        self.assertIsNone(stress.purgatory_note("base", "resting mach ports", unread))
        self.assertIsNone(stress.purgatory_note("playlist", "resting views", unread))


class CrashReportTests(unittest.TestCase):
    def test_only_the_named_process_reports_since_the_run(self):
        names = ("Vibe-2026-10-26-131617.ips", "Vibe-ab12-2026-10-26-131617.ips",
                 "Vibe-2026-2026-10-26-131617.ips", "Vibe_2026-10-26-131617_host.cpu_resource.diag",
                 "Vibe-ab12-2025-01-01-000000.ips")
        with tempfile.TemporaryDirectory() as directory:
            reports = Path(directory)
            for name in names:
                (reports / name).write_text("")
            old = reports / names[-1]
            os.utime(old, (old.stat().st_mtime - 3600,) * 2)
            with mock.patch.object(stress, "CRASH_DIR", reports):
                found = {product: sorted(p.name for p in stress.fresh_crash_reports(
                             old.stat().st_mtime + 1, product))
                         for product in ("Vibe", "Vibe-ab12", "Vibe-2026")}
        self.assertEqual(found, {"Vibe": [names[0], names[3]], "Vibe-ab12": [names[1]],
                                 "Vibe-2026": [names[2]]})


class TsanReplayTests(unittest.TestCase):
    REPORT = """==================
WARNING: ThreadSanitizer: data race (pid=4242)
  Write of size 8 at 0x7b0400001234 by thread T3:
    #0 -[AudioPlayer setPosition:] (Vibe:arm64+0x1000)
    #1 __dispatch_call_block (libdispatch.dylib:arm64+0x2000)

  Previous read of size 8 at 0x7b0400001234 by main thread:
    #0 -[AudioPlayer position] (Vibe:arm64+0x1100)

==================
==================
WARNING: ThreadSanitizer: heap-use-after-free (pid=4242)
    #0 VibeLevelMeterRender (Vibe:arm64+0x3000)
==================
"""

    def test_first_stack_of_each_report(self):
        reports = stress.tsan_first_stacks(self.REPORT)
        self.assertEqual(len(reports), 2)
        self.assertIn("data race", reports[0][0])
        self.assertEqual(len(reports[0][1]), 2)
        self.assertTrue(reports[0][1][0].startswith("#0 -[AudioPlayer setPosition:]"))
        self.assertEqual(reports[1][1], ["#0 VibeLevelMeterRender (Vibe:arm64+0x3000)"])

    def test_options_follow_the_sandbox_rules_in_the_apps_own_container(self):
        container = "/Users/u/Library/Containers/com.commonwealthrecordings.Vibe-ab12"
        with mock.patch.object(stress, "vibe_env", return_value=container) as env:
            options, logs = stress.tsan_options(Path("/apps/Vibe-ab12.app"))
        env.assert_called_once_with("VIBE_CONTAINER", Path("/apps/Vibe-ab12.app"))
        self.assertEqual(logs, Path(container) / "Data/tmp")
        self.assertIn(f"log_path={logs}/tsan:", options)
        self.assertIn("external_symbolizer_path=:", options)
        self.assertNotIn("suppressions", options)

    def run_tsan(self, replay, logs):
        args = mock.Mock(app="/apps/Vibe-tsan.app", tsan_replay="run.ndjson")
        with mock.patch.object(stress.subprocess, "run") as process, \
                mock.patch.object(stress, "replay", side_effect=replay), \
                mock.patch.object(stress, "app_pid", return_value=None), \
                mock.patch.object(stress, "tsan_options", return_value=("options", logs)), \
                contextlib.redirect_stdout(io.StringIO()):
            try:
                return stress.tsan_replay(args), process
            except KeyboardInterrupt:
                return None, process

    def test_options_are_unset_on_every_exit(self):
        def interrupted(*_):
            raise KeyboardInterrupt

        with tempfile.TemporaryDirectory() as directory:
            for replay in (lambda *_: 0, interrupted):
                result, process = self.run_tsan(replay, Path(directory))
                calls = [call.args[0] for call in process.call_args_list]
                self.assertEqual(calls[0][:3], ["launchctl", "setenv", "TSAN_OPTIONS"])
                self.assertEqual(calls[-1], ["launchctl", "unsetenv", "TSAN_OPTIONS"])

    def test_a_report_written_during_the_run_fails_it(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)

            def write_report(*_):
                (logs / "tsan.4242").write_text(self.REPORT)
                return 0

            result, _ = self.run_tsan(write_report, logs)
            self.assertEqual(result, 1)
            result, _ = self.run_tsan(lambda *_: 0, Path(directory) / "none")
            self.assertEqual(result, 0)


IOS_LAYOUT = {
    "": (["z album"], ["a1 tone-long.wav", "b bpm-120.wav"]),
    "z album": (["deeper"], ["key-am.wav", "tone-art-green.mp3"]),
    "z album/deeper": ([], ["tone.flac"]),
    "empty": ([], []),
}
IOS_CORPUS = Path("/sim/Documents/Music")


def ios_run(seed, favorites=(), dropbox=None, hits=2, count=3, index=1):
    """A run namespace that records each performed step and answers reads."""
    steps = []
    search = {"sections": [{"rows": []}, {"rows": [{"text": "x"}] * hits}, {"rows": []}]}
    starred = [str(IOS_CORPUS / p) for p in favorites]
    opened = []

    def perform(step):
        stress.ios_validate_step(step)
        steps.append(step)
        argv = step.get("command", [""])
        if argv[0] == "open":
            opened.append(str(IOS_CORPUS / argv[1].removeprefix("$CORPUS").lstrip("/")))
        elif argv[0] == "tap_favorite_star":
            # The star toggles the open folder, as the app's does.
            (starred.remove if opened[-1] in starred else starred.append)(opened[-1])
        return search if argv[0] == "search" else {"ok": True}

    def read(argv):
        return {"dump_state": {"playlist": {"count": count, "currentIndex": index}},
                "dump_favorites": {"favorites": [{"path": p} for p in starred]},
                "dump_dropbox": dropbox or {"linked": False, "fake": False}}[argv[0]]

    return random.Random(seed), mock.Mock(perform=perform, read=read, corpus=IOS_CORPUS,
                                          layout=IOS_LAYOUT), steps


def commands(steps):
    return [step["command"] for step in steps if "command" in step]


class IosOperationTests(unittest.TestCase):
    def test_the_table_is_whole(self):
        self.assertTrue(all(callable(getattr(stress, f"ios_op_{kind}", None)) for kind in stress.IOS_WEIGHTS))
        self.assertEqual(set(stress.IOS_OP_PROOFS),
                         set(stress.IOS_WEIGHTS) - {"transport", "burst", "fx"})
        self.assertTrue(all(stress.IOS_WEIGHTS[kind] > 0 for kind in stress.IOS_OP_PROOFS))

    def test_every_op_passes_the_gate_and_emits_its_proof_verb(self):
        for kind in stress.IOS_WEIGHTS:
            op = getattr(stress, f"ios_op_{kind}")
            verbs = set()
            for seed in range(40):
                rng, run, steps = ios_run(seed)
                op(rng, run)   # ios_run's perform gates every step
                verbs |= {argv[0] for argv in commands(steps)}
            with self.subTest(kind=kind):
                self.assertTrue(verbs)
                self.assertTrue(stress.IOS_OP_PROOFS.get(kind, verbs) & verbs)

    def test_tab_selects_known_tabs(self):
        for seed in range(30):
            rng, run, steps = ios_run(seed)
            stress.ios_op_tab(rng, run)
            tabs = [argv[1] for argv in commands(steps) if argv[0] == "select_tab"]
            self.assertTrue(1 <= len(tabs) <= 3)

    def test_card_reads_anchors_at_rest_around_a_track_change(self):
        for seed in range(30):
            rng, run, steps = ios_run(seed)
            stress.ios_op_card(rng, run)
            shape = [step.get("check") or step["command"][0] for step in steps]
            self.assertEqual(shape[:2], ["minimize_player", "anchors"])
            self.assertEqual(shape[4:6], ["minimize_player", "anchors"])
            self.assertIn(shape[3], ("next", "previous", "play_index"))

    def test_browse_taps_only_listed_names_and_never_backs_past_its_show(self):
        for seed in range(80):
            rng, run, steps = ios_run(seed)
            stress.ios_op_browse(rng, run)
            argvs = commands(steps)
            self.assertEqual(argvs[:2], [["minimize_player"], ["select_tab", "files"]])
            shown = argvs[2][2].removeprefix("$CORPUS").lstrip("/")
            path = [shown]
            for argv in argvs[3:]:
                folders, files = IOS_LAYOUT[path[-1]]
                if argv[1] == "back":
                    path.pop()
                    self.assertTrue(path)
                elif argv[1] == "tap" and argv[2] in folders:
                    path.append(f"{path[-1]}/{argv[2]}".lstrip("/"))
                else:
                    self.assertTrue(argv[1] == "play" or argv[2] in files)
                    self.assertTrue(files)

    def test_search_checks_no_match_then_opens_a_listed_hit_and_clears(self):
        for seed in range(30):
            rng, run, steps = ios_run(seed, hits=3)
            stress.ios_op_search(rng, run)
            argvs = commands(steps)
            self.assertEqual(argvs[2], ["search", stress.IOS_NO_MATCH])
            self.assertTrue(int(argvs[4][1]) < 3)
            self.assertEqual(argvs[-1], ["search"])

    def test_search_queries_fit_the_gate_whatever_the_corpus_names(self):
        # A 33-letter token would make the run abort at its own validator.
        for seed in range(10):
            rng, run, steps = ios_run(seed)
            run.layout = {"": ([], ["x" * 33 + " and-another.wav"])}
            stress.ios_op_search(rng, run)
            queries = [argv[1] for argv in commands(steps)
                       if argv[0] == "search" and len(argv) == 2 and argv[1] != stress.IOS_NO_MATCH]
            self.assertTrue(queries)
            self.assertTrue(all(len(query) <= 32 for query in queries))
        rng, run, steps = ios_run(0, hits=0)
        stress.ios_op_search(rng, run)
        self.assertNotIn("open_search_hit", [argv[0] for argv in commands(steps)])

    def test_favorite_stars_opens_and_unstars_but_leaves_a_users_folder(self):
        rng, run, steps = ios_run(3)
        stress.ios_op_favorite(rng, run)
        verbs = [argv[0] for argv in commands(steps)]
        self.assertEqual(verbs, ["open", "tap_favorite_star", "select_tab",
                                 "open_favorite", "tap_favorite_star"])
        for seed in range(20):
            rng, run, steps = ios_run(seed, favorites=["", "z album", "z album/deeper"])
            stress.ios_op_favorite(rng, run)
            self.assertEqual(steps, [])

    def test_route_plays_then_draws_each_kind(self):
        for seed in range(30):
            rng, run, steps = ios_run(seed)
            stress.ios_op_route(rng, run)
            argvs = commands(steps)
            self.assertEqual(argvs[0][0], "play_index")
            self.assertTrue(all(argv[0] == "set_output_route" for argv in argvs[1:]))

    def test_page_moves_to_adjacent_rows_under_the_card(self):
        for seed in range(30):
            rng, run, steps = ios_run(seed, count=4, index=0)
            stress.ios_op_page(rng, run)
            argvs = commands(steps)
            self.assertEqual(argvs[0], ["expand_player"])
            rows = [0] + [int(argv[1]) for argv in argvs[1:]]
            for a, b in zip(rows, rows[1:]):
                self.assertIn((b - a) % 4, (1, 3))
            self.assertEqual(steps[-1], {"check": "progress"})

    def test_fake_dropbox_browses_the_account_clears_its_fault_and_spares_a_real_one(self):
        for seed in range(40):
            rng, run, steps = ios_run(seed)
            stress.ios_op_fake_dropbox(rng, run)
            argvs = commands(steps)
            self.assertEqual(argvs[0][:2], ["set_fake_dropbox", "$CORPUS"])
            self.assertTrue(any(argv[:2] == ["browse", "show"] and argv[2].startswith("$DROPBOX")
                                for argv in argvs))
            if any(argv[0] == "fake_dropbox_fault" for argv in argvs):
                self.assertEqual(argvs[-1], ["fake_dropbox_fault", "clear"])
        rng, run, steps = ios_run(0, dropbox={"linked": True, "fake": False})
        stress.ios_op_fake_dropbox(rng, run)
        self.assertEqual(steps, [])

    def test_link_never_stalls_clears_its_fault_and_takes_a_sheet_road_only_unfaulted(self):
        roads = set()
        for seed in range(60):
            rng, run, steps = ios_run(seed)
            stress.ios_op_link(rng, run)
            argvs = commands(steps)
            verbs = [argv[0] for argv in argvs]
            self.assertNotIn(["fake_http_fault", "stall"], argvs)
            roads |= set(verbs) & {"open_url", "open_url_sheet", "paste_link"}
            if "fake_http_fault" in verbs:
                self.assertEqual(argvs[-1], ["fake_http_fault", "off"])
                self.assertIn("open_url", verbs)
            if "open_url_sheet" in verbs:
                self.assertEqual([argv[1] for argv in argvs if argv[0] == "open_url_sheet"],
                                 ["show", "type", "open"])
        self.assertEqual(roads, {"open_url", "open_url_sheet", "paste_link"})


class IosGateTests(unittest.TestCase):
    def test_refuses_escapes_other_hosts_stalls_and_input(self):
        for argv in (["open", "$CORPUS/../etc"], ["open", "/etc"], ["open", "$CORPUS/"],
                     ["browse", "show", "$CORPUS/a/../.."], ["browse", "tap", "a/b"],
                     ["browse", "tap", ".."], ["select_tab", "settings"],
                     ["set_output_route", "airplay", "Kitchen"], ["search", "a b"],
                     ["set_fake_dropbox", "/tmp", "1"], ["fake_dropbox_fault", "stall"],
                     ["fake_http_fault", "stall"], ["open_url", "https://example.com/a.mp3"],
                     ["open_url", "https://fake.vibe.test/%2E%2E/x"], ["add_search_folder", "/"],
                     ["paste_link", "https://example.com/a.mp3"], ["open_url_sheet", "paste", "x"],
                     ["open_url_sheet", "type", "https://example.com/a.mp3"],
                     ["open_url", "https://fake.vibe.test/a", "extra"],
                     ["tap", "1", "2"], ["drag", "1", "2", "3", "4"], ["set_clipboard", "x"]):
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                stress.ios_validate_step({"command": argv})

    def test_new_checks_pass(self):
        for check in ("anchors", "pending"):
            stress.ios_validate_step({"check": check})

    def test_anchor_shift_names_what_moved(self):
        rest = {"tabBar": [0, 791, 402, 83], "strip": [21, 735, 360, 48],
                "tabsSafeAreaInsets": [62, 0, 34, 0], "navigationBar": [0, 62, 402, 106]}
        self.assertEqual(stress.ios_anchor_shift(rest, {**rest, "navigationBar": [0, 62, 402, 54]}), [])
        self.assertEqual(stress.ios_anchor_shift(rest, {**rest, "tabsSafeAreaInsets": [62, 0, 0, 0]}),
                         ["tabsSafeAreaInsets"])

    def test_pending_holdouts_name_each_counter(self):
        self.assertEqual(stress.ios_pending_holdouts(
            {"cloudParsesPending": 0, "cloudLaneHeld": 0, "materialization": {"claims": 0}}), [])
        self.assertEqual(stress.ios_pending_holdouts(
            {"cloudParsesPending": 2, "cloudLaneHeld": 0, "materialization": {"waiters": 1}}),
            ["cloudParsesPending=2", "materialization.waiters=1"])

    def test_layout_lists_folders_and_playable_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "album" / ".hidden").mkdir(parents=True)
            (root / "album" / "a.flac").write_bytes(b"")
            (root / "notes.txt").write_text("")
            (root / ".DS_Store").write_text("")
            layout = stress.ios_corpus_layout(root)
        self.assertEqual(layout, {"": (["album"], []), "album": ([], ["a.flac"])})

    def test_landed_needs_every_row_inside_the_folder(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "a.wav").write_bytes(b"")
            (root / "b.wav").write_bytes(b"")
            state = {"currentTrack": {"url": str(root / "a.wav")},
                     "playlist": {"files": ["a.wav", "b.wav"]}}
            self.assertTrue(stress.ios_landed(state, root))
            self.assertFalse(stress.ios_landed({**state, "playlist": {"files": ["c.wav"]}}, root))
            self.assertFalse(stress.ios_landed({**state, "currentTrack": None}, root))


def ios_command_stub(replies, sent):
    def command(argv):
        sent.append(argv)
        reply = replies.get(argv[0], {"ok": True})
        return reply(argv) if callable(reply) else reply
    return command


class IosRestorerTests(unittest.TestCase):
    def before(self, **extra):
        return {"ui": {"selectedTab": "files", "playerPresentation": "minimized"},
                "settings": {"repeatMode": "off", "shuffleEnabled": False, "pauseAtTrackEnd": False},
                "favorites": [], "dropbox": {"fake": False}, "recents": ["/a"], **extra}

    def test_fakes_disarm_only_what_the_run_armed(self):
        sent = []
        stress.ios_restore_fakes(ios_command_stub({"dump_dropbox": {"fake": True}}, sent), self.before(), 1)
        self.assertIn(["set_fake_dropbox", "off"], sent)
        self.assertIn(["set_fake_http", "off"], sent)
        sent = []
        stress.ios_restore_fakes(ios_command_stub({"dump_dropbox": {"fake": True}}, sent),
                                 self.before(dropbox={"fake": True}), 1)
        self.assertNotIn(["set_fake_dropbox", "off"], sent)

    def test_favorites_unstar_what_the_run_added_and_report_a_loss(self):
        with tempfile.TemporaryDirectory() as directory:
            added, kept, lost = (Path(directory) / name for name in ("added", "kept", "lost"))
            for folder in (added, kept, lost):
                folder.mkdir()
                (folder / "a.wav").write_bytes(b"")
            listing = [[{"path": str(added)}, {"path": str(kept)}]]
            sent = []
            replies = {
                "dump_favorites": lambda _: {"favorites": listing[0]},
                "tap_favorite_star": lambda _: listing.__setitem__(0, [{"path": str(kept)}]) or {"ok": True},
                "dump_state": {"currentTrack": {"url": str(added / "a.wav")},
                               "playlist": {"files": ["a.wav"]}},
            }
            errors = stress.ios_restore_favorites(
                ios_command_stub(replies, sent),
                self.before(favorites=[{"path": str(kept)}, {"path": str(lost)}]), 1)
        self.assertIn(["open", str(added.resolve())], sent)
        self.assertEqual(sent.count(["tap_favorite_star"]), 1)
        self.assertEqual(len(errors), 1)
        self.assertIn("lost", errors[0])

    def test_chrome_puts_back_the_tab_the_card_and_the_models_route(self):
        sent = []
        stress.ios_restore_chrome(ios_command_stub(
            {"dump_state": {"ui": {"outputRoute": {"kind": 1, "name": "Speaker"}}}}, sent), self.before(), 1)
        self.assertEqual(sent, [["select_tab", "files"], ["minimize_player"], ["dump_state"],
                                ["set_output_route", "speaker", "Speaker"]])

    def test_recents_restore_and_verify(self):
        sent = []
        ok = stress.ios_restore_recents(ios_command_stub(
            {"recents": {"items": [{"path": "/a"}]}}, sent), self.before(), 1)
        self.assertEqual((sent, ok), ([["recents", "restore"]], None))
        self.assertTrue(stress.ios_restore_recents(ios_command_stub(
            {"recents": {"items": [{"path": "/b"}]}}, []), self.before(), 1))

    def test_restore_runs_every_restorer_with_recents_last(self):
        sent = []
        replies = {"dump_state": {"player": {"state": "paused"}, "ui": {},
                                  "settings": {"repeatMode": "off", "shuffleEnabled": False,
                                               "pauseAtTrackEnd": False}},
                   "dump_favorites": {"favorites": []}, "dump_dropbox": {"fake": True},
                   "recents": {"items": [{"path": "/a"}]}}
        with mock.patch.object(stress, "ios_wait"):
            errors = stress.ios_restore(ios_command_stub(replies, sent), self.before(), 1)
        self.assertEqual(errors, [])
        self.assertEqual(sent[-1], ["recents", "restore"])
        for argv in (["set_fake_dropbox", "off"], ["set_fake_http", "off"], ["set_fx_pad", "off"],
                     ["set_repeat", "off"], ["select_tab", "files"], ["set_output_route", "none"]):
            self.assertIn(argv, sent)

    def test_a_restorer_without_its_snapshot_is_skipped(self):
        sent = []
        replies = {"dump_dropbox": {"fake": False}, "dump_state": {"player": {"state": "paused"}}}
        with mock.patch.object(stress, "ios_wait"):
            errors = stress.ios_restore(ios_command_stub(replies, sent), {}, 1)
        self.assertEqual(errors, [])
        self.assertEqual(sent, [["dump_dropbox"], ["set_fake_http", "off"], ["set_fx_pad", "off"],
                                ["dump_state"]])

    def test_a_failing_restorer_does_not_stop_the_rest(self):
        def broken(argv):
            raise stress.Failure("channel", "gone", argv)
        sent = []
        replies = {"dump_dropbox": broken, "dump_favorites": broken, "dump_state": broken,
                   "recents": {"items": [{"path": "/a"}]}}
        errors = stress.ios_restore(ios_command_stub(replies, sent), self.before(), 1)
        self.assertTrue(errors)
        self.assertEqual(sent[-1], ["recents", "restore"])


class LaunchedIosApp:
    """The simulator app as launch-ios.sh can leave it: row 0 of the corpus
    playing. Answers ios_command. An open lands on the third dump after it,
    restarting row 0."""

    SETTERS = {"set_repeat": "repeatMode", "set_shuffle": "shuffleEnabled",
               "set_pause_at_track_end": "pauseAtTrackEnd"}

    def __init__(self, corpus):
        self.corpus, self.playing, self.position, self.landing = corpus, True, 30.0, None
        self.settings = {"repeatMode": "off", "shuffleEnabled": False, "pauseAtTrackEnd": False,
                         "folderOpenSort": "name", "crossfadeMilliseconds": 0,
                         "analyzeBPM": True, "audioFXEnabled": True}

    def __call__(self, env, journal, argv, phase="run", op=None):
        verb = argv[0]
        if verb == "play_pause":
            self.playing = not self.playing
        elif verb == "open":
            self.landing = 3
        elif verb in self.SETTERS:
            self.settings[self.SETTERS[verb]] = argv[1] if verb == "set_repeat" else argv[1] == "on"
        elif verb == "dump_state":
            if self.landing is not None:
                self.landing -= 1
                if not self.landing:
                    self.landing, self.playing, self.position = None, True, 0.0
            self.position += 0.5 if self.playing else 0
            return {"player": {"state": "playing" if self.playing else "paused", "position": self.position,
                               "duration": 120, "noAudioHw": True},
                    "currentTrack": {"url": str(self.corpus / "a.wav")},
                    "playlist": {"files": ["a.wav", "b.wav"], "currentIndex": 0, "count": 2},
                    "settings": dict(self.settings), "fx": {"stages": {}},
                    "ui": {"fxPadEngaged": False, "selectedTab": "playlist"}}
        elif verb == "dump_audio_path":
            return {"stages": [{"stage": "output", "idle": not self.playing, "running": self.playing}]}
        return {"dump_favorites": {"favorites": []}, "dump_dropbox": {"fake": False},
                "recents": {"items": []}}.get(verb, {"ok": True})


class IosSetupTests(unittest.TestCase):
    def test_a_row_the_launch_left_playing_does_not_fail_the_setup(self):
        uuid = "00000000-0000-0000-0000-00000000C0DE"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data, app = root / "data", root / "Vibe.app"
            corpus = data / "Documents" / "Music"
            corpus.mkdir(parents=True)
            app.mkdir()
            for path in (app / "Vibe", corpus / "a.wav", corpus / "b.wav"):
                path.write_bytes(b"")

            def simctl(argv, **_):
                if argv[:3] == ["xcrun", "simctl", "list"]:
                    return json.dumps({"devices": {"iOS": [{"udid": uuid, "state": "Booted"}]}})
                if argv[:3] == ["xcrun", "simctl", "get_app_container"]:
                    return str(data if argv[-1] == "data" else app)
                return f"4242 {app / 'Vibe'}\n"

            args = argparse.Namespace(replay=None, ios=uuid, corpus=str(corpus), app=None, seed=1,
                                      ios_output="pump", isolated_host_audio=False, iterations=0,
                                      batch=25, ios_rounds=0, duration=None, ios_idle_timeout=1,
                                      ios_progress_timeout=1)
            with mock.patch.object(stress.subprocess, "check_output", side_effect=simctl), \
                    mock.patch.object(stress, "ios_command", side_effect=LaunchedIosApp(corpus)), \
                    mock.patch.object(stress, "DEFAULT_OUTPUT_DIR", root / "out"), \
                    mock.patch.object(stress, "CRASH_DIR", root / "reports"), \
                    mock.patch.object(stress.time, "sleep"), \
                    mock.patch("tempfile.gettempdir", return_value=str(root)), \
                    contextlib.redirect_stdout(io.StringIO()):
                result = stress.run_ios(args)
            outcome = json.loads(next((root / "out").glob("ios-*/result.json")).read_text())
        self.assertEqual((result, outcome["failure"]), (0, None))


class IosDeadOpTests(unittest.TestCase):
    def test_the_journal_ios_command_writes_feeds_the_dead_op_warning(self):
        journal = io.StringIO()
        for op, argv, reply in ((None, ["set_fake_http", "off"], {"ok": True}),
                                ("search", ["search", "x"], {"ok": True}),
                                ("link", ["open_url", "https://fake.vibe.test/a"], {"ok": False}),
                                ("browse", ["browse", "tap", "a"], {"ok": True})):
            proc = mock.Mock(pid=1, returncode=0)
            proc.communicate.return_value = (json.dumps(reply), "")
            with mock.patch.object(stress.subprocess, "Popen", return_value=proc):
                stress.ios_command({}, journal, argv, op=op)
        entries = [json.loads(line) for line in journal.getvalue().splitlines()]
        warnings = "\n".join(stress.dead_op_warnings(entries, stress.IOS_WEIGHTS, stress.IOS_OP_PROOFS))
        for kind in ("search", "link", "tab", "favorite"):
            self.assertIn(f"`{kind}`", warnings)
        self.assertNotIn("`browse`", warnings)


class EqualizerProbeTests(unittest.TestCase):
    def test_polls_before_sleeping_and_batches_each_samples_dumps(self):
        playing = {"player": {"state": "playing", "duration": 1}}
        channel = mock.Mock()
        channel.run.side_effect = lambda argv, timeout=None: (0, playing, "")
        channel.run_batch.return_value = [(0, playing)]
        with mock.patch.object(stress.time, "sleep") as sleep, \
                mock.patch.object(stress, "equalizer_finding", return_value=(False, None)) as finding:
            stress.equalizer_probe(channel, Path("/c/a.wav"))
        self.assertEqual([c.args[0] for c in channel.run.call_args_list],
                         [["open", "/c/a.wav"], ["dump_state"]])
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [0.6, 0.8])
        self.assertEqual(channel.run_batch.call_count, 2)
        # The short batch is padded, so the finding still gets four samples.
        self.assertEqual(finding.call_args.args, (playing, None, playing, None))


if __name__ == "__main__":
    unittest.main()
