# Audio pipeline: remaining work

Validated 2026-09-25 against PR66 on `worktree-voice-bus`, including the consolidation and review fixes. The carrier split, owned-file migration, waveform consolidation, conversion-policy naming, metering cleanup and explicit decoder-error handling are implemented. Their current contracts live in [Audio/CLAUDE.md](../../Vibe/Audio/CLAUDE.md), [Devices/CLAUDE.md](../../Vibe/Audio/Mac/Devices/CLAUDE.md) and [iOS/CLAUDE.md](../../Vibe/Audio/iOS/CLAUDE.md).

## Unresolved: Apple mastering SRC tail length

On macOS 27.0 (26A428), using Xcode 27.0 (27A266a), the standalone `AVAudioFile` + `AVAudioConverter` path reproduces the bus’s short output, without `AudioFileHandle`, Vibe’s stream states, or gapless flushing. At maximum mastering quality, half-second 22.05 kHz and 24 kHz sources converted to 192 kHz produce 95,085 and 95,496 frames respectively, instead of 96,000. Sources at 32, 44.1 and 48 kHz produce all 96,000 frames. One-second sources lose the same 915 and 504 frames.

Increasing input/output buffers from 4,096 to 16,384 frames does not repair it. Changing the priming method changes latency and duration without yielding the required aligned stream. Apple’s normal algorithm at maximum quality produces the expected duration, but choosing a different filter is a playback-quality policy change, not an established fix to mastering SRC. The production converter retains its mastering setting. Apple documents the [priming methods](https://developer.apple.com/documentation/avfaudio/avaudioconverterprimemethod) and the converter’s [trailing-frame synthesis](https://developer.apple.com/documentation/audiotoolbox/audioconverterprimeinfo); these measurements do not establish why its mastering implementation falls short.

`AudioVoiceBusTests.testTheResamplerContinuesAtEveryRatePairAndPullSize` now checks clean playback and early/late gapless continuation against an independent Apple reader/converter across nine rate pairs and 63/256/1,024/4,096-frame pulls. Whole-file PCM permits only four float epsilons of independent-conversion rounding. The mathematical duration assertion keeps its two-frame tolerance: only the two exact independently reproduced shortfalls are scoped expected failures. The subsequent Vibe/reference duration and complete PCM comparisons remain required, and execute after those expected failures. A different shortfall fails normally; a corrected system converter needs no exemption.

`testRefusedSuccessorSeekFlushesMoreThanOneChunk` still compares a refused successor’s output against isolated predecessor playback. It proves the failure path adds no truncation. The refused-seek fix flushes the healthy predecessor tail through the existing chunked path, retaining error attribution to the unheard successor and suppressing its promotion. Do not replace it with one flush call: the measured tail exceeds one 4,096-frame chunk.

A mastering-quality workaround still needs complete duration, alignment, passband and alias evidence on both platforms. Do not pad the output or relax the duration oracle to conceal the missing tail.

## Remaining acceptance evidence

The 2026-09-25 review-fix pass reran 1,479 unit tests (the two scoped SRC duration issues above are expected failures), 87 rendered-audio tests, all 49 bus tests and all 87 rendered-audio tests under ThreadSanitizer, both Debug platform builds, both Release static analyses, and layout/vocabulary/strings/translations checks. All passed.

Earlier implementation live checks covered macOS silent HAL transport, a 240-operation torture run (seed 660925), iOS simulator transport, owned-file waveform/analysis and WAV→FLAC conversion, and the Advanced Bluetooth eligibility override. They do not establish:

- Physical iOS route changes, interruptions, media-services reset, or provider-backed file access.
- Final-tree macOS unplug/rebind, exclusive ownership, integer-format DAC negotiation, or complete hardware loopback acceptance. Older engine-era captures are not acceptance of this renderer.
- Extended soak/resource and performance comparisons, ASan/UBSan, or the owned-file migration’s all-configuration binary audit.

Use the existing [test instructions](../../Tests/CLAUDE.md), [hardware acceptance workflow](../../.claude/skills/vibe-debug/references/test-audio.md) and [debug skill](../../.claude/skills/vibe-debug/SKILL.md). Keep hardware results distinct from the manual pump and simulator. Prior run artifacts, while retained locally, are under `/private/tmp/vibe-consolidation-*` and `/private/tmp/vibe-any-device-*`.

## Separate proposals

- [Source-preserving PCM output](source-format-output.md): wider precision and native sample storage remain unimplemented.
- [Hardware stress follow-ups](end-of-graph-silent.md): the silent renderer and launch controls exist; the remaining work is measurement and harness coverage.

Use existing owners and test files for these fixes. Preserve the regression coverage for held renders/reads, successor identity, complete PCM, slot reuse and the pump’s 16,384-frame requests into 4,096-frame render slices.
