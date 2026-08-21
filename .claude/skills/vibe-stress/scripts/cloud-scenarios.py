#!/usr/bin/env python3
"""Deterministic cloud-loading scenarios, asserted on the fake provider's trace.

Where stress.py drives randomly and watches for violations, this drives ONE
named situation at a time and asserts what the trace must contain. It exists
because the cloud work's guarantees are all about ORDER — which download runs
next, which is abandoned, which never starts — and order is exactly what a
seeded monkey cannot state.

Three rules the whole file is built on:

  ASSERT ON THE TRACE, NEVER ON ELAPSED TIME. `dump_cloud_trace` records every
  transfer's requested/started/completed/cancelled with its role and a sequence
  number. Timing is used only to decide when to stop waiting.

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
right. None are currently marked — the two that documented review items 4 and
5 (S9, S13) flipped to must-pass when the materialization coordinator merge
closed both gaps by construction.

    cloud-scenarios.py --corpus build/cloud-scenarios-corpus
    cloud-scenarios.py --corpus <dir> --only S4b,S7 --verbose
"""

import argparse
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stress import Channel, launch  # noqa: E402

DEFAULT_APP = Path("build/DerivedData/Build/Products/Debug/Vibe.app")

# The base transfer, in seconds. Long enough that a scenario can observe a
# transfer mid-flight over a channel whose round trip is ~130ms, short enough
# that a dozen of them do not make the suite a soak.
TRANSFER = 1.0

# How long any wait_for gives up after. Every scenario's longest legitimate wait
# is a handful of transfers.
WAIT_TIMEOUT = 40.0
POLL = 0.15


# --------------------------------------------------------------------------
# Result plumbing
# --------------------------------------------------------------------------


class Failed(Exception):
    """A scenario's own assertion. Carries the trace for the report."""


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

    def wait_for_wedged_open(self, describe, timeout=WAIT_TIMEOUT):
        """Block until a hang_open-ed handle open has reached the uncancellable
        call. Polls the counter rather than sleeping: the open is behind a
        transfer whose length the scenario does not control."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.materialization().get("handleOpensInFlight", 0) >= 1:
                return
            time.sleep(POLL)
        raise Failed(f"timed out after {timeout:.0f}s waiting for {describe}")

    def state(self):
        return self.cmd("dump_state")

    def playlist(self):
        """{"count", "currentIndex", "files"} — files are basenames, in row
        order, which is the same identity the cloud trace records."""
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


def windows(events, role):
    """[(start_seq, end_seq)] for each transfer of `role` that started.

    end_seq is the matching completed/cancelled, or None if still in flight.
    Matched by file, oldest-open-first, which is exact here because one file
    never has two transfers of the same role in flight — and if it ever did,
    the fake's own metadataOverlapTransfers counter would already have fired.
    """
    open_by_file, spans = {}, []
    for e in events:
        if e["role"] != role:
            continue
        if e["event"] == "started":
            open_by_file.setdefault(e["file"], []).append(len(spans))
            spans.append([e["seq"], None, e["file"]])
        elif e["event"] in ("completed", "cancelled"):
            pending = open_by_file.get(e["file"])
            if pending:
                spans[pending.pop(0)][1] = e["seq"]
    return [(s, t, f) for s, t, f in spans]


def role_started_inside(events, inner_role, outer_role):
    """Transfers of inner_role that began inside an outer_role transfer's span."""
    hits = []
    outer = windows(events, outer_role)
    for e in events_of(events, event="started", role=inner_role):
        for start, end, ofile in outer:
            if start < e["seq"] and (end is None or e["seq"] < end):
                hits.append((e["file"], ofile))
    return hits


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
    """The hold's whole job: no background download begins inside a foreground one.

    Checked from the trace here as well as from the app's own cumulative
    counter, because the trace names WHICH files, which is what a failure
    report needs.
    """
    hits = role_started_inside(events, "metadata", "playback")
    if hits:
        raise Failed("a metadata download began during a playback download: "
                     + ", ".join(f"{m} inside {p}" for m, p in hits))
    counted = ctx.stats().get("foregroundContentionStarts", 0)
    if counted:
        raise Failed(f"the app counted {counted} foreground contention start(s)")


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
        ctx.cmd("play_index", index)


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
    ctx.arm()
    ctx.cmd("open", str(a))
    ctx.wait_for("an A metadata transfer to start",
                 lambda ev: events_of(ev, event="started", role="metadata"))
    a_started = {e["file"] for e in events_of(ctx.trace(), event="started", role="metadata")}

    # Which files belong to B is known from disk, so B's own playback transfer
    # is identified by name rather than by "the last one", which a rebind or a
    # superseded open would make wrong.
    b_names = {p.name for p in b.iterdir() if p.is_file()}
    ctx.cmd("open", str(b))
    events = ctx.wait_for("B's own playback transfer to start",
                          lambda ev: [e for e in events_of(ev, event="started", role="playback")
                                      if e["file"] in b_names])
    b_playback = [e for e in events_of(events, event="started", role="playback")
                  if e["file"] in b_names][0]

    # Every A metadata transfer must have ended before B's playback one began.
    for start, end, f in windows(events, "metadata"):
        if f in a_started and (end is None or end > b_playback["seq"]):
            raise Failed(f"A's metadata transfer of {f} was still running when "
                         f"B's playback open started ({b_playback['file']})")
    assert_no_foreground_contention(ctx, events)
    return f"{len(a_started)} A transfer(s) cancelled before B's open"


