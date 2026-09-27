#!/usr/bin/env python3
"""Single-playlist skip and seek torture test for the running Vibe app.

The fuzz profiles keep OPENING files; this loads ONE large playlist and
hammers transport, so track changes outrun the metadata scan, the waveform
load and the analyzers, and seeks land on a track already replaced. Each burst
is one `script -` invocation, which is what drives it faster than the fuzzer.

Oracles between bursts: the app is alive, check_consistency is clean, and
dump_health's fds / hosted units / pending counters / live heap have not run
away. --seed N replays an identical op sequence.
"""

import argparse
import json
import random
import subprocess
import sys
import time
from pathlib import Path


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
        p = subprocess.run([self.bin, "--debug-cmd", "script", "-"],
                           input="\n".join(lines) + "\n",
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr

    def alive(self):
        out = subprocess.run(["pgrep", "-x", "Vibe"], capture_output=True, text=True).stdout
        for pid in out.split():
            argv = subprocess.run(["ps", "-o", "command=", "-p", pid],
                                  capture_output=True, text=True).stdout
            if "--debug-cmd" not in argv and "CoreSimulator" not in argv:
                return int(pid)
        return None


# No sleeps anywhere: each transport command must land before the last one's
# async work has.
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
    """Walk off the end of the playlist and back: the end-of-playlist park."""
    ops = []
    while len(ops) < n:
        ops += ["next"] * rng.randint(8, 20)
        ops += [f"seek {rng.uniform(0, 1e7):.3f}"]     # skip past end
        ops += ["previous"] * rng.randint(1, 5)
        ops += ["play_pause"]
    return ops[:n]


def phase_jump(rng, st, n):
    """Land anywhere in the playlist.

    next/previous reach only the adjacent track, which the successor prefetch
    and the sweep's neighborhood ranking have already reached. A jump lands
    where nothing has — on a cloud playlist, a foreground transfer raised while
    the sweep still holds the lane.
    """
    count = max(2, st.get("playlistCount") or 2)
    ops = []
    for _ in range(n):
        r = rng.random()
        if r < 0.08:
            # Out of range must be a no-op.
            ops.append(f"play_index {rng.randrange(count, count * 4 + 16)}")
        elif r < 0.14:
            ops.append(f"play_index -{rng.randrange(1, 50)}")
        elif r < 0.24:
            # Same row twice: the first play's settlement passes every
            # content-based guard; only submission identity can drop it.
            index = rng.randrange(count)
            ops += [f"play_index {index}", f"play_index {index}"]
        else:
            ops.append(f"play_index {rng.randrange(count)}")
    return ops[:n]


def phase_blocked(rng, st, n):
    """Every op holds main, then runs a verb on the same turn.

    The channel's intake is on main, so a callback already dispatched to main
    always beats a command sent afterwards. Holding main first is the only way
    to queue stale deliveries (waveform, metadata, BPM, key) behind a user
    action already underway.
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
    """Violations present in both of two samples a settle apart, matched by id.

    Several rules compare a RENDERED label against its state, and a burst ends
    with opens in flight, when the render is legitimately a turn behind. One
    sample would fail on that lag; a settle that swaps one transient violation
    for another is still a settling app.
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
        "units": a["hostedUnits"],
        "refusals": a.get("renderRefusals", 0),
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
                    help="arm the fake file provider with this base transfer time "
                         "before opening, so each track change is a real transfer "
                         "issued before the last one's download has started")
    ap.add_argument("--cloud-percent", type=int, default=70,
                    help="percent of files that are placeholders (default 70)")
    ap.add_argument("--cloud-capacity", type=int, default=1,
                    help="provider transfer slots (default 1; 0 is unlimited, where "
                         "nothing waits and the foreground hold is unobservable)")
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
    deadline = time.time() + 180
    count = 0
    while time.time() < deadline:
        # dump_health, not dump_state: dump_state carries every path.
        h = app.json("dump_health") or {}
        count = (h.get("app") or {}).get("playlistCount") or 0
        if count > 1:
            break
        time.sleep(0.5)
    print(f"loaded:   {count} tracks")
    if count <= 1:
        if not app.alive():
            print("FAILED: app DIED while loading the playlist (crash on open)")
            return 1
        # Nearly always the sandbox grant: a direct-exec launch cannot grant a
        # folder from argv, so an ungranted folder opens as nothing.
        print("FAIL: playlist never populated")
        print(f"      The sandbox most likely holds no grant for {args.playlist}.")
        print("      run-torture.sh direct-execs the binary to be sure which build")
        print("      runs, and a direct-exec launch cannot grant a folder from argv.")
        print("      Grant it once through the open funnel, then re-run this:")
        print(f'        .claude/skills/vibe-debug/scripts/launch.sh "{args.playlist}"')
        return 2

    base = health_of(app)
    print(f"baseline: fds {base['fds']}  units {base['units']}  "
          f"live {base['liveMB']:.1f} MB  views {base['views']}")

    total_ops = 0
    t0 = time.time()
    for phase in args.phases.split(","):
        gen = PHASES[phase]
        print(f"\n--- phase {phase}: {args.rounds} bursts x {args.burst} ops")
        st = {"duration": 30.0, "playlistCount": count}
        for r in range(args.rounds):
            # dump_state lists every file, so refresh the seek scale rarely.
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
            if h["units"] > base["units"] + 64:
                bad.append(f"hostedUnits {base['units']}->{h['units']}")
            if h["refusals"] > base["refusals"]:
                bad.append(f"renderRefusals {base['refusals']}->{h['refusals']}")
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
                      f"fds {h['fds']}  units {h['units']}  live {h['liveMB']:5.1f} MB"
                      f"{'  PENDING ' + pend if pend else ''}")

    app.cmd("quiesce", timeout=120)
    rest = health_of(app)
    stuck = {k: v for k, v in rest["pending"].items() if v}
    print(f"\nat rest: fds {rest['fds']}  units {rest['units']}  "
          f"live {rest['liveMB']:.1f} MB  pending {rest['pending']}")
    if stuck:
        print(f"FAILED: pending counters did not unwind at rest: {stuck}")
        return 1

    if args.cloud is not None:
        # A stranded claim is too small for any memory oracle, and the
        # materialization gauges sit outside dump_health's pending: at rest
        # every gauge must be zero. Lifetime totals are skipped.
        cloud = app.json("dump_cloud_health") or {}
        mat = cloud.get("materialization") or {}
        cumulative = {"handleOpensStarted", "handleOpensCompleted"}
        left = {k: v for k, v in
                {"cloudParsesPending": cloud.get("cloudParsesPending"),
                 "cloudLaneHeld": cloud.get("cloudLaneHeld"),
                 **{k: mat.get(k) for k in sorted(mat)
                    if k not in cumulative and not k.startswith("requests")}}.items() if v}
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
    # Redirected stdout is block-buffered, hiding a long run's progress.
    sys.stdout.reconfigure(line_buffering=True)
    sys.exit(main())
