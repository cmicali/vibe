#!/usr/bin/env python3
"""Device-flap soak: does playback survive the output device vanishing?

Not a stress profile: flapping the system default moves audio for every app,
so this is run deliberately, and it restores the default when it stops.

It hunts a silent stop seen once in 15 physical power-cycles: `stopped` at
position 0, no resume, nothing logged. Neither a new AudioDeviceID nor the
`could not read output channels` warning explains it, so it needs volume.

A clean run clears Vibe's rebind path, not the hardware path: `vanish`
destroys a software aggregate that returns in microseconds, while a real DAC
waking from sleep takes seconds. Only physical power-cycling tests that.

Oracles per flap: playing before and after with a moving position,
check_consistency, the app alive; dump_health against a baseline every
--health-every flaps (outputDropouts and renderRefusals fail on any rise);
a final quiesce with every pending counter at zero.

TRAP: JUDGE THE HEAP AT REST, NOT WHILE RUNNING. A running sample counts
allocations in flight: it read ~5 KB/flap of growth while the at-rest heap fell
from ~21 MB to ~9.7 MB and stayed flat, and a no-flap control grew as fast.
Read the --rest-every series; the summary prints both so the running one is
never quoted alone.

    device-flap.py --corpus ~/Music/big --device <id> --flaps 200
    device-flap.py --corpus ~/Music/big --device <id> --device-b <id> --mode move --gone-ms 800
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
HELPER_SRC = HERE / "device-flap.swift"
DEFAULT_APP = REPO / "build/DerivedData/Build/Products/Debug/Vibe.app"

# Dotted paths into dump_health. footprintBytes is absent: it is the
# allocator's high-water mark and wanders hundreds of MB at rest.
HEALTH_KEYS = (
    "process.mallocLiveBytes",
    "process.fileDescriptors",
    "process.threads",
    "process.machPorts",
    "app.hostedUnits",
    "app.outputDropouts",
    "app.renderRefusals",
    "ui.views",
    "ui.layers",
)
# Cumulative counters a healthy run holds at zero: any rise over the baseline
# is a finding at once, which a growth factor over a zero baseline never sees.
MUST_NOT_GROW = ("app.outputDropouts", "app.renderRefusals")
# One sample over the limit means nothing (the opening decode peaks, and
# retiring voices swing as crossfade pairs drain): the baseline is the minimum
# of the first samples, and only consecutive breaches fail.
BASELINE_SAMPLES = 3
CONSECUTIVE_BREACHES = 3
GROWTH_FACTOR = 3.0

# TRAP: VANISH MODE DEGRADES coreaudiod, AND THE DAMAGE OUTLIVES THIS SCRIPT.
# Each vanish publishes and destroys a system-wide aggregate. ~400 in an
# afternoon left the daemon unable to start IO on any device for any process
# (the Vibe of the day logged "Could not start audio engine"; an unrelated
# AVAudioEngine hung 15 s), with nothing hogged or stranded, until
# `sudo killall coreaudiod`. The threshold moves and was never bisected: on
# macOS 27, ~935 in batches of 250 with these pauses stayed healthy and ~990
# wedged, AudioComponentInstanceNew hanging while property reads still
# answered. Hence the opt-in cap and the pauses, and a health check between
# batches must make an output unit, not read a property.
#
# TRAP: A LOCKED MAC CAN LOOK LIKE THIS DAMAGE. With the lock screen's
# password prompt up, no process got a render callback on any device while
# units made, started and stopped cleanly; unlocking fixed it, a coreaudiod
# restart did not. Only a render callback proves output, hence a start must
# reach a moving position below.
MAX_UNCAPPED_FLAPS = 250
RECOVER_EVERY = 20.0      # seconds of quiet
RECOVER_BATCH = 100       # ...every this many flaps


def dig(d, dotted):
    for part in dotted.split("."):
        if not isinstance(d, dict):
            return None
        d = d.get(part)
    return d


class App:
    def __init__(self, binary):
        self.bin = str(binary)

    def json(self, *argv, timeout=60):
        try:
            p = subprocess.run([self.bin, "--debug-cmd", *argv],
                               capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return {}
        try:
            return json.loads(p.stdout)
        except Exception:
            return {}

    def wait_for_channel(self, seconds=45):
        """A relaunch racing a dying instance can return before the new one
        listens, and an empty first reply reads as a refusal to play."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.json("dump_state", timeout=10).get("player"):
                return True
            time.sleep(0.5)
        return False

    def alive(self):
        # The CLI client IS the app binary, so filter argv for the GUI process.
        out = subprocess.run(["pgrep", "-x", "Vibe"], capture_output=True, text=True).stdout
        for pid in out.split():
            argv = subprocess.run(["ps", "-o", "command=", "-p", pid],
                                  capture_output=True, text=True).stdout
            if "--debug-cmd" not in argv and "CoreSimulator" not in argv:
                return True
        return False

    def playback(self):
        s = self.json("dump_state").get("player", {})
        return s.get("state"), s.get("position")

    def reload(self, corpus):
        """TRAP: quiesce empties the playlist and play_index on an empty one is
        a no-op, so without this reopen every later flap runs against an idle
        player and the silent-stop oracle passes vacuously. Absolute, because
        the app's working directory is not the shell's."""
        self.json("open", str(Path(corpus).resolve()))
        for _ in range(20):
            if (self.json("dump_state").get("playlist") or {}).get("count"):
                break
            time.sleep(0.5)
        self.json("play_index", "0")
        time.sleep(1.5)
        return self.playback()[0] == "playing"


