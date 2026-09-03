#!/usr/bin/env python3
"""Single-playlist skip and seek torture test for the running Vibe app.

The fuzz profiles in vibe-stress keep OPENING files; this loads ONE large
playlist and then hammers transport at the highest rate the channel allows,
which is a different hazard entirely: track changes outrunning the metadata
scan, the waveform load and the analyzers, plus seeks landing on a track that
has already been replaced.

Ops go through the channel's `script -` verb, so a burst is one CLI invocation
rather than one per op. That is what makes it a torture test — it drives skips
faster than any human or the ~12 ops/s fuzzer can.

Oracles between bursts: the app is alive, check_consistency has no violations,
and dump_health's fds / engine nodes / pending counters / live heap have not
run away. Seeded: --seed N replays an identical op sequence.
"""

import argparse
import json
import random
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[0]


class App:
    def __init__(self, binary):
        self.bin = binary

    def cmd(self, *argv, timeout=60):
        p = subprocess.run([self.bin, "--debug-cmd", *argv],
                           capture_output=True, text=True, timeout=timeout)
        return p.stdout

    def json(self, *argv, timeout=60):
        out = self.cmd(*argv, timeout=timeout)
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return None

    def script(self, lines, timeout=300):
        """One CLI invocation for a whole burst — the fast path."""
        p = subprocess.run([self.bin, "--debug-cmd", "script", "-"],
                           input="\n".join(lines) + "\n",
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr

    def alive(self):
        out = subprocess.run(["pgrep", "-x", "Vibe"], capture_output=True, text=True).stdout
        for pid in out.split():
            argv = subprocess.run(["ps", "-o", "command=", "-p", pid],
                                  capture_output=True, text=True).stdout
            if "--debug-cmd" not in argv:
                return int(pid)
        return None


# Each phase returns a list of channel commands. No sleeps anywhere: the whole
# point is to issue the next transport command before the last one's async work
# has landed.
def phase_skip_storm(rng, st, n):
    ops = []
    for _ in range(n):
        ops.append(rng.choices(["next", "previous"], weights=[7, 3])[0])
    return ops


def phase_seek_storm(rng, st, n):
    dur = max(1.0, st.get("duration") or 30.0)
    ops = []
    for _ in range(n):
        r = rng.random()
        if r < 0.10:
            ops.append(f"seek {rng.uniform(-1e6, -1):.3f}")      # out of range low
        elif r < 0.20:
            ops.append(f"seek {rng.uniform(dur, dur * 1000):.3f}")  # past the end
        else:
            ops.append(f"seek {rng.uniform(0, dur):.3f}")
    return ops


def phase_mixed(rng, st, n):
    dur = max(1.0, st.get("duration") or 30.0)
    ops = []
    for _ in range(n):
        r = rng.random()
        if r < 0.35:
            ops.append("next")
        elif r < 0.50:
            ops.append("previous")
        elif r < 0.72:
            ops.append(f"seek {rng.uniform(-5, dur * 1.2):.3f}")
        elif r < 0.80:
            ops.append("play_pause")
        else:
            ops.append(rng.choice([
                "skip_forward", "skip_forward_more", "skip_forward_most",
                "skip_back", "skip_back_more", "skip_back_most"]))
    return ops


def phase_boundary(rng, st, n):
    """Walk off the end of the playlist and back, repeatedly: the
    end-of-playlist park and finishCurrentTrack path."""
    ops = []
    while len(ops) < n:
        ops += ["next"] * rng.randint(8, 20)
        ops += [f"seek {rng.uniform(0, 1e7):.3f}"]     # skip past end
        ops += ["previous"] * rng.randint(1, 5)
        ops += ["play_pause"]
    return ops[:n]


def phase_jump(rng, st, n):
    """Land anywhere in the playlist, over and over.

    next/previous only ever walk to the adjacent track, and the adjacent track
    is the one case the successor prefetch has already parked and the metadata
    sweep's neighborhood ranking has already reached. A jump lands where
    nothing has prefetched — and against a cloud playlist that means a
    foreground transfer with no head start, raised while the sweep still holds
    the lane.
    """
    count = max(2, st.get("playlistCount") or 2)
    ops = []
    for _ in range(n):
        r = rng.random()
        if r < 0.08:
            # Out of range is a documented no-op; escaping it is the finding.
            ops.append(f"play_index {rng.randrange(count, count * 4 + 16)}")
        elif r < 0.14:
            ops.append(f"play_index -{rng.randrange(1, 50)}")
        elif r < 0.24:
            # Two jumps to the SAME row: replaying one produces the same track
            # and the same URL, so a settlement belonging to the first passes
            # every content-based guard. Only submission identity can drop it.
            index = rng.randrange(count)
            ops += [f"play_index {index}", f"play_index {index}"]
        else:
            ops.append(f"play_index {rng.randrange(count)}")
    return ops[:n]


def phase_blocked(rng, st, n):
    """Every op a held main thread with a verb chained onto the same turn.

    The channel's own intake is on the main queue, so an async callback the app
    dispatched to main always wins the race against a command sent afterwards.
    Holding main first is the only way to park a queue of worker callbacks —
    waveform, metadata, BPM and key deliveries from tracks already replaced —
    behind a user action that is already underway.
    """
    count = max(2, st.get("playlistCount") or 2)
    dur = max(1.0, st.get("duration") or 30.0)
    ops = []
    for _ in range(n):
        hold = f"{rng.uniform(0.05, 0.9):.2f}"
        then = rng.choice([
            f"play_index {rng.randrange(count)}",
            f"play_index {rng.randrange(count)}",
            f"seek {rng.uniform(-5, dur * 1.2):.3f}",
            f"burst {rng.choice([30, 80, 200])} {rng.randrange(1, 1 << 30)}",
            "clear_caches",
        ])
        ops.append(f"block_main {hold} {then}")
    return ops


PHASES = {
    "skip": phase_skip_storm,
    "seek": phase_seek_storm,
    "mixed": phase_mixed,
    "boundary": phase_boundary,
    "jump": phase_jump,
    "blocked": phase_blocked,
}


def surviving_violations(app, settle=0.4):
    """Violations that are still there after a settle and a second sample.

    Several of check_consistency's rules compare a RENDERED label against the
    state that should have produced it, and renderState runs from the updateUI
    funnel — so a state that flipped this runloop turn may legitimately not be
    drawn yet. A burst here ends 40 transport ops deep with opens still in
    flight, which is precisely when the render is a turn behind, so a single
    sample turns a lag into a failure and ends the phase seconds in.

    Only violations present in BOTH samples count, matched by id: a settle that
    swaps one transient violation for another is still a settling app.
    """
    first = app.json("check_consistency")
    if not first or not first.get("violations"):
        return None
    time.sleep(settle)
    second = app.json("check_consistency")
    if not second or not second.get("violations"):
        return None
    ids = {v["id"] for v in first["violations"]}
    return [v for v in second["violations"] if v["id"] in ids] or None


def health_of(app):
    h = app.json("dump_health")
    if not h:
        return None
    p, u, a = h["process"], h["ui"], h["app"]
    return {
        "footMB": p["footprintBytes"] / 1e6,
        "liveMB": p["mallocLiveBytes"] / 1e6,
        "fds": p["fileDescriptors"],
        "threads": p["threads"],
        "views": u["views"],
        "nodes": a["engineNodes"],
        "pending": h["pending"],
        "playlistCount": a["playlistCount"],
        "currentIndex": a["currentIndex"],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--playlist", required=True, help="folder to open as ONE playlist")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--burst", type=int, default=40, help="ops per script invocation")
    ap.add_argument("--rounds", type=int, default=40, help="bursts per phase")
    ap.add_argument("--phases", default="skip,seek,mixed,jump,blocked,boundary")
    ap.add_argument("--cloud", metavar="SECONDS", type=float, default=None,
                    help="arm the fake file provider before opening the playlist, so "
                         "every track change is a real transfer. This is the shape the "
                         "fuzz profiles cannot reach: they settle between opens to let a "
                         "sweep run, while this issues the next track change before the "
                         "last one's download has even started.")
    ap.add_argument("--cloud-percent", type=int, default=70)
    ap.add_argument("--cloud-capacity", type=int, default=1,
                    help="provider transfer slots (default 1). With the provider's "
                         "unlimited default nothing ever waits on anything, so the "
                         "ordering the foreground hold exists for is unobservable.")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    rng = random.Random(seed)
    binary = str(Path(args.app) / "Contents/MacOS/Vibe")
    app = App(binary)

    print(f"seed:     {seed}   (replay with --seed {seed})")
    print(f"playlist: {args.playlist}")

    pid = app.alive()
    if not pid:
        print("FAIL: app is not running")
        return 2

    if args.cloud is not None:
        armed = app.json("set_fake_cloud", f"{args.cloud:g}", str(args.cloud_percent),
                         f"capacity={args.cloud_capacity}")
        if not (armed or {}).get("installed"):
            print(f"FAIL: could not arm the fake provider: {armed}")
            return 2
        print(f"cloud:    {armed['percent']}% placeholders, {args.cloud:g}s base, "
              f"{armed['capacity']} transfer slot(s)")

    app.cmd("open", args.playlist, timeout=300)
    # Wait for the playlist to actually populate before hammering it.
    deadline = time.time() + 180
    count = 0
    while time.time() < deadline:
        # dump_health, not dump_state: the latter carries the whole file list,
        # which is 2000+ paths on this playlist.
        h = app.json("dump_health") or {}
        count = (h.get("app") or {}).get("playlistCount") or 0
        if count > 1:
            break
        time.sleep(0.5)
    print(f"loaded:   {count} tracks")
    if count <= 1:
        # Distinguish the two: a dead app during the load is the bug firing on
        # the open itself, not a driver problem.
        if not app.alive():
            print("FAILED: app DIED while loading the playlist (crash on open)")
            return 1
        # Nearly always the sandbox grant: this script direct-execs the binary
        # to pin WHICH build runs, and a direct-exec launch cannot grant a
        # folder from argv, so an ungranted folder opens as nothing at all.
        print("FAIL: playlist never populated")
        print(f"      The sandbox most likely holds no grant for {args.playlist}.")
        print("      run-torture.sh direct-execs the binary to be sure which build")
        print("      runs, and a direct-exec launch cannot grant a folder from argv.")
        print("      Grant it once through the open funnel, then re-run this:")
        print(f'        .claude/skills/vibe-debug/scripts/launch.sh "{args.playlist}"')
        return 2

    base = health_of(app)
    print(f"baseline: fds {base['fds']}  nodes {base['nodes']}  "
          f"live {base['liveMB']:.1f} MB  views {base['views']}")

    total_ops = 0
    t0 = time.time()
    for phase in args.phases.split(","):
        gen = PHASES[phase]
        print(f"\n--- phase {phase}: {args.rounds} bursts x {args.burst} ops")
        st = {"duration": 30.0, "playlistCount": count}
        for r in range(args.rounds):
            # dump_state is heavy on a large playlist (it lists every file), so
            # refresh the seek scale periodically rather than every burst.
            if r % 5 == 0:
                st_raw = app.json("dump_state") or {}
                st = {"duration": (st_raw.get("player") or {}).get("duration") or 30.0,
                      "playlistCount": ((st_raw.get("playlist") or {}).get("count")
                                        or st.get("playlistCount") or count)}
            ops = gen(rng, st, args.burst)
            rc, out, err = app.script(ops)
            total_ops += len(ops)

            pid = app.alive()
            if not pid:
                print(f"\nFAILED: app died in phase {phase}, burst {r}")
                print("last ops:", " | ".join(ops[-12:]))
                return 1

            surviving = surviving_violations(app)
            if surviving:
                print(f"\nFAILED: consistency violation in phase {phase}, burst {r}")
                print(json.dumps(surviving, indent=2))
                print("last ops:", " | ".join(ops[-12:]))
                return 1

            h = health_of(app)
            if h is None:
                print(f"\nFAILED: dump_health did not answer in phase {phase}, burst {r}")
                return 1
            bad = []
            if h["fds"] > base["fds"] + 64:
                bad.append(f"fds {base['fds']}->{h['fds']}")
            if h["nodes"] > base["nodes"] + 64:
                bad.append(f"engineNodes {base['nodes']}->{h['nodes']}")
            if h["liveMB"] > base["liveMB"] + 128:
                bad.append(f"liveHeap {base['liveMB']:.0f}->{h['liveMB']:.0f} MB")
            if h["views"] > base["views"] + 320:
                bad.append(f"views {base['views']}->{h['views']}")
            if bad:
                print(f"\nFAILED: resource growth in phase {phase}, burst {r}: {', '.join(bad)}")
                return 1

            if r % 10 == 0 or r == args.rounds - 1:
                rate = total_ops / max(0.001, time.time() - t0)
                pend = ",".join(f"{k}={v}" for k, v in h["pending"].items() if v)
                print(f"  burst {r:3d}  {total_ops:6d} ops  {rate:5.1f} ops/s  "
                      f"idx {h['currentIndex']:4d}/{h['playlistCount']}  "
                      f"fds {h['fds']}  nodes {h['nodes']}  live {h['liveMB']:5.1f} MB"
                      f"{'  PENDING ' + pend if pend else ''}")

    # Everything must unwind once it settles.
    app.cmd("quiesce", timeout=120)
    rest = health_of(app)
    stuck = {k: v for k, v in rest["pending"].items() if v}
    print(f"\nat rest: fds {rest['fds']}  nodes {rest['nodes']}  "
          f"live {rest['liveMB']:.1f} MB  pending {rest['pending']}")
    if stuck:
        print(f"FAILED: pending counters did not unwind at rest: {stuck}")
        return 1

    if args.cloud is not None:
        # dump_health's pending section deliberately does not score the two
        # cloud counters for growth — a sweep legitimately holds dozens of
        # parses. At rest, after a quiesce, every count and every hold belongs
        # at zero, and a stranded claim is a few hundred bytes that no memory
        # oracle would ever notice.
        cloud = app.json("dump_cloud_health") or {}
        mat = cloud.get("materialization") or {}
        left = {k: v for k, v in
                {"cloudParsesPending": cloud.get("cloudParsesPending"),
                 "cloudLaneHeld": cloud.get("cloudLaneHeld"),
                 **{k: mat.get(k) for k in sorted(mat)}}.items() if v}
        print(f"at rest: cloud {cloud.get('cloudParsesPending')} parses, "
              f"lane held {cloud.get('cloudLaneHeld')}, materialization {mat}")
        if left:
            print(f"FAILED: cloud work did not unwind at rest: {left}")
            return 1

    elapsed = time.time() - t0
    print(f"\nPASSED {total_ops} ops in {elapsed:.0f}s "
          f"({total_ops / elapsed:.1f} ops/s), no violations, no growth, all pending clear")
    return 0


if __name__ == "__main__":
    # A run's stdout is nearly always redirected to a file, and Python
    # block-buffers that — so a soak's progress stays invisible until the
    # process exits, which for an hour-long run is the entire run.
    sys.stdout.reconfigure(line_buffering=True)
    sys.exit(main())
