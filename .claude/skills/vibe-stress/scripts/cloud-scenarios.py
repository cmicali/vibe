#!/usr/bin/env python3
"""Deterministic cloud-loading scenarios, asserted on the fake provider's trace.

Where stress.py drives randomly and watches for violations, this drives ONE
named situation at a time and asserts what the trace must contain. It exists
because the cloud work's guarantees are all about ORDER — which download runs
next, which is abandoned, which never starts — and order is exactly what a
seeded monkey cannot state.

Three rules the whole file is built on:

  ASSERT ORDER ON THE TRACE, NEVER ON SLEEP TIMING. `dump_cloud_trace` records
  every transfer's requested/started/completed/cancelled with its role and a
  sequence number. Elapsed time is an assertion only where a deadline or
  fallback clock is itself the behavior under test; elsewhere it merely bounds
  how long the runner waits for an observable edge.

  ONE LAUNCH PER SCENARIO. `set_fake_cloud` deliberately preserves the
  completed/cancelled tally across a re-arm, the metadata cache persists to
  disk, and a hold left over from a previous scenario would be indistinguishable
  from one this scenario lost. A fresh process is the only honest reset.

  capacity=1 uniform UNLESS THE SCENARIO SAYS OTHERWISE. The provider's default
  is unlimited capacity and a 0.5x-2x per-file spread; neither can express
  "background work starved foreground work", which is the thing under test.

A scenario may be marked expected-fail (the third SCENARIOS field): it is run
and reported rather than skipped, so the day it starts passing is visible. An
expected-fail that PASSES is reported as XPASS and is a finding in its own
right. Only an ExpectedGap carrying the scenario's documented defect is XFAIL;
ordinary assertion and setup failures remain FAIL. S9 remains expected-fail:
a provider that withholds SF_DATALESS is
indistinguishable from a local file at the admission seam. The fake makes that
known limitation deterministic; a real-provider run is still required to say
which providers exhibit it.

    cloud-scenarios.py --corpus build/cloud-scenarios-corpus
    cloud-scenarios.py --corpus <dir> --only S4b,S7 --verbose
"""

import argparse
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stress import AUDIO_SUFFIXES, Channel, launch  # noqa: E402

DEFAULT_APP = Path("build/DerivedData/Build/Products/Debug/Vibe.app")

# The base transfer, in seconds. Long enough that a scenario can observe a
# transfer mid-flight over a channel whose round trip is ~130ms, short enough
# that a dozen of them do not make the suite a soak.
TRANSFER = 1.0

# How long any wait_for gives up after. Every scenario's longest legitimate wait
# is a handful of transfers.
WAIT_TIMEOUT = 40.0
POLL = 0.15
MIN_SCENARIO_ROWS = 6
MAX_SCENARIO_ROWS = 40


# --------------------------------------------------------------------------
# Result plumbing
# --------------------------------------------------------------------------


class Failed(Exception):
    """A scenario's own assertion. Carries the trace for the report."""


class ExpectedGap(Failed):
    """The one specifically documented defect an expected-fail reached."""


class Ctx:
    def __init__(self, channel, corpus, verbose):
        self.channel = channel
        self.corpus = corpus
        self.verbose = verbose
        self.folders = sorted(p for p in corpus.iterdir() if p.is_dir())
        if len(self.folders) < 2:
            sys.exit(f"{corpus} needs at least two subfolders — see make-cloud-corpus.py")

    # -- channel ----------------------------------------------------------

    def cmd(self, *argv, timeout=40):
        code, payload, _ = self.channel.run([str(a) for a in argv], timeout=timeout)
        if self.verbose:
            print(f"      $ {' '.join(str(a) for a in argv)} -> {code}", file=sys.stderr)
        if code not in (0,):
            raise Failed(f"`{' '.join(str(a) for a in argv)}` failed: exit {code} {payload}")
        return payload or {}

    def arm(self, seconds=TRANSFER, percent=100, capacity=1, uniform=True,
            progress=None, unflagged=False, sticky=False, fail=None):
        argv = ["set_fake_cloud", f"{seconds}", f"{percent}", f"capacity={capacity}"]
        if uniform:
            argv.append("uniform")
        if progress:
            argv.append(f"progress={progress}")
        if unflagged:
            argv.append("unflagged")
        if sticky:
            argv.append("sticky")
        if fail:
            argv.append(f"fail={fail}")
        stats = self.cmd(*argv)
        if not stats.get("installed"):
            raise Failed(f"could not arm the fake provider: {stats}")
        expected = {
            "percent": percent,
            "capacity": capacity,
            "uniform": uniform,
            "progressMode": progress or "hashed",
            "unflagged": unflagged,
            "sticky": sticky,
            "failingBasename": fail or "",
        }
        wrong = {key: (stats.get(key), value) for key, value in expected.items()
                 if stats.get(key) != value}
        if abs(float(stats.get("baseSeconds", -1)) - float(seconds)) > 0.001:
            wrong["baseSeconds"] = (stats.get("baseSeconds"), seconds)
        if wrong:
            raise Failed(f"fake provider did not install the requested shape: {wrong}")
        return stats

    def trace(self):
        return self.cmd("dump_cloud_trace").get("events", [])

    def stats(self):
        return self.cmd("dump_cloud_trace").get("stats", {})

    def health(self):
        return self.cmd("dump_cloud_health")

    def materialization(self):
        """The coordinator's own gauges and cumulative counters.

        This has been in dump_cloud_health's reply since the coordinator landed
        and no scenario read it, which is most of why a wedged handle open could
        starve every background transfer with the whole suite green. The two
        that matter here: handleOpensInFlight is an AVAudioFile call the OS
        still owes an answer for, and foregroundTransferActive is the gate — it
        is what tells "the foreground rule is holding metadata back" (correct)
        apart from "nothing can start at all" (the bug).
        """
        return self.health().get("materialization", {})

    def wait_for_hung_open(self, basename, describe, timeout=WAIT_TIMEOUT):
        """Block until this basename reaches the injected uncancellable open."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            reply = self.cmd("hang_open", basename)
            if reply.get("hungOpens", 0) >= 1:
                return reply
            time.sleep(POLL)
        raise Failed(f"timed out after {timeout:.0f}s waiting for {describe}")

    def configure_timeouts(self, baseline, silence):
        reply = self.cmd("set_audio_loading", f"timeout-baseline={baseline}",
                         f"timeout-silence={silence}")
        if not reply.get("ok"):
            raise Failed(f"could not install diagnostic open timeouts: {reply}")
        diagnostic = reply.get("configuration", {}).get("diagnostic", {})
        if diagnostic.get("timeoutBaseline") != baseline \
                or diagnostic.get("timeoutSilence") != silence:
            raise Failed(f"open timeout configuration did not stick: {diagnostic}")
        aligned = self.cmd("dump_audio_loading")
        if not aligned.get("aligned"):
            raise Failed(f"audio-loading consumers disagree after update: {aligned}")
        return reply

    def quiesce(self, timeout=60):
        reply = self.cmd("quiesce", timeout=timeout)
        if not reply.get("settled"):
            raise Failed(f"quiesce did not settle: {reply}")
        return reply

    def state(self):
        return self.cmd("dump_state")

    def playlist(self):
        """Playlist state, with files as trace-compatible basenames."""
        return self.cmd("dump_state").get("playlist", {})

    def wait_for(self, describe, predicate, timeout=WAIT_TIMEOUT):
        """Poll the trace until predicate(events) is true. Returns the events."""
        deadline = time.monotonic() + timeout
        events = []
        while time.monotonic() < deadline:
            events = self.trace()
            if predicate(events):
                return events
            time.sleep(POLL)
        raise Failed(f"timed out after {timeout:.0f}s waiting for {describe}")

    def settle(self, seconds):
        """Let the app run. `sleep` is served in-app, so it costs one round trip."""
        self.cmd("sleep", f"{seconds}")



# -- trace helpers ---------------------------------------------------------


def role_matches(recorded, wanted):
    """Exact, or family prefix: the coordinator splits "metadata" into
    "metadata-scan" and "metadata-priority", and the suite's assertions are
    about the family unless they say otherwise. An exact-only match silently
    emptied every metadata predicate after the split — the sweeps ran
    perfectly while the suite reported them absent."""
    return recorded == wanted or recorded.startswith(wanted + "-")


def events_of(events, event=None, role=None, file=None):
    out = events
    if event is not None:
        out = [e for e in out if e["event"] == event]
    if role is not None:
        out = [e for e in out if role_matches(e["role"], role)]
    if file is not None:
        out = [e for e in out if e["file"] == file]
    return out


def started_order(events, role):
    return [e["file"] for e in events_of(events, event="started", role=role)]


def transfer_spans(events, role):
    """[(start_event, end_event)] for each transfer in a role family.

    end_event is the matching completed/cancelled, or None if still in flight.
    Matched by file, oldest-open-first, which is exact here because one file
    never has two transfers of the same role in flight — and if it ever did,
    the fake's own metadataOverlapTransfers counter would already have fired.
    """
    open_by_file, spans = {}, []
    for e in events:
        if not role_matches(e["role"], role):
            continue
        if e["event"] == "started":
            open_by_file.setdefault(e["file"], []).append(len(spans))
            spans.append([e, None])
        elif e["event"] in ("completed", "cancelled"):
            pending = open_by_file.get(e["file"])
            if pending:
                spans[pending.pop(0)][1] = e
    return [(start, end) for start, end in spans]


def request_spans(events, role):
    """[(request_event, terminal_event)] for provider requests in a role family.

    Unlike transfer_spans(), these begin before the fake provider's capacity
    wait. This is the observable live edge closest to coordinator admission;
    claim-registration timing itself is pinned by coordinator XTests.
    """
    open_by_file, spans = {}, []
    for e in events:
        if not role_matches(e["role"], role):
            continue
        if e["event"] == "requested":
            open_by_file.setdefault(e["file"], []).append(len(spans))
            spans.append([e, None])
        elif e["event"] in ("completed", "cancelled"):
            pending = open_by_file.get(e["file"])
            if pending:
                spans[pending.pop(0)][1] = e
    return [(request, terminal) for request, terminal in spans]


def live_unstarted_requests(events, role, files, snapshot_seq):
    """Live provider requests still queued at one exact trace snapshot."""
    starts = events_of(events, event="started", role=role)
    return [request for request, terminal in request_spans(events, role)
            if terminal is None
            and request["file"] in files
            and request["seq"] <= snapshot_seq
            and not any(start["role"] == request["role"]
                        and start["file"] == request["file"]
                        and request["seq"] < start["seq"] <= snapshot_seq
                        for start in starts)]


def windows(events, role):
    """[(start_seq, end_seq, file)] projected from transfer_spans()."""
    return [(start["seq"], end["seq"] if end else None, start["file"])
            for start, end in transfer_spans(events, role)]


def role_events_inside(events, inner_role, outer_role, inner_event):
    """Inner-role events occurring strictly inside an outer transfer."""
    hits = []
    outer = windows(events, outer_role)
    for e in events_of(events, event=inner_event, role=inner_role):
        for start, end, ofile in outer:
            if start < e["seq"] and (end is None or e["seq"] < end):
                hits.append((e["file"], ofile))
    return hits


def role_events_inside_requests(events, inner_role, outer_role, inner_event):
    """Inner events strictly inside an outer provider request's lifetime."""
    hits = []
    outer = [(request["seq"], terminal["seq"] if terminal else None,
              request["file"])
             for request, terminal in request_spans(events, outer_role)]
    for e in events_of(events, event=inner_event, role=inner_role):
        for start, end, ofile in outer:
            if start < e["seq"] and (end is None or e["seq"] < end):
                hits.append((e["file"], ofile))
    return hits


def role_started_inside(events, inner_role, outer_role):
    """Transfers of inner_role that began inside an outer_role transfer's span."""
    return role_events_inside(events, inner_role, outer_role, "started")


def expected_scan_order(rows, current_file, observed):
    """The exact rank-then-index projection for observed dataless scan files."""
    if current_file not in rows:
        return []
    here = rows.index(current_file)
    neighborhood = [rows[index] for index in (here + 1, here + 2, here - 1)
                    if 0 <= index < len(rows)]
    rank = {name: index for index, name in enumerate(neighborhood)}
    row = {name: index for index, name in enumerate(rows)}
    return sorted(observed, key=lambda name: (rank.get(name, len(rows)),
                                               row.get(name, len(rows))))


