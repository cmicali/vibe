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


PHASES = {
    "skip": phase_skip_storm,
    "seek": phase_seek_storm,
    "mixed": phase_mixed,
    "boundary": phase_boundary,
}


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
    ap.add_argument("--phases", default="skip,seek,mixed,boundary")
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
        print("FAIL: playlist never populated")
        return 2

    base = health_of(app)
    print(f"baseline: fds {base['fds']}  nodes {base['nodes']}  "
          f"live {base['liveMB']:.1f} MB  views {base['views']}")

    total_ops = 0
    t0 = time.time()
    for phase in args.phases.split(","):
        gen = PHASES[phase]
        print(f"\n--- phase {phase}: {args.rounds} bursts x {args.burst} ops")
        st = {"duration": 30.0}
        for r in range(args.rounds):
            # dump_state is heavy on a large playlist (it lists every file), so
            # refresh the seek scale periodically rather than every burst.
            if r % 5 == 0:
                st_raw = app.json("dump_state") or {}
                st = {"duration": (st_raw.get("player") or {}).get("duration") or 30.0}
            ops = gen(rng, st, args.burst)
            rc, out, err = app.script(ops)
            total_ops += len(ops)

            pid = app.alive()
            if not pid:
                print(f"\nFAILED: app died in phase {phase}, burst {r}")
                print("last ops:", " | ".join(ops[-12:]))
                return 1

            inv = app.json("check_consistency")
            if inv and inv.get("violations"):
                print(f"\nFAILED: consistency violation in phase {phase}, burst {r}")
                print(json.dumps(inv["violations"], indent=2))
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

    elapsed = time.time() - t0
    print(f"\nPASSED {total_ops} ops in {elapsed:.0f}s "
          f"({total_ops / elapsed:.1f} ops/s), no violations, no growth, all pending clear")
    return 0


if __name__ == "__main__":
    sys.exit(main())
