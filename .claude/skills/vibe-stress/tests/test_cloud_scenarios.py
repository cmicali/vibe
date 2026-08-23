import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "cloud-scenarios.py"
SPEC = importlib.util.spec_from_file_location("vibe_cloud_scenarios", SCRIPT)
cloud = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cloud
SPEC.loader.exec_module(cloud)


def event(seq, kind, role, file="track.wav"):
    return {"seq": seq, "tMs": seq, "event": kind, "role": role, "file": file}


class FakeContext:
    def __init__(self, stats=None):
        self._stats = stats or {}

    def stats(self):
        return self._stats


class FakeArmContext(cloud.Ctx):
    def __init__(self, reply):
        self.reply = reply

    def cmd(self, *argv, timeout=40):
        return self.reply


class FakeOpenContext:
    def __init__(self, emit_selection):
        self.emit_selection = emit_selection
        self.events = [event(1, "requested", "playback", "a.wav")]
        self.selected = 0

    def cmd(self, verb, *args, timeout=40):
        if verb == "play_index" and self.emit_selection:
            self.selected = int(args[0])
            self.events.append(event(2, "requested", "playback", "b.wav"))
        return {}

    def wait_for(self, describe, predicate, timeout=cloud.WAIT_TIMEOUT):
        if predicate(self.events):
            return self.events
        raise cloud.Failed(f"timed out waiting for {describe}")

    def trace(self):
        return self.events

    def playlist(self):
        return {"files": ["a.wav", "b.wav"], "currentIndex": self.selected}


