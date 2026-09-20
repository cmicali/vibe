#!/usr/bin/env python3
"""Device-flap soak: does playback survive an output device disappearing?

The question this answers is a NAMED GUARANTEE, not something random driving can
state: playback must survive the output device going away and coming back. It is
the same reason cloud-scenarios.py exists separately from the fuzz profiles.

WHY THIS IS NOT A STRESS PROFILE. `stress.py` deliberately excludes device
changes along with the other OS-facing actions, and rightly: flapping the system
default moves audio for EVERY app on the machine, and an unattended multi-hour
soak has no business doing that. This driver is run deliberately, by someone who
knows the machine's audio will move, and it restores the default when it stops.

WHAT IT IS HUNTING. A silent stop observed once in 15 physical device
power-cycles: playback went to `stopped` at position 0, did not resume, and
logged nothing at any level. Two mechanisms were proposed and both falsified —
it is not a new AudioDeviceID (the device returned as a different id with
playback intact) and it is not the `could not read output channels` warning
(fired twice with no stop). Rare, silent, no error signature: it needs volume,
not another hypothesis.

WHAT A CLEAN RUN PROVES, AND WHAT IT DOES NOT. `vanish` destroys a software
aggregate, so the "device" returns in microseconds. A real DAC waking from sleep
takes seconds to become usable, and that latency is exactly where the delay in
#47 lives. A clean run here means Vibe's own rebind path survives; it cannot
clear the hardware path. Physical power-cycling remains the only way to test
that, and it cannot be automated.

Oracles per flap: playback state, position advancing, check_consistency, the app
alive. Plus dump_health against a baseline every --health-every flaps, and a
quiesce at the end requiring every pending counter at zero.

    device-flap.py --corpus ~/Music/big --flaps 200
    device-flap.py --corpus ~/Music/big --flaps 500 --mode move --gone-ms 800
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

# Metrics worth watching across a flap soak, as dotted paths into dump_health.
# Each rebind builds and tears down a CoreAudio aggregate and rewires the master
# bus, so a leak here would be a leak per device event — invisible in a run that
# never flaps. footprintBytes is deliberately absent: it is the allocator's
# high-water mark, wanders hundreds of MB in both directions at rest, and
# mallocLiveBytes is the sensitive metric that actually means something.
HEALTH_KEYS = (
    "process.mallocLiveBytes",
    "process.fileDescriptors",
    "process.threads",
    "process.machPorts",
    "app.engineNodes",
    "ui.views",
    "ui.layers",
)
# A single sample over the limit means nothing: the opening decode peaks far
# above resting and engine nodes swing widely as crossfade pairs drain. Baseline
# is the element-wise minimum of the first three samples, and a metric is only
# reported after this many consecutive breaches.
BASELINE_SAMPLES = 3
CONSECUTIVE_BREACHES = 3
GROWTH_FACTOR = 3.0


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
    ap.add_argument("--mode", choices=("vanish", "move"), default="vanish",
                    help="vanish: the default device ceases to exist (faithful). "
                         "move: the default merely moves (weaker, isolates which "
                         "half of the stimulus matters)")
    ap.add_argument("--device", type=int, required=True,
                    help="AudioDeviceID to wrap (vanish) or flap from (move)")
    ap.add_argument("--device-b", type=int, default=0, help="move mode only")
    ap.add_argument("--gone-ms", type=float, default=1500)
    ap.add_argument("--settle-ms", type=float, default=800,
                    help="wait after a flap before judging playback")
    ap.add_argument("--health-every", type=int, default=25)
    args = ap.parse_args()

    if args.mode == "move" and not args.device_b:
        sys.exit("--mode move needs --device-b")

    helper = build_helper(HERE / "device-flap-helper")
    binary = args.app / "Contents/MacOS/Vibe"
    if not binary.exists():
        sys.exit(f"no Debug build at {binary}")

    launch = REPO / ".claude/skills/vibe-stress/../vibe-debug/scripts/launch.sh"
    print(f"launching {args.app} with corpus {args.corpus}", flush=True)
    subprocess.run([str(launch.resolve()), str(args.corpus)],
                   capture_output=True, text=True,
                   env={**__import__("os").environ, "VIBE_AUDIBLE": "silent"})

    app = App(binary)
    if not app.alive():
        sys.exit("app did not come up")

    app.json("play_index", "0")
    time.sleep(2.0)
    state, pos = app.playback()
    if state != "playing":
        sys.exit(f"could not start playback (state={state})")
    print(f"playing at {pos:.1f}s; flapping {args.flaps}x in {args.mode} mode", flush=True)

    baseline, stops, failures, helper_errors = None, [], [], 0
    samples, breaches = [], {}
    for i in range(1, args.flaps + 1):
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
        # The oracle. A track ending naturally also reads stopped, so require
        # that the previous sample was NOT near the end of its track before
        # calling it a silent stop.
        if before_state == "playing" and state != "playing":
            dur = app.json("dump_state").get("player", {}).get("duration") or 0
            natural = dur and before_pos and (dur - before_pos) < 3.0
            if not natural:
                stops.append((i, before_pos, state))
                print(f"  flap {i}: *** SILENT STOP *** was playing at "
                      f"{before_pos:.1f}s, now {state}", flush=True)
            app.json("play_index", "0")
            time.sleep(1.5)

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
                    if b and v > b * GROWTH_FACTOR:
                        breaches[k] = breaches.get(k, 0) + 1
                        if breaches[k] == CONSECUTIVE_BREACHES:
                            failures.append(
                                (i, f"{k} over {GROWTH_FACTOR}x baseline for "
                                    f"{CONSECUTIVE_BREACHES} samples: {b} -> {v}"))
                    else:
                        breaches[k] = 0

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
    print(f"quiesce:        settled={q.get('settled')} pending={pending}")
    return 1 if (stops or failures) else 0


if __name__ == "__main__":
    sys.exit(main())
