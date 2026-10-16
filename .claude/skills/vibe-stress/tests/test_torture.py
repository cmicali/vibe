import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import torture  # noqa: E402


def state(position, status="playing", url="/c/a.wav", buffering=False, display="track", index=0):
    return {"player": {"state": status, "position": position, "buffering": buffering},
            "currentTrack": {"url": url}, "ui": {"displayState": display},
            "playlist": {"currentIndex": index}}


class FakeApp:
    def __init__(self, states):
        self.states = list(states)

    def json(self, *argv, timeout=60):
        return self.states.pop(0) if len(self.states) > 1 else self.states[0]


class PositionTests(unittest.TestCase):
    def test_scored_only_for_the_same_settled_playing_track(self):
        self.assertTrue(torture.position_stalled(state(3.0), state(3.0)))
        self.assertFalse(torture.position_stalled(state(3.0), state(3.5)))
        for second in (state(3.0, status="paused"), state(3.0, url="/c/b.wav"),
                       state(3.0, buffering=True), state(3.0, display="loading")):
            with self.subTest(second=second):
                self.assertIsNone(torture.position_stalled(state(3.0), second))
        self.assertIsNone(torture.position_stalled(state(3.0, status="stopped"), state(3.0)))

    def test_a_cue_row_transition_shares_the_url_and_is_not_a_stall(self):
        # Adjacent cue rows are windows of one file: row 0 at its end, then row 1
        # at its start, reads as a new row, never as a held position.
        self.assertIsNone(torture.position_stalled(state(59.9, index=0), state(0.5, index=1)))

    def test_a_position_that_went_backwards_is_a_replay_not_a_stall(self):
        # Repeat One replays the same row from 0 between two samples.
        self.assertFalse(torture.position_stalled(state(59.9), state(0.5)))
        self.assertTrue(torture.position_stalled(state(59.9), state(59.9)))


class CheckpointTests(unittest.TestCase):
    def checkpoint(self, states):
        with mock.patch.object(torture.time, "sleep"):
            return torture.playback_checkpoint(FakeApp(states))

    def test_a_still_position_fails_as_stalled(self):
        self.assertIn("playback stalled", self.checkpoint([state(2.0), state(2.0)]))

    def test_an_advancing_position_passes(self):
        self.assertIsNone(self.checkpoint([state(2.0), state(2.6)]))

    def test_a_burst_ending_mid_open_gets_its_grace(self):
        loading = state(0.0, display="loading")
        self.assertIsNone(self.checkpoint([loading, loading, state(0.1), state(0.7)]))
        self.assertIn("stalled", self.checkpoint([loading, state(0.1), state(0.1)]))

    def test_an_open_that_never_settles_is_not_scored(self):
        clock = iter(range(0, 100))
        loading = state(0.0, buffering=True)
        with mock.patch.object(torture.time, "time", side_effect=lambda: next(clock)):
            self.assertIsNone(self.checkpoint([loading]))

    def test_paused_and_stopped_are_not_scored(self):
        self.assertIsNone(self.checkpoint([state(1.0, status="paused")]))
        self.assertIsNone(self.checkpoint([state(1.0, status="stopped")]))


if __name__ == "__main__":
    unittest.main()
