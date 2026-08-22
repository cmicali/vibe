# Future: `--silent` as an end-of-graph gate, and stress on real hardware

Written 2026-08-21, revised 2026-08-22 (twice; the second revision is an adversarial pass with
every anchor re-checked against `main`). Planned, not implemented. The file:line anchors are
against `main` at the revision date and should be re-checked before acting.

Two parts. Part 1 is the engine change and stands alone — it fixes interactive equalizer
validation by itself, with no harness change, and the anchors and reasoning behind it survived
the adversarial pass intact. Part 2 moves the stress harness onto real audio hardware, depends
on Part 1, and rests on two claims that are **not yet established**: that a hardware-silent run
cannot steal the user's AirPods, and that seeded reproducibility survives real playback time.
Part 2's rollout is written around measuring both before committing.

A separate document, `vm-stress-harness.md`, covers running the harness in a VM. The first
revision of this plan treated that VM as a prerequisite for Part 2 and the second dropped it.
The VM is not dead: it comes back if the AirPods measurement below goes the wrong way and
device pinning does not fix it.

## Context

The stress harness launches off the audio hardware entirely. `launch.sh:100` and
`run-torture.sh:69` default to `--no-audio-hw --silent`, and `stress.py` shells out to
`launch.sh` (`stress.py:59`), so a soak never opens an output device, never drives a real
render callback, and never exercises the HAL layer. Worse, `--silent` is implemented as
`_engine.mainMixerNode.outputVolume = 0` (`AudioPlayer.m:299`), which sits **upstream** of
everything worth testing:

- The FX segment hangs off the main mixer (`AudioFX.m:191` — mainMixer → lowKillEQ →
  masterMix → output, with the reverb and delay sends parallel to that chain), so a zeroed
  mixer feeds the whole DJ FX graph silence. The reverb, the delays and the low-kill sweep run
  their DSP against zeros: the code paths execute, but no real signal ever crosses them.
- The level tap taps whatever feeds the output — `_fx.masterBusOutputNode` (`_masterMix`,
  `AudioFX.m:187`) or `mainMixerNode` (`applyLevelTapOnQueue`, `AudioPlayer.m:331`) — and both
  are at or downstream of the zeroed volume, so the equalizer reads flat zero under every
  default launch, interactive as well as stress. This is the documented TRAP at
  `Vibe/Audio/Levels/CLAUDE.md:37`, and it means neither the stress oracles nor an interactive
  debug session can notice a broken analyzer.

So a multi-hour soak proves nothing about the FX DSP under real signal, the level analyzer, the
HAL device open/close path, or real render-callback timing. The manual pump is also not a clock
(`vibe-debug` SKILL.md:31: a 48 kHz MP3 sat at position 0.000 for 2.7 s under it, against ~40 ms
on a real device), so the torture suite's transport hammering runs against timing no user ever
sees.

**Why hardware looks unsafe, and what is actually unproven.** `--no-audio-hw` also suppresses
the Now Playing publish, because registering as the active media app is enough for macOS to
pull auto-switching AirPods over (`launch.sh:12`, `NowPlayingController.h:12`). That coupling is
what made a hardware soak look like it needed a VM.

The suppression itself is one line — `NowPlayingController.m:98` reads `--no-audio-hw` from
argv — and what it protects is *this run must not present itself to the system as playing
music*. Splitting that property away from the device (Part 2) is right regardless.

But the previous revision then concluded that a run muted at the gate is therefore safe on the
desktop, and that conclusion rests on an untested premise: **that the media-app role is the
only thing that pulls AirPods.** macOS auto-switch also responds to audio playback activity —
an open, running HAL client with a live render callback — and the HAL does not care that the
samples are zeros. If that is how it behaves, a hardware-silent soak takes the user's AirPods
for hours even with the publish suppressed. This is a five-minute experiment (see Part 2) and
it gates the default flip.

The desired end state: **stress and torture can run against a real output device with the
volume zeroed at the last possible point** — after the main mixer, after the FX returns, after
the level tap — so every node in the graph carries real signal and only the final hop to the
output device is muted; and **no stress run claims the media-app role**, wherever it runs.
Whether hardware becomes the *default* or stays an explicit opt-in is decided by measurement,
not by this document.

## Part 1: the silence gate

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

The gate is a graph-fidelity delta and should be written down as one: a `--silent` run tests a
graph one node longer than production. That is the price of the whole approach; it is small,
and note 8 is where it can bite.

### Task 0: establish that the failsafe is a real check