def replacement_retirement_error(events, old_names, snapshot_seq,
                                 new_request_seq, new_start_seq,
                                 initially_live_start_seqs,
                                 initially_live_request_seqs):
    """Return (covered_count, error) for the old-loader retirement projection."""
    initially_live = set(initially_live_start_seqs)
    initially_requested = set(initially_live_request_seqs)
    relevant = []
    for start, end in transfer_spans(events, "metadata"):
        if start["file"] not in old_names:
            continue
        if (start["seq"] in initially_live
                or snapshot_seq < start["seq"] < new_start_seq):
            relevant.append((start, end))
    relevant_requests = [(request, terminal) for request, terminal
                         in request_spans(events, "metadata")
                         if request["file"] in old_names
                         and (request["seq"] in initially_requested
                              or snapshot_seq < request["seq"] < new_request_seq)]
    covered_count = max(len(relevant), len(relevant_requests))
    for start, end in relevant:
        if not end or end["seq"] > new_start_seq:
            return (covered_count,
                    f"old metadata transfer {start['file']} overlapped the new "
                    "playback provider start")
        if end["event"] != "cancelled":
            return (covered_count,
                    f"old metadata transfer {start['file']} completed instead of "
                    "being cancelled by replacement")
    for request, terminal in relevant_requests:
        if (not terminal or terminal["seq"] > new_start_seq
                or terminal["event"] != "cancelled"):
            return (covered_count,
                    f"late old metadata request {request['file']} escaped "
                    "replacement and overlapped the new playback start")
    late = [e for e in events_of(events, event="requested", role="metadata")
            if e["file"] in old_names and e["seq"] > new_request_seq]
    if late:
        return (covered_count,
                f"the departed scan submitted work after replacement: "
                f"{[e['file'] for e in late]}")
    late_starts = [e for e in events_of(events, event="started", role="metadata")
                   if e["file"] in old_names and e["seq"] > new_start_seq]
    if late_starts:
        return (covered_count,
                f"old metadata work started after B consumed its provider slot: "
                f"{[e['file'] for e in late_starts]}")
    return covered_count, None


def row_loading_projection_error(snapshot, expected_file, expected_index):
    """Compare the registry entry with the exact playlist-row projection."""
    transfers = snapshot.get("transfers", [])
    rows = snapshot.get("loadingRows", [])
    if (len(transfers) != 1 or len(rows) != 1
            or transfers[0].get("file") != expected_file
            or rows[0].get("file") != expected_file):
        return f"expected sole live row {expected_index} {expected_file}: {snapshot}"
    transfer_progress = transfers[0].get("progress")
    row_progress = rows[0].get("progress")
    numeric = lambda value: isinstance(value, (int, float)) \
            and not isinstance(value, bool)
    if (not numeric(transfer_progress) or not numeric(row_progress)
            or not -1 <= float(transfer_progress) <= 1
            or not -1 <= float(row_progress) <= 1):
        return f"loading progress was not a valid indeterminate/fraction value: {snapshot}"
    if abs(float(transfer_progress) - float(row_progress)) > 0.000001:
        return f"registry and row progress disagreed: {snapshot}"
    if rows[0].get("index") != expected_index:
        return f"loading projected to the wrong playlist index: {snapshot}"
    return None


def post_timeout_scan_pick(events, cancellation_seq, picked):
    """Return (file, error) for the first metadata transfer after abandonment.

    `requested` is before the fake provider's capacity queue. The claim that a
    row consumed the next provider slot therefore needs the matching `started`
    edge too, and it needs to be the first metadata start after cancellation.
    """
    requests = [e for e in events_of(events, event="requested", role="metadata")
                if e["seq"] > cancellation_seq]
    if not requests:
        return None, "no metadata request followed the abandoned playback"
    first_request = requests[0]
    if first_request["role"] != "metadata-scan" or first_request["file"] == picked:
        return (first_request["file"],
                f"the first metadata request after timeout was "
                f"{first_request['role']} {first_request['file']}; expected an "
                "ordinary scan of a different file")
    starts = [e for e in events_of(events, event="started", role="metadata")
              if e["seq"] > cancellation_seq]
    if not starts:
        return first_request["file"], (f"the ordinary scan of "
                                       f"{first_request['file']} was requested "
                                       "but never consumed a provider slot")
    first_start = starts[0]
    if (first_start["role"] != first_request["role"]
            or first_start["file"] != first_request["file"]
            or first_start["seq"] <= first_request["seq"]):
        return (first_request["file"],
                f"the first metadata provider start after timeout was "
                f"{first_start['role']} {first_start['file']}; expected the "
                f"requested scan of {first_request['file']}")
    return first_request["file"], None


def single_successful_transfer_error(events, target):
    """Require exactly one complete provider request for one file."""
    requested = events_of(events, event="requested", file=target)
    started = events_of(events, event="started", file=target)
    completed = events_of(events, event="completed", file=target)
    cancelled = events_of(events, event="cancelled", file=target)
    counts = (len(requested), len(started), len(completed), len(cancelled))
    if counts != (1, 1, 1, 0):
        return (f"{target} provider lifecycle was requested/started/completed/"
                f"cancelled={counts}; expected exactly 1/1/1/0")
    if not (requested[0]["seq"] < started[0]["seq"] < completed[0]["seq"]):
        return f"{target} provider lifecycle was out of order"
    return None


def exact_failed_transfers_error(events, target, role, expected):
    """Require exact request/start/failure lifecycles for one provider file."""
    requested = events_of(events, event="requested", role=role, file=target)
    started = events_of(events, event="started", role=role, file=target)
    completed = events_of(events, event="completed", role=role, file=target)
    cancelled = events_of(events, event="cancelled", role=role, file=target)
    counts = (len(requested), len(started), len(completed), len(cancelled))
    wanted = (expected, expected, 0, expected)
    if counts != wanted:
        return (f"{target} failed lifecycle was requested/started/completed/"
                f"cancelled={counts}; expected {wanted}")
    for index, (request, start, terminal) in enumerate(
            zip(requested, started, cancelled)):
        if not request["seq"] < start["seq"] < terminal["seq"]:
            return f"{target} failed lifecycle {index + 1} was out of order"
        if index and cancelled[index - 1]["seq"] >= request["seq"]:
            return f"{target} failed lifecycles overlapped"
    return None


def stall_deadline_error(max_fraction, elapsed_ms, seconds, silence):
    """Prove the movement phase and both bounds of its silence deadline."""
    if max_fraction < 0.35:
        return (f"stall progress reached only {max_fraction:.3f}; the scripted "
                "40% movement phase was not exercised")
    lower_bound_ms = ((seconds * 0.4) + silence) * 1000 - 500
    upper_bound_ms = ((seconds * 0.4) + silence) * 1000 + 1500
    if elapsed_ms is not None and elapsed_ms < lower_bound_ms:
        return (f"the stalled transfer was abandoned after {elapsed_ms}ms, before "
                "movement could stop and the configured silence budget expire "
                f"({lower_bound_ms:.0f}ms lower bound)")
    if elapsed_ms is not None and elapsed_ms > upper_bound_ms:
        return (f"the stalled transfer was abandoned after {elapsed_ms}ms, after "
                "the configured silence deadline should have fired "
                f"({upper_bound_ms:.0f}ms upper bound)")
    return None


def baseline_deadline_error(elapsed_ms, baseline):
    """Require a no-movement timeout to fire near its configured baseline."""
    lower_bound_ms = baseline * 1000 - 300
    upper_bound_ms = baseline * 1000 + 1500
    if elapsed_ms < lower_bound_ms:
        return (f"the transfer was abandoned after {elapsed_ms}ms, before the "
                f"configured {baseline:.1f}s baseline could expire")
    if elapsed_ms > upper_bound_ms:
        return (f"the transfer was abandoned after {elapsed_ms}ms, after the "
                f"configured {baseline:.1f}s baseline should have fired "
                f"({upper_bound_ms:.0f}ms upper bound)")
    return None


def playlist_belongs_to_folder(files, folder_names):
    """A nonempty playlist whose every row resolves to the replacement folder."""
    return bool(files) and set(files).issubset(folder_names)


def exact_playlist_error(files, expected):
    """Reject omission, duplication, replacement and reordering alike."""
    if files != expected:
        return f"append produced {files}; expected the exact ordered rows {expected}"
    return None


def duplicate_order_error(order):
    """Reject a supposedly one-pass provider order that repeats a file."""
    seen = set()
    duplicates = []
    for value in order:
        if value in seen and value not in duplicates:
            duplicates.append(value)
        seen.add(value)
    if duplicates:
        return f"provider order repeated file(s): {duplicates}"
    return None


def deferred_sweep_error(scan, elapsed, lower_bound=1.5, upper_bound=3.5):
    """Validate the stage-one oracle and the nominal 2s fallback's live bound."""
    if not scan.get("stageOneFinished") or not scan.get("pending"):
        return f"the deferred sweep never finished stage 1 with scan records: {scan}"
    if elapsed < lower_bound:
        return (f"the nominal 2s deferred-sweep fallback fired after only "
                f"{elapsed:.2f}s")
    if elapsed > upper_bound:
        return (f"the nominal 2s deferred-sweep fallback took {elapsed:.2f}s "
                "to finish stage 1")
    return None


def fmt_trace(events, limit=60):
    lines = []
    for e in events[-limit:]:
        extra = ""
        if "queuedMs" in e:
            extra = f" queued={e['queuedMs']}ms"
        if "roles" in e:
            extra = f" roles={e['roles']}"
        lines.append(f"  {e['seq']:>3} {e['tMs']:>7}ms {e['event']:<10} "
                     f"{e['role']:<9} {e['file']}{extra}")
    return "\n".join(lines) or "  (no events)"


# --------------------------------------------------------------------------
# Shared assertions
# --------------------------------------------------------------------------


def assert_no_foreground_contention(ctx, events):
    """No background provider request is submitted inside foreground work.

    `requested` precedes the fake provider's capacity queue. Checking only
    `started` lets a forbidden request hide behind capacity=1. Playback and
    prefetch both count as foreground. The still-earlier internal claim edge is
    deterministic coordinator behavior and is covered in XCTest.
    """
    for foreground in ("playback", "prefetch"):
        requested = role_events_inside_requests(
                events, "metadata", foreground, "requested")
        if requested:
            raise Failed(f"a metadata provider request was submitted during a "
                         f"{foreground} request: "
                         + ", ".join(f"{m} inside {p}" for m, p in requested))
        started = role_events_inside_requests(events, "metadata", foreground, "started")
        if started:
            raise Failed(f"a metadata download began during a {foreground} request: "
                         + ", ".join(f"{m} inside {p}" for m, p in started))
    counted = ctx.stats().get("foregroundContentionStarts", 0)
    if counted:
        raise Failed(f"the app counted {counted} foreground contention start(s)")


def wait_for_playlist_resolution(ctx, timeout=WAIT_TIMEOUT):
    """Poll until every listed row has received a metadata result."""
    deadline = time.monotonic() + timeout
    playlist = ctx.playlist()
    while time.monotonic() < deadline:
        playlist = ctx.playlist()
        count = playlist.get("count", 0)
        if count > 0 and playlist.get("resolvedRows", 0) >= count:
            return playlist
        time.sleep(POLL)
    raise Failed(f"playlist did not resolve inside {timeout:.0f}s: {playlist}")


def loading_residue(ctx):
    """All live loading gauges that must read empty at natural or forced rest."""
    health = ctx.health()
    materialization = health.get("materialization", {})
    keys = ("claims", "waiters", "interactiveRunning", "backgroundRunning",
            "interactivePending", "backgroundPending", "handleRuns",
            "datalessProbesInFlight", "handleOpensInFlight")
    live = {key: materialization.get(key, 0) for key in keys
            if materialization.get(key, 0)}
    priority = health.get("priorityLane", {})
    scan = health.get("scanLane", {})
    fake = ctx.stats()
    rows = ctx.cmd("dump_row_loading")
    residue = {}
    if health.get("cloudLaneHeld") or health.get("cloudParsesPending"):
        residue["health"] = health
    if live:
        residue["materialization"] = live
    if (priority.get("pending") or priority.get("inFlight")
            or priority.get("liveTokens") or priority.get("yieldedUnderHold")):
        residue["priorityLane"] = priority
    if (scan.get("pending") or scan.get("delayed") or scan.get("inFlight")
            or scan.get("liveTokens")):
        residue["scanLane"] = scan
    if fake.get("executing") or fake.get("queued"):
        residue["fake"] = fake
    if rows.get("transfers") or rows.get("loadingRows"):
        residue["rowLoading"] = rows
    return residue


def wait_for_loading_settlement(ctx, timeout=WAIT_TIMEOUT):
    """Poll boundedly for all loader/coordinator/provider/row gauges to drain."""
    deadline = time.monotonic() + timeout
    residue = {}
    while time.monotonic() < deadline:
        residue = loading_residue(ctx)
        if not residue:
            return
        time.sleep(POLL)
    raise Failed(f"loading machinery did not settle inside {timeout:.0f}s: {residue}")


