#!/usr/bin/env python3
"""Does bit-perfect output SETTLE, track after track, and put the device back?

`make test-bit-perfect` checks the samples are unchanged. This checks that
across track changes, rate boundaries, mode toggles and device switches the
mode reaches Active, drives the device to each file's rate, holds exclusive
access when asked, and restores the device's format when it lets go.

Settle-paced on purpose, not a torture phase: a format switch needs about a
second to confirm, and torture's 10-70 ops/s leaves the mode in `switchFailed`
and the hog never taken while still reporting PASSED.

REQUIRES a device the mode can drive (`VibeBitPerfectDeviceEligible`: never
Bluetooth, AirPlay or System Output) and a corpus of mixed sample rates, or the
rate-follow assertion proves nothing.

TRAP: exclusive output hogs the device, and hogging the system default MOVES
the default elsewhere while held. The run releases it; a SIGKILL leaves it.

    bitperfect-soak.py --corpus Assets/test_audio_files/rates --device 110
    bitperfect-soak.py --corpus <dir> --device 110 --no-exclusive --rounds 3
"""

import argparse
import atexit
import json
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
HELPER_SRC = HERE / "device-flap.swift"
DEFAULT_APP = REPO / "build/DerivedData/Build/Products/Debug/Vibe.app"

# A rate change relocks the DAC in ~1 s on real interfaces; this is headroom.
SETTLE_SECONDS = 5.0


def run(binary, *argv, timeout=60):
    try:
        p = subprocess.run([str(binary), "--debug-cmd", *argv],
                           capture_output=True, text=True, timeout=timeout)
        return json.loads(p.stdout)
    except Exception:
        return {}


def file_format(path):
    """(rate, depth) from afinfo: asserting the device against the app's own
    idea of the file's rate would be circular."""
    try:
        out = subprocess.run(["afinfo", str(path)], capture_output=True, text=True,
                             timeout=30).stdout
    except Exception:
        return None, None
    m = re.search(r"Data format:.*?([\d.]+) Hz.*?(\d+)-bit", out, re.S)
    if not m:
        m2 = re.search(r"([\d.]+) Hz", out)
        return (float(m2.group(1)) if m2 else None), None
    return float(m.group(1)), int(m.group(2))


def helper_json(helper, mode, device, *extra):
    """The helper's one-line JSON reply to `mode` on `device`, or {}."""
    try:
        out = subprocess.run([str(helper), mode, str(device), "0", *extra],
                             capture_output=True, text=True, timeout=30).stdout
        return json.loads(out.strip().splitlines()[-1])
    except Exception:
        return {}


def device_rate(helper, device):
    return helper_json(helper, "rate", device).get("rate")


def device_volume(helper, device, writes=None):
    """{element: scalar} for every settable output volume ("v" is the virtual
    main volume), after applying `writes` if given."""
    extra = [",".join(f"{e}:{v!r}" for e, v in writes.items())] if writes else []
    return helper_json(helper, "volume", device, *extra).get("elements", {})