def build_helper(out):
    if out.exists() and out.stat().st_mtime > HELPER_SRC.stat().st_mtime:
        return out
    r = subprocess.run(["swiftc", "-O", str(HELPER_SRC), "-o", str(out)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"could not build helper:\n{r.stderr}")
    return out


def flap(helper, mode, dev_a, gone_ms, dev_b):
    argv = [str(helper), mode, str(dev_a), str(gone_ms)]
    if mode == "move":
        argv.append(str(dev_b))
    r = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        return {"ok": False, "error": r.stderr.strip()[:200] or "no output"}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", required=True, type=Path,
                    help="folder of audio files; opened via launch.sh so the "
                         "sandbox grant covers it")
    ap.add_argument("--app", type=Path, default=DEFAULT_APP)
    ap.add_argument("--flaps", type=int, default=200)
    ap.add_argument("--i-know-this-degrades-coreaudiod", action="store_true",
                    help=f"permit more than {MAX_UNCAPPED_FLAPS} vanish flaps in one "
                         "run; see the coreaudiod TRAP in this script")
    ap.add_argument("--recover-every", type=int, default=RECOVER_EVERY,
                    help="pause this many seconds every --recover-batch flaps "
                         "to let coreaudiod settle; 0 disables")
    ap.add_argument("--recover-batch", type=int, default=RECOVER_BATCH)
    ap.add_argument("--mode", choices=("vanish", "move"), default="vanish",
                    help="vanish: the default device ceases to exist (faithful). "
                         "move: the default merely moves (weaker, isolates which "
                         "half of the stimulus matters)")
    ap.add_argument("--device", type=int, required=True,
                    help="AudioDeviceID to wrap (vanish) or flap from (move)")
    ap.add_argument("--device-b", type=int, default=0, help="move mode only")
    ap.add_argument("--gone-ms", type=float, default=1500,
                    help="how long the helper holds after the device vanishes or moves")
    ap.add_argument("--settle-ms", type=float, default=800,
                    help="wait after a flap before judging playback")
    ap.add_argument("--health-every", type=int, default=25)
    ap.add_argument("--rest-every", type=int, default=100,
                    help="quiesce and sample the heap AT REST this often; this "
                         "is the series to judge growth by, not the running one")
    args = ap.parse_args()

    if args.mode == "move" and not args.device_b:
        sys.exit("--mode move needs --device-b")

    if (args.mode == "vanish" and args.flaps > MAX_UNCAPPED_FLAPS
            and not args.i_know_this_degrades_coreaudiod):
        sys.exit(
            f"refusing {args.flaps} vanish flaps in one run.\n\n"
            f"Each one publishes and destroys a system-wide aggregate, and "
            f"about 400 in an afternoon left coreaudiod unable to start IO on "
            f"any device — including for unrelated apps. Clearing it needs "
            f"`sudo killall coreaudiod`.\n\n"
            f"Either run {MAX_UNCAPPED_FLAPS} or fewer, use --mode move (which "
            f"creates no devices), or pass "
            f"--i-know-this-degrades-coreaudiod if you accept that risk on "
            f"this machine.")

    helper = build_helper(HERE / "device-flap-helper")
    binary = args.app / "Contents/MacOS/Vibe"
    if not binary.exists():
        sys.exit(f"no Debug build at {binary}")

    launch = REPO / ".claude/skills/vibe-stress/../vibe-debug/scripts/launch.sh"
    print(f"launching {args.app} with corpus {args.corpus}", flush=True)
    subprocess.run([str(launch.resolve()), str(args.corpus)],
                   capture_output=True, text=True,
                   # TRAP: without VIBE_APP, launch.sh starts the default Debug build and
                   # --app reaches only the channel client: the soak tests the wrong app.
                   env={**__import__("os").environ, "VIBE_AUDIBLE": "silent",
                        "VIBE_APP": str(args.app.resolve())})

    app = App(binary)
    if not app.alive():
        sys.exit("app did not come up")
    if not app.wait_for_channel():
        sys.exit("app is running but its debug channel never answered — a "
                 "Release build, or a second instance holding the channel")

    # One failed first play must not abandon an hour-long run.
    for attempt in range(3):
        app.json("play_index", "0")
        time.sleep(2.0)
        state, pos = app.playback()
        if state == "playing" and pos and pos > 0.5:
            break
        print(f"  start attempt {attempt + 1}: state={state} at {pos}s, retrying", flush=True)
    else:
        sys.exit(f"could not start playback after 3 attempts (state={state})")
    print(f"playing at {pos:.1f}s; flapping {args.flaps}x in {args.mode} mode", flush=True)

    baseline, stops, failures, helper_errors = None, [], [], 0
    samples, breaches, at_rest = [], {}, []
    for i in range(1, args.flaps + 1):
        before_state, before_pos = app.playback()
        if before_state != "playing":
            # A flap over an idle player tests nothing and must not count as clean.
            failures.append((i, f"not playing before the flap (state={before_state})"))
            print(f"  flap {i}: *** NOT PLAYING before flap ({before_state}) ***", flush=True)
            if not app.reload(args.corpus):
                break
            before_state, before_pos = app.playback()
        res = flap(helper, args.mode, args.device, args.gone_ms, args.device_b)
        if not res.get("ok"):
            helper_errors += 1
            print(f"  flap {i}: helper failed: {res.get('error')}", flush=True)
            continue
        time.sleep(args.settle_ms / 1000.0)

        if not app.alive():
            failures.append((i, "app died"))
            print(f"  flap {i}: *** APP GONE ***", flush=True)
            break

        state, pos = app.playback()
        # TRAP: "playing" is intent, not sound. With the output rendering
        # nothing, every flap read playing at 0.0s and the run passed
        # vacuously; a position that does not move is a silent stop too.
        if state == "playing":
            time.sleep(0.5)
            state, moved = app.playback()
            if state == "playing" and moved is not None and pos is not None and abs(moved - pos) < 0.05:
                state = f"playing, stuck at {moved:.2f}s"
        # A natural track end also reads stopped.
        if before_state == "playing" and state != "playing":
            dur = app.json("dump_state").get("player", {}).get("duration") or 0
            natural = dur and before_pos and (dur - before_pos) < 3.0
            if not natural:
                stops.append((i, before_pos, state))
                print(f"  flap {i}: *** SILENT STOP *** was playing at "
                      f"{before_pos:.1f}s, now {state}", flush=True)
            app.reload(args.corpus)  # so the next flap does not count it again

        viol = app.json("check_consistency").get("violations") or []
        if viol:
            failures.append((i, f"consistency: {viol}"))
            print(f"  flap {i}: consistency violations: {viol}", flush=True)

        if i % args.health_every == 0:
            h = app.json("dump_health")
            sample = {k: dig(h, k) for k in HEALTH_KEYS}
            sample = {k: v for k, v in sample.items() if isinstance(v, (int, float))}
            if not sample:
                failures.append((i, "dump_health returned none of the expected "
                                    "keys — the health oracle is not running"))
            samples.append(sample)
            short = {k.split(".")[-1]: v for k, v in sample.items()}
            print(f"  flap {i}: {short}", flush=True)

            if len(samples) == BASELINE_SAMPLES:
                baseline = {k: min(s.get(k, float("inf")) for s in samples)
                            for k in sample}
            if baseline:
                for k, v in sample.items():
                    b = baseline.get(k)
                    if k in MUST_NOT_GROW:
                        if b is not None and v > b and k not in breaches:
                            breaches[k] = 1
                            failures.append((i, f"{k} rose from {b} to {v}"))
                    elif b and v > b * GROWTH_FACTOR:
                        breaches[k] = breaches.get(k, 0) + 1
                        if breaches[k] == CONSECUTIVE_BREACHES:
                            failures.append(
                                (i, f"{k} over {GROWTH_FACTOR}x baseline for "
                                    f"{CONSECUTIVE_BREACHES} samples: {b} -> {v}"))
                    else:
                        breaches[k] = 0

        if (args.mode == "vanish" and args.recover_every and args.recover_batch
                and i % args.recover_batch == 0 and i < args.flaps):
            print(f"  flap {i}: pausing {args.recover_every:.0f}s to let "
                  f"coreaudiod settle", flush=True)
            time.sleep(args.recover_every)

        if args.rest_every and i % args.rest_every == 0:
            # After quiesce what remains is retained, not in flight.
            app.json("quiesce", timeout=40)
            rest = dig(app.json("dump_health"), "process.mallocLiveBytes")
            if rest:
                at_rest.append((i, rest))
                print(f"  flap {i}: AT REST live heap {rest:,}", flush=True)
            if not app.reload(args.corpus):
                failures.append((i, "could not resume playback after the at-rest quiesce"))
                print(f"  flap {i}: *** NOT PLAYING after reload ***", flush=True)
                break

    q = app.json("quiesce", timeout=40)
    pending = q.get("pending")
    print("\n================ RESULTS ================")
    print(f"flaps run:      {args.flaps}  (mode={args.mode}, gone={args.gone_ms}ms)")
    print(f"silent stops:   {len(stops)}")
    for i, p, s in stops:
        print(f"    flap {i}: was playing at {p:.1f}s -> {s}")
    print(f"other failures: {len(failures)}")
    for i, why in failures:
        print(f"    flap {i}: {why}")
    print(f"helper errors:  {helper_errors}")
    if at_rest:
        print("live heap AT REST (judge growth by THIS, not the running samples):")
        for i, v in at_rest:
            print(f"    flap {i}: {v:,}")
        if len(at_rest) >= 2:
            span = at_rest[-1][0] - at_rest[0][0]
            delta = at_rest[-1][1] - at_rest[0][1]
            print(f"    -> {delta:+,} bytes over {span} flaps "
                  f"({delta / span:+,.0f}/flap). An app merely playing audio for "
                  f"the same wall-clock grows at a comparable rate, so treat this "
                  f"as flap-attributable only if a no-flap control says so.")
    print(f"quiesce:        settled={q.get('settled')} pending={pending}")
    return 1 if (stops or failures) else 0


if __name__ == "__main__":
    sys.exit(main())