def join_live_scan_with_playback(ctx, target_start, row_index, timeout=8):
    """Submit playback while one exact scan transfer is still the claim owner.

    Historical completion is not enough. This samples the original transfer
    live before submission, then requires the foreground waiter to be visible
    while that same start sequence is still live. A second provider request for
    the target is forbidden throughout.
    """
    target = target_start["file"]
    before = ctx.trace()
    exact_before = [(start, end) for start, end
                    in transfer_spans(before, "metadata-scan")
                    if start["seq"] == target_start["seq"]]
    if not exact_before or exact_before[0][1] is not None:
        raise Failed(f"scan of {target} settled before playback could join it")
    live_foreground = [(request, terminal) for request, terminal
                       in request_spans(before, "playback")
                       + request_spans(before, "prefetch")
                       if terminal is None]
    if live_foreground:
        raise Failed(f"foreground work was already live before the join: "
                     f"{[request['file'] for request, _ in live_foreground]}")
    before_health = ctx.materialization()
    if before_health.get("foregroundTransferActive"):
        raise Failed("the coordinator already had a foreground waiter before "
                     f"playback tried to join {target}")
    waiter_count_before = before_health.get("waiters", 0)
    submission_seq = max((e["seq"] for e in before), default=-1)
    ctx.cmd("play_index", row_index)

    deadline = time.monotonic() + timeout
    last_health = {}
    while time.monotonic() < deadline:
        events = ctx.trace()
        repeats = [e for e in events_of(events, event="requested", file=target)
                   if e["seq"] > submission_seq]
        if repeats:
            raise Failed(f"joining {target} submitted a second provider request")
        foreign_foreground = [e for e in events
                              if e["seq"] > submission_seq
                              and e["event"] == "requested"
                              and role_matches(e["role"], "playback")
                              and e["file"] != target]
        foreign_foreground += [e for e in events
                               if e["seq"] > submission_seq
                               and e["event"] == "requested"
                               and role_matches(e["role"], "prefetch")
                               and e["file"] != target]
        if foreign_foreground:
            raise Failed(f"play submission minted unrelated foreground work: "
                         f"{[(e['role'], e['file']) for e in foreign_foreground]}")
        exact = [(start, end) for start, end
                 in transfer_spans(events, "metadata-scan")
                 if start["seq"] == target_start["seq"]]
        if not exact:
            raise Failed(f"the original scan trace for {target} disappeared")
        if exact[0][1] is not None:
            raise Failed(f"scan of {target} settled before the foreground waiter "
                         "was observed on its claim")
        last_health = ctx.materialization()
        if (last_health.get("foregroundTransferActive")
                and last_health.get("waiters", 0) > waiter_count_before):
            confirm = ctx.trace()
            exact_confirm = [(start, end) for start, end
                             in transfer_spans(confirm, "metadata-scan")
                             if start["seq"] == target_start["seq"]]
            if exact_confirm and exact_confirm[0][1] is None:
                return submission_seq
        time.sleep(POLL)
    raise Failed(f"playback waiter never joined live scan {target}: {last_health}")


def open_and_play(ctx, folder, index=0, wait=True):
    """Open a folder and play a row, returning once the play has been submitted.

    The mac's folder open auto-plays row 0, so an explicit play_index is a
    REBIND for index 0 rather than a new open. Scenarios that need a distinct
    foreground open therefore pick a row the auto-play did not.
    """
    ctx.cmd("open", str(folder))
    if wait:
        ctx.wait_for("the folder's first playback transfer",
                     lambda ev: events_of(ev, event="requested", role="playback"))
    if index is not None:
        rows = ctx.playlist().get("files", [])
        if not 0 <= index < len(rows):
            raise Failed(f"cannot select row {index} in playlist {rows}")
        target = rows[index]
        mark = max((e["seq"] for e in ctx.trace()), default=-1)
        ctx.cmd("play_index", index)
        if index != 0:
            ctx.wait_for(
                    f"the explicit playback submission for {target}",
                    lambda ev: [e for e in events_of(
                            ev, event="requested", role="playback", file=target)
                            if e["seq"] > mark])
            deadline = time.monotonic() + 5
            selected = ctx.playlist()
            while (selected.get("currentIndex") != index
                   and time.monotonic() < deadline):
                time.sleep(POLL)
                selected = ctx.playlist()
            if selected.get("currentIndex") != index:
                raise Failed(f"play_index {index} requested {target} but selected "
                             f"index {selected.get('currentIndex')}: {selected}")


def park_selected_open(ctx, index):
    """Pause one exact pending open and prove its neighborhood stays selected."""
    rows = ctx.playlist().get("files", [])
    if not 0 <= index < len(rows):
        raise Failed(f"cannot park row {index} in playlist {rows}")
    target = rows[index]
    events = ctx.wait_for(f"the selected open of {target}",
                          lambda ev: events_of(ev, event="requested",
                                               role="playback", file=target))
    live = [(request, terminal) for request, terminal
            in request_spans(events, "playback")
            if request["file"] == target and terminal is None]
    if not live:
        raise Failed(f"selected open of {target} settled before it could be parked")
    ctx.cmd("play_pause")
    ctx.wait_for(f"the parked open of {target} to complete",
                 lambda ev: events_of(ev, event="completed",
                                      role="playback", file=target),
                 timeout=20)
    deadline = time.monotonic() + 5
    state = {}
    while time.monotonic() < deadline:
        state = ctx.state()
        current = Path((state.get("currentTrack") or {}).get("url", "")).name
        if state.get("player", {}).get("state") == "paused" and current == target:
            return target
        time.sleep(POLL)
    raise Failed(f"selected open did not land paused on {target}: {state}")


def suppress_setup_prefetch(ctx):
    """Keep a setup play from manufacturing successor work for another oracle."""
    reply = ctx.cmd("set_pause_at_track_end", "on")
    if reply.get("pauseAtTrackEnd") is not True:
        raise Failed(f"could not suppress setup prefetch: {reply}")


def discover_playable_rows(ctx, folder, minimum):
    """Ask the app's real folder filter/order for fixture identities, then reset."""
    ctx.arm(seconds=0.01)
    ctx.cmd("open", str(folder))
    ctx.wait_for("the setup folder's playback request",
                 lambda ev: events_of(ev, event="requested", role="playback"))
    rows = ctx.playlist().get("files", [])
    if len(rows) < minimum:
        raise Failed(f"{folder} needs at least {minimum} playable rows, got {rows}")
    ctx.quiesce()
    ctx.cmd("clear_cloud_trace")
    ctx.cmd("clear_caches", timeout=60)
    return rows


# --------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------
#
# Each takes a Ctx, raises Failed with a sentence, and returns a short note for
# the report on success. The app is freshly launched and its caches cleared
# before each one.


def s1_replacement_cancels_the_old_scan(ctx):
    """A folder replacement stops the old folder's downloads before the new
    folder's first open starts. macOS did not do this before the change: only
    iOS cancelled the loader at replacement."""
    a, b = ctx.folders[0], ctx.folders[1]
    # Long enough that replacement, reached through two command-channel round
    # trips, controls the terminal edge rather than racing natural completion.
    ctx.arm(seconds=4.0)
    suppress_setup_prefetch(ctx)
    ctx.cmd("open", str(a))
    a_names = {p.name for p in a.iterdir() if p.is_file()}
    before = ctx.wait_for("an A metadata transfer to start",
                          lambda ev: [(start, end) for start, end
                                      in transfer_spans(ev, "metadata")
                                      if start["file"] in a_names and end is None])
    snapshot_seq = max(item["seq"] for item in before)
    active = [(start, end) for start, end in transfer_spans(before, "metadata")
              if start["file"] in a_names and end is None]
    active_requests = [(request, terminal) for request, terminal
                       in request_spans(before, "metadata")
                       if request["file"] in a_names and terminal is None]
    queued_requests = live_unstarted_requests(
            before, "metadata", a_names, snapshot_seq)
    if not active:
        raise Failed("A had no live metadata transfer at replacement time")
    if not active_requests:
        raise Failed("A had no live metadata request at replacement time")
    # Which files belong to B is known from disk, so B's own playback transfer
    # is identified by name rather than by "the last one", which a rebind or a
    # superseded open would make wrong.
    b_names = {p.name for p in b.iterdir() if p.is_file()}
    ctx.cmd("open", str(b))
    events = ctx.wait_for("B's own playback transfer to start",
                          lambda ev: [e for e in events_of(ev, event="started", role="playback")
                                      if e["file"] in b_names])
    b_requests = [e for e in events_of(events, event="requested", role="playback")
                  if e["file"] in b_names and e["seq"] > snapshot_seq]
    if not b_requests:
        raise Failed("B's playback started without a matching provider request")
    b_request = b_requests[0]
    b_playback = [e for e in events_of(events, event="started", role="playback")
                  if e["file"] in b_names][0]
    if b_playback["file"] != b_request["file"]:
        raise Failed(f"B request/start identity changed: {b_request} -> {b_playback}")
    b_playlist = ctx.playlist()
    b_index = b_playlist.get("currentIndex")
    if (not isinstance(b_index, int)
            or not 0 <= b_index < len(b_playlist.get("files", []))
            or b_playlist["files"][b_index] != b_playback["file"]):
        raise Failed(f"B playback identity disagreed with its playlist: {b_playlist}")
    park_selected_open(ctx, b_index)

    # Observe beyond B's first edge. A departed loader that schedules one last
    # delayed retry can otherwise submit it after this scenario has already
    # declared victory.
    events = ctx.wait_for("B playback to settle and its scan to make progress",
                          lambda ev: any(
                              e["file"] in b_names and e["seq"] > b_playback["seq"]
                              for e in events_of(ev, event="requested",
                                                 role="metadata-scan")))

    # Every transfer known live at the snapshot, plus any A transfer that began
    # in the narrow snapshot-to-open gap, must be cancelled before B consumes
    # its provider slot. The cancellation terminal may validly trail B's
    # requested edge because the fake worker observes cancellation
    # asynchronously. Looking only at the original `active` list missed a late
    # A start that could remain live across B's start.
    retired, error = replacement_retirement_error(
            events, a_names, snapshot_seq, b_request["seq"], b_playback["seq"],
            [start["seq"] for start, _ in active],
            [request["seq"] for request, _ in active_requests])
    if error:
        raise Failed(error)
    assert_no_foreground_contention(ctx, events)
    return (f"{retired} live/queued A request(s) cancelled before B's provider "
            f"start ({len(queued_requests)} had not started at the snapshot)")


def s2_foreground_request_excludes_background_provider_work(ctx):
    """No background provider request is admitted while a picked open is live.

    The earlier claim-registration edge and cache-hit delivery are deterministic
    coordinator/loader behavior covered in XCTest; this is the live wiring from
    shell playback through the provider trace.
    """
    ctx.arm(seconds=4)
    suppress_setup_prefetch(ctx)
    open_and_play(ctx, ctx.folders[0], index=5)
    if not ctx.materialization().get("foregroundTransferActive"):
        raise Failed("the coordinator did not report a foreground transfer after submission")
    park_selected_open(ctx, 5)
    events = ctx.wait_for("several metadata transfers after the open settles",
                          lambda ev: len(events_of(ev, event="completed", role="metadata")) >= 2)
    assert_no_foreground_contention(ctx, events)
    progress = ctx.cmd("dump_metadata_progress")
    if progress.get("attempted", 0) == 0:
        raise Failed("no row had metadata attempted at all — the sweep never ran")
    return (f"{len(events_of(events, event='started', role='metadata'))} metadata transfers, "
            f"none inside foreground provider work; "
            f"{progress['attempted']}/{progress['total']} rows attempted")


def s3_successor_materializes_once(ctx):
    """The successor's bytes are pulled exactly once, whichever role pulls
    them. The prefetch may JOIN a sweep transfer already in flight for the
    same file — one transfer per standardized path — in which case no
    prefetch-role event ever exists: the trace records the transfer under the
    role that started it. So the assertion is on the successor's FILE, not on
    a prefetch-role event (an earlier version waited for `completed
    prefetch` and read the join as a missing prefetch)."""
    ctx.arm()
    open_and_play(ctx, ctx.folders[0], index=3)
    successor = ctx.playlist()["files"][4]
    ctx.wait_for(f"the successor's transfer to complete",
                 lambda ev: events_of(ev, event="completed", file=successor))
    wait_for_playlist_resolution(ctx, timeout=60)
    wait_for_loading_settlement(ctx)
    events = ctx.trace()
    lifecycle_error = single_successful_transfer_error(events, successor)
    if lifecycle_error:
        raise Failed(lifecycle_error)
    if ctx.stats().get("metadataOverlapTransfers"):
        raise Failed("the metadata lane downloaded a file another role was already downloading")
    role = events_of(events, event="completed", file=successor)[0]["role"]
    return f"successor {successor} materialized exactly once (via {role})"


def s4a_rapid_next_keeps_the_hold(ctx):
    """Rapid newer plays cancel every superseded open and keep one hold."""
    ctx.arm(seconds=6.0)
    open_and_play(ctx, ctx.folders[0], index=None, wait=True)
    live_initial = ctx.wait_for(
            "the initial playback transfer to be live",
            lambda ev: [(start, end) for start, end in
                        transfer_spans(ev, "playback") if end is None])
    initial = ctx.playlist()
    start_index = initial.get("currentIndex", 0)
    expected_moves = min(8, max(0, initial.get("count", 0) - start_index - 1))
    live_initial_requests = [(request, terminal) for request, terminal in
                             request_spans(live_initial, "playback")
                             if terminal is None]
    if len(live_initial_requests) != 1:
        raise Failed(f"expected one live initial playback request, got "
                     f"{len(live_initial_requests)}")
    initial_request = live_initial_requests[0][0]
    storm_mark = max((e["seq"] for e in live_initial), default=-1)
    for _ in range(8):
        ctx.cmd("next")
    events = ctx.wait_for(
            "every rapid play request to reach a provider terminal",
            lambda ev: (len([e for e in events_of(
                    ev, event="requested", role="playback")
                    if e["seq"] > storm_mark]) >= expected_moves
                and len([(request, terminal) for request, terminal in
                         request_spans(ev, "playback")
                         if request["seq"] > storm_mark and terminal])
                    >= expected_moves),
            timeout=30)
    newer_spans = [(request, terminal) for request, terminal in
                   request_spans(events, "playback")
                   if request["seq"] > storm_mark]
    initial_spans = [(request, terminal) for request, terminal in
                     request_spans(events, "playback")
                     if request["seq"] == initial_request["seq"]]
    if len(initial_spans) != 1:
        raise Failed("the exact initial playback request disappeared from the trace")
    storm_spans = initial_spans + newer_spans
    submitted = len(newer_spans)
    final_index = ctx.playlist().get("currentIndex")
    if submitted != expected_moves or final_index != start_index + expected_moves:
        raise Failed(f"rapid next landed index {final_index} with {submitted} newer "
                     f"playback request(s); expected index {start_index + expected_moves} "
                     f"and exactly {expected_moves} requests")
    wrong_terminals = [(request["file"],
                        terminal["event"] if terminal else "unterminated")
                       for request, terminal in storm_spans[:-1]
                       if not terminal or terminal["event"] != "cancelled"]
    if wrong_terminals:
        raise Failed(f"superseded rapid plays did not cancel: {wrong_terminals}")
    if storm_spans[-1][1]["event"] != "completed":
        raise Failed(f"the final rapid play settled as "
                     f"{storm_spans[-1][1]['event']}, not completed")
    storm_end = storm_spans[-1][1]["seq"]
    leaked_metadata = [e for e in events_of(
            events, event="requested", role="metadata")
            if initial_request["seq"] < e["seq"] < storm_end]
    if leaked_metadata:
        raise Failed(f"metadata admission opened inside the continuous rapid-play "
                     f"hold: {[(e['role'], e['file']) for e in leaked_metadata]}")
    assert_no_foreground_contention(ctx, events)
    return (f"{len(storm_spans) - 1} superseded opens cancelled before the final one "
            f"settled at index {final_index}; the hold admitted no metadata")


