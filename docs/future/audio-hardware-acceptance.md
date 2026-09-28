# Audio pipeline: hardware acceptance

**Status: the pipeline work is done; what remains is evidence only real hardware gives (verified 2026-09-27).** The output-unit split, owned-file migration, waveform consolidation, conversion-policy naming, metering cleanup, and explicit decoder-error handling are implemented. Their contracts live in [Audio/CLAUDE.md](../../Vibe/Audio/CLAUDE.md), [Devices/CLAUDE.md](../../Vibe/Audio/Mac/Devices/CLAUDE.md), and [iOS/CLAUDE.md](../../Vibe/Audio/iOS/CLAUDE.md).

## Resolved: Apple SRC tail length

Apple's converter, told the end of its stream, gives up only part of its filter's tail at high up-conversion ratios, so the bus never tells it: the flushing fill supplies silence and stops at the frames fed (the `TRAP:` in `VibeConverterSupplyInput`, `AudioVoiceBus.m`). The one reason to revisit the resampler: r8brain-free-src matched Apple's quality and cost 4–8× less CPU than Apple at High, the quality iOS runs at by default for cost.

## Remaining acceptance evidence

The 2026-09-25 pass reran 1,479 unit tests, 87 rendered-audio tests, all 49 bus tests and all 87 rendered-audio tests under ThreadSanitizer, both Debug platform builds, both Release static analyses, and the layout, vocabulary, strings, and translations checks. All passed; the resampler test's two SRC duration shortfalls, then expected failures, have since been fixed by the flush above.

