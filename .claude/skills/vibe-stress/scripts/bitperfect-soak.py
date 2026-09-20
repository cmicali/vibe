#!/usr/bin/env python3
"""Does bit-perfect output SETTLE, track after track, and put the device back?

`make test-bit-perfect` already answers "are the samples unchanged" through a
BlackHole loopback. This answers a different question: across many track
changes, rate boundaries, mode toggles and device switches, does the mode reach
Active every time, drive the device to each file's own rate, hold exclusive
access when asked, and restore the device's format when it lets go.

WHY THIS IS NOT A TORTURE PHASE. torture.py exists to outrun everything async,
and it does — measured at 10-70 ops/s. A bit-perfect format switch needs about
a second to confirm, so under torture the switch never completes before the next
track change arrives: the mode sits in `switchFailed` for the whole run and,
because exclusive only acquires once bit-perfect confirms, hog is never taken at
all. A torture run with both settings enabled therefore tests NEITHER, and
reports "PASSED, no violations" while doing it. Measured, not theorised.

So this driver is settle-paced on purpose. It is slower than every other suite
here and that is the point: the thing under test is whether the mode settles,
and you cannot observe settling by refusing to let it settle.

REQUIRES a device the mode can drive (`VibeBitPerfectDeviceEligible`: built-in,
PCI, USB, FireWire, Thunderbolt, HDMI, DisplayPort, AVB, virtual — never
Bluetooth, AirPlay or System Output) and a corpus whose files differ in sample
rate, or the rate-follow assertion proves nothing.

TRAP: exclusive output takes hog mode, and taking the device that is the system
default MOVES the default elsewhere for as long as it is held. That is expected
and documented; the run releases it, but a SIGKILL mid-run leaves it taken.

    bitperfect-soak.py --corpus Assets/test_audio_files/rates --device 110
    bitperfect-soak.py --corpus <dir> --device 110 --no-exclusive --rounds 3
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
HELPER_SRC = HERE / "device-flap.swift"
DEFAULT_APP = REPO / "build/DerivedData/Build/Products/Debug/Vibe.app"

# How long to let a track settle before judging it. A rate change relocks the
# DAC; measured at ~1s on real interfaces, so this is deliberate headroom.
SETTLE_SECONDS = 5.0


def run(binary, *argv, timeout=60):
    try:
        p = subprocess.run([str(binary), "--debug-cmd", *argv],
                           capture_output=True, text=True, timeout=timeout)
        return json.loads(p.stdout)
    except Exception:
        return {}


def file_format(path):
    """(rate, depth) from afinfo — an INDEPENDENT source. Asserting the device
    rate against the app's own idea of the file's rate would be circular."""
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


def device_rate(helper, device):
    try:
        out = subprocess.run([str(helper), "rate", str(device), "0"],
                             capture_output=True, text=True, timeout=30).stdout
        return json.loads(out.strip().splitlines()[-1]).get("rate")
    except Exception:
        return None


def build_helper(out):
    if not out.exists() or out.stat().st_mtime <= HELPER_SRC.stat().st_mtime:
        r = subprocess.run(["swiftc", "-O", str(HELPER_SRC), "-o", str(out)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"could not build helper:\n{r.stderr}")
    return out


def device_rates(helper, device):
    """The rates the device can actually run at. Without this, a DAC that simply
    lacks a rate is indistinguishable from a failure to switch to it — the FiiO
    DAC-E10 has no 88.2 kHz, and reporting rateUnsupported there is CORRECT."""
    try:
        out = subprocess.run([str(helper), "rates", str(device), "0"],
                             capture_output=True, text=True, timeout=30).stdout
        d = json.loads(out.strip().splitlines()[-1])
        return {r["min"] for r in d.get("ranges", [])} if d.get("ok") else None
    except Exception:
        return None


def check_track(report, want_rate, want_exclusive, device, label, failures,
                supported=None):
    """Every assertion the settled report has to satisfy for one track."""
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
    # All three equal is the bit-perfect shape; any difference means the graph
    # resamples somewhere, which is the whole thing the mode exists to prevent.
    rates = {report.get("mixerOutputRate"), report.get("outputNodeInputRate"),
             report.get("outputNodeOutputRate")}
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
                         "e.g. '122:Audient iD4'. Repeatable. Switching devices "
                         "with the mode armed is where the documented traps are")
    ap.add_argument("--no-exclusive", action="store_true")
    ap.add_argument("--settle", type=float, default=SETTLE_SECONDS)
    args = ap.parse_args()

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

    launch = (REPO / ".claude/skills/vibe-debug/scripts/launch.sh").resolve()
    subprocess.run([str(launch), str(args.corpus)], capture_output=True, text=True,
                   env={**__import__("os").environ, "VIBE_AUDIBLE": "silent"})
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline and not run(binary, "dump_state").get("player"):
        time.sleep(0.5)

    failures, checked = [], 0

    # Arm the mode on the chosen device. Modes belong to the device UID, so the
    # device has to be selected BEFORE the toggles mean anything.
    run(binary, "settings_open", "audio"); time.sleep(0.6)
    ui = run(binary, "dump_settings_ui")
    rows = next((c.get("rows", []) for c in ui.get("controls", [])
                 if c.get("kind") == "table" and c.get("name") == "Output"), [])
    # TRAP: the Output list shows NAMES, not ids, so --device alone cannot pick
    # the row. Falling back to a guess silently armed the wrong device and then
    # reported every track as "hog is on 110, expected 999999" — the oracle
    # caught it, but the run had already wasted its time on the wrong device.
    # TRAP: the System Output row EMBEDS the current default device's name, so
    # "Fireface 802 (24240711)" matches "System Output (Fireface 802 (24240711))"
    # first. That row is the -1 policy and is never eligible, so the mode simply
    # refuses to arm and the run dies looking like a device problem. Exclude it,
    # and prefer an exact row match over a substring.
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
        """Select a device and arm the mode on it. Modes belong to the device
        UID, so the selection has to land BEFORE the toggles mean anything."""
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

    # Each entry is (device id, row index, supported rates). The primary is
    # first; --also-device adds the rest.
    targets = [(args.device, row, supported)]
    for spec in args.also_device:
        did, _, dname = spec.partition(":")
        if not dname:
            sys.exit(f"--also-device wants ID:NAME, got {spec!r}")
        cand = [(i, r) for i, r in enumerate(rows) if not r.startswith("System Output")]
        r_i = next((i for i, r in cand if r == dname), None)
        if r_i is None:
            r_i = next((i for i, r in cand if dname in r), None)
        if r_i is None:
            sys.exit(f"--also-device {spec!r}: no Output row matches {dname!r}")
        targets.append((int(did), r_i, device_rates(helper, int(did))))
    if len(targets) > 1:
        print(f"rotating across {len(targets)} devices between rounds: "
              f"{[t[0] for t in targets]}", flush=True)

    for rnd in range(1, args.rounds + 1):
        device, row_i, supported = targets[(rnd - 1) % len(targets)]
        if len(targets) > 1 and rnd > 1:
            # Switching devices with the mode armed: the switch must prepare and
            # hog the DESTINATION before committing, and must not strand the old
            # device's format. Re-arm because modes are per device UID.
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

        # A mid-run toggle must return to Active, not strand the mode.
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

    # Leave no trace: the mode is per device UID and would persist into the next
    # run, and a held hog would persist for every other app on the machine.
    run(binary, "set_bit_perfect", "off"); time.sleep(1.5)
    run(binary, "settings_click", "Output", "0"); time.sleep(2)
    run(binary, "settings_close")
    run(binary, "quit")
    time.sleep(2)

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
