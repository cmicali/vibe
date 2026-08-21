# Future: stress runs in a Tart VM, and `--silent` moved to the end of the graph

Written 2026-08-21, planned but not implemented. The file:line anchors below are against `main`
at that date and should be re-checked before acting.

Two changes, and they are deliberately one plan: moving the stress harness onto real audio
hardware is what makes a VM the right place to run it, and the VM is what makes always-on
hardware safe. Neither half should ship without at least acknowledging the other.

## Context

Today the stress harness launches off the hardware entirely: `launch.sh:100` and
`run-torture.sh:69` default to `--no-audio-hw --silent`, so a soak never opens an output
device, never drives the real render callback, and never exercises the HAL layer at all.
Worse, `--silent` is implemented as `_engine.mainMixerNode.outputVolume = 0`
(`AudioPlayer.m:298`), which sits **upstream** of everything interesting:

- The FX segment hangs off the main mixer (`AudioFX.m:191` — mainMixer → lowKillEQ →
  masterMix → output, with the reverb and delay sends parallel to that chain), so a zeroed
  mixer feeds the whole DJ FX graph silence. The reverb, the delays, and the low-kill sweep
  run their DSP against zeros — the code paths execute, but no real signal ever crosses them.
- The level tap taps whatever feeds the output — `_fx.masterBusOutputNode` (`_masterMix`,
  `AudioFX.m:187`) or `mainMixerNode` (`AudioPlayer.m` `applyLevelTapOnQueue`) — and both are
  at or downstream of the zeroed volume, so the equalizer reads flat zero under every default
  stress launch. This is the documented TRAP in `Vibe/Audio/Levels/CLAUDE.md:37`, and it means
  the stress oracles structurally cannot notice a broken analyzer.

So a multi-hour soak currently proves nothing about the FX DSP under real signal, the level
analyzer, the HAL device open/close path, or real render-callback timing. The manual pump is
also not a clock (`vibe-debug` skill: a 48 kHz MP3 sat at position 0.000 for 2.7 s under it),
so the torture suite's transport hammering runs against timing no user ever sees.

The desired end state: **stress and torture always run against a real output device with the
volume zeroed at the last possible point** — after the main mixer, after the FX returns, after
the level tap — so every node in the graph carries real signal and only the final hop to the
output device is muted.

