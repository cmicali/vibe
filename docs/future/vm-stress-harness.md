# Future: running the stress harness in a Tart VM

Written 2026-08-21, revised 2026-08-22. Planned, not implemented. The file:line anchors are
against `main` at the revision date and should be re-checked before acting.

## Context

The stress and torture harnesses run in the developer's own login session, against the
developer's own `~/Library` container, on a binary that whatever is in `build/DerivedData` at
that moment. Four traps documented in the `vibe-stress` skill all trace to that:

- a second Vibe instance colliding with the one under test
- Simulator's Vibe matching `pgrep -x Vibe`
- a concurrent ⌘B swapping the binary mid-campaign
- `AppSettings` inheriting the last fuzzer run's random final toggle

A snapshot-restored guest kills all four by construction, and gives cold caches and a cold
container every run without trusting `clear_caches` to have covered everything.

**This is isolation work, not a safety prerequisite.** An earlier version of this plan argued
that stress could only move onto real audio hardware once a VM existed, because a hardware run
claims the media-app role and can pull the developer's auto-switching AirPods over. That
coupling turned out to be one line of argv parsing (`NowPlayingController.m:98`) rather than a
fact about hardware; `end-of-graph-silent.md` splits it apart and makes hardware-silent stress
safe on the desktop. The two documents are independent — build this one when the isolation is
worth the maintenance, not because something else is blocked on it.

The one real coupling runs the other way: **if `end-of-graph-silent.md` has landed, the guest
needs a working CoreAudio output device**, because hardware-silent is then the harness default
and a guest with no sound device fails at launch instead of testing anything. See the audio
decision below.

## Decisions

- **Tart** over UTM/Parallels: Virtualization.framework (near-native CPU), fully CLI-driven,
  `tart clone` gives instant copy-on-write snapshots, and the cirruslabs base images ship with
  Xcode, auto-login and SSH enabled. Apple's EULA allows 2 macOS guests per host.
- **Build inside the guest.** A Debug build is signed to run locally; copying it into another
  machine's session invites exactly the provenance problems `run-torture.sh` exists to catch.
  The sanitizer matrix needs in-guest `xcodebuild` anyway.
- **Corpus lives on the guest's disk**, copied in at provisioning, not `--dir`-shared. Sandbox
  grants, `NSURL+Hash` mtimes and the fake provider's dataless machinery over virtio-fs are
  triage territory nobody wants inside a failure report.
- **Audio in the guest.** Check what the pinned Tart attaches (`system_profiler SPAudioDataType`
  in-guest). If there is no output device, `brew install blackhole-2ch` and set it as default
  output — BlackHole is a real HAL device with no hardware behind it, precisely the shape
  wanted. Record which path was taken in the golden image notes. Under the pre-`end-of-graph-silent`
  default (`--no-audio-hw`) a device-less guest is harmless; after it, it is a hard failure.
- **TCC cannot be pre-seeded** (SIP stays on in VZ guests): grant Screen Recording and
  Accessibility to the terminal once over VNC, then snapshot. Most of the harness needs neither
  — in-process screenshots and channel verbs are permission-free; only `screencapture`
  real-pixel capture and `input.swift` are affected.

## The golden image

One-time, scripted as far as possible (`scripts/vm/provision.sh`, run in-guest over SSH):

1. `tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest vibe-golden` — pin the tag to the
   Xcode version `project.yml` needs; resize the disk to ~100 GB (`tart set --disk-size`).
2. In-guest: `brew install xcodegen ffmpeg` (ffmpeg for `make-cloud-corpus.py`), BlackHole if
   needed per the audio decision, and configure for unattended runs (disable sleep and the
   screen saver, exclude the build tree from Spotlight).
3. Copy the corpora over (`scp`): the real-music corpus, plus pre-built cloud and hostile
   corpora so per-run clones need no ffmpeg time.
4. One VNC session for the TCC grants and any first-run dialogs.
5. Never run the golden image again except to upgrade it; every run clones it.

## Per-run orchestration

New `scripts/vm/vm-stress.sh` (host side), and a `make stress-vm CORPUS=<guest-path> ARGS=...`
target that wraps it:

1. `tart clone vibe-golden vibe-run-$$` — ephemeral, deleted on exit, kept on failure.
2. `tart run --no-graphics vibe-run-$$ &`; auto-login gives the Aqua session the window server
   needs. `tart ip` plus an SSH-wait for readiness — no guessed sleeps, same discipline as
   `launch-ios.sh`.
3. Push the checkout over SSH and print the SHA in the run header. Prefer `git archive` of HEAD,
   but **allow a dirty tree**: the common moment to want a soak is with uncommitted work in
   hand, so push the working tree, mark the header `<sha>-dirty` and save the diff into the
   artifacts directory. Forcing a commit to run a soak is a tax nobody will pay.
4. In-guest: `make project && make build CONFIG=Debug`, then `make stress` / `make torture` with
   the caller's ARGS, output streamed back over the SSH channel so the host sees the seed line
   and per-batch progress live.
5. Pull artifacts to `build/vm-runs/<timestamp>-<seed>/` on the host: the NDJSON journal, any
   `stress-<seed>-failure/` directory, and the in-guest `~/Library/Logs/DiagnosticReports`
   delta. Then `tart delete` the clone — unless something failed, in which case keep it and
   print the `tart run` command to reopen it, because the live container (caches, defaults, TSan
   logs) is part of the evidence.
6. Sanitizer runs are the same flow with the build step swapped for the TSan/ASan invocation
   from the `vibe-stress` skill; `launchctl setenv TSAN_OPTIONS` being session-wide is finally
   harmless, since the session is disposable.

## What a VM run cannot cover

A green VM soak is not coverage of: real device switching and `AudioDeviceManager`
config-change behavior against actual hardware; output-latency and start-latency numbers
(virtio/BlackHole timing is not a MacBook's); Now Playing against real AirPods and media keys;
and anything `vibe-debug` lists as needing `VIBE_AUDIBLE=1` on the desktop. Those stay desktop
tests, run deliberately and briefly.

This list must land in the `vibe-stress` skill beside the `make stress-vm` documentation, or a
green VM campaign will eventually be read as coverage it never had.

## Verification

- Provision the golden image, clone it, and confirm the clone reaches SSH readiness without a
  guessed sleep.
- In-guest `system_profiler SPAudioDataType` reports an output device, and a `--silent` launch
  brings the engine up with `silenceGateActive` — the check that matters if
  `end-of-graph-silent.md` has landed.
- One short `make stress-vm` end to end: the run header prints the pushed SHA, progress streams
  live to the host, and artifacts land under `build/vm-runs/`.
- Force a failure (a bad seed, or a deliberately broken build) and confirm the clone is kept,
  the reopen command is printed, and the failure directory and DiagnosticReports delta both
  arrive on the host.
- Run two clones concurrently and confirm neither sees the other's channel or container.

## Open questions

- Does the pinned Tart version attach a virtio sound device that `AVAudioEngine` accepts as
  default output, or is BlackHole required? One in-guest command; the plan works either way.
- Is one guest enough, or do stress and torture campaigns want the second EULA slot as a
  standing pair?
- Does the maintenance cost of the golden image (Xcode upgrades, corpus refreshes, TCC
  re-grants after an OS bump) stay below what the isolation is worth? Worth revisiting after
  the first few campaigns rather than deciding up front.