def build_helper(out):
    if not out.exists() or out.stat().st_mtime <= HELPER_SRC.stat().st_mtime:
        r = subprocess.run(["swiftc", "-O", str(HELPER_SRC), "-o", str(out)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"could not build helper:\n{r.stderr}")
    return out


def device_rates(helper, device):
    """The rates the device offers, so a correct rateUnsupported (the FiiO
    DAC-E10 lacks 88.2 kHz) is told apart from a failed switch."""
    d = helper_json(helper, "rates", device)
    return {r["min"] for r in d.get("ranges", [])} if d.get("ok") else None


def check_track(report, want_rate, want_exclusive, device, label, failures,
                supported=None):
    def bad(why):
        failures.append(f"{label}: {why}")

    # A rate the hardware does not offer must be reported, not delivered.
    if (supported and want_rate
            and not any(abs(r - want_rate) < 1 for r in supported)):
        if report.get("status") != "rateUnsupported":
            bad(f"device has no {want_rate:.0f} Hz, so status should be "
                f"'rateUnsupported', not {report.get('status')!r}")
        return

    if report.get("status") != "active":
        bad(f"status is {report.get('status')!r}, expected 'active'")
        return
    if want_rate and abs((report.get("sampleRate") or 0) - want_rate) > 1:
        bad(f"device at {report.get('sampleRate')} Hz, file is {want_rate:.0f} Hz")
    # Bus and output unit at different rates means the graph resamples.
    rates = {report.get("busRate"), report.get("outputUnitRate")}
    if len(rates) != 1:
        bad(f"graph rates disagree: {sorted(r for r in rates if r is not None)}")
    if report.get("varispeedPresent"):
        bad("a varispeed is in the chain; bit-perfect must remove it")
    for flag in ("rateExact", "formatConfirmed", "channelsMatch", "depthOK"):
        if report.get(flag) is False:
            bad(f"{flag} is false")
    if want_exclusive:
        if not report.get("exclusive"):
            bad("exclusive requested but the report says it is not held")
        if report.get("hoggedDeviceId") != device:
            bad(f"hog is on {report.get('hoggedDeviceId')}, expected {device}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", required=True, type=Path,
                    help="folder of audio files; use one with MIXED sample rates")
    ap.add_argument("--device", type=int, required=True,
                    help="AudioDeviceID of an eligible output device. Changes on "
                         "every re-enumeration, so read it fresh")
    ap.add_argument("--app", type=Path, default=DEFAULT_APP)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--device-name", default=None,
                    help="text identifying the device's row in the Output list; "
                         "needed because that list shows names, not ids")
    ap.add_argument("--also-device", action="append", default=[], metavar="ID:NAME",
                    help="another eligible device to rotate onto between rounds, "
                         "e.g. '122:Audient iD4'; repeatable")
    ap.add_argument("--no-exclusive", action="store_true")
    ap.add_argument("--settle", type=float, default=SETTLE_SECONDS,
                    help=f"seconds per track before judging it (default {SETTLE_SECONDS:g})")
    args = ap.parse_args()
    also = []
    for spec in args.also_device:
        did, _, dname = spec.partition(":")
        if not did.isdigit() or not dname:
            sys.exit(f"--also-device wants ID:NAME, got {spec!r}")
        also.append((int(did), dname))

    helper = build_helper(HERE / "device-flap-helper")
    binary = args.app / "Contents/MacOS/Vibe"
    if not binary.exists():
        sys.exit(f"no Debug build at {binary}")

    files = sorted(p for p in args.corpus.iterdir()
                   if p.suffix.lower() in {".wav", ".flac", ".aiff", ".aif", ".m4a", ".mp3"})
    if not files:
        sys.exit(f"no playable files in {args.corpus}")
    formats = {p.name: file_format(p) for p in files}
    distinct = {r for r, _ in formats.values() if r}
    print(f"{len(files)} files, {len(distinct)} distinct sample rates: "
          f"{sorted(int(r) for r in distinct)}")
    if len(distinct) < 2:
        print("  WARNING: one rate only — the rate-follow assertion proves little", flush=True)

    rate_before = device_rate(helper, args.device)
    supported = device_rates(helper, args.device)
    print(f"device {args.device} nominal rate before: {rate_before}")
    print(f"device supports: {sorted(int(r) for r in supported) if supported else 'UNREADABLE'}")
    if supported:
        missing = sorted(int(r) for r in distinct if not any(abs(s - r) < 1 for s in supported))
        if missing:
            print(f"  note: corpus has rates this device lacks {missing} — those "
                  f"tracks must report rateUnsupported", flush=True)

    # TRAP: a DAC below unity volume makes every track truthfully report
    # volumeScaled (a FiiO at 0.877 failed 10/10). Hold every target at unity and
    # restore the exact levels on every exit path but SIGKILL.
    saved_volumes = {d: device_volume(helper, d) for d in [args.device, *(d for d, _ in also)]}
    saved_volumes = {d: v for d, v in saved_volumes.items() if v}

    def restore_volumes():
        for d, v in saved_volumes.items():
            device_volume(helper, d, v)
        saved_volumes.clear()
    atexit.register(restore_volumes)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    for d, v in saved_volumes.items():
        forced = device_volume(helper, d, {e: 1.0 for e in v})
        print(f"device {d} volume held at unity for the run (was {v}, now {forced})", flush=True)

    launch = (REPO / ".claude/skills/vibe-debug/scripts/launch.sh").resolve()
    subprocess.run([str(launch), str(args.corpus)], capture_output=True, text=True,
                   # TRAP: without VIBE_APP, launch.sh starts the default Debug build and
                   # --app reaches only the channel client: the soak tests the wrong app.
                   env={**__import__("os").environ, "VIBE_AUDIBLE": "silent",
                        "VIBE_APP": str(args.app.resolve())})
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline and not run(binary, "dump_state").get("player"):
        time.sleep(0.5)

    failures, checked = [], 0

    run(binary, "settings_open", "audio"); time.sleep(0.6)
    ui = run(binary, "dump_settings_ui")
    rows = next((c.get("rows", []) for c in ui.get("controls", [])
                 if c.get("kind") == "table" and c.get("name") == "Output"), [])
    # TRAP: the Output list shows NAMES, not ids, so --device cannot pick the
    # row; a guessed row arms the wrong device for the whole run. No match exits.
    # TRAP: the System Output row EMBEDS the default device's name, so a
    # substring match hits it first; that row never arms and the run dies
    # looking like a device fault. Exclude it and prefer an exact match.
    needle = args.device_name or str(args.device)
    concrete = [(i, r) for i, r in enumerate(rows) if not r.startswith("System Output")]
    row = next((i for i, r in concrete if r == needle), None)
    if row is None:
        row = next((i for i, r in concrete if needle in r), None)
    if row is None:
        sys.exit(f"no Output row matches {needle!r}. Rows are:\n"
                 + "\n".join(f"  {i}: {r}" for i, r in enumerate(rows))
                 + f"\n\nPass --device-name with text from the right row, and make "
                   f"sure --device {args.device} is that device's CURRENT id.")
    def arm_on(row_index):
        """Modes belong to the device UID, so select the row BEFORE the toggles."""
        run(binary, "settings_click", "Output", str(row_index)); time.sleep(3)
        run(binary, "set_bit_perfect", "on"); time.sleep(2)
        if not args.no_exclusive:
            run(binary, "settings_click", "Exclusive output", "on"); time.sleep(2.5)
        return run(binary, "dump_state").get("player", {}).get("bitPerfect", {})

    arm_on(row)
    armed = run(binary, "dump_state").get("player", {}).get("bitPerfect", {})
    print(f"armed: status={armed.get('status')} exclusive={armed.get('exclusive')} "
          f"hog={armed.get('hoggedDeviceId')}", flush=True)
    if armed.get("status") in (None, "off"):
        sys.exit("bit-perfect did not arm on this device — is it eligible?")

    # (device id, row index, supported rates), primary first.
    targets = [(args.device, row, supported)]
    for did, dname in also:
        cand = [(i, r) for i, r in enumerate(rows) if not r.startswith("System Output")]
        r_i = next((i for i, r in cand if r == dname), None)
        if r_i is None:
            r_i = next((i for i, r in cand if dname in r), None)
        if r_i is None:
            sys.exit(f"--also-device {did}:{dname}: no Output row matches {dname!r}")
        targets.append((did, r_i, device_rates(helper, did)))
    if len(targets) > 1:
        print(f"rotating across {len(targets)} devices between rounds: "
              f"{[t[0] for t in targets]}", flush=True)

    for rnd in range(1, args.rounds + 1):
        device, row_i, supported = targets[(rnd - 1) % len(targets)]
        if len(targets) > 1 and rnd > 1:
            # Modes are per device UID, so re-arm on the destination.
            armed_now = arm_on(row_i)
            if armed_now.get("status") in (None, "off"):
                failures.append(f"round {rnd}: mode did not arm on device {device}")
        print(f"\n--- round {rnd}/{args.rounds} (device {device}) ---", flush=True)
        for i, path in enumerate(files):
            run(binary, "play_index", str(i))
            time.sleep(args.settle)
            state = run(binary, "dump_state")
            report = state.get("player", {}).get("bitPerfect", {})
            title = state.get("ui", {}).get("title")
            want_rate, _ = formats[path.name]
            before = len(failures)
            check_track(report, want_rate, not args.no_exclusive, device,
                        f"round {rnd} dev{device} {path.name}", failures, supported)
            checked += 1
            mark = "ok " if len(failures) == before else "FAIL"
            print(f"  {mark} {title:<20} want {want_rate and int(want_rate)} Hz  "
                  f"got {report.get('sampleRate')} Hz  status={report.get('status')} "
                  f"excl={report.get('exclusive')}", flush=True)

        # A toggle must release the hog and return to Active or Idle.
        run(binary, "set_bit_perfect", "off"); time.sleep(2)
        off = run(binary, "dump_state").get("player", {}).get("bitPerfect", {})
        if off.get("status") != "off":
            failures.append(f"round {rnd} toggle: status {off.get('status')!r} after off")
        if off.get("hoggedDeviceId") not in (-1, None):
            failures.append(f"round {rnd} toggle: hog {off.get('hoggedDeviceId')} still held after off")
        run(binary, "set_bit_perfect", "on"); time.sleep(3)
        back = run(binary, "dump_state").get("player", {}).get("bitPerfect", {})
        if back.get("status") not in ("active", "idle"):
            failures.append(f"round {rnd} toggle: did not recover, status {back.get('status')!r}")
        print(f"  toggle off/on -> {off.get('status')} / {back.get('status')}", flush=True)

    viol = run(binary, "check_consistency").get("violations") or []
    if viol:
        failures.append(f"consistency: {viol}")
    q = run(binary, "quiesce", timeout=40)

    # The mode persists per device UID, and a held hog blocks every other app.
    run(binary, "set_bit_perfect", "off"); time.sleep(1.5)
    run(binary, "settings_click", "Output", "0"); time.sleep(2)
    run(binary, "settings_close")
    run(binary, "quit")
    time.sleep(2)

    restore_volumes()
    rate_after = device_rate(helper, args.device)
    restored = rate_before is not None and rate_after is not None and \
        abs(rate_before - rate_after) < 1
    if not restored:
        failures.append(f"device format NOT restored: {rate_before} -> {rate_after}")

    print("\n================ RESULTS ================")
    print(f"tracks checked : {checked}")
    print(f"device rate    : before {rate_before}  after {rate_after}  "
          f"{'restored' if restored else 'NOT RESTORED'}")
    print(f"quiesce        : settled={q.get('settled')} pending={q.get('pending')}")
    print(f"failures       : {len(failures)}")
    for f in failures:
        print(f"    {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