def s4b_replay_stays_out_of_error_while_its_transfer_is_live(ctx):
    """Live smoke that a same-row replay stays non-error while still loading.

    Track identity cannot tell the two plays apart — same AudioTrack, same URL —
    and submission identity is pinned deterministically in XCTest. This stages
    the closest live interleaving the command channel can produce:

        [ one main-thread turn: wait, then submit the replay ] [ possible queued error ]

    The held turn makes that interleaving possible: if the file-open failure is
    dispatched while main is held, replay submission precedes its delivery.
    Two separate commands cannot do that because channel intake is itself on
    main. The chained action must be `play_index`, not asynchronous `open`, so
    the submission occurs in that same turn.

    The provider trace can prove the first transfer completed while main was
    held, but not that the subsequent AVAudioFile failure had already been
    dispatched. This scenario therefore owns only the observable live-app
    smoke: throughout the replay's exact provider span, stale UI error must
    never replace Loading; after that span, its own valid error must appear.
    The queued-error ordering itself remains an XCTest claim."""
    folder = ctx.folders[1]
    bad = folder / "zzz-bad.mp3"
    # Not empty: an empty file fails the coordinator's own check before any
    # transfer, so the error would arrive in milliseconds with nothing staged.
    # Garbage of a real size costs the whole transfer and then fails to open.
    if bad.exists():
        raise Failed(f"refusing to overwrite corpus fixture {bad}")
    created = False
    try:
        bad.write_bytes(os.urandom(64 * 1024))
        created = True
        # Sticky, so the file never reads as materialized and EVERY open of it
        # pays the transfer again; otherwise only the first half of the replay
        # exercise reaches the provider.
        # Unlimited capacity, so a resumed lane can actually start a download
        # rather than queue behind the foreground one.
        pair_seconds = 2.0
        ctx.arm(seconds=pair_seconds, capacity=0, sticky=True)
        ctx.cmd("open", str(folder))
        ctx.wait_for("the folder's rows to be listed",
                     lambda ev: events_of(ev, event="requested", role="playback"))
        rows = ctx.playlist()["files"]
        if bad.name not in rows:
            raise Failed(f"{bad.name} did not appear in the playlist")
        row = rows.index(bad.name)
        valid_error_observations = 0
        live_replay_samples = 0

        for pair in range(3):
            pair_mark = max((e["seq"] for e in ctx.trace()), default=-1)
            ctx.cmd("play_index", row)
            events = ctx.wait_for(
                    f"staged play {pair + 1} to start",
                    lambda ev: [e for e in events_of(
                            ev, event="started", role="playback", file=bad.name)
                            if e["seq"] > pair_mark])
            first_start = [e for e in events_of(
                    events, event="started", role="playback", file=bad.name)
                    if e["seq"] > pair_mark][0]
            # The turn: hold main across the first play's failure, then submit
            # the replay without yielding, so the queued error lands behind it.
            ctx.cmd("block_main", pair_seconds * 1.1,
                    "play_index", row, timeout=60)
            events = ctx.wait_for(
                    f"staged replay {pair + 1} to start",
                    lambda ev: [e for e in events_of(
                            ev, event="started", role="playback", file=bad.name)
                            if e["seq"] > first_start["seq"]])
            starts = [e for e in events_of(
                    events, event="started", role="playback", file=bad.name)
                    if e["seq"] > pair_mark]
            if len(starts) != 2:
                raise Failed(f"staged pair {pair + 1} produced {len(starts)} "
                             "playback starts before its replay sample")
            replay_start = starts[1]
            first_terminals = [e for e in events_of(
                    events, role="playback", file=bad.name)
                    if e["event"] in ("completed", "cancelled")
                    and first_start["seq"] < e["seq"] < replay_start["seq"]]
            if (len(first_terminals) != 1
                    or first_terminals[0]["event"] != "completed"):
                raise Failed(f"staged play {pair + 1} settled as "
                             f"{[e['event'] for e in first_terminals]} before replay; "
                             "the queued post-download open-error race was not staged")

            # This is the stale-error oracle: after main drains the old error,
            # the replay's own provider transfer is still live. Error here can
            # only belong to the superseded play; the valid replay error has no
            # bytes to open yet.
            sampled_live = False
            deadline = time.monotonic() + pair_seconds + 3
            while time.monotonic() < deadline:
                before_state = ctx.trace()
                exact = [(start, end) for start, end in
                         transfer_spans(before_state, "playback")
                         if start["seq"] == replay_start["seq"]]
                if not exact:
                    raise Failed(f"replay {pair + 1}'s exact transfer disappeared")
                if exact[0][1] is not None:
                    break
                display = ctx.state().get("ui", {}).get("displayState")
                after_state = ctx.trace()
                confirmed = [(start, end) for start, end in
                             transfer_spans(after_state, "playback")
                             if start["seq"] == replay_start["seq"]]
                if not confirmed:
                    raise Failed(f"replay {pair + 1}'s exact transfer disappeared")
                if display == "error" and confirmed[0][1] is None:
                    raise Failed(f"the superseded play's error replaced live "
                                 f"replay {pair + 1}")
                if confirmed[0][1] is not None:
                    break
                sampled_live = True
                time.sleep(POLL)
            else:
                raise Failed(f"replay {pair + 1} never reached a provider terminal")
            if not sampled_live:
                raise Failed(f"replay {pair + 1} settled before its stale-error sample")
            live_replay_samples += 1

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if ctx.state().get("ui", {}).get("displayState") == "error":
                    valid_error_observations += 1
                    break
                time.sleep(POLL)
            else:
                raise Failed(f"replay {pair + 1}'s own valid open error never landed")

        events = ctx.trace()
        requests = events_of(events, event="requested", role="playback", file=bad.name)
        starts = events_of(events, event="started", role="playback", file=bad.name)
        completed = events_of(events, event="completed", role="playback", file=bad.name)
        cancelled = events_of(events, event="cancelled", role="playback", file=bad.name)
        lifecycles = list(zip(requests, starts, completed))
        ordered = (len(lifecycles) == 6
                   and all(request["seq"] < start["seq"] < terminal["seq"]
                           for request, start, terminal in lifecycles)
                   and all(lifecycles[index - 1][2]["seq"]
                           < lifecycles[index][0]["seq"]
                           for index in range(1, len(lifecycles))))
        if ((len(requests), len(starts), len(completed), len(cancelled))
                != (6, 6, 6, 0) or not ordered
                or live_replay_samples != 3 or valid_error_observations != 3):
            raise Failed(f"the three staged play/replay pairs produced "
                         f"{len(requests)}/{len(starts)}/{len(completed)}/"
                         f"{len(cancelled)} requested/started/completed/cancelled, "
                         f"{live_replay_samples} live replay sample(s), "
                         f"{valid_error_observations} valid error state(s), and "
                         f"ordered={ordered}")
        assert_no_foreground_contention(ctx, events)
        if ctx.health().get("cloudLaneHeld"):
            raise Failed("the cloud lane is still held after the errors settled")
        return (f"3 staged same-row replay turns kept every replay out of "
                f"error while live, then showed all {valid_error_observations} "
                "valid replay errors, with every provider request settled")
    finally:
        if created:
            bad.unlink(missing_ok=True)


def s5_lane_follows_rank_then_index(ctx):
    """With one provider slot and uniform durations, the serial lane's order is
    the neighborhood's rank and then ascending playlist index — not the order
    the stage-one cache checks happened to finish in."""
    ctx.arm(seconds=2)
    suppress_setup_prefetch(ctx)
    folder = ctx.folders[0]
    open_and_play(ctx, folder, index=0)
    played = park_selected_open(ctx, 0)
    scenario_rows = ctx.playlist().get("files", [])
    resolution_timeout = max(60, len(scenario_rows) * 2.5 + 10)
    wait_for_playlist_resolution(ctx, timeout=resolution_timeout)
    wait_for_loading_settlement(ctx)
    settled = ctx.playlist()
    if (settled.get("files", []) != scenario_rows
            or settled.get("count") != len(scenario_rows)
            or settled.get("resolvedRows") != len(scenario_rows)):
        raise Failed(f"the ordered scan changed or stranded playlist rows: {settled}")
    events = ctx.trace()
    order = started_order(events, "metadata-scan")
    if len(order) < 2:
        raise Failed("fewer than two scan transfers started; ordering was not exercised")
    duplicate_error = duplicate_order_error(order)
    if duplicate_error:
        raise Failed(duplicate_error)
    for scanned in order:
        lifecycle_error = single_successful_transfer_error(events, scanned)
        if lifecycle_error:
            raise Failed(lifecycle_error)
    rows = scenario_rows
    index_of = {name: i for i, name in enumerate(rows)}
    unknown = [f for f in order if f not in index_of]
    if unknown:
        raise Failed(f"traced files not found in the playlist: {unknown[:3]}")
    expected = expected_scan_order(rows, played, order)
    if order != expected:
        raise Failed(f"scan order is not exact rank-then-index: got {order}, expected {expected}")
    completed_other = {e["file"] for e in events_of(events, event="completed")
                       if not role_matches(e["role"], "metadata")}
    unexplained = set(rows) - set(order) - completed_other
    if unexplained:
        raise Failed(f"resolved rows were omitted from the scan order without a "
                     f"playback/prefetch transfer: {sorted(unexplained)}")
    return f"{len(order)} scan transfers followed exact rank-then-index order"


def s6_first_scan_pick_is_neighborhood_ranked(ctx):
    """The first live scan pick is one of the current track's ranked neighbors.

    This is a wiring smoke test, not proof of the stage-one arrival barrier;
    that barrier requires a deterministic loader test with a held cache check.
    """
    ctx.arm(seconds=2)
    suppress_setup_prefetch(ctx)
    folder = ctx.folders[0]
    open_and_play(ctx, folder, index=2)
    played = park_selected_open(ctx, 2)
    events = ctx.wait_for("the lane to be well under way",
                          lambda ev: len(events_of(ev, event="completed", role="metadata")) >= 4)
    order = started_order(events, "metadata-scan")
    if not order:
        raise Failed("no scan transfer started")
    rows = ctx.playlist()["files"]
    if order[0] not in rows:
        raise Failed(f"first lane pick {order[0]} is not in the playlist")
    here = rows.index(played)
    # Next, the one after, the one behind — the neighborhood the cache ranks by.
    neighborhood = {rows[i] for i in (here + 1, here + 2, here - 1) if 0 <= i < len(rows)}
    if order[0] not in neighborhood:
        raise Failed(f"the lane's first pick was {order[0]}, outside the neighborhood "
                     f"of {played} ({sorted(neighborhood)})")
    return f"first pick {order[0]} was in the neighborhood of {played}"