def s2_hold_is_armed_at_submission(ctx):
    """No background download is admitted while the picked track's own open is
    in flight, and rows still fill from cache meanwhile."""
    ctx.arm()
    open_and_play(ctx, ctx.folders[0], index=5)
    events = ctx.wait_for("several metadata transfers after the open settles",
                          lambda ev: len(events_of(ev, event="completed", role="metadata")) >= 2)
    assert_no_foreground_contention(ctx, events)
    progress = ctx.cmd("dump_metadata_progress")
    if progress.get("attempted", 0) == 0:
        raise Failed("no row had metadata attempted at all — the sweep never ran")
    return (f"{len(events_of(events, event='started', role='metadata'))} metadata transfers, "
            f"none inside a playback one; {progress['attempted']}/{progress['total']} rows attempted")


def s3_successor_prefetch_runs_once(ctx):
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
    events = ctx.wait_for(f"the successor's transfer to complete",
                          lambda ev: events_of(ev, event="completed", file=successor))
    completed_for_target = events_of(events, event="completed", file=successor)
    if len(completed_for_target) > 1:
        raise Failed(f"{successor} was downloaded to term {len(completed_for_target)} times "
                     f"by {[e['role'] for e in completed_for_target]}")
    if ctx.stats().get("metadataOverlapTransfers"):
        raise Failed("the metadata lane downloaded a file another role was already downloading")
    roles = [e["role"] for e in completed_for_target]
    return f"successor {successor} materialized exactly once (via {roles[0]})"


def s4a_rapid_next_keeps_the_hold(ctx):
    """A prefetch acknowledgement outrun by a newer play must not strip the
    newer play's hold. Driven by rapid `next` while acks are in flight."""
    ctx.arm()
    open_and_play(ctx, ctx.folders[0], index=0, wait=True)
    for _ in range(8):
        ctx.cmd("next")
    ctx.settle(6)
    events = ctx.trace()
    assert_no_foreground_contention(ctx, events)
    return f"{len(events_of(events, event='requested', role='playback'))} rapid plays, no contention"


def s4b_replay_during_a_queued_error(ctx):
    """The review's item-1 case: an error for a row, delivered after the SAME
    row was replayed, must not release the hold the replay asserted.

    Track identity cannot tell the two plays apart — same AudioTrack, same URL —
    which is why the acknowledgement path guards on a hold generation instead.
    The error path does not, so this stages the one interleaving that would
    exploit that:

        [ one main-thread turn: wait, then submit the replay ] [ queued error ]

    Both halves are load-bearing and were each got wrong once while writing
    this. The replay must be submitted from a main-thread turn that was ALREADY
    RUNNING when the error was dispatched, because the channel's own intake is
    on the main queue — two separate commands cannot straddle a callback, since
    while main is held nothing else can even be enqueued. And it must be
    `play_index`, not `open`: the open funnel is asynchronous, so its play lands
    in a later turn, behind the error rather than ahead of it.

    WHAT THIS DOES AND DOES NOT PROVE. It reaches the interleaving the review
    describes. It does not reach the remaining window inside it: the error's own
    `isStopped` test is a second, incidental guard, and by the time the error
    block runs the replay has reached the player queue and the state is
    Loading, so the error returns early. The unreachable remainder is the few
    microseconds between the replay's synchronous submission on main and the
    player queue publishing Loading. Nothing in this harness can widen it."""
    folder = ctx.folders[1]
    bad = folder / "zzz-bad.mp3"
    # Not empty: an empty file fails the coordinator's own check before any
    # transfer, so the error would arrive in milliseconds with nothing staged.
    # Garbage of a real size costs the whole transfer and then fails to open.
    bad.write_bytes(os.urandom(64 * 1024))
    try:
        # Sticky, so the file never reads as materialized and EVERY open of it
        # pays the transfer again — otherwise the replay's open returns
        # instantly and a stripped hold would have no window to show in.
        # Unlimited capacity, so a resumed lane can actually start a download
        # rather than queue behind the foreground one.
        ctx.arm(capacity=0, sticky=True)
        ctx.cmd("open", str(folder))
        ctx.wait_for("the folder's rows to be listed",
                     lambda ev: events_of(ev, event="requested", role="playback"))
        rows = ctx.playlist()["files"]
        if bad.name not in rows:
            raise Failed(f"{bad.name} did not appear in the playlist")
        row = rows.index(bad.name)

        for _ in range(6):
            ctx.cmd("play_index", row)
            time.sleep(TRANSFER * 0.45)
            # The turn: hold main across the first play's failure, then submit
            # the replay without yielding, so the queued error lands behind it.
            ctx.cmd("block_main", TRANSFER * 0.9, "play_index", row, timeout=60)
            ctx.settle(TRANSFER * 1.5)
            if not ctx.health().get("cloudLaneHeld"):
                state = ctx.state().get("player", {}).get("state")
                if state == "loading":
                    raise Failed("the cloud lane was released while the replayed open "
                                 "was still loading — the previous play's queued error "
                                 "stripped the hold the replay had just asserted")
        ctx.settle(2)
        events = ctx.trace()
        assert_no_foreground_contention(ctx, events)
        if ctx.health().get("cloudLaneHeld"):
            raise Failed("the cloud lane is still held after the errors settled")
        return ("6 staged error-behind-replay turns; hold held across both plays "
                "(the error's isStopped test also guards this)")
    finally:
        bad.unlink(missing_ok=True)