Earlier live checks covered macOS silent HAL transport, a 240-operation torture run (seed 660925), iOS simulator transport, owned-file waveform/analysis and WAV→FLAC conversion, and the Advanced Bluetooth eligibility override. The [device lifecycle](#device-lifecycle-acceptance) pass covered the macOS rebind path, the stale-device and rebuild symptoms, and exclusive ownership on three DACs. They do not establish:

- **Physical iOS interruptions, media-services reset, and the rest of the route pass.** Run on an iPhone 17 Pro (iOS 27), 2026-09-26, with #72's route and recovery log lines:
  - AirPods Pro connected while playing, several times: the verdict was recover, the unit kept running, and the one audible effect was a ~200–300 ms render-clock stall as iOS moved the audio, on some connects and not others.
  - AirPods disconnected while playing, several times: the verdict was pause, and **iOS then stopped RemoteIO itself about 0.75 s after the route change**, every time. The system-stop path handled it, and the next play restarted the unit in ~95 ms.
  - AirPlay to the speaker by a category change: paused, as external-to-built-in should. The rate follow ran at play start (48 → 44.1 kHz on AirPlay) and at resume (44.1 → 48 kHz on the speaker).
  - Background playback on the Home screen, out of the foreground for ~20 s at a time.

  **Not yet run:** a route change that keeps playing *and* has iOS stop the unit, the path where `recoverOutput` restarts it (switching output from Control Center, or wired headphones, are the likely triggers); a rate follow mid-playback on a route change; a phone call ended with and without `ShouldResume` (the unit's `IsRunning` listener is what makes the resume start it again); a media-services reset re-making the unit; playback across the lock screen with Now Playing commanding it; and a cold launch leaving another app's audio playing. Provider-backed file access on a device is unverified too.
- **Physical macOS power-cycle and wake:** [device lifecycle](#device-lifecycle-acceptance) below. Integer-format DAC negotiation through `verify-bit-perfect --device-check` (`test-audio.md`), which the pass did not run.
- **ASan/UBSan, and the owned-file migration's all-configuration binary audit.** Performance has had one pass, iOS only: Instruments on device against Release builds (#74), which lowered the iOS resampling quality to High by default and fixed the main-thread costs it found. macOS has had no comparable profile.

Use the [test instructions](../../Tests/CLAUDE.md), the [hardware acceptance workflow](../../.claude/skills/vibe-debug/references/test-audio.md), and the [debug skill](../../.claude/skills/vibe-debug/SKILL.md). Keep hardware results distinct from the manual pump and the simulator.

## Device lifecycle acceptance

Issues #50, #53, #56, and #57 were closed because the mechanism each described no longer exists; their *symptoms* are what the output unit must show absent. On 2026-09-25 (Mac Studio, macOS 27, Debug `ed0361dd`, real HAL, silent, Now Playing suppressed; Fireface 802, Audient iD4, FiiO E10, BlackHole 2ch) the software layer passed everywhere, #53 after its fix:

- **#50, software layer:** 750 `device-flap.py` vanish flaps over three DACs and 1,800 move flaps across six device pairs, with no silent stop, dropout, refusal, consistency violation, or pending counter; the at-rest heap matched a no-flap control.
- **#53:** a play submitted during a bind waited it out (median 127 ms, max 270 ms across 104 plays) while the rebind ran on the player queue. The output unit now waits on the HAL, and reads the device's latencies, on its own queue (`Mac/Devices/CLAUDE.md`); rerun, every play submitted during a bind was admitted within 3.4 ms (109 plays, median 0.1 ms), and the rest of this pass passed again on the fix.
- **#56:** 40 BlackHole `--ordinary` loopback captures, each spanning 8–9 system-default changes between two other DACs, all PCM-exact, with no rebind and continuous render cycles.
- **#57:** all three cases against the app's own HAL reads, including 20 vanish/return cycles of an explicitly bound device (a fixed-UID aggregate) while playing and paused: `pendingDeviceUID` carried the lost UID, and the return re-bound under a new id, at once when paused and at the next pause when playing, by `VibeCanBindSavedOutputDevice`'s design.
- **Exclusive + bit-perfect:** `bitperfect-soak.py --rounds 2` on each DAC; every rate Active or correctly `rateUnsupported`, hogs released, formats restored.

A vanished device does not park playback. AUHAL moves a unit whose device vanishes to the system default and keeps pulling, and the device-list observer's rebind to System Output restores the track as it was, Playing included; only no output device at all, or another app's hog, parks it (`Mac/Devices/CLAUDE.md`). That is why the vanished aggregate kept playing on System Output in every playing cycle.

**Still open.**

- **#50 and #53, hardware layer.** A real USB DAC power-cycled ten to fifteen times while playing, once on System Output and once explicitly bound to it. The original #50 was one silent stop in fifteen cycles with nothing logged; the oracle is the streamed log carrying the renderer's Timeline lines for every cycle and no `stopped` at position 0 without an error beside it. The same run confirms a physical unplug takes the fall-back-and-keep-playing path the aggregate did, and that a waking DAC no longer freezes transport (#53's last evidence).
- **Silent HAL playback and output auto-switching.** Launch with `VIBE_AUDIBLE=silent` (Now Playing stays suppressed unless `VIBE_NOW_PLAYING=1`) with auto-switching AirPods paired, and see whether playback still pulls them or moves the system output, once on System Output and once explicitly bound. Zero output samples and suppressed Now Playing do not by themselves establish isolation; the 2026-09-25 pass had no Bluetooth device. Hardware stays opt-in until this has evidence.

## Hardware stress campaigns

The stress harness defaults to the manual pump (`--no-audio-hw --silent`). Before any change to that default:

- **Long HAL campaigns.** Cloud/artwork and transport campaigns on real HAL, long enough to be a soak; the 240-operation torture run above is bounded evidence. Keep deliberate pump coverage if the default ever changes.
- **Seeded campaigns under the pump and the output unit.** Repeat seeded campaigns and shrinking under the pump and under HAL, recording journals, endings, failures, and settled resource counters. A seed reproduces the generated operations, not callback timing, under either; retune waits only where the measurements show a need.

Independent of the default, the consistency oracle checks meter demand and output liveness but not that equalizer publications advance with nonzero signal. If that coverage is wanted, drive a known non-silent fixture and read the [equalizer counters](../../.claude/skills/vibe-debug/references/equalizer-counters.md); an occluded view, no demand, or genuine silence must not fail it, and the beta probe's independent meter hold must be respected.

On iOS, `VIBE_AUDIBLE=silent` runs the real RemoteIO output unit with its buffers zeroed, as on the mac; any other nonempty value is an audible launch.

## Separate proposals

- [Source-preserving PCM output](source-format-output.md): parked. The production opener still takes the float32 default, and the bus still refuses anything but planar float32.
- [Stress harness in a VM](vm-stress-harness.md): isolation work, not a prerequisite for any of the above.

Fix what these runs find in the existing owners and test files. Preserve the regression coverage for held renders and reads, successor identity, complete PCM, slot reuse, and the pump's 16,384-frame requests into 4,096-frame render slices.