**Do this before writing any of the rest.** Note 5 below refuses to run unless the gate reads
`outputVolume == 0`, and after Part 2 that check is the only thing between a soak and the
speakers. But this codebase's own hard-won comments (`AudioFX.m:281`, `AudioPlayer.m:295`)
record that a mixer volume written before the node is attached and wired is *silently dropped*.
If `AVAudioMixerNode`'s getter returns the ObjC-side cached value rather than the AU parameter,
then a readback of 0 proves nothing about a write that never landed, and the failsafe is
decorative.

So: write 0 to a detached mixer, read it back, then attach, wire and read again. If the getter
lies, the failsafe needs a different mechanism — a tap on the gate asserting silence over a
window, or a `renderOffline` probe — before Part 2 may proceed.

### Implementation notes, in the order they will bite

1. **Wire it in `installMasterBusOnQueue` (`AudioPlayer.m:311`)**, because that method is the
   single wiring funnel for both configurations and the gate is wiring — a connect, not a
   volume write. Note that survival across the iOS media-services rebuild is *not* the reason:
   that rebuild calls `createEngineAndMasterBusOnQueue` (`Vibe/Audio/iOS/AudioPlayer+Recovery.m:118`
   — the category is iOS-only, which makes the point narrower than the previous revision
   implied), which already re-runs the `--silent` write at `AudioPlayer.m:299`, so today's mute
   survives a reset fine. The reason is that both the FX and no-FX branches must terminate at
   the gate, and only `installMasterBusOnQueue` sees both. Put the zero there too, so wiring and
   mute cannot drift apart.
2. **`AudioFX.installInEngine:` needs a terminal-node parameter** (or an
   `installInEngine:terminatingAt:` variant): its final connect at `AudioFX.m:279` hardcodes
   `engine.outputNode`. Under `--silent` the player hands it the gate instead; the default
   remains `outputNode`. A plain nullable node parameter, so no `#if DEBUG` reaches the header.
   `AudioFX.h:56`'s comment on `masterBusOutputNode` ("what installInEngine: connects to the
   engine's outputNode") describes the old wiring and must be updated with it; the level tap
   depends on that property.
3. **The gate is debug-only state, so follow the `VibeManualRenderPump` pattern**
   (vocabulary rule 4): a small debug-only object the player holds, owning the node and its
   attach/connect/zero logic, created under `#if DEBUG` in the `.m`. No `#if DEBUG` reaches a
   header.
4. **Volume writes before wiring are silently dropped** — the existing comment at
   `AudioPlayer.m:295` earned that knowledge. Zero the gate *after* it is attached and
   connected, every time `installMasterBusOnQueue` runs.
5. **Verify the mute, and refuse to run without it — hard, with no fallback.** Today a
   `--silent` that fails to take effect is still inaudible, because the default pairs it with
   `--no-audio-hw`. After Part 2 a silent failure becomes an audible one. After wiring, assert
   the gate is attached, connected to `outputNode`, and reads zero; on failure log an error and
   **refuse to start the engine**. The previous revision offered "or fall back to manual
   rendering" as an alternative — it is not one. A soak that silently downgrades to the pump
   reports hardware coverage it did not have, which is the worst failure mode for a tool whose
   only product is confidence. Fail loudly.
6. **Assert on the engine-start edge, not only the wiring edge.** `installMasterBusOnQueue` is
   not the only path that reaches a running engine with an open device.
   `configureOutputDeviceOnQueue` (`AudioPlayer+Devices.m:158`) stops the engine, detaches the
   player node, rebinds the HAL device and restarts through `startEngineAndPlayNode:` **without**
   re-running the wiring funnel; and `AudioPlayer+Devices.m:424` calls `setOutputUnitDevice:`
   on a *live* output unit with no stop/start at all. The master bus is untouched by both, so a
   graph-node gate survives them — but that has to be reasoned out rather than read off, and a
   future path need not be so kind. Putting the check on every engine start covers all of them
   by construction, and costs a property read.
7. **Report the gate as observed, not as requested.** `dump_state` already distinguishes
   `noAudioHw` (argv, `DebugCommonVerbs.m:143`) from `manualRendering` (what actually happened,
   `AudioPlayer+Debug.h:17`), and `vibe-debug` SKILL.md:27 tells readers to trust the latter.
   `--silent` needs the same pair: the argv flag, and a `silenceGateActive` the harness can
   assert before it plays anything at volume.