def s7_stand_aside_and_no_stranding(ctx):
    """Playing the scan's current file joins that work, never duplicates it,
    and the remaining rows still converge."""
    # Four seconds leaves enough room for two debug-channel round trips to
    # observe the join while the original transfer is still live.
    ctx.arm(seconds=4.0, capacity=0)
    suppress_setup_prefetch(ctx)
    folder = ctx.folders[0]
    open_and_play(ctx, folder, index=1)
    park_selected_open(ctx, 1)
    events = ctx.wait_for("a metadata scan transfer to be live",
                          lambda ev: [(start, end) for start, end in
                                      transfer_spans(ev, "metadata-scan") if end is None])
    live = [(start, end) for start, end in transfer_spans(events, "metadata-scan")
            if end is None]
    target = live[-1][0]["file"]
    rows = ctx.playlist()["files"]
    if target not in rows:
        raise Failed(f"active scan target {target} is not a playlist row")
    submission_seq = join_live_scan_with_playback(
            ctx, live[-1][0], rows.index(target))
    ctx.cmd("play_pause")
    deadline = time.monotonic() + 20
    landed = False
    while time.monotonic() < deadline:
        state = ctx.state()
        current = Path((state.get("currentTrack") or {}).get("url", "")).name
        completed = [e for e in events_of(
                ctx.trace(), event="completed", file=target)
                     if e["seq"] > submission_seq]
        if (current == target and completed
                and state.get("player", {}).get("state") == "paused"):
            landed = True
            break
        time.sleep(POLL)
    if not landed:
        raise Failed(f"play aimed at the active scan target never landed paused: {target}")
    target_requests = events_of(ctx.trace(), event="requested", file=target)
    if len(target_requests) != 1:
        raise Failed(f"joining {target} produced {len(target_requests)} provider "
                     f"requests instead of reusing the live scan claim")
    if ctx.stats().get("metadataOverlapTransfers"):
        raise Failed("the metadata lane downloaded a file another role was already downloading")
    wait_for_playlist_resolution(ctx, timeout=60)
    wait_for_loading_settlement(ctx)
    settled = ctx.playlist()
    if (settled.get("files", []) != rows
            or settled.get("count") != len(rows)
            or settled.get("resolvedRows") != len(rows)):
        raise Failed(f"the joined scan stranded or changed playlist rows: {settled}")
    events = ctx.trace()
    assert_no_foreground_contention(ctx, events)
    return (f"play joined the live scan of {target} with one provider request; "
            f"all {len(rows)} rows resolved")


# Production's 60-second values and their math are pinned in XCTest. These
# diagnostic values exercise the live monitor -> player -> cancellation wiring
# without making five scenarios spend more than seven minutes asleep.
SHORT_TIMEOUT = 3.0
SUBPERCENT_SURVIVAL_TIMEOUT = 3.0


def _deadline_scenario(ctx, progress_mode, expect_timeout, seconds, watch,
                       baseline=SHORT_TIMEOUT, silence=SHORT_TIMEOUT):
    """Shared body for S8a/b/c: one very slow transfer under a scripted progress
    source, watched for whether the open is abandoned.

    `seconds` is chosen per mode so the expected verdict lands inside `watch`.
    It has to be: the stall script climbs to 40% of the transfer before
    stopping, so a 200s transfer keeps reporting movement until t=80 and its
    deadline is t=100 — past a 95s watch, which reads as "never abandoned" and
    is a harness fault, not the app's."""
    ctx.configure_timeouts(baseline, silence)
    ctx.arm(seconds=seconds, capacity=1, uniform=True, progress=progress_mode)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    started_events = ctx.wait_for(
            "the playback transfer to start",
            lambda ev: events_of(ev, event="started", role="playback"))
    start = events_of(started_events, event="started", role="playback")[-1]
    target = start["file"]
    deadline = time.monotonic() + watch
    abandoned = False
    terminal = None
    max_fraction = 0.0
    while time.monotonic() < deadline:
        ev = ctx.trace()
        cancelled = [e for e in events_of(
                ev, event="cancelled", role="playback", file=target)
                     if e["seq"] > start["seq"]]
        if cancelled:
            abandoned = True
            terminal = cancelled[-1]
            break
        loading = ctx.cmd("dump_row_loading")
        fractions = [float(item.get("progress", 0))
                     for item in loading.get("transfers", [])
                     if item.get("file") == target
                     and float(item.get("progress", 0)) >= 0]
        if fractions:
            max_fraction = max(max_fraction, max(fractions))
        time.sleep(1.0)
    events = ctx.trace()
    spans = [(span_start, span_end) for span_start, span_end
             in transfer_spans(events, "playback")
             if span_start["seq"] == start["seq"]]
    still_live = bool(spans and spans[0][1] is None)
    if abandoned and not expect_timeout:
        raise Failed(f"a healthy transfer under progress={progress_mode} was abandoned")
    if not abandoned and expect_timeout:
        raise Failed(f"a transfer under progress={progress_mode} was never abandoned")
    elapsed_ms = terminal["tMs"] - start["tMs"] if terminal else None
    if terminal and progress_mode == "none":
        error = baseline_deadline_error(elapsed_ms, baseline)
        if error:
            raise Failed(f"progress={progress_mode}: {error}")
    if progress_mode in ("linear", "stall") and max_fraction <= 0:
        raise Failed(f"progress={progress_mode} never published positive progress; "
                     "the movement/stall path was not exercised")
    if progress_mode == "stall":
        error = stall_deadline_error(max_fraction, elapsed_ms, seconds, silence)
        if error:
            raise Failed(error)
    if not expect_timeout and not still_live:
        raise Failed(f"the healthy progress={progress_mode} transfer settled before "
                     "the survival window ended, so no live deadline was tested")
    if expect_timeout:
        return (f"{target} abandoned after {elapsed_ms}ms "
                f"with max progress {max_fraction:.3f}")
    return (f"{target} remained live for {watch:.0f}s while progress reached "
            f"{max_fraction:.3f}")


def s8a_no_progress_times_out(ctx):
    """A provider that publishes no fraction reaches the configured baseline."""
    return _deadline_scenario(ctx, "none", expect_timeout=True,
                              seconds=20, watch=SHORT_TIMEOUT + 5)


def s8b_subpercent_progress_survives(ctx):
    """Sub-percent raw movement keeps a healthy open alive even while the UI
    handler's whole-percent gate remains silent.

    At 600 seconds total, each one-second fake tick advances about 0.17%; the
    three-second silence budget would fire before the first 1% UI delivery if
    the player were wired to the coalesced handler instead of raw movement.
    """
    return _deadline_scenario(ctx, "linear", expect_timeout=False,
                              seconds=600, watch=7,
                              baseline=SUBPERCENT_SURVIVAL_TIMEOUT,
                              silence=SUBPERCENT_SURVIVAL_TIMEOUT)


def s8c_a_stall_after_progress_times_out(ctx):
    """Progress to 40% and then nothing: the stall budget must still fire.

    Diagnostic budgets keep the same shape in seconds: a 12-second transfer
    stops moving near t=5, times out near t=8 and cannot complete until t=12."""
    return _deadline_scenario(ctx, "stall", expect_timeout=True,
                              seconds=12, watch=11)


def s9_unflagged_placeholders(ctx):
    """A placeholder that denies being dataless still waits its turn.

    This guards a HYPOTHETICAL provider, not an observed one. No provider has
    been measured withholding SF_DATALESS; the one named-provider measurement
    in the repo found the opposite (DownloadProgressMonitor.h: Dropbox on
    iPhone reported dataless=1 for the whole transfer, and withheld PROGRESS
    rather than the flag). NSURLUtil.m states the same conditionally — "if a
    provider ever does appear whose placeholders carry no flag" — and names
    where the fix would go. Keep the wording conditional here too: a suite
    that asserts an unobserved fact teaches the next reader something false.

    Were such a provider to exist, the probe's NO would be indistinguishable
    from a genuinely local file at the admission seam, and the local-file
    exemption — load-bearing, and correct for real local files — would route
    its metadata read straight past the foreground hold. Unlimited
    fake-provider capacity ensures the provider queue cannot hide that bypass.
    This stays an explicit expected-fail until the app has a second reliable
    signal or real providers are ruled out; `set_dataless_diag` /
    `dump_dataless_diag` is the instrument for the latter.

    The property has to be measured DURING the picked track's open, not after
    it. "Rows were parsed" is true either way once the open settles — that is
    the sweep doing its job. What only the bypass produces is rows filling
    while the user is still waiting, so the open is made long enough to sample
    inside, and the assertion is that the count does not climb across that
    window. Only cloud-backed rows must hold: an already-local file is exempt
    from the rule by design, but this corpus is all placeholders."""
    # Unlimited capacity is load-bearing: capacity=1 merely queues an illegally
    # admitted metadata request behind playback and makes the trace look clean.
    ctx.arm(seconds=10, capacity=0, uniform=True, unflagged=True)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the picked track's own transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback"))
    ctx.settle(1)
    before = ctx.cmd("dump_metadata_progress")
    ctx.settle(5)
    during = ctx.cmd("dump_metadata_progress")
    events = ctx.trace()

    # Still inside the open, or the sample proves nothing.
    spans = windows(events, "playback")
    if not spans or spans[-1][1] is not None:
        raise Failed("the picked track's open had already settled before the "
                     "sample — the transfer was not long enough to measure in")

    climbed = during.get("attempted", 0) - before.get("attempted", 0)
    playback_requests = role_events_inside_requests(
            events, "metadata", "playback", "requested")
    playback_starts = role_events_inside_requests(
            events, "metadata", "playback", "started")
    prefetch_hits = (role_events_inside_requests(
            events, "metadata", "prefetch", "requested")
            + role_events_inside_requests(
                    events, "metadata", "prefetch", "started"))
    if prefetch_hits:
        raise Failed(f"S9 also observed unexpected prefetch contention: {prefetch_hits}")
    if playback_requests or playback_starts or climbed > 0:
        raise ExpectedGap(
                f"unflagged placeholder bypass: {len(playback_requests)} metadata "
                f"request(s), {len(playback_starts)} start(s), and {climbed} parsed "
                f"row(s) while playback remained live ({before.get('attempted')} -> "
                f"{during.get('attempted')} of {during.get('total')})")
    counted = ctx.stats().get("foregroundContentionStarts", 0)
    if counted:
        raise Failed(f"fake counted {counted} contention start(s) without a "
                     "matching live playback trace")
    return (f"rows held at {during.get('attempted')}/{during.get('total')} across the "
            "open; no bypass observed")


def s10_provider_failure_then_close_settles_clean(ctx):
    """A provider failure settles the open; Close then drains every live gauge."""
    # Fail a real playable file at the provider boundary. An empty synthetic
    # MP3 is rejected before the playback open on some AVFoundation versions,
    # so it cannot prove the error settlement path at all.
    folder = ctx.folders[0]
    playable = discover_playable_rows(ctx, folder, minimum=1)
    bad = folder / playable[0]
    ctx.arm(seconds=0.4, fail=bad.name)
    failed_before = ctx.materialization().get("requestsFailed", 0)
    ctx.cmd("open", str(bad))
    ctx.wait_for("the failing playback transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback",
                                      file=bad.name))
    ctx.wait_for("the provider failure to settle the playback transfer",
                 lambda ev: events_of(ev, event="cancelled", role="playback",
                                      file=bad.name))

    # Poll for the hold to clear rather than sampling at a fixed instant. The
    # exact delivery delay is not part of the contract; eventual settlement is.
    deadline = time.monotonic() + 20
    state = ctx.state()
    materialization = ctx.materialization()
    while time.monotonic() < deadline:
        current = Path((state.get("currentTrack") or {}).get("url", "")).name
        if (state.get("player", {}).get("state") == "stopped"
                and current == bad.name
                and materialization.get("requestsFailed", 0) > failed_before):
            break
        time.sleep(POLL)
        state = ctx.state()
        materialization = ctx.materialization()
    else:
        raise Failed(f"provider failure did not land on stopped {bad.name}: "
                     f"state={state}, materialization={materialization}")
    ctx.quiesce()
    residue = loading_residue(ctx)
    if residue:
        raise Failed(f"Close left loading state behind: {residue}")
    return f"provider error for {bad.name}, then Close, settled to zero"


def s11_append_preserves_and_fast_path(ctx):
    """The real AppDelegate append funnel preserves the pending first row, and
    replaying an already-materialized file is a no-transfer fast path.

    A provider trace cannot attribute the eventual sweep to the append or to
    the pending play's settlement, so this scenario deliberately makes no
    sweep-ownership claim.
    """
    folder = ctx.folders[0]
    playable = discover_playable_rows(ctx, folder, minimum=4)
    files = [folder / name for name in playable[:4]]
    ctx.arm(seconds=4)
    suppress_setup_prefetch(ctx)
    ctx.cmd("open", str(files[0]))
    events = ctx.wait_for("the first file's transfer to start",
                          lambda ev: events_of(ev, event="started", role="playback"))
    first_start = events_of(events, event="started", role="playback")[-1]
    first_name = ctx.playlist()["files"][0]
    # Append during Loading through the actual deliberate-open funnel.
    for f in files[1:4]:
        ctx.cmd("append", str(f))
    first_spans = [(start, end) for start, end in transfer_spans(
            ctx.trace(), "playback") if start["seq"] == first_start["seq"]]
    if len(first_spans) != 1 or first_spans[0][1] is not None:
        raise Failed("the first playback transfer was no longer live after all "
                     "three appends, so append-during-Loading was not exercised")
    first_name = park_selected_open(ctx, 0)
    expected_files = [f.name for f in files]
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and ctx.playlist().get("count") != 4:
        time.sleep(POLL)
    playlist = ctx.playlist()
    error = exact_playlist_error(playlist.get("files"), expected_files)
    if error:
        raise Failed(error)
    ctx.settle(6)
    events = ctx.trace()
    assert_no_foreground_contention(ctx, events)

    # The fast path: replay a file whose transfer has already completed.
    rows = ctx.playlist()["files"]
    done = {e["file"] for e in events_of(events, event="completed") if e["file"] in rows}
    current_before = Path((ctx.state().get("currentTrack") or {}).get("url", "")).name
    replay_candidates = [name for name in rows
                         if name in done and name != current_before]
    if not replay_candidates:
        raise Failed("no non-current file completed, so a dropped fast-path replay "
                     "could not be distinguished from the existing selection")
    target = replay_candidates[0]
    target_index = rows.index(target)
    # By sequence number, not by list position: the trace is a bounded ring, so
    # an index into it stops meaning the same event once it wraps.
    mark = max((e["seq"] for e in ctx.trace()), default=-1)
    ctx.cmd("play_index", target_index)
    ctx.cmd("play_pause")
    deadline = time.monotonic() + 5
    replay_state = {}
    while time.monotonic() < deadline:
        replay_state = ctx.state()
        current = Path((replay_state.get("currentTrack") or {}).get("url", "")).name
        if (current == target
                and replay_state.get("player", {}).get("state") == "paused"):
            break
        time.sleep(POLL)
    else:
        raise Failed(f"fast-path replay did not land paused on {target}: {replay_state}")
    ctx.settle(0.5)
    replayed = [e for e in ctx.trace()
                if e["seq"] > mark and e["event"] == "requested" and e["file"] == target]
    if replayed:
        raise Failed(f"replaying an already-materialized file asked for a second "
                     f"transfer: {target}")
    final_state = ctx.state()
    current = Path((final_state.get("currentTrack") or {}).get("url", "")).name
    if current != target or final_state.get("player", {}).get("state") != "paused":
        raise Failed(f"fast-path replay did not remain parked on {target}: {final_state}")
    return f"three real appends preserved {first_name}; replay of {target} cost no transfer"


