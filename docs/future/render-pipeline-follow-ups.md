# Audio pipeline: remaining work

Validated 2026-09-25 against PR66 on `worktree-voice-bus`, including the consolidation and review fixes. The carrier split, owned-file migration, waveform consolidation, conversion-policy naming, metering cleanup and explicit decoder-error handling are implemented. Their current contracts live in [Audio/CLAUDE.md](../../Vibe/Audio/CLAUDE.md), [Devices/CLAUDE.md](../../Vibe/Audio/Mac/Devices/CLAUDE.md) and [iOS/CLAUDE.md](../../Vibe/Audio/iOS/CLAUDE.md).

## Unresolved: Apple mastering SRC tail length

On macOS 27.0 (26A428), using Xcode 27.0 (27A266a), the standalone `AVAudioFile` + `AVAudioConverter` path reproduces the bus’s short output, without `AudioFileHandle`, Vibe’s stream states, or gapless flushing. At maximum mastering quality, half-second 22.05 kHz and 24 kHz sources converted to 192 kHz produce 95,085 and 95,496 frames respectively, instead of 96,000. Sources at 32, 44.1 and 48 kHz produce all 96,000 frames. One-second sources lose the same 915 and 504 frames.

Increasing input/output buffers from 4,096 to 16,384 frames does not repair it. Changing the priming method changes latency and duration without yielding the required aligned stream. Apple’s normal algorithm at maximum quality produces the expected duration, but choosing a different filter is a playback-quality policy change, not an established fix to mastering SRC. The production converter retains its mastering setting. Apple documents the [priming methods](https://developer.apple.com/documentation/avfaudio/avaudioconverterprimemethod) and the converter’s [trailing-frame synthesis](https://developer.apple.com/documentation/audiotoolbox/audioconverterprimeinfo); these measurements do not establish why its mastering implementation falls short.

`AudioVoiceBusTests.testTheResamplerContinuesAtEveryRatePairAndPullSize` now checks clean playback and early/late gapless continuation against an independent Apple reader/converter across nine rate pairs and 63/256/1,024/4,096-frame pulls. Whole-file PCM permits only four float epsilons of independent-conversion rounding. The mathematical duration assertion keeps its two-frame tolerance: only the two exact independently reproduced shortfalls are scoped expected failures. The subsequent Vibe/reference duration and complete PCM comparisons remain required, and execute after those expected failures. A different shortfall fails normally; a corrected system converter needs no exemption.

`testRefusedSuccessorSeekFlushesMoreThanOneChunk` still compares a refused successor’s output against isolated predecessor playback. It proves the failure path adds no truncation. The refused-seek fix flushes the healthy predecessor tail through the existing chunked path, retaining error attribution to the unheard successor and suppressing its promotion. Do not replace it with one flush call: the measured tail exceeds one 4,096-frame chunk.

A mastering-quality workaround still needs complete duration, alignment, passband and alias evidence on both platforms. Do not pad the output or relax the duration oracle to conceal the missing tail.

The bus now drives the converter as an AudioToolbox `AudioConverterRef` rather than through `AVAudioConverter` (34cbed68). The two shortfalls reproduce with the identical frame counts, as expected of the same resampler underneath; the swap is not a lead.

## Remaining acceptance evidence

The 2026-09-25 review-fix pass reran 1,479 unit tests (the two scoped SRC duration issues above are expected failures), 87 rendered-audio tests, all 49 bus tests and all 87 rendered-audio tests under ThreadSanitizer, both Debug platform builds, both Release static analyses, and layout/vocabulary/strings/translations checks. All passed.

Earlier implementation live checks covered macOS silent HAL transport, a 240-operation torture run (seed 660925), iOS simulator transport, owned-file waveform/analysis and WAV→FLAC conversion, and the Advanced Bluetooth eligibility override. They do not establish:

- Physical iOS route changes, interruptions, media-services reset, or provider-backed file access.
- Final-tree macOS unplug/rebind and the stale-device and slow-bind symptoms of the closed engine-era issues: the [device lifecycle acceptance](#device-lifecycle-acceptance) below. Exclusive ownership and integer-format DAC negotiation: `bitperfect-soak.py` and `verify-bit-perfect --device-check` (`vibe-stress`, `test-audio.md`). Older engine-era captures are not acceptance of this renderer.
- Extended soak/resource and performance comparisons, ASan/UBSan, or the owned-file migration’s all-configuration binary audit.

Use the existing [test instructions](../../Tests/CLAUDE.md), [hardware acceptance workflow](../../.claude/skills/vibe-debug/references/test-audio.md) and [debug skill](../../.claude/skills/vibe-debug/SKILL.md). Keep hardware results distinct from the manual pump and simulator. Prior run artifacts, while retained locally, are under `/private/tmp/vibe-consolidation-*` and `/private/tmp/vibe-any-device-*`.

## Device lifecycle acceptance

Issues #50, #53, #56 and #57 were closed with PR66 because the mechanism each described — the engine graph, its bind-driven rebuild and the player's device bookkeeping around it — no longer exists. Their *symptoms* are what a device-lifecycle pass on the new carrier must show absent. These are live tests through the debug channel and the `vibe-stress` drivers, never unit tests. Read the `vibe-stress` skill's device-flap section first: every driver below moves audio for every app on the machine, and an `AudioDeviceID` changes on every re-enumeration, so read it fresh.

**Silent stop after a device vanishes and returns (#50).** Two layers. Software volume first, with Vibe on System Output — `dump_state.player.requestedOutputDeviceId` at -1, or the vanish never reaches it:

```bash
.claude/skills/vibe-stress/scripts/device-flap.py --corpus ~/Music/big --device <id> --flaps 250
```

The driver's oracles are the ones wanted: state and position per flap, `check_consistency`, the app alive, `dump_health` against its baseline, and a closing `quiesce` with every pending counter at zero. A clean run proves Vibe's rebind path and nothing about hardware wake latency, so the second layer is a real USB DAC power-cycled ten to fifteen times while playing, once on System Output and once explicitly bound to that DAC. The original was one silent stop in fifteen cycles with nothing logged; the oracle is the streamed log carrying the renderer's Timeline lines for every cycle and no `stopped` at position 0 without an error beside it.

**A slow bind blocking the player queue (#53).** The renderer logs the number directly: every play submission logs how long it waited for admission on the player queue (`Timeline: play N admitted after X ms on player queue`, `AudioPlayer+Diagnostics`), and a slow output start logs how long the queue was blocked (`AudioPlayer+Pipeline`). Rotate the system default across real devices with the slowest one owned in the list (the helper's `rotate` mode; the skill's table puts an RME bind at half a second), submit plays during the binds, and read those lines. An admission wait that tracks the bind time is the symptom back on the new carrier; one under a few milliseconds whatever the destination is the fix holding.

**A bind rebuilding when the device has not changed (#56).** The stimulus is a default-device change that does not concern the bound device: bind Vibe explicitly to BlackHole (`set_output_device "BlackHole 2ch"`, then poll `dump_state.player.outputDeviceUID` until it names it), run a sample-exact loopback capture, and rotate the system default between two *other* real devices while it runs:

```bash
build/verify-bit-perfect "$PWD/build/audio-fixtures/noise-48000-24-2.wav" 3 "BlackHole 2ch" --play-app "$V" --force-volume --ordinary
```

Any rebuild that interrupts the render is a PCM mismatch, and `dump_health`'s render cycles must be continuous with the dropout count unchanged. Clear BlackHole's device mute first; a muted loopback reads as silence. The bound device's *nominal rate* moving under another process is a legitimate rebind (`Mac/Devices/CLAUDE.md`), not this case.

**The player's device notion going stale (#57).** After every flap or rotation compare the app's answer to the HAL's, never the app to itself: the app's side is `dump_state.player.outputDeviceId`, `outputDeviceUID` and `requestedOutputDeviceId`, and the device stage of `dump_audio_path`; the HAL's side is what the flap helper reports. Three cases: on System Output `requestedOutputDeviceId` is -1 and the bound id is the current default's; explicitly bound to a device that vanishes, `outputDeviceUID` stops naming it and `bitPerfect.pendingDeviceUID` carries the UID the player is waiting to rebind, never the stale id; when that device returns under a new `AudioDeviceID`, `outputDeviceUID` names it again and the bound id is the new one.

Record selected device, actual carrier, silent state and media-publication mode with each result, and keep hardware results distinct from the pump and the simulator. The AirPods are usually the default output and a real-HAL launch can take them; select the speakers first. The installed Vibe is often running; direct-exec the Debug build beside it.

**Silent HAL playback and output auto-switching.** Run with the pass above: launch with `VIBE_AUDIBLE=silent` (Now Playing stays suppressed unless `VIBE_NOW_PLAYING=1`) and see whether playback still pulls auto-switching AirPods or moves the system output, once on System Output and once explicitly bound. Zero output samples and suppressed Now Playing do not by themselves establish isolation. Hardware stays opt-in until this has evidence; use the existing device selection before proposing another launch flag.

## Hardware stress campaigns

The stress harness defaults to the manual pump (`--no-audio-hw --silent`). Before any change to that default:

- **Long HAL campaigns.** Cloud/artwork and transport campaigns on real HAL, long enough to be a soak; the 240-operation torture run above is bounded evidence. Keep deliberate pump coverage if the default ever changes.
- **Seeded campaigns across carriers.** Repeat seeded campaigns and shrinking under the pump and under HAL, recording journals, endings, failures and settled resource counters. A seed reproduces the generated operations, not callback timing, on either carrier; retune waits only where the measurements show a need.

Independent of the default, the consistency oracle checks meter demand and output liveness but not that equalizer publications advance with nonzero signal. If that coverage is wanted, drive a known non-silent fixture and read the [equalizer counters](../../.claude/skills/vibe-debug/references/equalizer-counters.md); an occluded view, no demand or genuine silence must not fail it, and the beta probe's independent meter hold must be respected.

On iOS any nonempty `VIBE_AUDIBLE` is an audible launch; the macOS `silent` value does not carry over.

## Separate proposals

Each validated 2026-09-25 against this tree.

- [Source-preserving PCM output](source-format-output.md): accurate. The production opener still takes the float32 default (`AudioFileMaterializationCoordinator.m`, `initForReading:error:`), the bus still refuses anything but planar float32, and the 24,641,537 → 24,641,536 narrowing it cites is recorded in `OutputFormatRules.h`. Unimplemented; nothing in it is overtaken by PR66's consolidation, which it already credits.
- [Stress harness in a VM](vm-stress-harness.md): isolation work, not a prerequisite for any of the above, and listed so the relationship is stated once.
- [RemoteIO carrier on iOS, #69](https://github.com/cmicali/vibe/issues/69): the last `AVAudioEngine` use, with the `AVAudioTime` fold and the physical-iPhone acceptance the first bullet of the evidence list already requires.

Use existing owners and test files for these fixes. Preserve the regression coverage for held renders/reads, successor identity, complete PCM, slot reuse and the pump’s 16,384-frame requests into 4,096-frame render slices.
