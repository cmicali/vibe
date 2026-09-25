# Audio pipeline: remaining work

Validated 2026-09-25 against PR66 on `worktree-voice-bus`, including the consolidation and review fixes. The carrier split, owned-file migration, waveform consolidation, conversion-policy naming, metering cleanup and explicit decoder-error handling are implemented. Their current contracts live in [Audio/CLAUDE.md](../../Vibe/Audio/CLAUDE.md), [Devices/CLAUDE.md](../../Vibe/Audio/Mac/Devices/CLAUDE.md) and [iOS/CLAUDE.md](../../Vibe/Audio/iOS/CLAUDE.md).

## Investigate high-ratio resampler truncation

Clean playback of 11,025 source frames at 22.05 kHz into a 192 kHz bus ended at 95,085 output frames instead of 96,000. Investigate `AudioVoiceBus.produceChunkForSlot:final:` and the converter’s end-of-input/flush behavior before changing duration tolerances. Establish the complete expected output with an independent reference and check nearby rate ratios, ordinary EOF and gapless continuation.

`testRefusedSuccessorSeekFlushesMoreThanOneChunk` compares a refused successor’s output against isolated predecessor playback. It proves the failure path adds no truncation; it does not prove the clean path’s duration is correct. The refused-seek fix is already implemented: a healthy shared converter flushes the predecessor’s tail through the existing chunked decode path, retaining error attribution to the unheard successor and suppressing its promotion. Do not replace this with one flush call: the measured tail exceeds one 4,096-frame chunk.

## Remaining acceptance evidence

The latest implementation checks passed: 1,478 unit tests, 87 rendered-audio tests, 48 bus tests and all 87 rendered-audio tests under ThreadSanitizer, both Debug platform builds, both Release analyses, and layout/vocabulary/string checks. These are the 2026-09-25 implementation results, not checks rerun by the documentation cleanup.

Live checks covered macOS silent HAL transport, a 240-operation torture run (seed 660925), iOS simulator transport, owned-file waveform/analysis and WAV→FLAC conversion, and the Advanced Bluetooth eligibility override. They do not establish:

- Physical iOS route changes, interruptions, media-services reset, or provider-backed file access.
- Final-tree macOS unplug/rebind, exclusive ownership, integer-format DAC negotiation, or complete hardware loopback acceptance. Older engine-era captures are not acceptance of this renderer.
- Extended soak/resource and performance comparisons, ASan/UBSan, or the owned-file migration’s all-configuration binary audit.

Use the existing [test instructions](../../Tests/CLAUDE.md), [hardware acceptance workflow](../../.claude/skills/vibe-debug/references/test-audio.md) and [debug skill](../../.claude/skills/vibe-debug/SKILL.md). Keep hardware results distinct from the manual pump and simulator. Prior run artifacts, while retained locally, are under `/private/tmp/vibe-consolidation-*` and `/private/tmp/vibe-any-device-*`.

## Separate proposals

- [Source-preserving PCM output](source-format-output.md): wider precision and native sample storage remain unimplemented.
- [Hardware stress follow-ups](end-of-graph-silent.md): the silent renderer and launch controls exist; the remaining work is measurement and harness coverage.

Use existing owners and test files for these fixes. Preserve the regression coverage for held renders/reads, successor identity, complete PCM, slot reuse and the pump’s 16,384-frame requests into 4,096-frame render slices.
