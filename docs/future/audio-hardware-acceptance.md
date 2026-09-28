# Audio pipeline: hardware acceptance

**Status: the pipeline work is done; what remains is evidence only real hardware gives (verified 2026-09-28).** The output-unit split, owned-file migration, waveform consolidation, conversion-policy naming, metering cleanup, and explicit decoder-error handling are implemented. Their contracts live in [Audio/AGENTS.md](../../Vibe/Audio/AGENTS.md), [Devices/AGENTS.md](../../Vibe/Audio/Mac/Devices/AGENTS.md), and [iOS/AGENTS.md](../../Vibe/Audio/iOS/AGENTS.md).

## Resolved: Apple SRC tail length

Apple's converter, told the end of its stream, gives up only part of its filter's tail at high up-conversion ratios, so the bus never tells it: the flushing fill supplies silence and stops at the frames fed (the `TRAP:` in `VibeConverterSupplyInput`, `AudioVoiceBus.m`). The one reason to revisit the resampler: r8brain-free-src matched Apple's quality and cost 4–8× less CPU than Apple at High, the quality iOS runs at by default for cost.

## Remaining acceptance evidence

Live checks have covered macOS silent HAL transport, a 240-operation torture run (seed 660925), iOS simulator transport, owned-file waveform/analysis and WAV→FLAC conversion, and the Advanced Bluetooth eligibility override. The [device lifecycle](#device-lifecycle-acceptance) pass covered the macOS rebind path, the stale-device and rebuild symptoms, and exclusive ownership on three DACs. The [hardware layer](#device-lifecycle-acceptance) of #50 and #53 has since run on a real USB DAC. They do not establish:

- **Two physical iOS route cases.** A route change that keeps playing *and* has iOS stop the unit, the path where `recoverOutput` restarts it (wired headphones are the likely trigger; Control Center to AirPods does not stop it), and a rate follow mid-playback on a route change. The rest of the iOS pass has run, on an iPhone 17 Pro (iOS 27), 2026-09-26 and 2026-09-27, playing from a CloudStorage provider folder:
  - **Session release.** A pause releases the session 6 s later, 7–10 ms after RemoteIO's stop has landed; under a released delay, at the end of its declared tail (18 s); in the background too; and at once for a parked open.
  - **Interruptions.** A timer, a declined call and an answered call stop the unit, hold the release and resume on `ShouldResume`, the unit restarting in ~90–100 ms. Another app taking the audio ends without `ShouldResume` and releases the session at that edge. Siri ducks and interrupts nothing.
  - **Media-services reset** (Settings > Developer). iOS stops the unit seconds before it delivers the notification (6.5 s and 3.8 s measured), with no interruption; the player pauses a second after the stop, and the reset re-makes the unit and re-parks the track.
  - **Routes.** AirPods connected while playing: recover, the unit kept running. AirPods into their case: pause, an interruption Began (route-disconnected) that no Ended follows, and **iOS stops RemoteIO itself about 0.75 s after the route change**. AirPlay by a category change, with the rate follow at play start (48 → 44.1 kHz) and at resume.
  - **Lock screen and background.** A minute of playback past lock, commanded from the card; a cold launch beside Music leaves Music playing.
  - **The render clock stalls while iOS moves the hardware**: ~0.7 s after an interruption's resume and 0.2–1.8 s on a route move, the IO thread waiting inside the system. Nothing in the app's render is in the stack.
- **The in-rebind player-queue holds** of the physical power-cycle; one source of its holds is fixed (below).

Integer-format DAC negotiation, ASan/UBSan, TSan, the owned-file migration's all-configuration binary audit, a macOS profile, and the long and seeded HAL campaigns have run: [overnight acceptance](#overnight-acceptance). The one iOS performance pass is Instruments on device against Release builds (#74), which lowered the iOS resampling quality to High by default and fixed the main-thread costs it found.

Use the [test instructions](../../Tests/AGENTS.md), the [hardware acceptance workflow](../../.claude/skills/vibe-debug/references/test-audio.md), and the [debug skill](../../.claude/skills/vibe-debug/SKILL.md). Keep hardware results distinct from the manual pump and the simulator.

## Device lifecycle acceptance

Issues #50, #53, #56, and #57 were closed because the mechanism each described no longer exists; their *symptoms* are what the output unit must show absent. On 2026-09-25 (Mac Studio, macOS 27, Debug `ed0361dd`, real HAL, silent, Now Playing suppressed; Fireface 802, Audient iD4, FiiO E10, BlackHole 2ch) the software layer passed everywhere, #53 after its fix:

- **#50, software layer:** 750 `device-flap.py` vanish flaps over three DACs and 1,800 move flaps across six device pairs, with no silent stop, dropout, refusal, consistency violation, or pending counter; the at-rest heap matched a no-flap control.
- **#53:** a play submitted during a bind waited it out (median 127 ms, max 270 ms across 104 plays) while the rebind ran on the player queue. The output unit now waits on the HAL, and reads the device's latencies, on its own queue (`Mac/Devices/AGENTS.md`); rerun, every play submitted during a bind was admitted within 3.4 ms (109 plays, median 0.1 ms), and the rest of this pass passed again on the fix.
- **#56:** 40 BlackHole `--ordinary` loopback captures, each spanning 8–9 system-default changes between two other DACs, all PCM-exact, with no rebind and continuous render cycles.
- **#57:** all three cases against the app's own HAL reads, including 20 vanish/return cycles of an explicitly bound device (a fixed-UID aggregate) while playing and paused: `pendingDeviceUID` carried the lost UID, and the return re-bound under a new id, at once when paused and at the next pause when playing, by `VibeCanBindSavedOutputDevice`'s design.
- **Exclusive + bit-perfect:** `bitperfect-soak.py --rounds 2` on each DAC; every rate Active or correctly `rateUnsupported`, hogs released, formats restored.

A vanished device does not park playback. AUHAL moves a unit whose device vanishes to the system default and keeps pulling, and the device-list observer's rebind to System Output restores the track as it was, Playing included; only no output device at all, or another app's hog, parks it (`Mac/Devices/AGENTS.md`). That is why the vanished aggregate kept playing on System Output in every playing cycle.

**#50 and #53, hardware layer** (2026-09-28, MacBook Pro, macOS 27, Debug `4c8660d0`, real HAL, silent, Now Playing suppressed, AirPods disconnected). An Audient iD4, bus-powered so an unplug is its power cycle, was unplugged and replugged fifteen times while playing, once on System Output and once explicitly bound to it, with the log streamed and `dump_state` polled every 0.5 s:

- **System Output, 15/15.** Every unplug fell back to the built-in speakers still Playing and every replug followed the default back to the iD4 under a new id; 30 rebinds, 28 of them at 2–43 ms on the player queue, each re-voiced from its frame with its Timeline start and live lines. No error, no `stopped`, no position stall, no output dropout. Each move stalled the render clock 200–520 ms while the HAL moved the hardware.
- **Bound, 15/15.** Every unplug kept the iD4 as the wanted device (`pendingDeviceUID`) and fell back Playing; every replug logged the device present and waited, by `VibeCanBindSavedOutputDevice`'s design, for the next pause, which a helper issued with a play 150 ms after it. All fifteen adopted the iD4 and resumed on it. Fourteen resumes were admitted in 0 ms and played on the iD4 within 0.15–0.19 s.
- **A slow HAL bind can still hold the player queue about as long.** The bind runs on the output unit's queue, yet of the seven unit binds over 150 ms, three held the player queue's rebind for about their length: 0.39 s and 0.38 s on System Output beside 404 and 447 ms, and 1.2 s in the first bound cycle beside 1,019 ms. The other four (155–487 ms) held it 4–43 ms, and the faster binds 1–142 ms. Only that bound cycle had a play waiting, admitted after 1,041 ms, #53's symptom once in fifteen. The bounded rate read did not time out, so most of the wait is elsewhere in the rebind, most likely an unbounded synchronous HAL call such as the bound device's listener add or remove; unproven, and another session's test run was using the HAL at the time. No stack exists because the queue stall watcher parked when the rebind stopped the output. The rebind is now a `Phase:`, so the watcher samples the next one.
- **The physical unplug itself** stalled the render clock up to 965 ms: the HAL took that long between the iD4 stopping and declaring it dead, and the rebind followed its notice within 5 ms. An unplug 1.4 s after a replug stalled it 3.3 s, the device list changing 2.6 s after the iD4 read dead, with no default to fall back to in between.

**The capture** (the same day and setup, System Output, 57 more cycles over three runs, most with `make test` looping beside them for HAL load, which is what brought the holds back; `make test` touches neither the default nor aggregates):

- **A default change's default-device read held the player queue 366 ms**, sampled by the rebind phase's watcher: `systemDefaultOutputDeviceDidChange` → `setOutputDeviceOnQueue:-1` → `readSystemDefaultOutputDeviceID:`, waiting in `HALDefaultDeviceProperty::GetDefaultDeviceIDFromServer` while `coreaudiod` moved the hardware. The fix takes System Output's default from the manager's snapshot, which it refreshes before notifying (`Mac/Devices/AGENTS.md`).
- **The same read parked playback on a 390 ms blip**: macOS named no default while the speakers were present and the unit was playing on them, and the "no output device" branch parked the voice and raised `DeviceUnavailable`; nothing resumed it when the default came back. Now no default among present devices is unknown, like a failed read: playback continues and one retry follows.
- **No step inside the rebind held the queue under instrumentation**: a temporary per-step timing over 49 rebinds, some beside unit binds of 534 and 668 ms, never saw a step above 11 ms (stop, leave, the listener swap, the bounded rate read, the FX reconcile). The 0.38–1.2 s rebinds of the first two runs were timed around the rebind alone, so what held them is still unobserved.
- **On the fix, 15/15 cycles** with no player-queue stall, no default wait, and no park from a missing default.

**Still open.**

- **#53, the in-rebind holds.** The phase now samples the player queue during a rebind; a hold over 250 ms names its call. Until one recurs, the first two runs' three are unexplained.
- **A start the HAL refuses because the device vanished mid-start parks playback.** An unplug 0.35 s after a replug refused the iD4's start (`'what'`), `outputUnitFailedOnQueue:` parked the voice Paused with `EngineStartFailed`, and the fallback 300 ms later kept it Paused. A clean unplug keeps Playing; this one loses it. Whether a refusal whose device is then confirmed gone should keep the playing intent is a policy question.
- **Silent HAL playback and output auto-switching.** Launch with `VIBE_AUDIBLE=silent` (Now Playing stays suppressed unless `VIBE_NOW_PLAYING=1`) with auto-switching AirPods paired, and see whether playback still pulls them or moves the system output, once on System Output and once explicitly bound. Zero output samples and suppressed Now Playing do not by themselves establish isolation; the 2026-09-25 pass had no Bluetooth device. Hardware stays opt-in until this has evidence.

## Overnight acceptance

2026-09-28, MacBook Pro, macOS 27, `9fcdc73a`, the built-in speakers as System Output, each build in its own derived data; the corpus 432 local files (FLAC, MP3, AIFF, WAV):

- **Integer-format DAC negotiation, Audient iD4, audible** (`verify-bit-perfect --device-check`; the verifier refuses a `--silent` app): 44.1/16, 48/24, 88.2/24 and 96/24 each Active, 24-bit integer on the device, `rateExact`, `formatConfirmed`, `depthOK` and `channelsMatch` true, the six-second idle release, and the device's 44.1 kHz format restored after each. A 48/32 float fixture cannot be bit-perfect on an integer-only device and correctly never reached Active.
- **Binary audit:** no Debug or Release build of either app links `AVAudioFile`, `AVAudioEngine` or `AVAudioPlayerNode` (`nm`, with `AVAudioFormat` found in every binary as the control).
- **ASan + UBSan:** 50,484 ops on `make-hostile-corpus.py`'s corpus (52 broken entries among 127 files) and 54,801 on the real corpus, no report. **TSan:** 76,292 ops on the `ui` profile, no report.
- **Real HAL, silent:** a 90-minute `base` stress run, 109,661 ops and 506,270 render cycles, no violation or growth, 0 dropouts; a cold-cache torture over all 432 tracks, 9,600 ops, every `pending` counter clear at rest.
- **One seed, pump and HAL:** seed 70030 on the `loading` profile for 30 min each, 26,606 and 26,580 ops, 16,295 and 15,984 handle opens, 0 failed requests under either.
- **macOS profile** (an optimized Debug build, since Release has no debug channel; Time Profiler, silent HAL): steady playback 3.4% of one core, about 70% of it Apple's `Resampler2` taking 44.1 kHz files to the speakers' 48 kHz at Max quality, FLAC decode about 5%, the per-tick position UI about 3%; busy transport with the reverb send and pitch 7.6%, the FX chain and the varispeed the additions.

## Hardware stress campaigns

The stress harness defaults to the manual pump (`--no-audio-hw --silent`). The `base` and `loading` profiles and torture now have long HAL evidence ([overnight acceptance](#overnight-acceptance)). Before any change to that default:

- **Cloud and artwork campaigns on real HAL.** Keep deliberate pump coverage if the default ever changes.
- **Shrinking under HAL.** Nothing failed to shrink; a seed reproduces the generated operations, not callback timing, under either; retune waits only where the measurements show a need.

Independent of the default, the consistency oracle checks meter demand and output liveness but not that equalizer publications advance with nonzero signal. If that coverage is wanted, drive a known non-silent fixture and read the [equalizer counters](../../.claude/skills/vibe-debug/references/equalizer-counters.md); an occluded view, no demand, or genuine silence must not fail it, and the beta probe's independent meter hold must be respected.

On iOS, `VIBE_AUDIBLE=silent` runs the real RemoteIO output unit with its buffers zeroed, as on the mac; any other nonempty value is an audible launch.

## Separate proposals

- [Source-preserving PCM output](source-format-output.md): parked. The production opener still takes the float32 default, and the bus still refuses anything but planar float32.
- [Stress harness in a VM](vm-stress-harness.md): isolation work, not a prerequisite for any of the above.

Fix what these runs find in the existing owners and test files. Preserve the regression coverage for held renders and reads, successor identity, complete PCM, slot reuse, and the pump's 16,384-frame requests into 4,096-frame render slices.