Why that forces the VM question: `--no-audio-hw` is also what suppresses the Now Playing
publish, because registering as the active media app is enough for macOS to pull
auto-switching AirPods over (`launch.sh:12`). A hardware-silent stress run on the desktop
therefore grabs the media-app role and can steal the user's AirPods for hours. Inside a VM
the "hardware" is a virtual device and the media-app role belongs to the guest, so the
desktop is untouched — plus a snapshot-restored guest kills four documented harness traps by
construction (second instances, Simulator's Vibe matching `pgrep -x Vibe`, a concurrent ⌘B
swapping the binary, and `AppSettings` inheriting the last fuzzer's random final toggle).

## Part 1: `--silent` as an end-of-graph gate

### Design

Under `--silent`, attach a debug-only `AVAudioMixerNode` — the **silence gate** — as the last
node before `engine.outputNode`, with `outputVolume = 0`, and wire the master bus through it:

- no FX: `mainMixerNode → gate → outputNode` (today: `mainMixerNode → outputNode`,
  `AudioPlayer.m:317`)
- FX: `… → masterMix → gate → outputNode` (today: `masterMix → outputNode`, `AudioFX.m:279`)

The tap node selection in `applyLevelTapOnQueue` is untouched — it still taps `masterMix` or
`mainMixerNode`, both now **upstream** of the mute, so the analyzer sees the real signal. A
mixer node's tap reads post-`outputVolume` data, which is exactly why the current
implementation zeroes the tap and why the gate must be a separate node downstream of the tap,
not an `outputVolume` write on the tap node itself.

Implementation notes, in the order they will bite:

1. **Wire it in `installMasterBusOnQueue` (`AudioPlayer.m:311`)**, not in the init path. That
   method is the single wiring funnel for both configurations and is what the iOS
   media-services-reset rebuild re-runs — the comment at `AudioPlayer.m:248` already records
   that a `--silent` run must not turn audible after a reset, and a gate installed anywhere
   else would die with the old engine exactly the way an out-of-place level tap does.
2. **`AudioFX.installInEngine:` needs a terminal-node parameter** (or an
   `installInEngine:terminatingAt:` variant): its final connect at `AudioFX.m:279` hardcodes
   `engine.outputNode`. Under `--silent` the player hands it the gate instead; the default
   remains `outputNode`. Keep the format argument the mixer format it already uses — the
   output node still does the device-rate conversion on the last hop.
3. **The gate is debug-only state, so follow the `VibeManualRenderPump` pattern**
   (vocabulary rule 4): a small debug-only object the player holds, owning the node and its
   attach/zero logic, created under `#if DEBUG` in the `.m`. No `#if DEBUG` reaches a header.
4. **Volume writes before wiring are silently dropped** — the existing comment at
   `AudioPlayer.m:297` earned that knowledge. Zero the gate *after* it is attached and
   connected, every time `installMasterBusOnQueue` runs.
5. **Wet tails stay silenced** — the gate is downstream of the FX returns, same as the muted
   mixer was upstream of the sends. What changes is that the tails are now *computed* from
   real signal, so `held_fx` ops in the stress profiles finally exercise reverb and delay DSP
   with content in it.
6. `--no-audio-hw` is unchanged: manual rendering mode, no device, Now Playing suppressed.
   The two flags stay orthogonal, and `launch.sh`'s default for interactive debugging stays
   `--no-audio-hw --silent` — the AirPods rule is about desktop runs, and most `vibe-debug`
   use is on the desktop.

### Harness changes

- `stress.py`, `torture.py`, and `run-torture.sh` default to **`--silent` only** (real
  hardware, gate muted) instead of `--no-audio-hw --silent`. `VIBE_AUDIBLE=1` still means
  audible; add `VIBE_STRESS_NO_HW=1` as the explicit desktop escape hatch that restores the
  old off-hardware pair for anyone soaking beside their AirPods.
- With real signal at the tap, `dump_equalizer` becomes assertable under the default stress
  launch: add a cheap oracle — during confirmed playback, `audio.publications` must advance
  and at least one band must be nonzero within a settle. That is new coverage the old default
  could never have.
- The liveness oracle's `VERB_TIMEOUTS` may need a look: a real device open on every launch
  (and every shrink candidate's relaunch) is slower than manual-render init.

### Documentation that must move in the same commit

- `Vibe/Audio/Levels/CLAUDE.md:37` — the TRAP inverts: bands are live under `--silent`, flat
  only under `--silent` **plus** a pre-gate zero, i.e. never by default.
- `vibe-debug` SKILL.md — the "default launch cannot validate the live equalizer" paragraph,
  the `VIBE_AUDIBLE=silent` description, and the start-latency warning (unchanged for
  `--no-audio-hw`, but stress runs are no longer under it).
- `launch.sh` header comment, `stress.py` docstring, `run-torture.sh` comment.
- The `--silent` comment block in `AudioPlayer.m` itself.

### Verification

- Launch `--silent`, play a real file: `dump_state` reports `player.silent`, no audible
  output, `dump_equalizer` shows moving bands and advancing `analyzedWindows`. Toggle FX on
  and off; still silent, bands still move (tap node swaps with the wiring).
- `VIBE_AUDIBLE=silent` on hardware with AirPods nearby confirms the publish still happens
  (that is `--silent`'s documented behavior, unchanged).
- iOS: relaunch through `launch-ios.sh`, then background/foreground through a media-services
  reset if reachable — the gate must survive the rebuild muted.
- A short `make stress` and `make torture` run each, then one full `--profile cloud` and one
  `--profile artwork` soak at the new default before trusting the timeouts.

## Part 2: running the harness in a Tart VM

### Decisions

- **Tart** over UTM/Parallels: Virtualization.framework (near-native CPU), fully CLI-driven,
  `tart clone` gives instant copy-on-write snapshots, and the cirruslabs base images ship
  with Xcode, auto-login, and SSH enabled. Apple's EULA allows 2 macOS guests per host.
- **Build inside the guest.** A Debug build is signed to run locally; copying it into another
  machine's session invites exactly the provenance problems `run-torture.sh` exists to catch.
  The sanitizer matrix needs in-guest `xcodebuild` anyway.
- **Corpus lives on the guest's disk**, copied in at provisioning, not `--dir`-shared.
  Sandbox grants, `NSURL+Hash` mtimes, and the fake provider's dataless machinery over
  virtio-fs is triage territory nobody wants inside a failure report.
- **Audio in the guest**: the guest needs a real CoreAudio output device for the new
  hardware-silent default. Verify what the current Tart attaches (`system_profiler
  SPAudioDataType` in-guest); if the VM exposes no sound device, `brew install blackhole-2ch`
  and set it as default output — BlackHole is a real HAL device with no hardware behind it,
  which is precisely the shape wanted. Record which path was taken in the golden image notes.
- **TCC cannot be pre-seeded** (SIP stays on in VZ guests): grant Screen Recording and
  Accessibility to the terminal once over VNC, then snapshot. Most of the harness needs
  neither (in-process screenshots and channel verbs are permission-free); only
  `screencapture` real-pixel capture and `input.swift` do.

### The golden image

One-time, scripted as far as possible (`scripts/vm/provision.sh`, run in-guest over SSH):

1. `tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest vibe-golden` — pin the actual
   tag to the Xcode version `project.yml` needs; resize disk to ~100 GB
   (`tart set --disk-size`).
2. In-guest: `brew install xcodegen ffmpeg` (ffmpeg for `make-cloud-corpus.py`), BlackHole if
   needed per the audio decision, `caffeinate` configuration (disable sleep, screen saver,
   and Spotlight indexing of the build tree).
3. Copy the corpora over (`scp`): the real-music corpus, and pre-build the cloud and hostile
   corpora so per-run clones need no ffmpeg time.
4. One VNC session for the TCC grants and any first-run dialogs.
5. Never run the golden image again except to upgrade it; every run clones it.

### Per-run orchestration

New `scripts/vm/vm-stress.sh` (host side), and a `make stress-vm CORPUS=<guest-path>
ARGS=...` target that wraps it:

1. `tart clone vibe-golden vibe-run-$$` — ephemeral, deleted on exit (kept on failure).
2. `tart run --no-graphics vibe-run-$$ &`; auto-login gives the Aqua session the window
   server needs. `tart ip` + SSH-wait for readiness — no guessed sleeps, same discipline as
   `launch-ios.sh`.
3. Push the checkout: `git archive` of HEAD piped over SSH (not the working tree — the run's
   provenance is a commit, which fixes the "which binary was this" question by construction).
   Print the SHA in the run header.
4. In-guest: `make project && make build CONFIG=Debug`, then `make stress` / `make torture`
   with the caller's ARGS, output streamed back over the SSH channel so the host sees the
   seed line and per-batch progress live.
5. Pull artifacts to `build/vm-runs/<timestamp>-<seed>/` on the host: the NDJSON journal,
   any `stress-<seed>-failure/` directory, and the in-guest `~/Library/Logs/DiagnosticReports`
   delta. Then `tart delete` the clone — unless something failed, in which case keep it and
   print the `tart run` command to reopen it, because the live container (caches, defaults,
   TSan logs) is part of the evidence.
6. Sanitizer runs are the same flow with the build step swapped for the TSan/ASan invocation
   from the vibe-stress skill; `launchctl setenv TSAN_OPTIONS` being session-wide is finally
   harmless, since the session is disposable.

### What a VM run buys, and what it cannot cover

Buys: cold container and cold caches every run without trusting `clear_caches`; no second
instance, ever; no Simulator collision; no binary swap mid-campaign; hardware-silent as the
default with zero AirPods risk; parallel campaigns (two guests) without contesting one
channel.

Cannot cover, so a green VM soak must not be read as coverage of: real device switching and
`AudioDeviceManager` config-change behavior against actual hardware, output-latency and
start-latency numbers (virtio/BlackHole timing is not a MacBook's), Now Playing against real
AirPods and media keys, and anything `vibe-debug` already lists as needing `VIBE_AUDIBLE=1`
on the desktop. Those stay desktop tests, run deliberately and briefly.

## Rollout order

1. Part 1's engine change plus its doc moves, verified on the desktop with short runs
   (`VIBE_STRESS_NO_HW=1` remains the fallback if the new default misbehaves).
2. Harness defaults flip to hardware-silent.
3. Golden image and `vm-stress.sh`; first long soaks move to the VM.
4. Only then consider retiring the desktop soak workflow from the vibe-stress skill's
   examples, keeping the desktop-only coverage list.

## Open questions

- Does the pinned Tart version attach a virtio sound device by default, and does
  `AVAudioEngine` accept it as the default output — or is BlackHole required? (First
  in-guest check; the plan works either way.)
- Does the gate change the engine's render topology enough to shift any measured stress
  timing (`VERB_TIMEOUTS`, the ~110 ms probe)? Measure before and after on the same seed.
- Is one guest enough, or do stress and torture campaigns want the second EULA slot as a
  standing pair?