class TraceHelperTests(unittest.TestCase):
    def test_open_and_play_requires_the_explicit_nonzero_submission(self):
        cloud.open_and_play(FakeOpenContext(True), Path("folder"), index=1)
        with self.assertRaisesRegex(cloud.Failed, "explicit playback submission"):
            cloud.open_and_play(FakeOpenContext(False), Path("folder"), index=1)

    def test_role_family_matching_is_delimited(self):
        self.assertTrue(cloud.role_matches("metadata-scan", "metadata"))
        self.assertTrue(cloud.role_matches("metadata-priority", "metadata"))
        self.assertTrue(cloud.role_matches("playback", "playback"))
        self.assertFalse(cloud.role_matches("metadataish", "metadata"))
        self.assertFalse(cloud.role_matches("metadata-scan", "metadata-priority"))

    def test_metadata_windows_include_both_roles_and_pair_terminals(self):
        events = [
            event(1, "started", "metadata-scan", "a.wav"),
            event(2, "started", "metadata-priority", "b.wav"),
            event(3, "cancelled", "metadata-scan", "a.wav"),
        ]
        self.assertEqual(cloud.windows(events, "metadata"), [
            (1, 3, "a.wav"),
            (2, None, "b.wav"),
        ])

    def test_repeated_same_file_windows_pair_oldest_first(self):
        events = [
            event(1, "started", "metadata-scan"),
            event(2, "completed", "metadata-scan"),
            event(3, "started", "metadata-scan"),
            event(4, "cancelled", "metadata-scan"),
        ]
        self.assertEqual(cloud.windows(events, "metadata-scan"), [
            (1, 2, "track.wav"),
            (3, 4, "track.wav"),
        ])

    def test_inside_is_strict_and_checks_request_admission(self):
        events = [
            event(9, "requested", "playback", "picked.wav"),
            event(10, "started", "playback", "picked.wav"),
            event(9, "requested", "metadata-scan", "boundary-a.wav"),
            event(11, "requested", "metadata-scan", "bad.wav"),
            event(20, "completed", "playback", "picked.wav"),
            event(20, "requested", "metadata-scan", "boundary-b.wav"),
        ]
        self.assertEqual(
            cloud.role_events_inside_requests(
                events, "metadata", "playback", "requested"),
            [("bad.wav", "picked.wav")],
        )
        with self.assertRaisesRegex(cloud.Failed, "provider request was submitted"):
            cloud.assert_no_foreground_contention(FakeContext(), events)

    def test_started_overlap_and_cumulative_counter_are_independent_oracles(self):
        started = [
            event(0, "requested", "prefetch", "picked.wav"),
            event(1, "started", "playback", "picked.wav"),
            event(2, "started", "metadata-scan", "bad.wav"),
        ]
        with self.assertRaisesRegex(cloud.Failed, "download began"):
            cloud.assert_no_foreground_contention(FakeContext(), started)
        with self.assertRaisesRegex(cloud.Failed, "counted 1"):
            cloud.assert_no_foreground_contention(
                FakeContext({"foregroundContentionStarts": 1}), [])

    def test_request_spans_include_queued_and_cancelled_work(self):
        events = [
            event(1, "requested", "prefetch", "a.wav"),
            event(2, "requested", "playback", "b.wav"),
            event(3, "cancelled", "prefetch", "a.wav"),
        ]
        spans = cloud.request_spans(events, "prefetch")
        self.assertEqual([(start["seq"], end["seq"] if end else None)
                          for start, end in spans], [(1, 3)])
        self.assertEqual(cloud.request_spans(events, "playback")[0][1], None)

        queued = [event(1, "requested", "metadata-scan", "queued.wav"),
                  event(2, "requested", "metadata-scan", "running.wav"),
                  event(3, "started", "metadata-scan", "running.wav")]
        self.assertEqual(
            [request["file"] for request in cloud.live_unstarted_requests(
                queued, "metadata", {"queued.wav", "running.wav"}, 3)],
            ["queued.wav"],
        )

    def test_expected_scan_order_is_exact_rank_then_index(self):
        rows = ["a", "b", "c", "d", "e", "f"]
        observed = ["a", "f", "d", "b", "e"]
        self.assertEqual(
            cloud.expected_scan_order(rows, "c", observed),
            ["d", "e", "b", "a", "f"],
        )
        self.assertEqual(
            cloud.expected_scan_order(rows, "c", ["unknown", "d"]),
            ["d", "unknown"],
        )

    def test_replacement_oracle_catches_a_late_old_transfer(self):
        good = [
            event(1, "started", "metadata-scan", "old.wav"),
            event(2, "cancelled", "metadata-scan", "old.wav"),
            event(3, "requested", "playback", "new.wav"),
        ]
        covered, error_text = cloud.replacement_retirement_error(
            good + [event(4, "started", "playback", "new.wav")],
            {"old.wav"}, snapshot_seq=1, new_request_seq=3, new_start_seq=4,
            initially_live_start_seqs={1}, initially_live_request_seqs=set())
        self.assertEqual(covered, 1)
        self.assertIsNone(error_text)

        escaped = [
            event(1, "started", "metadata-scan", "old.wav"),
            event(2, "cancelled", "metadata-scan", "old.wav"),
            event(3, "started", "metadata-priority", "late-old.wav"),
            event(4, "requested", "playback", "new.wav"),
            event(5, "cancelled", "metadata-priority", "late-old.wav"),
        ]
        _, error_text = cloud.replacement_retirement_error(
            escaped, {"old.wav", "late-old.wav"}, snapshot_seq=2,
            new_request_seq=4, new_start_seq=4,
            initially_live_start_seqs=set(), initially_live_request_seqs=set())
        self.assertIn("overlapped", error_text)

        asynchronous_cancel = [
            event(3, "requested", "metadata-scan", "queued-old.wav"),
            event(4, "requested", "playback", "new.wav"),
            event(5, "cancelled", "metadata-scan", "queued-old.wav"),
            event(6, "started", "playback", "new.wav"),
        ]
        _, error_text = cloud.replacement_retirement_error(
            asynchronous_cancel, {"queued-old.wav"}, snapshot_seq=2,
            new_request_seq=4, new_start_seq=6,
            initially_live_start_seqs=set(), initially_live_request_seqs={3})
        self.assertIsNone(error_text)

        late_submission = asynchronous_cancel + [
            event(7, "requested", "metadata-scan", "escaped-old.wav")]
        _, error_text = cloud.replacement_retirement_error(
            late_submission, {"queued-old.wav", "escaped-old.wav"},
            snapshot_seq=2, new_request_seq=4, new_start_seq=6,
            initially_live_start_seqs=set(), initially_live_request_seqs={3})
        self.assertIn("departed scan", error_text)

        starts_after_b = [
            event(1, "requested", "metadata-scan", "prequeued.wav"),
            event(4, "requested", "playback", "new.wav"),
            event(5, "started", "playback", "new.wav"),
            event(6, "started", "metadata-scan", "prequeued.wav"),
            event(7, "cancelled", "metadata-scan", "prequeued.wav"),
        ]
        covered, error_text = cloud.replacement_retirement_error(
            starts_after_b, {"prequeued.wav"}, snapshot_seq=2,
            new_request_seq=4, new_start_seq=5,
            initially_live_start_seqs=set(), initially_live_request_seqs={1})
        self.assertEqual(covered, 1)
        self.assertIn("overlapped", error_text)

        cancelled_then_started_late = [
            event(1, "requested", "metadata-scan", "prequeued.wav"),
            event(3, "cancelled", "metadata-scan", "prequeued.wav"),
            event(4, "requested", "playback", "new.wav"),
            event(5, "started", "playback", "new.wav"),
            event(6, "started", "metadata-scan", "prequeued.wav"),
        ]
        covered, error_text = cloud.replacement_retirement_error(
            cancelled_then_started_late, {"prequeued.wav"}, snapshot_seq=2,
            new_request_seq=4, new_start_seq=5,
            initially_live_start_seqs=set(), initially_live_request_seqs={1})
        self.assertEqual(covered, 1)
        self.assertIn("started after B", error_text)

    def test_post_timeout_oracle_rejects_a_priority_chase(self):
        good = [event(5, "cancelled", "playback", "picked.wav"),
                event(6, "requested", "metadata-scan", "other.wav"),
                event(7, "started", "metadata-scan", "other.wav")]
        self.assertEqual(cloud.post_timeout_scan_pick(good, 5, "picked.wav"),
                         ("other.wav", None))
        chased = [event(5, "cancelled", "playback", "picked.wav"),
                  event(6, "requested", "metadata-priority", "picked.wav"),
                  event(7, "started", "metadata-priority", "picked.wav"),
                  event(8, "requested", "metadata-scan", "other.wav")]
        first, error_text = cloud.post_timeout_scan_pick(chased, 5, "picked.wav")
        self.assertEqual(first, "picked.wav")
        self.assertIn("metadata-priority", error_text)

    def test_post_timeout_oracle_requires_the_scan_to_consume_a_slot(self):
        queued = [event(5, "cancelled", "playback", "picked.wav"),
                  event(6, "requested", "metadata-scan", "other.wav")]
        first, error_text = cloud.post_timeout_scan_pick(queued, 5, "picked.wav")
        self.assertEqual(first, "other.wav")
        self.assertIn("never consumed a provider slot", error_text)

        wrong_start = queued + [event(7, "started", "metadata-scan", "third.wav")]
        _, error_text = cloud.post_timeout_scan_pick(
            wrong_start, 5, "picked.wav")
        self.assertIn("third.wav", error_text)

    def test_single_transfer_oracle_rejects_cancel_then_retry(self):
        exact = [
            event(1, "requested", "prefetch", "next.wav"),
            event(2, "started", "prefetch", "next.wav"),
            event(3, "completed", "prefetch", "next.wav"),
        ]
        self.assertIsNone(cloud.single_successful_transfer_error(exact, "next.wav"))
        retried = [
            event(1, "requested", "prefetch", "next.wav"),
            event(2, "started", "prefetch", "next.wav"),
            event(3, "cancelled", "prefetch", "next.wav"),
            event(4, "requested", "playback", "next.wav"),
            event(5, "started", "playback", "next.wav"),
            event(6, "completed", "playback", "next.wav"),
        ]
        self.assertIn("2, 2, 1, 1",
                      cloud.single_successful_transfer_error(retried, "next.wav"))

    def test_failed_transfer_oracle_rejects_queued_or_unsettled_attempts(self):
        exact = []
        for base in (1, 4, 7):
            exact.extend([
                event(base, "requested", "metadata-scan", "bad.wav"),
                event(base + 1, "started", "metadata-scan", "bad.wav"),
                event(base + 2, "cancelled", "metadata-scan", "bad.wav"),
            ])
        self.assertIsNone(cloud.exact_failed_transfers_error(
            exact, "bad.wav", "metadata", 3))
        queued = exact[:-2] + [
            event(8, "cancelled", "metadata-scan", "bad.wav")]
        self.assertIn("2, 0, 3", cloud.exact_failed_transfers_error(
            queued, "bad.wav", "metadata", 3))
        unterminated = exact[:-1]
        self.assertIn("3, 0, 2", cloud.exact_failed_transfers_error(
            unterminated, "bad.wav", "metadata", 3))

    def test_stall_deadline_oracle_requires_movement_and_silence(self):
        self.assertIn("movement phase",
                      cloud.stall_deadline_error(0.1, 8500, 12, 3))
        self.assertIn("silence budget",
                      cloud.stall_deadline_error(0.4, 3000, 12, 3))
        self.assertIsNone(cloud.stall_deadline_error(0.4, 8500, 12, 3))
        self.assertIn("upper bound",
                      cloud.stall_deadline_error(0.4, 11000, 12, 3))

    def test_baseline_deadline_oracle_rejects_early_and_late_timeouts(self):
        self.assertIn("before", cloud.baseline_deadline_error(2000, 3))
        self.assertIsNone(cloud.baseline_deadline_error(3300, 3))
        self.assertIn("upper bound", cloud.baseline_deadline_error(5000, 3))

    def test_replacement_playlist_oracle_rejects_empty_and_old_rows(self):
        self.assertFalse(cloud.playlist_belongs_to_folder([], {"b.wav"}))
        self.assertFalse(cloud.playlist_belongs_to_folder(
            ["b.wav", "old.wav"], {"b.wav", "c.wav"}))
        self.assertTrue(cloud.playlist_belongs_to_folder(
            ["b.wav", "c.wav"], {"b.wav", "c.wav"}))

    def test_append_playlist_oracle_requires_exact_order_and_identity(self):
        expected = ["a.wav", "b.wav", "c.wav", "d.wav"]
        self.assertIsNone(cloud.exact_playlist_error(expected, expected))
        self.assertIn("exact ordered", cloud.exact_playlist_error(
            ["a.wav", "c.wav", "b.wav", "d.wav"], expected))
        self.assertIn("exact ordered", cloud.exact_playlist_error(
            ["a.wav", "b.wav", "b.wav", "d.wav"], expected))

    def test_provider_order_oracle_rejects_duplicate_successes(self):
        self.assertIsNone(cloud.duplicate_order_error(["a.wav", "b.wav"]))
        self.assertIn("b.wav", cloud.duplicate_order_error(
            ["a.wav", "b.wav", "b.wav"]))

    def test_row_loading_oracle_checks_progress_and_playlist_index(self):
        good = {"transfers": [{"file": "a.wav", "progress": 0.25}],
                "loadingRows": [{"index": 2, "file": "a.wav", "progress": 0.25}]}
        self.assertIsNone(cloud.row_loading_projection_error(good, "a.wav", 2))
        indeterminate = {"transfers": [{"file": "a.wav", "progress": -1}],
                         "loadingRows": [{"index": 2, "file": "a.wav",
                                          "progress": -1}]}
        self.assertIsNone(cloud.row_loading_projection_error(
            indeterminate, "a.wav", 2))
        wrong_progress = {"transfers": [{"file": "a.wav", "progress": 0.5}],
                          "loadingRows": [{"index": 2, "file": "a.wav",
                                           "progress": 0.25}]}
        self.assertIn("disagreed", cloud.row_loading_projection_error(
            wrong_progress, "a.wav", 2))
        self.assertIn("wrong playlist index", cloud.row_loading_projection_error(
            good, "a.wav", 1))

    def test_deferred_sweep_oracle_enforces_stage_one_and_fallback_bound(self):
        self.assertIn("never finished", cloud.deferred_sweep_error(
            {"stageOneFinished": False, "pending": 2}, 2.1))
        self.assertIn("only 0.20s", cloud.deferred_sweep_error(
            {"stageOneFinished": True, "pending": 2}, 0.2))
        self.assertIn("took 7.00s", cloud.deferred_sweep_error(
            {"stageOneFinished": True, "pending": 2}, 7.0))
        self.assertIsNone(cloud.deferred_sweep_error(
            {"stageOneFinished": True, "pending": 2}, 2.2))

    def test_mixed_valid_and_unknown_only_ids_are_rejected(self):
        self.assertEqual([item[0] for item in cloud.scenario_plan({"S1", "S20"})],
                         ["S1", "S20"])
        with self.assertRaisesRegex(ValueError, "S2O"):
            cloud.scenario_plan({"S1", "S2O"})

    def test_xpass_requires_review_but_documented_xfail_is_accepted(self):
        self.assertEqual(cloud.result_exit_code({"PASS": 24, "XFAIL": 1}), 0)
        self.assertEqual(cloud.result_exit_code({"PASS": 24, "XPASS": 1}), 1)
        self.assertEqual(cloud.failure_outcome(
            cloud.ExpectedGap("known"), expected_fail=True), "XFAIL")
        self.assertEqual(cloud.failure_outcome(
            cloud.Failed("setup broke"), expected_fail=True), "FAIL")
        for outcome in ("FAIL", "XFAIL", "ERROR"):
            merged, detail = cloud.cleanup_failure_outcome(
                outcome, "scenario evidence", "app died")
            self.assertEqual(merged, outcome)
            self.assertIn("scenario evidence", detail)
            self.assertIn("app died", detail)
        for outcome in ("PASS", "XPASS"):
            merged, detail = cloud.cleanup_failure_outcome(
                outcome, "scenario evidence", "app died")
            self.assertEqual(merged, "ERROR")
            self.assertIn("scenario evidence", detail)

    def test_arm_verifies_every_requested_fake_option(self):
        good = {
            "installed": True,
            "percent": 100,
            "capacity": 0,
            "uniform": True,
            "progressMode": "stall",
            "unflagged": True,
            "sticky": True,
            "failingBasename": "bad.wav",
            "baseSeconds": 2.5,
        }
        FakeArmContext(good).arm(seconds=2.5, capacity=0, progress="stall",
                                  unflagged=True, sticky=True, fail="bad.wav")
        wrong = dict(good, capacity=1)
        with self.assertRaisesRegex(cloud.Failed, "requested shape"):
            FakeArmContext(wrong).arm(seconds=2.5, capacity=0, progress="stall",
                                       unflagged=True, sticky=True, fail="bad.wav")

    def test_corpus_shape_rejects_undersized_folders_before_scenarios_run(self):
        with tempfile.TemporaryDirectory() as temp:
            corpus = Path(temp)
            for folder_name in ("a", "b"):
                folder = corpus / folder_name
                folder.mkdir()
                for index in range(5):
                    (folder / f"{folder_name}-{index}.wav").touch()
                for index in range(6):
                    (folder / f"cover-{index}.jpg").touch()
            with self.assertRaises(SystemExit):
                cloud.check_corpus_shape(corpus)
            (corpus / "a" / "a-5.wave").touch()
            (corpus / "b" / "b-5.bwf").touch()
            cloud.check_corpus_shape(corpus)
            for folder_name in ("a", "b"):
                for index in range(6, 41):
                    (corpus / folder_name / f"{folder_name}-{index}.wav").touch()
            with self.assertRaisesRegex(SystemExit, "at most 40"):
                cloud.check_corpus_shape(corpus)

    def test_unique_basenames_ignores_sidecars_but_rejects_audio_duplicates(self):
        with tempfile.TemporaryDirectory() as temp:
            corpus = Path(temp)
            first = corpus / "a"
            second = corpus / "b"
            first.mkdir()
            second.mkdir()
            (first / "cover.jpg").touch()
            (second / "cover.jpg").touch()
            (first / "first.wav").touch()
            (second / "second.wav").touch()

            cloud.check_unique_basenames(corpus)

            (first / "duplicate.mp3").touch()
            (second / "duplicate.mp3").touch()
            with self.assertRaisesRegex(SystemExit, "duplicate.mp3"):
                cloud.check_unique_basenames(corpus)


if __name__ == "__main__":
    unittest.main()