8. **Wet tails stay silenced** — the gate is downstream of the FX returns, same as the muted
   mixer was upstream of the sends. What changes is that the tails are now *computed* from real
   signal, so `held_fx` ops in the stress profiles finally exercise reverb and delay DSP with
   content in them.
9. **A mixer converts.** An `AVAudioMixerNode` downmixes to stereo and converts format by
   default, so the gate — not the output node — could silently start deciding the shape of the
   audio on the last hop. Keep it format-transparent: connect `masterMix → gate` and
   `gate → outputNode` **both** at the same `mixerFormat` used today, so the output node keeps
   doing the device-rate conversion exactly as it does now and the gate adds no conversion.
   Invisible on a normal stereo device; check `dump_state` once against a multichannel or
   unusual-rate device.
10. `--no-audio-hw` is unchanged: manual rendering mode, no device. The flags stay orthogonal.

### The alternative that avoids the node, and why it probably loses

The AUHAL output unit exposes `kHALOutputParam_Volume` (public, `AudioUnitParameters.h`), and
`_engine.outputNode.audioUnit` is already reached for device selection
(`AudioPlayer+Devices.m:120`). Setting it to zero would mute at the true last hop with **no
graph change at all**: no extra node, no format question (note 9 evaporates), no `AudioFX`
signature change, no debug-only object, no fidelity delta, and a readback through
`AudioUnitGetParameter` that sidesteps task 0 entirely.

It is worth an hour before committing to the node, but it likely loses on one specific hazard:
binding `kAudioOutputUnitProperty_CurrentDevice` reinitializes the unit and may reset its
parameters, and `AudioPlayer+Devices.m:424` does exactly that on a live unit with **no engine
start edge to re-assert on**. A gate that can be cleared by a device switch mid-soak, with no
hook to notice, is worse than an extra mixer node. The node is structural; the parameter is
state that something else owns. It is also macOS-only — RemoteIO does not expose the parameter
— so iOS would keep the mixer zero and the two platforms would diverge.

Measure it, then choose. Default to the node.

## What Part 1 buys on its own

The interactive default (`launch.sh:100`, `--no-audio-hw --silent`) starts validating the
equalizer with no further change. `Vibe/Audio/Levels/CLAUDE.md:37` already states that
`--no-audio-hw` alone "still manually renders through the tap and is suitable for functional
bar/counter checks" — so the pump does drive real signal through the tap, and only the mixer
zero under it flattens the result. Move the mute downstream and the default debug launch shows
live bands.