def _timeout_abandonment_scenario(ctx, progress_mode, seconds, watch):
    """Time an open out under a scripted progress source, then assert the
    abandoned pick is NOT chased into the provider's next slot: the next fetch
    is an ordinary sweep choice and playback stays stopped. Its eventual place
    later in that full sweep is deterministic ranking covered by loader XTests,
    not part of this live timeout-wiring scenario.

    An earlier design ranked a pick that had shown progress back in first
    (1b8e03e, "chase a timed-out pick only if it was still moving"); the
    loading rewrite in 597f6fc removed it, and the retirement is deliberate:
    under the extend-on-movement deadline (AudioFileOpenTimeoutMath.h) any
    abandoned transfer has by definition been silent for its whole 60s
    budget — there is no "still moving at the deadline" case left to chase,
    only a stalled one, and re-fetching a stalled transfer spends the
    provider's next slot behind a terminal error the user is looking at.
    Both progress modes therefore assert the same verdict."""
    ctx.configure_timeouts(SHORT_TIMEOUT, SHORT_TIMEOUT)
    ctx.arm(seconds=seconds, capacity=1, uniform=True, progress=progress_mode)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    events = ctx.wait_for("the playback transfer to start",
                          lambda ev: events_of(ev, event="started", role="playback"))
    picked = events_of(events, event="started", role="playback")[-1]["file"]
    start = events_of(events, event="started", role="playback")[-1]
    deadline = time.monotonic() + watch
    cancellation = None
    max_fraction = 0.0
    while time.monotonic() < deadline:
        cancelled = events_of(ctx.trace(), event="cancelled", role="playback", file=picked)
        if cancelled:
            cancellation = cancelled[-1]
            break
        loading = ctx.cmd("dump_row_loading")
        fractions = [float(item.get("progress", 0))
                     for item in loading.get("transfers", [])
                     if item.get("file") == picked
                     and float(item.get("progress", 0)) >= 0]
        if fractions:
            max_fraction = max(max_fraction, max(fractions))
        time.sleep(1.0)
    else:
        raise Failed("the open was never abandoned, so there is no timeout to follow")

    deadline = time.monotonic() + 10
    state = ctx.state()
    while time.monotonic() < deadline and state.get("player", {}).get("state") != "stopped":
        time.sleep(POLL)
        state = ctx.state()
    if state.get("player", {}).get("state") != "stopped":
        raise Failed(f"playback landed {state.get('player', {}).get('state')} "
                     "after timeout, not stopped")
    elapsed_ms = cancellation["tMs"] - start["tMs"]
    if progress_mode == "stall":
        error = stall_deadline_error(max_fraction, elapsed_ms, seconds, SHORT_TIMEOUT)
        if error:
            raise Failed(error)
    else:
        error = baseline_deadline_error(elapsed_ms, SHORT_TIMEOUT)
        if error:
            raise Failed(error)

    # Whatever the verdict, the sweep must run: the deferred load is released
    # by the error path either way.
    events = ctx.wait_for("a metadata transfer to consume the next provider slot",
                          lambda ev: [e for e in events_of(
                              ev, event="started", role="metadata")
                              if e["seq"] > cancellation["seq"]],
                          timeout=40)
    first, error = post_timeout_scan_pick(events, cancellation["seq"], picked)
    if error:
        raise Failed(error)
    progress_note = (f" after reaching {max_fraction:.3f} progress"
                     if progress_mode == "stall" else "")
    return (f"{first}, not abandoned {picked}, consumed the provider's next "
            f"slot{progress_note}; playback stayed stopped")


def s12a_a_dead_timeout_is_not_chased(ctx):
    """A pick that timed out having shown NO progress stays an ordinary sweep
    candidate rather than taking the provider's next slot."""
    return _timeout_abandonment_scenario(ctx, "none", seconds=20,
                                         watch=SHORT_TIMEOUT + 5)


def s12b_a_stalled_timeout_is_not_chased_either(ctx):
    """Progress to 40% and then nothing: the abandoned pick is judged the same
    as one that never moved. The old moving/dead distinction died with the
    deadline redesign — see _timeout_abandonment_scenario."""
    return _timeout_abandonment_scenario(ctx, "stall", seconds=12, watch=11)


def s13_one_download_per_claimed_file(ctx):
    """One file is never downloaded by two roles at once.

    Pre-refactor this was a check-then-act seam — isMaterializingURL: was a
    query followed later by an act, so a claim registered between the two
    could in principle let playback and the sweep download the same bytes
    (review item 5, an expected-fail until the coordinator merge; the timing
    never actually produced it). Now the property holds by construction:
    materialization is one path-keyed claim table, so a play aimed at the
    sweep's own current pick JOINS that claim rather than racing it, and the
    fake's metadataOverlapTransfers counter is the ground truth that no
    duplicate transfer ever ran."""
    # Unlimited capacity is the negative control: a duplicate could really run
    # instead of hiding in a one-slot provider queue.
    ctx.arm(seconds=4.0, capacity=0)
    suppress_setup_prefetch(ctx)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    park_selected_open(ctx, 0)
    events = ctx.wait_for(
            "a scan transfer to be live",
            lambda ev: [(start, end) for start, end in
                        transfer_spans(ev, "metadata-scan") if end is None])
    rows = ctx.playlist()["files"]
    index_of = {name: i for i, name in enumerate(rows)}
    live = [(start, end) for start, end in transfer_spans(events, "metadata-scan")
            if end is None]
    target_start = live[-1][0]
    target = target_start["file"]
    if target not in index_of:
        raise Failed(f"active scan target {target} is not a playlist row")
    submission_seq = join_live_scan_with_playback(
            ctx, target_start, index_of[target])
    ctx.cmd("play_pause")
    deadline = time.monotonic() + 20
    landed = False
    while time.monotonic() < deadline:
        state = ctx.state()
        current = Path((state.get("currentTrack") or {}).get("url", "")).name
        completed = [e for e in events_of(
                ctx.trace(), event="completed", file=target)
                     if e["seq"] > submission_seq]
        if (current == target and completed
                and state.get("player", {}).get("state") == "paused"):
            landed = True
            break
        time.sleep(POLL)
    if not landed:
        raise Failed(f"play of the active scan target never landed paused: {target}")
    ctx.settle(1)
    overlaps = ctx.stats().get("metadataOverlapTransfers", 0)
    if overlaps:
        raise Failed(f"the metadata lane downloaded a file another role was "
                     f"already downloading {overlaps} time(s)")
    requests = events_of(ctx.trace(), event="requested", file=target)
    if len(requests) != 1:
        raise Failed(f"active scan join for {target} produced {len(requests)} "
                     "provider requests")
    return f"play joined active scan of {target}; exactly one provider transfer ran"


def s14_storm_then_close_drains_loading_state(ctx):
    """Close drains work after play storms spanning a playlist replacement.

    Priority retry decisions themselves are deterministic and covered by the
    real-loader XTests. A UI-driven storm cannot promise that it creates
    a priority record: the current track often joins the existing playback
    claim and never emits a metadata-priority transfer. This live case owns the
    repeated-supersession and forced-teardown accounting half instead. S1 owns
    the cache-to-loader replacement composition; the loader XCTest pins what
    cancellation itself drops."""
    ctx.arm(seconds=20.0)
    open_and_play(ctx, ctx.folders[0], index=None, wait=True)
    rows = ctx.playlist()["files"]
    a_names = set(rows)
    a_storm_mark = max((e["seq"] for e in ctx.trace()), default=-1)
    for i in range(min(10, len(rows))):
        ctx.cmd("play_index", i)
    # Replace the playlist mid-storm: the old loader's records and claims must
    # die with it, then the replacement must survive another burst.
    b_names = {path.name for path in ctx.folders[1].iterdir() if path.is_file()}
    before_events = ctx.wait_for(
            "multiple folder A storm transfers to cancel",
            lambda ev: len([e for e in events_of(
                    ev, event="cancelled", role="playback")
                    if e["seq"] > a_storm_mark and e["file"] in a_names]) >= 2,
            timeout=10)
    a_cancelled = len([e for e in events_of(
            before_events, event="cancelled", role="playback")
            if e["seq"] > a_storm_mark and e["file"] in a_names])
    before_seq = before_events[-1]["seq"] if before_events else -1
    ctx.cmd("open", str(ctx.folders[1]))
    ctx.wait_for("the replacement's playback transfer",
                 lambda ev: [e for e in events_of(
                         ev, event="requested", role="playback")
                         if e["seq"] > before_seq and e["file"] in b_names])
    deadline = time.monotonic() + 10
    replacement = ctx.playlist()
    while time.monotonic() < deadline:
        files = replacement.get("files", [])
        if playlist_belongs_to_folder(files, b_names):
            break
        time.sleep(POLL)
        replacement = ctx.playlist()
    rows = replacement.get("files", [])
    if not playlist_belongs_to_folder(rows, b_names):
        raise Failed(f"the replacement playlist never became folder B: {replacement}")
    b_storm_mark = max((e["seq"] for e in ctx.trace()), default=-1)
    for i in range(min(6, len(rows))):
        ctx.cmd("play_index", i)
    events = ctx.wait_for(
            "multiple folder B storm transfers to cancel with a final one live",
            lambda ev: (len([e for e in events_of(
                    ev, event="requested", role="playback")
                    if e["seq"] > b_storm_mark and e["file"] in b_names]) >= 2
                and len([e for e in events_of(
                    ev, event="cancelled", role="playback")
                    if e["seq"] > b_storm_mark and e["file"] in b_names]) >= 2
                and any(start["seq"] > b_storm_mark
                        and start["file"] in b_names and end is None
                        for start, end in transfer_spans(ev, "playback"))),
            timeout=10)
    b_requests = [e for e in events_of(events, event="requested", role="playback")
                  if e["seq"] > b_storm_mark and e["file"] in b_names]
    live_b = [(start, end) for start, end in transfer_spans(events, "playback")
              if start["seq"] > b_storm_mark
              and start["file"] in b_names and end is None]
    if len(live_b) != 1:
        raise Failed(f"expected one exact B transfer live before Close, got {live_b}")
    forced_start = live_b[0][0]

    ctx.quiesce()
    after_close = ctx.trace()
    forced = [(start, end) for start, end in transfer_spans(after_close, "playback")
              if start["seq"] == forced_start["seq"]]
    if (len(forced) != 1 or forced[0][1] is None
            or forced[0][1]["event"] != "cancelled"):
        raise Failed(f"the B transfer live at Close did not cancel: {forced}")
    b_cancelled_after = [e for e in events_of(
            after_close, event="cancelled", role="playback")
            if e["seq"] > b_storm_mark and e["file"] in b_names]
    residue = loading_residue(ctx)
    if residue:
        raise Failed(f"Close after replacement storm left work behind: {residue}")
    return (f"{a_cancelled} A cancellations plus {len(b_requests)} B requests/"
            f"{len(b_cancelled_after)} B cancellations including the live Close edge; "
            "loader, coordinator, provider and row registry all drained")




