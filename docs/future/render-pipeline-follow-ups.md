# Audio pipeline: remaining work

Validated 2026-09-25 against PR66 on `worktree-voice-bus`, including the consolidation and review fixes. The output-unit split, owned-file migration, waveform consolidation, conversion-policy naming, metering cleanup and explicit decoder-error handling are implemented. Their current contracts live in [Audio/CLAUDE.md](../../Vibe/Audio/CLAUDE.md), [Devices/CLAUDE.md](../../Vibe/Audio/Mac/Devices/CLAUDE.md) and [iOS/CLAUDE.md](../../Vibe/Audio/iOS/CLAUDE.md).

## Resolved: Apple SRC tail length

Apple's converter, told the end of its stream, gives up only part of its filter's tail at high up-conversion ratios: on macOS at Maximum, 22.05 and 24 kHz to 192 kHz ended 915 and 504 frames short; on iOS (measured in the simulator's AudioToolbox), every conversion up to 96 or 192 kHz ended short, at both qualities, up to 3,989 frames (22.05 → 192 kHz at Maximum). Its passband, SINAD and alias rejection measured identically on both platforms, so only the flush differs.

The bus no longer tells the converter the end: the flushing fill supplies silence and stops at the frames fed, at the bus rate (`AudioVoiceBus.m`, the `TRAP:` in `VibeConverterSupplyInput`). That is not padding: the output is exactly the length the input implies, and an impulse twenty input frames before the end comes out whole and in place, measured on a standalone converter on both platforms. `testTheResamplerContinuesAtEveryRatePairAndPullSize` builds its independent reference the same way and has no expected failure; against the old flush it fails at 22.05 → 192 kHz (191,085 frames for 192,000).

The measurement that led here also compared r8brain-free-src and libsamplerate against Apple at Maximum and High. Apple and r8brain's 24-bit preset were within a few dB of each other and far below audibility (SINAD ≥ 145 dB, aliasing ≤ −147 dB); libsamplerate's best preset let through −127 dB at the Nyquist edge, and its medium preset rolls off 3.25 dB at 20 kHz. r8brain cost 4–8× less CPU than Apple at High, which is the one reason left to revisit it: running iOS at top quality for less than High costs now.

## Remaining acceptance evidence

The 2026-09-25 review-fix pass reran 1,479 unit tests (the two scoped SRC duration issues above are expected failures), 87 rendered-audio tests, all 49 bus tests and all 87 rendered-audio tests under ThreadSanitizer, both Debug platform builds, both Release static analyses, and layout/vocabulary/strings/translations checks. All passed.

Earlier implementation live checks covered macOS silent HAL transport, a 240-operation torture run (seed 660925), iOS simulator transport, owned-file waveform/analysis and WAV→FLAC conversion, and the Advanced Bluetooth eligibility override. The 2026-09-25 device-lifecycle pass below covered the macOS rebind path, the stale-device and rebuild symptoms, and exclusive ownership on three DACs. They do not establish:

- Physical iOS interruptions, media-services reset, and the rest of the route pass. The iOS output unit is a RemoteIO `AudioOutputUnit` since #72. **Run on an iPhone 17 Pro (iOS 27), 2026-09-26, with the route/recovery log lines #72 added:**
  - AirPods Pro connected while playing, several times: the verdict was recover, the unit kept running, and the one audible effect was a ~200–300 ms render-clock stall as iOS moved the audio, seen on some connects and not others.
  - AirPods disconnected while playing, several times: the verdict was pause, and **iOS then stopped RemoteIO itself about 0.75 s after the route change**, every time. The system-stop path handled it (the player stopped its output while already paused) and the next play restarted the unit in ~95 ms. `iOS/CLAUDE.md` now says the unit does not always survive a route change.
  - AirPlay to the speaker by a category change: paused, as external-to-built-in should. The rate follow ran at play start (48 → 44.1 kHz on AirPlay) and at resume (44.1 → 48 kHz on the speaker).
  - Background playback on the Home screen, with the app out of the foreground for ~20 s at a time.

  **Not yet run:** a route change that keeps playing *and* has iOS stop the unit, which is the path where `recoverOutput` restarts it (switching output from Control Center, or wired headphones, are the likely triggers); a rate follow mid-playback on a route change; a phone call ended with and without `ShouldResume` (the unit's `IsRunning` listener is what makes the resume start it again); a media-services reset re-making the unit; playback across the lock screen with Now Playing commanding it; and a cold launch leaving another app's audio playing, now that `prepareIdleCategory` is gone. Provider-backed file access on a device is unverified too.
- Physical macOS unplug and wake: [device lifecycle acceptance](#device-lifecycle-acceptance) below. Integer-format DAC negotiation through `verify-bit-perfect --device-check` (`test-audio.md`), which the pass did not run.
- ASan/UBSan, or the owned-file migration’s all-configuration binary audit. Performance has had one pass, iOS only: Instruments on device against Release builds (#74), which lowered the iOS resampling quality to High by default and fixed the main-thread costs it found. macOS has had no comparable profile.

Use the existing [test instructions](../../Tests/CLAUDE.md), [hardware acceptance workflow](../../.claude/skills/vibe-debug/references/test-audio.md) and [debug skill](../../.claude/skills/vibe-debug/SKILL.md). Keep hardware results distinct from the manual pump and simulator.

## Device lifecycle acceptance

Issues #50, #53, #56 and #57 were closed with PR66 because the mechanism each described no longer exists; their *symptoms* are what the new output unit must show absent. On 2026-09-25 (Mac Studio, macOS 27, Debug `ed0361dd`, real HAL, silent, Now Playing suppressed; Fireface 802, Audient iD4, FiiO E10, BlackHole 2ch) the software layer passed everywhere except #53:

- **#50, software layer:** 750 `device-flap.py` vanish flaps over three DACs and 1,800 move flaps across six device pairs — no silent stop, dropout, refusal, consistency violation or pending counter; the at-rest heap matched a no-flap control.
- **#56:** 40 BlackHole `--ordinary` loopback captures, each spanning 8–9 system-default changes between two other DACs, all PCM-exact, with no rebind and continuous render cycles.
- **#57:** all three cases against the app's own HAL reads, including 20 vanish/return cycles of an explicitly bound device (a fixed-UID aggregate) while playing and paused: `pendingDeviceUID` carried the lost UID, and the return re-bound under a new id — at once when paused, at the next pause when playing, by `VibeCanBindSavedOutputDevice`'s design.
- **Exclusive + bit-perfect:** `bitperfect-soak.py --rounds 2` on each DAC — every rate Active or correctly `rateUnsupported`, hogs released, formats restored.

**Still open.**

- **#53, a slow bind blocking the player queue: failed, then fixed.** A play submitted during a bind waited it out — median 127 ms, max 270 ms across 104 plays — because the whole rebind ran on the player queue. The output unit now waits on the HAL on its own queue (`Mac/Devices/CLAUDE.md`), and since 69cb6f94 reads the device's presentation and buffer latencies there too, so a wedged device no longer holds `dump_state` or `dump_audio_path` on the player queue for the 30 s HAL timeout; the same rotate-plus-plays measurement after the fix admitted every play submitted during a bind within 3.4 ms (109 plays, median 0.1 ms), with no player-queue stall, and the rest of this pass — vanish flaps, the #57 cycles, the #56 loopback and the bit-perfect soak — passed again on the fix. It stays on this list only until the physical power-cycle below confirms a waking DAC no longer freezes transport.
- **#50, hardware layer.** A real USB DAC power-cycled ten to fifteen times while playing, once on System Output and once explicitly bound to it. The original was one silent stop in fifteen cycles with nothing logged; the oracle is the streamed log carrying the renderer's Timeline lines for every cycle and no `stopped` at position 0 without an error beside it. It must also settle a discrepancy: `Mac/Devices/CLAUDE.md` says an unplug parks playback as Paused, but a vanished explicitly-bound aggregate kept playing on System Output in every playing cycle — either the doc is stale or a real unplug takes another path.
- **Silent HAL playback and output auto-switching.** Launch with `VIBE_AUDIBLE=silent` (Now Playing stays suppressed unless `VIBE_NOW_PLAYING=1`) with auto-switching AirPods paired, and see whether playback still pulls them or moves the system output, once on System Output and once explicitly bound. Zero output samples and suppressed Now Playing do not by themselves establish isolation; the 2026-09-25 pass had no Bluetooth device. Hardware stays opt-in until this has evidence.

## Hardware stress campaigns

The stress harness defaults to the manual pump (`--no-audio-hw --silent`). Before any change to that default:

- **Long HAL campaigns.** Cloud/artwork and transport campaigns on real HAL, long enough to be a soak; the 240-operation torture run above is bounded evidence. Keep deliberate pump coverage if the default ever changes.
- **Seeded campaigns under the pump and the output unit.** Repeat seeded campaigns and shrinking under the pump and under HAL, recording journals, endings, failures and settled resource counters. A seed reproduces the generated operations, not callback timing, under either; retune waits only where the measurements show a need.

Independent of the default, the consistency oracle checks meter demand and output liveness but not that equalizer publications advance with nonzero signal. If that coverage is wanted, drive a known non-silent fixture and read the [equalizer counters](../../.claude/skills/vibe-debug/references/equalizer-counters.md); an occluded view, no demand or genuine silence must not fail it, and the beta probe's independent meter hold must be respected.

On iOS, `VIBE_AUDIBLE=silent` runs the real RemoteIO output unit with its buffers zeroed, as on the mac; any other nonempty value is an audible launch.

## Separate proposals

Each validated 2026-09-25 against this tree.

- [Source-preserving PCM output](source-format-output.md): accurate. The production opener still takes the float32 default (`AudioFileMaterializationCoordinator.m`, `initForReading:error:`), the bus still refuses anything but planar float32, and the 24,641,537 → 24,641,536 narrowing it cites is recorded in `OutputFormatRules.h`. Unimplemented; nothing in it is overtaken by PR66's consolidation, which it already credits.
- [Stress harness in a VM](vm-stress-harness.md): isolation work, not a prerequisite for any of the above, and listed so the relationship is stated once.

Use existing owners and test files for these fixes. Preserve the regression coverage for held renders/reads, successor identity, complete PCM, slot reuse and the pump’s 16,384-frame requests into 4,096-frame render slices.