def s5_lane_follows_rank_then_index(ctx):
    """With one provider slot and uniform durations, the serial lane's order is
    the neighborhood's rank and then ascending playlist index — not the order
    the stage-one cache checks happened to finish in."""
    ctx.arm()
    folder = ctx.folders[0]
    open_and_play(ctx, folder, index=0)
    events = ctx.wait_for("most of the folder to be swept",
                          lambda ev: len(events_of(ev, event="completed", role="metadata")) >= 6)
    order = started_order(events, "metadata")
    rows = ctx.playlist()["files"]
    index_of = {name: i for i, name in enumerate(rows)}
    unknown = [f for f in order if f not in index_of]
    if unknown:
        raise Failed(f"traced files not found in the playlist: {unknown[:3]}")
    # The neighborhood (next, the one after, the one behind) is ranked ahead of
    # the tail, so only the tail is required to ascend. Find where the tail
    # starts: the first entry after which every entry ascends.
    tail = [index_of[f] for f in order]
    descents = [(order[i], order[i + 1]) for i in range(len(tail) - 1) if tail[i + 1] < tail[i]]
    if len(descents) > 1:
        raise Failed("the lane's order descends more than once, so it is not "
                     f"(rank, index): {descents}")
    return f"{len(order)} transfers in playlist order after the neighborhood ({order[0]} first)"


def s6_no_stage_two_before_stage_one_drains(ctx):
    """The arrival boundary. Sorting only what has arrived does not make the
    sweep deterministic, so the lane waits for every stage-one cache check
    before dispatching the first download."""
    ctx.arm()
    folder = ctx.folders[0]
    open_and_play(ctx, folder, index=2)
    events = ctx.wait_for("the lane to be well under way",
                          lambda ev: len(events_of(ev, event="completed", role="metadata")) >= 4)
    order = started_order(events, "metadata")
    # A lane that dispatched from a half-populated list picks whichever cache
    # check happened to finish first, which on a folder of one file type is
    # effectively arbitrary. The observable consequence is the FIRST pick: it
    # must be the best-ranked entry, and which entry that is cannot be known
    # until every stage-one check has landed.
    rows = ctx.playlist()["files"]
    if order[0] not in rows:
        raise Failed(f"first lane pick {order[0]} is not in the playlist")
    played = [e["file"] for e in events_of(events, event="requested", role="playback")]
    if not played:
        raise Failed("nothing was ever played, so there is no neighborhood to rank against")
    here = rows.index(played[-1])
    # Next, the one after, the one behind — the neighborhood the cache ranks by.
    neighborhood = {rows[i] for i in (here + 1, here + 2, here - 1) if 0 <= i < len(rows)}
    if order[0] not in neighborhood:
        raise Failed(f"the lane's first pick was {order[0]}, outside the neighborhood "
                     f"of {played[-1]} ({sorted(neighborhood)}) — it dispatched before "
                     "the stage-one checks had drained")
    return f"first pick {order[0]} was in the neighborhood of {played[-1]}"


def s7_stand_aside_and_no_stranding(ctx):
    """The lane must not download a file the player or its prefetch is already
    downloading, and a lane blocked on nothing else must still make progress
    once the block clears."""
    ctx.arm()
    folder = ctx.folders[0]
    open_and_play(ctx, folder, index=1)
    events = ctx.wait_for("the sweep to get going",
                          lambda ev: len(events_of(ev, event="completed", role="metadata")) >= 3)
    if ctx.stats().get("metadataOverlapTransfers"):
        raise Failed("the metadata lane downloaded a file another role was already downloading")
    # No stranding: the lane must keep draining to the end of the folder.
    total = len([p for p in folder.iterdir() if p.is_file()])
    events = ctx.wait_for(f"the lane to drain all {total} rows",
                          lambda ev: len(events_of(ev, event="completed", role="metadata"))
                                     + len(events_of(ev, event="completed", role="playback"))
                                     + len(events_of(ev, event="completed", role="prefetch"))
                                     >= total,
                          timeout=total * TRANSFER * 2 + 20)
    assert_no_foreground_contention(ctx, events)
    return f"{total} rows drained with no overlap and no stranding"


# The open-timeout policy, restated from AudioFileOpenTimeoutMath.h
# (kVibeAudioOpenDefaultNoProgressSeconds / DefaultProgressSilenceSeconds) so
# the scenarios size themselves against it rather than against a guessed
# number. An earlier restatement said the silence budget was 20s against a
# header that holds no budgets at all — the stall scenarios then sized their
# transfers to complete at the very instant the real 60s deadline fired, and
# the photo-finish read as "never abandoned".
NO_PROGRESS_BUDGET = 60.0
PROGRESS_SILENCE_BUDGET = 60.0