def s15_a_failing_file_spends_its_budget_and_stops(ctx):
    """A file whose transfers always fail is retried exactly to the budget —
    three attempts, spec D7 — then dropped for the session: the request rate
    for it goes flat while every other row completes. The live analogue of
    the ledger regression 925209b fixed, staged with the fake's fail= mode
    (transfers run to term, then report a provider error)."""
    folder = ctx.folders[0]
    # Ask the actual open/filter/sort path which rows exist before choosing the
    # victim. Deriving it from directory entries accidentally selected cover
    # art or another non-audio file in a custom corpus, and forcing name sort
    # persisted over the user's preference after the runner exited.
    rows = discover_playable_rows(ctx, folder, minimum=2)
    victim = rows[len(rows) // 2]
    if victim == rows[0]:
        raise Failed(f"could not choose a non-playing retry victim from {rows}")

    ctx.arm(seconds=1.0, fail=victim)
    suppress_setup_prefetch(ctx)
    ctx.cmd("open", str(folder))
    ctx.wait_for("the folder's playback request",
                 lambda ev: events_of(ev, event="requested", role="playback"))
    opened = ctx.playlist()
    if opened.get("files", []) != rows:
        raise Failed(f"retry setup changed the discovered playlist: {opened}")
    if opened.get("files", [victim])[0] == victim:
        raise Failed(f"failing victim {victim} became auto-play row 0; retry "
                     "coverage setup is invalid")
    park_selected_open(ctx, 0)
    ctx.wait_for("the sweep to reach and retry the failing file",
                 lambda ev: len(events_of(ev, event="requested", role="metadata",
                                          file=victim)) >= 3,
                 timeout=60)
    ctx.settle(6)
    events = ctx.trace()
    attempts = len(events_of(events, event="requested", role="metadata", file=victim))
    error = exact_failed_transfers_error(events, victim, "metadata", 3)
    if error:
        raise Failed(error)
    before = attempts
    ctx.settle(5)
    after = len(events_of(ctx.trace(), event="requested", role="metadata", file=victim))
    if after > before:
        raise Failed(f"{victim} is still being retried at rest: {before} -> {after}")
    expected_resolved = len(rows) - 1
    deadline = time.monotonic() + 20
    playlist = ctx.playlist()
    while (playlist.get("resolvedRows", 0) < expected_resolved
           and time.monotonic() < deadline):
        time.sleep(POLL)
        playlist = ctx.playlist()
    if (playlist.get("files", []) != rows
            or playlist.get("count") != len(rows)
            or playlist.get("resolvedRows") != expected_resolved):
        raise Failed(f"non-failing rows did not all resolve: {playlist}")
    wait_for_loading_settlement(ctx)
    settled = ctx.playlist()
    if (settled.get("files", []) != rows
            or settled.get("count") != len(rows)
            or settled.get("resolvedRows") != expected_resolved):
        raise Failed(f"the retry playlist changed while loading settled: {settled}")
    progress = ctx.cmd("dump_metadata_progress")
    if (progress.get("attempted"), progress.get("total")) \
            != (expected_resolved, len(rows)):
        raise Failed(f"metadata progress disagrees with the retry result: {progress}")
    return (f"{victim} spent exactly {attempts} attempts and stopped; "
            f"{progress.get('attempted', '?')}/{progress.get('total', '?')} rows attempted")


def s16_close_during_a_live_transfer_starts_nothing(ctx):
    """File > Close while the playback transfer is still moving: no metadata
    transfer may start inside that transfer's remaining window (spec C5), and
    everything settles to zero. The regression test for the closeFile:
    ordering bug — the hold was once released before stop's supersession
    landed, draining parked metadata claims into the dying open's window."""
    ctx.arm(seconds=20)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    events = ctx.wait_for("the playback transfer to start",
                          lambda ev: events_of(ev, event="started", role="playback"))
    picked = events_of(events, event="started", role="playback")[-1]["file"]
    close_mark = max(e["seq"] for e in events)
    # quiesce runs closeFile: first, then waits for the pending counters.
    ctx.quiesce()
    events = ctx.trace()
    cancelled = [e for e in events_of(
            events, event="cancelled", role="playback", file=picked)
            if e["seq"] > close_mark]
    if not cancelled:
        raise Failed("Close did not cancel the live playback transfer")
    assert_no_foreground_contention(ctx, events)
    post_close_metadata = [e for e in events
                           if e["seq"] > close_mark
                           and role_matches(e["role"], "metadata")
                           and e["event"] in ("requested", "started")]
    if post_close_metadata:
        raise Failed("Close admitted metadata provider work behind the cancelled "
                     f"playback: {[(e['event'], e['file']) for e in post_close_metadata]}")
    residue = loading_residue(ctx)
    if residue:
        raise Failed(f"Close left cloud state behind: {residue}")
    return "Close cancelled the transfer with no later metadata request or start"


def s17_play_pause_during_loading_lands_parked(ctx):
    """play_pause while the open is still materializing flips the landing:
    the open completes and the track parks paused instead of playing
    (spec B2). The transfer itself must complete — the toggle changes the
    landing intent, never the open."""
    ctx.arm(seconds=4)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    events = ctx.wait_for("the playback transfer to start",
                          lambda ev: events_of(ev, event="started", role="playback"))
    picked = events_of(events, event="started", role="playback")[-1]["file"]
    state = ctx.state()["player"]["state"]
    if state != "playing":
        raise Failed(f"expected the pending intent to read playing, got {state}")
    ctx.cmd("play_pause")
    ctx.wait_for("the playback transfer to complete",
                 lambda ev: events_of(ev, event="completed", role="playback",
                                      file=picked),
                 timeout=20)
    ctx.settle(2)
    state = ctx.state()["player"]["state"]
    if state != "paused":
        raise Failed(f"the open landed {state}, not paused")
    current = Path((ctx.state().get("currentTrack") or {}).get("url", "")).name
    if current != picked:
        raise Failed(f"pause landing applied to {current}, not submitted {picked}")
    error = single_successful_transfer_error(ctx.trace(), picked)
    if error:
        raise Failed(error)
    return f"{picked} landed parked; its exact transfer ran to term"


def s18_a_wedged_open_still_starts_the_sweep(ctx):
    """The deferral's 2s fallback (spec D4): an open that never settles must
    not strand the playlist unpopulated. The sweep's stage 1 runs — pending
    records pile up — while the open is still Loading; its dataless stage 2
    correctly stays gated behind the foreground rule."""
    ctx.arm(seconds=300, progress="stall")
    folder = ctx.folders[0]
    submitted_at = time.monotonic()
    ctx.cmd("open", str(folder))
    ctx.wait_for("the playback transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback"))
    deadline = time.monotonic() + 8
    scan = {}
    while time.monotonic() < deadline:
        health = ctx.health()
        scan = health.get("scanLane", {})
        if scan.get("stageOneFinished") and scan.get("pending"):
            break
        time.sleep(0.5)
    fallback_elapsed = time.monotonic() - submitted_at
    error = deferred_sweep_error(scan, fallback_elapsed)
    if error:
        raise Failed(error)
    state = ctx.state()["player"]["state"]
    if state != "playing":
        raise Failed(f"the pending playback intent should read playing, got {state}")
    events = ctx.trace()
    assert_no_foreground_contention(ctx, events)
    # Why no metadata transfer started, which this scenario could not say until
    # it read the gate. "Correctly held by the foreground rule" and "unable to
    # start at all" produce the identical trace, and asserting only the trace
    # is what let S19's bug hide behind a green S18.
    if not ctx.materialization().get("foregroundTransferActive"):
        raise Failed("no metadata transfer started, but the foreground rule was "
                     "NOT in force — this is starvation, not the hold")
    return (f"the 2s fallback finished stage 1 in {fallback_elapsed:.2f}s and filed "
            f"{len(scan['pending'])} scan row(s) behind the wedged open; "
            "stage 2 stayed gated by a live foreground transfer")


def s19_a_wedged_successor_open_does_not_starve_the_sweep(ctx):
    """A successor's handle open that never returns must not stop every other
    background transfer for the rest of the process.

    S18 wedges stage ONE — the download — so it never reaches a handle open.
    This wedges stage TWO: the transfer completes, and the uncancellable
    AVAudioFile call it fed is what never comes back. That is the shape that
    reproduced the original starvation, and the fake provider could not stage
    it until hang_open existed.

    Written as an instance of the progress oracle rather than as a trace
    assertion, because "no metadata transfer started" is ambiguous on its own:
    demand outstanding, plus no foreground gate in force, plus no progress, is
    the three-part statement that means starvation and nothing else.
    """
    ctx.arm(seconds=TRANSFER, capacity=1)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the folder's first playback transfer",
                 lambda ev: events_of(ev, event="requested", role="playback"))
    rows = ctx.playlist()["files"]
    if len(rows) < 4:
        raise Failed(f"{folder} has too few rows to observe a sweep")
    ctx.cmd("hang_open", rows[1])
    ctx.wait_for_hung_open(rows[1], "the successor's handle open to wedge")
    resolved_before = ctx.playlist().get("resolvedRows", 0)

    # Everything from here is after the wedge, so a start proves the lane is
    # still admitting rather than merely that it once did.
    ctx.cmd("clear_cloud_trace")
    ctx.settle(8)

    materialization = ctx.materialization()
    health = ctx.health()
    scan = health.get("scanLane", {})
    demand = len(scan.get("pending", [])) + len(scan.get("delayed", [])) \
            + int(bool(scan.get("inFlight")))
    gated = materialization.get("foregroundTransferActive")
    progress = events_of(ctx.trace(), event="started", role="metadata-scan")
    unique_progress = {event["file"] for event in progress}
    resolved_after = ctx.playlist().get("resolvedRows", 0)
    try:
        hung = ctx.cmd("hang_open", rows[1]).get("hungOpens", 0)
        if hung < 1 or materialization.get("handleOpensInFlight", 0) < 1:
            raise Failed("the successor open was no longer wedged during the progress sample")
        if gated:
            raise Failed("the foreground rule was still in force 8s after the "
                         "transfer settled — this scenario proves nothing")
        if demand == 0 and not progress:
            raise Failed("no rows left to scan — the sweep finished before the "
                         "wedge landed, so this scenario proves nothing")
        if len(unique_progress) < 2 or resolved_after <= resolved_before:
            raise Failed(f"{demand} rows still want scanning, no foreground "
                         f"transfer holds the lane, but only {len(unique_progress)} "
                         f"unique scan transfer(s) started and resolved rows moved "
                         f"{resolved_before}->{resolved_after} in 8s: the wedged open "
                         f"({materialization.get('handleOpensInFlight')} in "
                         f"flight) is holding admission")
    finally:
        ctx.cmd("hang_open", "release")
    return (f"{len(unique_progress)} unique scan transfers advanced resolved rows "
            f"{resolved_before}->{resolved_after} while the successor open stayed wedged")


def s20_row_loading_tracks_live_provider_transfers(ctx):
    """The registry and playlist-row loading projection agree while a provider
    transfer runs, are bounded by capacity, and both clear at settlement."""
    ctx.arm(seconds=4, capacity=1)
    suppress_setup_prefetch(ctx)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    events = ctx.wait_for("the playback transfer to start",
                          lambda ev: events_of(ev, event="started", role="playback"))
    playback_start = events_of(events, event="started", role="playback")[-1]
    playback_file = playback_start["file"]
    playback_playlist = ctx.playlist()
    if playback_file not in playback_playlist.get("files", []):
        raise Failed(f"playback transfer is not a playlist row: {playback_playlist}")
    playback_index = playback_playlist["files"].index(playback_file)
    if playback_playlist.get("currentIndex") != playback_index:
        raise Failed(f"playback row is not selected: {playback_playlist}")
    deadline = time.monotonic() + 5
    loading = {}
    while time.monotonic() < deadline:
        before = ctx.trace()
        before_live = [(start, end) for start, end
                       in transfer_spans(before, "playback")
                       if start["seq"] == playback_start["seq"] and end is None]
        if not before_live:
            raise Failed(f"playback transfer {playback_file} settled before its "
                         "live row projection could be sampled")
        loading = ctx.cmd("dump_row_loading")
        after = ctx.trace()
        after_live = [(start, end) for start, end
                      in transfer_spans(after, "playback")
                      if start["seq"] == playback_start["seq"] and end is None]
        if not after_live:
            raise Failed(f"row state for {playback_file} was sampled after its "
                         "playback transfer settled")
        projection_error = row_loading_projection_error(
                loading, playback_file, playback_index)
        if projection_error is None:
            break
        time.sleep(POLL)
    else:
        raise Failed(f"live playback transfer {playback_file} was not projected "
                     f"as the sole loading row: {loading}")
    current_index = ctx.playlist().get("currentIndex")
    if not isinstance(current_index, int):
        raise Failed(f"playback row had no selected index: {ctx.playlist()}")
    park_selected_open(ctx, current_index)

    events = ctx.wait_for("a metadata scan transfer after playback",
                          lambda ev: [(start, end) for start, end
                                      in transfer_spans(ev, "metadata-scan")
                                      if end is None],
                          timeout=30)
    live_scans = [(start, end) for start, end
                  in transfer_spans(events, "metadata-scan") if end is None]
    scan_start = live_scans[-1][0]
    scan_file = scan_start["file"]
    scan_playlist = ctx.playlist()
    if scan_file not in scan_playlist.get("files", []):
        raise Failed(f"scan transfer is not a playlist row: {scan_playlist}")
    scan_index = scan_playlist["files"].index(scan_file)
    deadline = time.monotonic() + 5
    scan_loading = {}
    while time.monotonic() < deadline:
        before = ctx.trace()
        before_live = [(start, end) for start, end
                       in transfer_spans(before, "metadata-scan")
                       if start["seq"] == scan_start["seq"] and end is None]
        if not before_live:
            raise Failed(f"metadata transfer {scan_file} settled before its live "
                         "row projection could be sampled")
        scan_loading = ctx.cmd("dump_row_loading")
        after = ctx.trace()
        after_live = [(start, end) for start, end
                      in transfer_spans(after, "metadata-scan")
                      if start["seq"] == scan_start["seq"] and end is None]
        if not after_live:
            raise Failed(f"row state for {scan_file} was sampled after its metadata "
                         "transfer settled")
        projection_error = row_loading_projection_error(
                scan_loading, scan_file, scan_index)
        if projection_error is None:
            break
        time.sleep(POLL)
    else:
        raise Failed(f"metadata transfer {scan_file} was not projected as the "
                     f"one live loading row: {scan_loading}")

    ctx.quiesce()
    settled = ctx.cmd("dump_row_loading")
    if settled.get("transfers") or settled.get("loadingRows"):
        raise Failed(f"loading publication survived settlement: {settled}")
    return (f"playback {playback_file} and scan {scan_file} each appeared as the "
            "sole live row and cleared at settlement")


