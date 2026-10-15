import contextlib
import io
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
           loading=False, running=0):
    return {"pending": {"cloudParsesPending": parses, "cloudLaneHeld": lane},
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
                      health(ready=5, loading=True), health(ready=5, running=1)):
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
        note = stress.purgatory_note("playlist", "at rest: resting mach ports grew", self.LISTING)
        self.assertIn("96 PlaylistRowView", note)

    def test_absent_row_views_say_it_is_new(self):
        note = stress.purgatory_note("playlist", "resting mach ports grew", "   1 2 3 NSView ObjC AppKit")
        self.assertIn("NOT the known", note)

    def test_unreadable_heap_names_the_suspect(self):
        self.assertIn("suspected cause", stress.purgatory_note("playlist", "resting mach ports", None))

    def test_other_profiles_and_metrics_get_no_note(self):
        self.assertIsNone(stress.purgatory_note("base", "resting mach ports", self.LISTING))
        self.assertIsNone(stress.purgatory_note("playlist", "resting views", self.LISTING))


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

    def test_options_follow_the_sandbox_rules(self):
        self.assertIn(f"log_path={stress.TSAN_LOG_DIR}/tsan", stress.TSAN_OPTIONS)
        self.assertIn("external_symbolizer_path=:", stress.TSAN_OPTIONS)
        self.assertNotIn("suppressions", stress.TSAN_OPTIONS)

    def run_tsan(self, replay, logs):
        args = mock.Mock(app="/apps/Vibe-tsan.app", tsan_replay="run.ndjson")
        with mock.patch.object(stress.subprocess, "run") as process, \
                mock.patch.object(stress, "replay", side_effect=replay), \
                mock.patch.object(stress, "app_pid", return_value=None), \
                mock.patch.object(stress, "TSAN_LOG_DIR", logs), \
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


if __name__ == "__main__":
    unittest.main()