def _deadline_scenario(ctx, progress_mode, expect_timeout, seconds=200, watch=95):
    """Shared body for S8a/b/c: one very slow transfer under a scripted progress
    source, watched for whether the open is abandoned.

    `seconds` is chosen per mode so the expected verdict lands inside `watch`.
    It has to be: the stall script climbs to 40% of the transfer before
    stopping, so a 200s transfer keeps reporting movement until t=80 and its
    deadline is t=100 — past a 95s watch, which reads as "never abandoned" and
    is a harness fault, not the app's."""
    ctx.arm(seconds=seconds, capacity=1, uniform=True, progress=progress_mode)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the playback transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback"))
    deadline = time.monotonic() + watch
    abandoned = False
    while time.monotonic() < deadline:
        ev = ctx.trace()
        if events_of(ev, event="cancelled", role="playback"):
            abandoned = True
            break
        time.sleep(1.0)
    if abandoned and not expect_timeout:
        raise Failed(f"a healthy transfer under progress={progress_mode} was abandoned")
    if not abandoned and expect_timeout:
        raise Failed(f"a transfer under progress={progress_mode} was never abandoned")
    return ("abandoned as it should be" if expect_timeout
            else "kept its transfer, as a healthy one must")


def s8a_no_progress_times_out(ctx):
    """A provider that publishes no fraction at all gets the flat 60s baseline."""
    return _deadline_scenario(ctx, "none", expect_timeout=True)


def s8b_sparse_progress_survives(ctx):
    """The review's item 6: a healthy transfer whose UI-visible percentage moves
    only every 10s must not be abandoned. It survives because the deadline is
    fed from the monitor's uncoalesced movement feed, not the whole-percent
    handler."""
    return _deadline_scenario(ctx, "sparse", expect_timeout=False)


def s8c_a_stall_after_progress_times_out(ctx):
    """Progress to 40% and then nothing: the stall budget must still fire.

    Sized so the deadline clearly beats the transfer's own completion: the
    stall script stops moving at 40%, so a 130s transfer last moves at t=52,
    its deadline is 52 + the 60s silence budget = t=112, and completion would
    not arrive until t=130 — an 18s margin for the abandonment to land in,
    where the watch would expire first."""
    return _deadline_scenario(ctx, "stall", expect_timeout=True,
                              seconds=130,
                              watch=0.4 * 130 + PROGRESS_SILENCE_BUDGET + 15)


def s9_unflagged_placeholders(ctx):
    """A placeholder that denies being dataless still waits its turn.

    Some providers answer NO to the dataless probe for files whose read still
    costs a whole download. Pre-refactor that answer routed the read around
    the cloud lane entirely — background downloads ran inside the foreground
    open (review item 4, an expected-fail until the coordinator merge). Now
    every metadata materialization funnels through the one coordinator, whose
    foreground rule is derived from its claim table rather than keyed off the
    probe's answer, so the lie buys nothing.

    The property has to be measured DURING the picked track's open, not after
    it. "Rows were parsed" is true either way once the open settles — that is
    the sweep doing its job. What only the bypass produces is rows filling
    while the user is still waiting, so the open is made long enough to sample
    inside, and the assertion is that the count does not climb across that
    window. Only cloud-backed rows must hold: an already-local file is exempt
    from the rule by design, but this corpus is all placeholders."""
    # A long transfer for the picked file, so there is a window to sample in.
    ctx.arm(seconds=10, capacity=1, uniform=True, unflagged=True)
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

    hits = role_started_inside(events, "metadata", "playback")
    if hits:
        raise Failed(f"background downloads ran inside the foreground open: {hits}")
    climbed = during.get("attempted", 0) - before.get("attempted", 0)
    if climbed > 0:
        raise Failed(f"{climbed} more rows were parsed while the picked track's own "
                     f"open was still in flight ({before.get('attempted')} -> "
                     f"{during.get('attempted')} of {during.get('total')}) — the "
                     "unflagged placeholder bypassed the cloud lane and its hold")
    return (f"rows held at {during.get('attempted')}/{during.get('total')} across the "
            "open; no bypass observed")


def s10_error_and_close_settle_clean(ctx):
    """An open error, then Close: nothing is left held, pending or in flight."""
    bad = ctx.corpus / "zz-unreadable-close.mp3"
    bad.write_bytes(b"")
    try:
        ctx.arm()
        ctx.cmd("open", str(ctx.folders[0]))
        ctx.wait_for("the folder to start playing",
                     lambda ev: events_of(ev, event="requested", role="playback"))
        ctx.cmd("open", str(bad))
        # Poll for the hold to CLEAR inside a bounded window, never sample it
        # at a fixed instant: the folder open's prefetch claim legitimately
        # holds the lane behind capacity=1 for a decode's length, and a decode
        # is not a constant — the analyzers roughly double it, and the harness
        # forces them on. Measured: clear at t=2 with them off, t=3 on, and a
        # fixed t=2 sample read that one-second difference as a stranded hold.
        # What this scenario actually asserts is that the errored open cannot
        # strand the hold FOREVER, which only a poll can state.
        deadline = time.monotonic() + 20
        health = ctx.health()
        while time.monotonic() < deadline and health.get("cloudLaneHeld"):
            time.sleep(0.5)
            health = ctx.health()
        if health.get("cloudLaneHeld"):
            raise Failed("the error path left the cloud lane held (20s poll)")
        ctx.cmd("quiesce", timeout=60)
        health = ctx.health()
        if health.get("cloudLaneHeld") or health.get("cloudParsesPending"):
            raise Failed(f"quiesce left cloud state behind: {health}")
        return "error then Close settled to zero"
    finally:
        bad.unlink(missing_ok=True)