That deletes, rather than amends, `vibe-debug` SKILL.md:29 ("The default launch cannot validate
the live equalizer") and the `--silent` half of `Levels/CLAUDE.md:37`. It is the largest single
win here and it needs nothing else in this document.

## Part 2: decouple Now Playing, then decide about hardware

### The third flag

Split the media-app role away from the device:

- `--no-audio-hw` — no output device opened at all; manual rendering, keeps the pump under test
- `--silent` — device opened and driven, real signal through every node, muted on the last hop
- `--no-now-playing` — do not publish to `MPNowPlayingInfoCenter`, do not register remote
  commands

`NowPlayingController.m:98` changes from reading `--no-audio-hw` to reading either flag, so
existing `--no-audio-hw` launches keep behaving exactly as documented and nothing that depends
on today's suppression moves.

A third flag rather than folding suppression into `--silent`: `VIBE_AUDIBLE=silent` is a
documented way to test Now Playing against real hardware (`launch.sh:14`, `vibe-debug`
SKILL.md:35), and quietly changing it would break a workflow already in use.

This step is unconditionally worth landing, and it does not depend on either measurement below.

### Measurement A: does a silent HAL client still steal the AirPods?

The whole desktop-hardware story depends on this. With auto-switching AirPods nearby and
awake, launch `--silent --no-now-playing`, play a real file for a minute, and watch whether the
system output device moves.

- **If it stays put**, desktop hardware-silent stress is safe and the VM stays optional.
- **If it switches**, the media-app role was not the only coupling. The mitigation is to stop
  following the system default: add `--audio-device <uid>` so a run pins a chosen device.
  `setOutputUnitDevice:` (`AudioPlayer+Devices.m:132`) already exists, so the flag is small,
  and pinning exercises the HAL open path *more* than following the default does — which was
  one of Part 2's goals to begin with. Re-run the measurement pinned. If it still switches,
  `vm-stress-harness.md` is back on the table for hardware soaks.

### Measurement B: what real playback time does to a seeded run

`stress.py:18` promises "Every run is reproducible: the seed is printed at the start", and
`--shrink` delta-debugs a failing journal by replaying it. That property is currently held up
by an accident: **under the pump, playback time is effectively frozen.** Position takes 2.7 s
to move at all, so a three-minute track never ends during a soak and op order alone determines
state.

On real hardware a `settle` of 0.05–0.8 s (`stress.py:694`, `stress.py:698`) advances that much
real audio. Track ends, auto-advance, gapless splices and prefetch arming start firing on
wall-clock rather than on op index. Same seed, different trajectory.

That is simultaneously the best and the worst thing about the flip. Best: end-of-track and
gapless paths finally get hammered by the soak instead of only by targeted tests. Worst: a
seeded run stops being a replayable run, and the shrinker gets flaky exactly when it is needed.
`check_consistency` itself should tolerate it — it is an in-app comparison of rendered labels
against the state that produced them, re-sampled after a settle (`stress.py:932`) — so the
exposure is to reproducibility, not to false failures.

Measure it: run the same seed and corpus three times under `--silent`, diff the resulting
journals and the at-rest counters, and shrink one deliberately-injected failure under both flag
sets. The answer decides the rollout's step 4.

### Timing: retune the settles, not `VERB_TIMEOUTS`

The previous revision made `VERB_TIMEOUTS` (`stress.py:70`) the measurement gating the flip.
That was the wrong table. It holds three entries — `file_cache` 90, `convert_to_flac` 150,
`quiesce` 40 — all file- and CPU-bound work that the render clock never touches, plus a 30 s
default; and `STALL_PROBE_MS` (`stress.py:75`) is a main-thread stall detector, equally
unaffected by whether a device is open. None of them were tuned against pump timing in any way
that hardware invalidates.

What *was* tuned against frozen playback time is the `settle` distribution and every profile's
`settle` weight (`stress.py:811` onward) — the cloud profile's "heavy settle, so a sweep gets
seconds to work through a folder" reasoning in particular assumes those seconds cost no
playback progress. Those are the numbers to re-derive. A real device open on every launch, and
on every shrink candidate's relaunch, is also slower than manual-render init, which pushes the
other way on total run time but not on any single verb.

### Harness changes

- `launch.sh` grows `VIBE_NO_NOW_PLAYING=1`, which appends `--no-now-playing` to the argv it
  builds. Its own default is unchanged — interactive debugging stays `--no-audio-hw --silent`,
  which after Part 1 already validates the equalizer.
- `stress.py` and `run-torture.sh:69` gain `VIBE_STRESS_HW=1`, which selects
  `VIBE_AUDIBLE=silent` plus `VIBE_NO_NOW_PLAYING=1` in the child environment. **Opt-in first.**
  Whether it becomes the default is step 4, decided by measurements A and B — the previous
  revision wrote the flip in as the endpoint before the evidence for it existed.
- `VIBE_AUDIBLE=1` still means audible.
- **If hardware ever does become the default, keep one profile explicitly on `--no-audio-hw`.**
  `VibeManualRenderPump` and the manual-rendering rebuild path are exercised today almost
  entirely by the stress default; move every profile onto hardware and nothing hammers them
  regularly.

### The equalizer oracle

With real signal at the tap, `dump_equalizer` (`DebugCommonVerbs.m:350`) becomes assertable
under a hardware-silent launch — but not unconditionally. The tap only exists when
`_levelsWanted` is nonzero (`AudioPlayer.m:331`), and that demand is published by visible
playing rows per the equalizer guarantee in the root `CLAUDE.md`. A run whose window is
occluded, or which has no playing row on screen, publishes nothing and is correct to.

So: read `requested` from the dump (`AudioPlayer.m:1272`); skip the assertion when it is zero,
and when it is nonzero require that `audio.publications` advances and at least one band reads
nonzero within a window of several settles — not a single one, since a genuinely quiet passage
is legal. That is new coverage the old default could never have had, and it is available to the
opt-in profile immediately; it does not wait on the default flip.

## Rollout order

1. **Task 0** — establish that the gate's readback is a real check. Everything after depends on
   it.
2. **Part 1**, plus its doc moves, verified on the desktop with short runs. Harness defaults
   untouched. This alone fixes interactive equalizer validation and is the bulk of the value in
   this document.
3. **Part 2's flag split**, with `--no-now-playing` landing and `NowPlayingController.m:98`
   reading either flag, plus `VIBE_STRESS_HW=1` as an **opt-in**. Then measurements A and B,
   and the equalizer oracle under the opt-in profile.
4. **Only then, decide the default.** Hardware-silent by default with one pump profile retained
   is one outcome; keeping the deterministic pump default and running hardware as a separate
   scheduled profile is an equally legitimate one, and measurement B may well choose it. Do not
   treat step 4 as a foregone conclusion — the coverage argument for hardware and the
   reproducibility argument for the pump are both real, and "both, deliberately" may be the
   right end state.

Steps 3 and 4 must not be reordered: putting stress on hardware before the flag split exists
means every desktop soak claims the media-app role and can hold the user's AirPods for hours.

## Documentation that must move with the code

- `Vibe/Audio/Levels/CLAUDE.md:37` — the TRAP inverts. Bands are live under `--silent`; flat
  only under a pre-gate zero, i.e. never by default.
- **The equalizer guarantee in the root `CLAUDE.md`** — not conditional, as the previous
  revision had it. The guarantee says the tap sits at "whichever node feeds the output", and
  with a gate the node that feeds the output *is the gate*. The phrasing has to become the last
  node carrying unmuted signal.
- `vibe-debug` SKILL.md — delete the "default launch cannot validate the live equalizer"
  paragraph (:29); update the flag description (:27) for the third flag and for
  `silenceGateActive`; the start-latency warning (:31) is unchanged for `--no-audio-hw`; the
  Now Playing paragraph (:35) and the `dump_now_playing` line (:190) must name
  `--no-now-playing`; the manual-launch examples (:39) and `launch-ios.sh`'s description (:80).
- `vibe-stress` SKILL.md — the default-launch description, `VIBE_STRESS_HW`, and the sanitizer
  example (:186).
- `launch.sh` header comment (:8–14), `stress.py` docstring (:28–30), `run-torture.sh`
  comment (:61), `launch-ios.sh:11–13`.
- The `--silent` comment block in `AudioPlayer.m` (:291–301), `AudioFX.h:48–56`, and
  `NowPlayingController.h:12` / `.m:91`.
- `Vibe/Audio/CLAUDE.md:84`.

## Verification

- Task 0's readback experiment, before anything else.
- Launch `--silent` alone and play a real file: `dump_state` reports `player.silent` and
  `silenceGateActive`, nothing is audible, and `dump_equalizer` shows moving bands with
  advancing `analyzedWindows`. Toggle FX on and off; still silent, bands still move as the tap
  node swaps with the wiring.
- Launch the interactive default (`--no-audio-hw --silent`) and confirm the same live bands —
  this is the Part 1 win, and it must hold under manual rendering.
- Force the gate to fail (temporarily skip the connect) and confirm the app refuses to start
  the engine rather than playing audibly. Then force it to fail the *other* way — skip the
  volume write, keep the connect — and confirm the check still catches it. If task 0 found the
  getter lies, this second case is the one that fails.
- Switch output devices mid-playback under `--silent`, through both paths: a genuine device
  change (`configureOutputDeviceOnQueue`) and a pin of the already-active device
  (`AudioPlayer+Devices.m:424`). Still silent through both.
- `VIBE_AUDIBLE=silent` on hardware with AirPods nearby: the publish still happens, unchanged.
  Then `VIBE_NO_NOW_PLAYING=1` on the same setup: `dump_now_playing` reports `hasInfo: 0` — and
  measurement A, which is whether the AirPods stay put.
- iOS: relaunch through `launch-ios.sh`, then force a media-services reset if reachable — the
  gate must come back muted with the rebuilt engine.
- Check `dump_state` once against a multichannel or non-48 kHz output device for note 9.
- A short `make stress` and `make torture` under `VIBE_STRESS_HW=1`, then one full
  `--profile cloud` and one `--profile artwork` soak before trusting any retuned settle weights.

## Open questions

- **Measurement A.** Does a muted-at-the-gate HAL client pull auto-switching AirPods on its
  own? If yes, does `--audio-device` pinning fix it, or does the VM come back?
- **Measurement B.** How much of the harness's seeded reproducibility survives real playback
  time, and does the shrinker still converge? This is what decides step 4, and it is a question
  the previous revision did not ask.
- Which `settle` weights are wrong once playback time actually passes during them, and by how
  much? `VERB_TIMEOUTS` is very likely untouched by the move; confirm that rather than assuming
  it, but do not spend the retune budget there.
- If a pump profile is retained, should it be an existing one or a dedicated `--profile pump`?
  Whichever keeps `VibeManualRenderPump` and the iOS rebuild path under regular test.