def s21_the_library_converges(ctx):
    """Every row ends up with metadata. Stated in user terms and in no terms
    at all about lanes, claims or slots, so it outlives any refactor of the
    mechanism and catches the whole silent-stall class rather than one bug.
    """
    ctx.arm(seconds=0.2, capacity=1)
    suppress_setup_prefetch(ctx)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the folder's first playback transfer",
                 lambda ev: events_of(ev, event="requested", role="playback"))
    # Paused, so advancing playback does not keep minting foreground work that
    # legitimately holds the sweep back for the whole run.
    ctx.cmd("play_pause")

    deadline = time.monotonic() + 60
    playlist = ctx.playlist()
    expected_count = playlist.get("count", 0)
    if expected_count < 6:
        raise Failed(f"convergence needs at least six playable rows: {playlist}")
    if playlist.get("resolvedRows", 0) >= playlist.get("count", 0):
        raise Failed("the supposedly cold library was already fully resolved at scenario start")
    resolved = playlist.get("resolvedRows", 0)
    stalled_since = time.monotonic()
    while time.monotonic() < deadline:
        playlist = ctx.playlist()
        if playlist.get("count", 0) != expected_count:
            raise Failed(f"the library changed size during convergence: "
                         f"expected {expected_count}, got {playlist}")
        now_resolved = playlist.get("resolvedRows", 0)
        if now_resolved == expected_count:
            events = ctx.trace()
            if not events_of(events, event="requested", role="metadata-scan"):
                raise Failed("all rows resolved without exercising a scan transfer")
            wait_for_loading_settlement(ctx)
            settled = ctx.playlist()
            if (settled.get("count", 0), settled.get("resolvedRows", 0)) \
                    != (expected_count, expected_count):
                raise Failed(f"the library changed while loading settled: {settled}")
            return f"all {expected_count} rows resolved and loading machinery settled"
        if now_resolved != resolved:
            resolved, stalled_since = now_resolved, time.monotonic()
        elif time.monotonic() - stalled_since > 20:
            break
        time.sleep(0.5)
    materialization = ctx.materialization()
    raise Failed(f"the sweep stopped at {resolved}/{playlist.get('count')} rows "
                 f"(admission refusals {materialization.get('requestsAdmissionExhausted')}, "
                 f"opens in flight {materialization.get('handleOpensInFlight')})")


SCENARIOS = [
    ("S1", s1_replacement_cancels_the_old_scan, False),
    ("S2", s2_foreground_request_excludes_background_provider_work, False),
    ("S3", s3_successor_materializes_once, False),
    ("S4a", s4a_rapid_next_keeps_the_hold, False),
    ("S4b", s4b_replay_stays_out_of_error_while_its_transfer_is_live, False),
    ("S5", s5_lane_follows_rank_then_index, False),
    ("S6", s6_first_scan_pick_is_neighborhood_ranked, False),
    ("S7", s7_stand_aside_and_no_stranding, False),
    ("S8a", s8a_no_progress_times_out, False),
    ("S8b", s8b_subpercent_progress_survives, False),
    ("S8c", s8c_a_stall_after_progress_times_out, False),
    ("S9", s9_unflagged_placeholders, True),
    ("S10", s10_provider_failure_then_close_settles_clean, False),
    ("S11", s11_append_preserves_and_fast_path, False),
    ("S12a", s12a_a_dead_timeout_is_not_chased, False),
    ("S12b", s12b_a_stalled_timeout_is_not_chased_either, False),
    ("S13", s13_one_download_per_claimed_file, False),
    ("S14", s14_storm_then_close_drains_loading_state, False),
    ("S15", s15_a_failing_file_spends_its_budget_and_stops, False),
    ("S16", s16_close_during_a_live_transfer_starts_nothing, False),
    ("S17", s17_play_pause_during_loading_lands_parked, False),
    ("S18", s18_a_wedged_open_still_starts_the_sweep, False),
    ("S19", s19_a_wedged_successor_open_does_not_starve_the_sweep, False),
    ("S20", s20_row_loading_tracks_live_provider_transfers, False),
    ("S21", s21_the_library_converges, False),
]


# --------------------------------------------------------------------------


def scenario_plan(wanted):
    """Validate --only as a set, never silently discard a mistyped id."""
    known = {ident for ident, _, _ in SCENARIOS}
    unknown = sorted((wanted or set()) - known)
    if unknown:
        raise ValueError(f"unknown --only id(s) {unknown}; ids are {sorted(known)}")
    return [(ident, fn, expected_fail) for ident, fn, expected_fail in SCENARIOS
            if wanted is None or ident in wanted]


def result_exit_code(counts):
    """XFAIL is accepted; a surprising XPASS needs human review just like failure."""
    hard = (counts.get("FAIL", 0) + counts.get("ERROR", 0)
            + counts.get("XPASS", 0))
    return 1 if hard else 0


def failure_outcome(error, expected_fail):
    """Only the documented defect can satisfy an expected-fail scenario."""
    return "XFAIL" if expected_fail and isinstance(error, ExpectedGap) else "FAIL"


def cleanup_failure_outcome(outcome, detail, error):
    """Attach cleanup evidence without erasing a scenario's stronger verdict."""
    cleanup = f"could not restore On track end: {error}"
    preserved = outcome if outcome in ("FAIL", "XFAIL", "ERROR") else "ERROR"
    return preserved, f"{detail}; {cleanup}"


def pause_at_track_end(ctx):
    value = ctx.state().get("settings", {}).get("pauseAtTrackEnd")
    if not isinstance(value, bool):
        raise Failed(f"On track end setting was absent or non-boolean: {value!r}")
    return value


def set_pause_at_track_end(ctx, value):
    reply = ctx.cmd("set_pause_at_track_end", "on" if value else "off")
    if reply.get("pauseAtTrackEnd") is not value:
        raise Failed(f"On track end update did not stick: {reply}")


def snapshot_pause_at_track_end(channel, corpus, app, verbose):
    """Read the user's baseline once, before any scenario can mutate it."""
    launch(corpus, app)
    ctx = Ctx(channel, corpus, verbose)
    try:
        return pause_at_track_end(ctx)
    finally:
        channel.run(["quit"], timeout=10)


def restore_pause_at_track_end(channel, corpus, app, verbose, value):
    """Restore through a fresh process, including after a scenario killed one."""
    try:
        launch(corpus, app)
        ctx = Ctx(channel, corpus, verbose)
        set_pause_at_track_end(ctx, value)
        return None
    except (Exception, SystemExit) as error:
        return f"{type(error).__name__}: {error}"
    finally:
        channel.run(["quit"], timeout=10)


def check_unique_basenames(corpus: Path):
    """The trace records a playable transfer by last path component alone, so
    two audio files sharing a basename are one file to every assertion here."""
    seen, dupes = {}, set()
    for path in corpus.rglob("*"):
        if path.is_file() and path.suffix.lower() in AUDIO_SUFFIXES:
            if path.name in seen:
                dupes.add(path.name)
            seen[path.name] = path
    if dupes:
        sys.exit(f"{corpus} has {len(dupes)} duplicate basename(s) — the cloud "
                 f"trace could not tell them apart. Rebuild with "
                 f"make-cloud-corpus.py.\n  e.g. {sorted(dupes)[:3]}")


def check_corpus_shape(corpus: Path):
    """Reject corpora outside the scenario runner's bounded trace/time shape."""
    folders = sorted(path for path in corpus.iterdir() if path.is_dir())
    if len(folders) < 2:
        sys.exit(f"{corpus} needs at least two subfolders — rebuild it with "
                 "make-cloud-corpus.py")
    counts = [(folder.name,
               sum(1 for path in folder.iterdir()
                   if path.is_file() and path.suffix.lower() in AUDIO_SUFFIXES))
              for folder in folders[:2]]
    undersized = [(name, count) for name, count in counts
                  if count < MIN_SCENARIO_ROWS]
    if undersized:
        sys.exit(f"the first two corpus folders need at least "
                 f"{MIN_SCENARIO_ROWS} generated "
                 f"audio files each; got {undersized}")
    oversized = [(name, count) for name, count in counts
                 if count > MAX_SCENARIO_ROWS]
    if oversized:
        sys.exit(f"the first two corpus folders may contain at most "
                 f"{MAX_SCENARIO_ROWS} playable files each; larger folders can "
                 f"outlive scenario bounds or rotate the trace ring; got {oversized}")


def main():
    # Line-buffer even when stdout is a file, so a driver tailing the log sees
    # each scenario's outcome as it lands rather than everything at exit.
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True,
                        help="folder of folders, from make-cloud-corpus.py")
    parser.add_argument("--app", help=f"path to Vibe.app (default {DEFAULT_APP})")
    parser.add_argument("--only", help="comma-separated scenario ids to run")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    corpus = Path(args.corpus).resolve()
    if not corpus.is_dir():
        sys.exit(f"no corpus at {corpus}")
    check_unique_basenames(corpus)
    check_corpus_shape(corpus)
    app = Path(args.app).resolve() if args.app else DEFAULT_APP.resolve()

    wanted = {s.strip() for s in args.only.split(",")} if args.only else None
    try:
        plan = scenario_plan(wanted)
    except ValueError as error:
        sys.exit(str(error))
    if not plan:
        sys.exit(f"--only matched nothing; ids are {[i for i, _, _ in SCENARIOS]}")

    channel = Channel(app, verbose=args.verbose)
    results = []
    folders = [p for p in corpus.iterdir() if p.is_dir()]
    print(f"corpus: {corpus}  ({len(folders)} folders, "
          f"{sum(1 for _ in corpus.rglob('*') if _.is_file())} files)")
    print(f"app:    {app}\n")

    try:
        original_pause_at_end = snapshot_pause_at_track_end(
                channel, corpus, app, args.verbose)
    except Failed as error:
        sys.exit(f"could not snapshot On track end before the run: {error}")

    suite_cleanup_error = None
    completed_plan = False
    try:
        for ident, fn, expect_fail in plan:
            label = f"{ident} {fn.__name__.split('_', 1)[1].replace('_', ' ')}"
            print(f"{label} ... ", end="", flush=True)
            # A fresh process per scenario: the fake's tally, the metadata cache and
            # any hold all survive a re-arm, and a leftover is indistinguishable
            # from a failure.
            launch(corpus, app)
            ctx = Ctx(channel, corpus, args.verbose)
            started = time.monotonic()
            try:
                # launch() opens the corpus to establish the sandbox grant. That
                # also starts playback and a scan; quiesce them before installing
                # global fake-provider hooks or their late work contaminates this
                # scenario's trace and cache state. The folder grant survives.
                ctx.quiesce()
                ctx.cmd("clear_caches", timeout=60)
                set_pause_at_track_end(ctx, False)
                note = fn(ctx)
                outcome = "XPASS" if expect_fail else "PASS"
                detail = note
            except Failed as exc:
                outcome = failure_outcome(exc, expect_fail)
                detail = str(exc)
            except Exception as exc:  # harness fault, not the app's
                outcome, detail = "ERROR", f"{type(exc).__name__}: {exc}"
            try:
                set_pause_at_track_end(ctx, original_pause_at_end)
            except Exception as exc:
                outcome, detail = cleanup_failure_outcome(outcome, detail, exc)
            elapsed = time.monotonic() - started
            trace = []
            if outcome in ("FAIL", "XFAIL", "XPASS", "ERROR"):
                try:
                    trace = ctx.trace()
                except Exception:
                    pass
            results.append((ident, label, outcome, detail, elapsed, trace))
            print(f"{outcome}  ({elapsed:.0f}s)")
            if outcome in ("FAIL", "ERROR"):
                print(f"    {detail}")
            try:
                channel.run(["quit"], timeout=10)
            except Exception:
                pass
        completed_plan = True
    finally:
        suite_cleanup_error = restore_pause_at_track_end(
                channel, corpus, app, args.verbose, original_pause_at_end)
        if suite_cleanup_error and not completed_plan:
            print(f"\nERROR restoring On track end at process exit: "
                  f"{suite_cleanup_error}", file=sys.stderr)

    if suite_cleanup_error:
        results.append(("cleanup", "suite On track end restoration", "ERROR",
                        suite_cleanup_error, 0, []))

    print("\n" + "=" * 78)
    for ident, label, outcome, detail, elapsed, trace in results:
        print(f"{outcome:<6} {label}  ({elapsed:.0f}s)")
        print(f"       {detail}")
        if outcome in ("FAIL", "XFAIL", "XPASS", "ERROR") and trace:
            print(fmt_trace(trace, limit=40))
    print("=" * 78)

    counts = {}
    for _, _, outcome, _, _, _ in results:
        counts[outcome] = counts.get(outcome, 0) + 1
    print("  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    # XFAIL is a recorded gap, not a failure of the run. XPASS is ambiguous: the
    # gap may have closed, or its oracle may have stopped reaching the defect.
    # It therefore needs review and makes unattended acceptance fail.
    return result_exit_code(counts)


if __name__ == "__main__":
    sys.exit(main())