def s11_append_and_fast_path(ctx):
    """Appending files while an open is in flight must not start a sweep of its
    own, and a second play of an already-materialized file is a fast path with
    no transfer at all."""
    ctx.arm()
    folder = ctx.folders[0]
    files = sorted(p for p in folder.iterdir() if p.is_file())
    ctx.cmd("open", str(files[0]))
    ctx.wait_for("the first file's transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback"))
    # Appending during Loading: the pending open's own didStartPlaying
    # recomputes the sweep and the prefetch, so this must add no transfer.
    for f in files[1:4]:
        ctx.cmd("open", str(f))
    ctx.settle(6)
    events = ctx.trace()
    assert_no_foreground_contention(ctx, events)

    # The fast path: replay a file whose transfer has already completed.
    done = {e["file"] for e in events_of(events, event="completed")}
    if not done:
        raise Failed("nothing completed, so there is no materialized file to replay")
    # By sequence number, not by list position: the trace is a bounded ring, so
    # an index into it stops meaning the same event once it wraps.
    mark = max((e["seq"] for e in ctx.trace()), default=-1)
    ctx.cmd("play_index", 0)
    ctx.settle(2)
    replayed = [e for e in ctx.trace()
                if e["seq"] > mark and e["event"] == "requested" and e["file"] in done]
    if replayed:
        raise Failed(f"replaying an already-materialized file asked for a second "
                     f"transfer: {[e['file'] for e in replayed]}")
    return f"{len(done)} materialized; replay cost no transfer"


def _timeout_abandonment_scenario(ctx, progress_mode, seconds, watch):
    """Time an open out under a scripted progress source, then assert the
    abandoned pick is NOT chased: the lane's next fetch is an ordinary sweep
    choice and playback stays stopped.

    An earlier design ranked a pick that had shown progress back in first
    (1b8e03e, "chase a timed-out pick only if it was still moving"); the
    loading rewrite in 597f6fc removed it, and the retirement is deliberate:
    under the extend-on-movement deadline (AudioFileOpenTimeoutMath.h) any
    abandoned transfer has by definition been silent for its whole 60s
    budget — there is no "still moving at the deadline" case left to chase,
    only a stalled one, and re-fetching a stalled transfer spends the
    provider's next slot behind a terminal error the user is looking at.
    Both progress modes therefore assert the same verdict."""
    ctx.arm(seconds=seconds, capacity=1, uniform=True, progress=progress_mode)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    events = ctx.wait_for("the playback transfer to start",
                          lambda ev: events_of(ev, event="started", role="playback"))
    picked = events_of(events, event="started", role="playback")[-1]["file"]
    deadline = time.monotonic() + watch
    while time.monotonic() < deadline:
        if events_of(ctx.trace(), event="cancelled", role="playback"):
            break
        time.sleep(1.0)
    else:
        raise Failed("the open was never abandoned, so there is no timeout to follow")

    if ctx.state().get("player", {}).get("state") == "playing":
        raise Failed("playback auto-resumed after a timeout")

    # Whatever the verdict, the sweep must run: the deferred load is released
    # by the error path either way.
    events = ctx.wait_for("the lane to pick something after the timeout",
                          lambda ev: events_of(ev, event="requested", role="metadata"),
                          timeout=40)
    first = events_of(events, event="requested", role="metadata")[0]["file"]
    if first == picked:
        raise Failed(f"the abandoned pick was chased: the lane re-fetched {picked} "
                     "first — the provider's next slot spent re-fetching a stalled "
                     "transfer, unasked, behind a terminal error the user is "
                     "looking at")
    return (f"{picked} left as an ordinary sweep candidate ({first} fetched first), "
            "playback stayed stopped")


def s12a_a_dead_timeout_is_not_chased(ctx):
    """A pick that timed out having shown NO progress stays an ordinary sweep
    candidate rather than taking the provider's next slot."""
    return _timeout_abandonment_scenario(ctx, "none", seconds=200,
                                         watch=NO_PROGRESS_BUDGET + 35)


def s12b_a_stalled_timeout_is_not_chased_either(ctx):
    """Progress to 40% and then nothing: the abandoned pick is judged the same
    as one that never moved. The old moving/dead distinction died with the
    deadline redesign — see _timeout_abandonment_scenario."""
    return _timeout_abandonment_scenario(ctx, "stall", seconds=130,
                                         watch=0.4 * 130 + PROGRESS_SILENCE_BUDGET + 20)


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
    # Unlimited capacity: with one slot the second transfer would merely queue,
    # and a queued duplicate is not the duplicate DOWNLOAD under test. Short
    # transfers so the lane churns through many picks per second of wall clock,
    # which is what makes the window come round often.
    ctx.arm(seconds=0.35, capacity=0)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the sweep to start",
                 lambda ev: events_of(ev, event="started", role="metadata"))
    rows = ctx.playlist()["files"]
    index_of = {name: i for i, name in enumerate(rows)}

    # Aim at the window rather than stirring: play whatever the lane has just
    # asked for. The claim then registers while that same pick is between its
    # stand-aside check and its materializeURL:, which is the only interval in
    # which a check-then-act query can be wrong.
    chased = 0
    for _ in range(60):
        ev = ctx.trace()
        asked = events_of(ev, event="requested", role="metadata")
        if not asked:
            ctx.settle(0.1)
            continue
        target = asked[-1]["file"]
        if target in index_of:
            ctx.cmd("play_index", index_of[target])
            chased += 1
        if ctx.stats().get("metadataOverlapTransfers"):
            break
    ctx.settle(3)
    overlaps = ctx.stats().get("metadataOverlapTransfers", 0)
    if overlaps:
        raise Failed(f"the metadata lane downloaded a file another role was "
                     f"already downloading {overlaps} time(s)")
    return (f"{chased} plays aimed at the lane's own current pick produced no "
            "duplicate download")


def s14_the_priority_records_drain(ctx):
    """Play storms and a playlist replacement strand no priority records: once
    playback settles, dump_cloud_health.priorityLane is empty and the priority
    request rate stops growing.

    The regression test for the 37-queued/7-token strand: a retry budget that
    could never be spent kept every failed priority request resubmitting at
    0.25s forever, invisible to every oracle because the retries lived in
    dispatch_after blocks no counter saw. Queue depth is the symptom; the
    unbounded request rate is the disease — both are asserted."""
    ctx.arm(seconds=1.0)
    open_and_play(ctx, ctx.folders[0], index=None, wait=True)
    rows = ctx.playlist()["files"]
    for i in range(min(10, len(rows))):
        ctx.cmd("play_index", i)
    # Replace the playlist mid-storm — the old loader's records, the priority
    # one included, must die with it — then storm the replacement too.
    playback_before = len(events_of(ctx.trace(), event="requested", role="playback"))
    ctx.cmd("open", str(ctx.folders[1]))
    ctx.wait_for("the replacement's playback transfer",
                 lambda ev: len(events_of(ev, event="requested", role="playback"))
                         > playback_before)
    rows = ctx.playlist()["files"]
    for i in range(min(6, len(rows))):
        ctx.cmd("play_index", i)
    # 1s uniform transfers on capacity 1: the last play and its priority join
    # settle well inside this.
    ctx.settle(8)
    lane = ctx.health().get("priorityLane", {})
    if lane.get("pending") or lane.get("inFlight"):
        raise Failed(f"priority records stranded after settle: "
                     f"pending={lane.get('pending')} inFlight={lane.get('inFlight')}")
    before = len(events_of(ctx.trace(), event="requested", role="metadata-priority"))
    ctx.settle(4)
    after = len(events_of(ctx.trace(), event="requested", role="metadata-priority"))
    if after > before:
        raise Failed(f"the priority request rate is still growing at rest: "
                     f"{before} -> {after} over a 4s quiet window")
    return f"lane drained after two storms and a replacement; request rate flat at rest"




def s15_a_failing_file_spends_its_budget_and_stops(ctx):
    """A file whose transfers always fail is retried exactly to the budget —
    three attempts, spec D7 — then dropped for the session: the request rate
    for it goes flat while every other row completes. The live analogue of
    the ledger regression 925209b fixed, staged with the fake's fail= mode
    (transfers run to term, then report a provider error)."""
    folder = ctx.folders[0]
    victims = sorted(f.name for f in folder.iterdir() if f.is_file())
    # Not the auto-played row 0: its playback open must succeed so the sweep
    # runs at all.
    victim = victims[len(victims) // 2]
    ctx.arm(seconds=0.4, fail=victim)
    ctx.cmd("open", str(folder))
    ctx.wait_for("the sweep to reach and retry the failing file",
                 lambda ev: len(events_of(ev, event="requested", role="metadata",
                                          file=victim)) >= 3,
                 timeout=60)
    ctx.settle(6)
    events = ctx.trace()
    attempts = len(events_of(events, event="requested", role="metadata", file=victim))
    if attempts > 3:
        raise Failed(f"{victim} was requested {attempts} times — the 3-attempt "
                     "budget did not hold")
    completed = events_of(events, event="completed", role="metadata", file=victim)
    if completed:
        raise Failed(f"{victim} completed a transfer the fake was told to fail")
    before = attempts
    ctx.settle(5)
    after = len(events_of(ctx.trace(), event="requested", role="metadata", file=victim))
    if after > before:
        raise Failed(f"{victim} is still being retried at rest: {before} -> {after}")
    progress = ctx.cmd("dump_metadata_progress")
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
    ctx.wait_for("the playback transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback"))
    # quiesce runs closeFile: first, then waits for the pending counters.
    ctx.cmd("quiesce", timeout=60)
    events = ctx.trace()
    playback = windows(events, "playback")
    for start_seq, end_seq, _file in playback:
        for started in events_of(events, event="started", role="metadata"):
            if started["seq"] > start_seq and (end_seq is None
                                               or started["seq"] < end_seq):
                raise Failed(f"a metadata transfer started inside the closing "
                             f"playback window: {started}")
    health = ctx.health()
    if health.get("cloudLaneHeld") or health.get("cloudParsesPending"):
        raise Failed(f"Close left cloud state behind: {health}")
    return "Close cancelled the transfer and admitted nothing behind it"


def s17_play_pause_during_loading_lands_parked(ctx):
    """play_pause while the open is still materializing flips the landing:
    the open completes and the track parks paused instead of playing
    (spec B2). The transfer itself must complete — the toggle changes the
    landing intent, never the open."""
    ctx.arm(seconds=4)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the playback transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback"))
    state = ctx.state()["player"]["state"]
    if state != "playing":
        raise Failed(f"expected the pending intent to read playing, got {state}")
    ctx.cmd("play_pause")
    ctx.wait_for("the playback transfer to complete",
                 lambda ev: events_of(ev, event="completed", role="playback"),
                 timeout=20)
    ctx.settle(2)
    state = ctx.state()["player"]["state"]
    if state != "paused":
        raise Failed(f"the open landed {state}, not paused")
    return "the open landed parked; the transfer ran to term"


def s18_a_wedged_open_still_starts_the_sweep(ctx):
    """The deferral's 2s fallback (spec D4): an open that never settles must
    not strand the playlist unpopulated. The sweep's stage 1 runs — pending
    records pile up — while the open is still Loading; its dataless stage 2
    correctly stays gated behind the foreground rule."""
    ctx.arm(seconds=300, progress="stall")
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the playback transfer to start",
                 lambda ev: events_of(ev, event="started", role="playback"))
    deadline = time.monotonic() + 8
    pending = 0
    while time.monotonic() < deadline:
        pending = ctx.health().get("cloudParsesPending", 0)
        if pending > 0:
            break
        time.sleep(0.5)
    if pending == 0:
        raise Failed("the deferred sweep never started behind the wedged open")
    state = ctx.state()["player"]["state"]
    if state not in ("playing", "loading"):
        raise Failed(f"the open should still be pending, got {state}")
    if events_of(ctx.trace(), event="started", role="metadata"):
        raise Failed("a dataless metadata transfer started while the "
                     "foreground open was live")
    # Why no metadata transfer started, which this scenario could not say until
    # it read the gate. "Correctly held by the foreground rule" and "unable to
    # start at all" produce the identical trace, and asserting only the trace
    # is what let S19's bug hide behind a green S18.
    if not ctx.materialization().get("foregroundTransferActive"):
        raise Failed("no metadata transfer started, but the foreground rule was "
                     "NOT in force — this is starvation, not the hold")
    return (f"stage 1 filed {pending} pending rows behind the wedged open; "
            "stage 2 stayed gated by a live foreground transfer")


def s19_a_wedged_prefetch_open_does_not_starve_the_sweep(ctx):
    """A successor's handle open that never returns must not stop every other
    background transfer for the rest of the process.

    S18 wedges stage ONE — the download — which never reaches the carried-slot
    path at all. This wedges stage TWO: the transfer completes, and the
    uncancellable AVAudioFile call it fed is what never comes back. That is the
    only shape that reaches the bug, and the fake provider could not stage it
    until hang_open existed.

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
    ctx.cmd("hang_open", rows[1])          # the successor prefetch will open this
    ctx.wait_for_wedged_open("the successor's handle open to wedge")

    # Everything from here is after the wedge, so a start proves the lane is
    # still admitting rather than merely that it once did.
    ctx.cmd("clear_cloud_trace")
    ctx.settle(8)

    materialization = ctx.materialization()
    demand = ctx.health().get("cloudParsesPending", 0)
    gated = materialization.get("foregroundTransferActive")
    progress = events_of(ctx.trace(), event="started", role="metadata")
    try:
        if gated:
            raise Failed("the foreground rule was still in force 8s after the "
                         "transfer settled — this scenario proves nothing")
        if demand == 0 and not progress:
            raise Failed("no rows left to scan — the sweep finished before the "
                         "wedge landed, so this scenario proves nothing")
        if not progress:
            raise Failed(f"{demand} rows still want scanning, no foreground "
                         f"transfer holds the lane, and not one metadata "
                         f"transfer started in 8s: the wedged open "
                         f"({materialization.get('handleOpensInFlight')} in "
                         f"flight) is holding admission")
    finally:
        ctx.cmd("hang_open", "release")
    return f"{len(progress)} metadata transfers started behind the wedged open"


def s21_the_library_converges(ctx):
    """Every row ends up with metadata. Stated in user terms and in no terms
    at all about lanes, claims or slots, so it outlives any refactor of the
    mechanism and catches the whole silent-stall class rather than one bug.
    """
    ctx.arm(seconds=0.2, capacity=1)
    folder = ctx.folders[0]
    ctx.cmd("open", str(folder))
    ctx.wait_for("the folder's first playback transfer",
                 lambda ev: events_of(ev, event="requested", role="playback"))
    # Paused, so advancing playback does not keep minting foreground work that
    # legitimately holds the sweep back for the whole run.
    ctx.cmd("play_pause")

    deadline = time.monotonic() + 60
    playlist = ctx.playlist()
    resolved = playlist.get("resolvedRows", 0)
    stalled_since = time.monotonic()
    while time.monotonic() < deadline:
        playlist = ctx.playlist()
        now_resolved = playlist.get("resolvedRows", 0)
        if now_resolved >= playlist.get("count", 0):
            return f"all {now_resolved} rows resolved"
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
    ("S2", s2_hold_is_armed_at_submission, False),
    ("S3", s3_successor_prefetch_runs_once, False),
    ("S4a", s4a_rapid_next_keeps_the_hold, False),
    ("S4b", s4b_replay_during_a_queued_error, False),
    ("S5", s5_lane_follows_rank_then_index, False),
    ("S6", s6_no_stage_two_before_stage_one_drains, False),
    ("S7", s7_stand_aside_and_no_stranding, False),
    ("S8a", s8a_no_progress_times_out, False),
    ("S8b", s8b_sparse_progress_survives, False),
    ("S8c", s8c_a_stall_after_progress_times_out, False),
    ("S9", s9_unflagged_placeholders, False),
    ("S10", s10_error_and_close_settle_clean, False),
    ("S11", s11_append_and_fast_path, False),
    ("S12a", s12a_a_dead_timeout_is_not_chased, False),
    ("S12b", s12b_a_stalled_timeout_is_not_chased_either, False),
    ("S13", s13_one_download_per_claimed_file, False),
    ("S14", s14_the_priority_records_drain, False),
    ("S15", s15_a_failing_file_spends_its_budget_and_stops, False),
    ("S16", s16_close_during_a_live_transfer_starts_nothing, False),
    ("S17", s17_play_pause_during_loading_lands_parked, False),
    ("S18", s18_a_wedged_open_still_starts_the_sweep, False),
    # Expected-fail until docs/bugs/background-lane-wedged-open-starvation.md
    # is fixed. Run and reported, never skipped: the day it XPASSes is the day
    # the fix landed, or the day the scenario stopped reaching the bug.
    ("S19", s19_a_wedged_prefetch_open_does_not_starve_the_sweep, True),
    ("S21", s21_the_library_converges, False),
]


# --------------------------------------------------------------------------


def check_unique_basenames(corpus: Path):
    """The trace records a transfer by last path component alone, so two files
    sharing a basename are one file to every assertion in this file."""
    seen, dupes = {}, set()
    for path in corpus.rglob("*"):
        if path.is_file():
            if path.name in seen:
                dupes.add(path.name)
            seen[path.name] = path
    if dupes:
        sys.exit(f"{corpus} has {len(dupes)} duplicate basename(s) — the cloud "
                 f"trace could not tell them apart. Rebuild with "
                 f"make-cloud-corpus.py.\n  e.g. {sorted(dupes)[:3]}")


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
    app = Path(args.app).resolve() if args.app else DEFAULT_APP.resolve()

    wanted = {s.strip() for s in args.only.split(",")} if args.only else None
    plan = [(i, f, x) for i, f, x in SCENARIOS if not wanted or i in wanted]
    if not plan:
        sys.exit(f"--only matched nothing; ids are {[i for i, _, _ in SCENARIOS]}")

    channel = Channel(app, verbose=args.verbose)
    results = []
    folders = [p for p in corpus.iterdir() if p.is_dir()]
    print(f"corpus: {corpus}  ({len(folders)} folders, "
          f"{sum(1 for _ in corpus.rglob('*') if _.is_file())} files)")
    print(f"app:    {app}\n")

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
            ctx.cmd("clear_caches", timeout=60)
            note = fn(ctx)
            outcome = "XPASS" if expect_fail else "PASS"
            detail = note
        except Failed as exc:
            outcome = "XFAIL" if expect_fail else "FAIL"
            detail = str(exc)
        except Exception as exc:  # harness fault, not the app's
            outcome, detail = "ERROR", f"{type(exc).__name__}: {exc}"
        elapsed = time.monotonic() - started
        trace = []
        if outcome in ("FAIL", "XFAIL", "XPASS"):
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

    print("\n" + "=" * 78)
    for ident, label, outcome, detail, elapsed, trace in results:
        print(f"{outcome:<6} {label}  ({elapsed:.0f}s)")
        print(f"       {detail}")
        if outcome in ("FAIL", "XFAIL", "XPASS") and trace:
            print(fmt_trace(trace, limit=40))
    print("=" * 78)

    counts = {}
    for _, _, outcome, _, _, _ in results:
        counts[outcome] = counts.get(outcome, 0) + 1
    print("  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    # XFAIL is a recorded gap, not a failure of the run. XPASS is a finding —
    # a guarantee the code now provides and nothing claimed — so it is reported
    # loudly but does not fail either.
    hard = counts.get("FAIL", 0) + counts.get("ERROR", 0)
    return 1 if hard else 0


if __name__ == "__main__":
    sys.exit(main())
