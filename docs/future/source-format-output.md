# Plan: preserve source PCM through bit-perfect output

Validated 2026-09-25 against [PR66](https://github.com/cmicali/vibe/pull/66) on `worktree-voice-bus`, including the consolidation and review fixes. Source-preserving playback remains unimplemented: the production opener still selects float32, and the bus and HAL client still require planar float32. The owned reader and carrier consolidation are already complete; do not reimplement them.

The proposal is to preserve the source's decoded PCM representation through the existing voice bus and into CoreAudio wherever the destination permits it. Ordinary mixing and FX retain their float32 path. This is a change to the bus's sample storage, copy operations, decoder opening and output negotiation, not a second player or transport.

## What the promise means

“Bitrate” here means **sample format and precision**, alongside sample rate and channel layout. A compressed stream's bitrate in kb/s does not specify its decoded PCM precision.

Float32 is not inherently an obstacle to bit-perfect playback: its 24-bit significand can represent every normalized 16-, 20- and 24-bit signed PCM value exactly. Converting those values to float32 and back without processing need not change any sample. It cannot represent every 32-bit integer sample, and float64 PCM can lose precision when narrowed to float32. The existing code explicitly records `24,641,537 → 24,641,536` through the default reader.

The useful improvements are therefore:

- Preserve 32-bit integer and float64 source precision when the entire output path supports it.
- Remove unnecessary format changes, including the lossy float32 → int16 → float32 round trip.
- Stop choosing a lossy file's decoded precision from the device's preferred integer depth.
- Show where conversion actually occurs when the device cannot carry the decoded samples unchanged.

There are three different facts to report: preserving decoded sample values, preserving the PCM representation, and using a lossless source. A 16-bit source carried exactly in a wider integer container preserves its values. A lossy file can have an unchanged decoded PCM path without recovering what compression discarded. A physical device's advertised word length does not establish its analog resolution.

## Decoder output is the boundary

The current reader is [AudioFileHandle](../../Vibe/Audio/AudioFileHandle.h), which owns its descriptor, parser and `ExtAudioFile` codec. Its default initializer requests planar float32; `initForReading:commonFormat:interleaved:error:` already accepts an explicit PCM representation. The production materialization opener still calls the default initializer. A reader’s `processingFormat == float32` therefore describes the chosen interface, not the codec’s internal arithmetic or the original PCM depth of an MP3/AAC file.

For lossy audio, preserve the PCM exposed by the selected Apple decoding API. Prefer a documented, unambiguous decoder output representation when one is available. Otherwise retain float32 and describe it as decoded float32. Do not infer a permanent bit depth from the filename, compression bitrate, silence, or a prefix of decoded samples. The PR's observation that tested Apple MP3 output lies on a 16-bit grid is evidence for those measurements, not a universal MP3/MP2 format guarantee.

Apple exposes supported/current codec output formats, but a supported int16 output can itself be a requested conversion. A capability list is not proof that decoding naturally produces int16. Probe these public APIs in the first step; do not replace the owned reader’s file parsing, seeking and gapless handling just to discover undocumented decoder internals. [Apple: codec output formats](https://developer.apple.com/documentation/audiotoolbox/kaudiocodecpropertyoutputformatsforinputformat), [Apple: current codec properties](https://developer.apple.com/documentation/audiotoolbox/1494111-instance-codec-properties)

| Source | Reader/ring policy in bit-perfect mode | Destination policy |
| --- | --- | --- |
| Signed PCM16 | Int16 | Same rate/layout and integer depth 16 or greater; an exact float representation is an allowed fallback |
| PCM20/24, FLAC/ALAC with known depth | Int32 storage, retaining the source's valid-bit count and verified alignment | Prefer matching valid depth; widening/packing must preserve normalized sample values |
| PCM32 integer, lossless compressed 32-bit if the Apple decoder supports it exactly | Int32, never through float32 | Int32 or another verified representation that preserves all 32 bits; float32 is insufficient |
| Float32 PCM | Float32 | Float32 or float64 for unchanged values; integer output is a conversion |
| Float64 PCM | Float64 | Float64 for unchanged values; narrower output is a conversion |
| MP3, MP2, AAC and other supported lossy codecs | Preserve the API-visible decoded representation; float32 when no stronger output-format guarantee is available | Negotiate from that PCM format; do not default to int16 because the source is lossy |
| Unknown lossless depth | Use a conservatively wide supported reader; keep depth unknown until authoritative metadata establishes it | Do not certify source precision using the current assumed-24-bit fallback |

The storage container and valid precision are separate. Packed 24-bit audio need not use three-byte samples in the ring: a verified integer widening to Int32 is exact. Byte order and interleaving can also change without changing the samples. None of these changes should be described as numerical processing.

Initial scope is macOS bit-perfect playback through the existing `AudioOutputUnit` HAL carrier. The shared implementation must continue to build and work on iOS, whose route and source-node path retain their present format policy. Extending the user-facing mode to iOS is separate work.

## Existing owners and the required changes

| Current owner | Current constraint | Planned change |
| --- | --- | --- |
| `Audio/AudioFileHandle.{h,m}` and `Loading/AudioFileMaterializationCoordinator.m`, `kProductionFileOpener` | The reader supports explicit PCM formats, but the production opener chooses float32 before any voice exists | Source-preserving reader selection within the existing admitted handle-open run |
| `Audio/AudioVoiceBus.{h,m}` | Float pointers, float buffers and float-only initialization; lossy Int16 expanded back into float | Format-sized PCM storage and a direct copy operation, sharing all slot, decode and transport machinery |
| `Audio/AudioPlayer+Pipeline.{h,m}` | Master slicing and pointer offsets assume `sizeof(float)`; `_masterFormat` selected around float playback | A full-format reconcile and byte-correct rendering for the selected PCM format |
| `Audio/Mac/Devices/AudioOutputUnit.{h,m}` and its existing internal header | Client format asserts noninterleaved float32; callback shape assumes one buffer per channel | Validated PCM client formats and buffer geometry derived from their ASBD |
| `Audio/Mac/Devices/OutputFormatRules.h`, `AudioPlayer+Devices.m`, `CoreAudioUtil` | Lossy depth defaults to 16; precision report checks source/reader/physical format | One format choice and precision assessment across the actual reader, bus, client, virtual and physical formats |
| `Audio/Levels/AudioLevelMeter` and `AudioPlayer+Diagnostics` | Meter and diagnostic signal capture read floats | Bounded conversion of an observation copy only, with no write back into playback |
| `Debug/VibeManualRenderPump`, existing audio tests and verifier | Pump/capture and comparison use float32 | Preserve reference and capture precision independently of playback |

## Implementation sequence

### 1. Establish what the Apple reader and HAL can actually preserve

Use the existing fixture generator and test files to exercise the owned reader’s existing explicit Int16, Int32, Float32 and Float64 opens. Include PCM/AIFF byte orders, packed 24-bit, ALAC/FLAC depth flags, supported 32-bit lossless files, MP3/MP2 and AAC. Read back the processing ASBD and verify actual samples against the generated source integers or float bit patterns. An initializer succeeding is not enough.

For lossy decoding, record the codec/API output information available through public APIs and preserve the selected decoded PCM as the reference. If native precision remains unobservable, the recorded fact is “float32 decoder output”; no int16 optimization is enabled based only on observed sample grids.

Probe the HAL output unit's acceptance and read-back of each client PCM format at an unchanged sample rate. Read the selected stream's virtual and physical formats as well. Apple's AUHAL can insert a converter between client and device formats, so setting an Int32 client format does not by itself prove an integer path. [Apple: AUHAL format conversion](https://developer.apple.com/library/archive/technotes/tn2091/_index.html#//apple_ref/doc/uid/DTS10000418-CH1-SUBSECTION6)

This step produces a measured support table and failing precision regressions, before broadening the render implementation. If a decoder or driver narrows internally, record that boundary as unsupported for exact delivery. Do not promise to solve an OS conversion by merely setting another ASBD flag.

### 2. Select a reader that has not already discarded precision

Change the existing playback/prefetch open path to select the existing owned reader’s explicit processing format from source metadata and the decoder policy above. Keep that choice independent of the currently selected output device and mode: a prefetched file should remain useful if the user changes either while it opens. Ordinary playback can convert this reader into its existing float bus.

Perform inspection and any necessary close/reopen sequentially inside the admitted handle-open worker, before publishing the file to the voice decoder. Keep provider access, materialization, cancellation, the six-run ceiling and submission identity intact. Never reopen a file on the audio thread or bypass the coordinator from the pipeline. Metadata/waveform consumers retain their existing reader policy; pass the existing role/purpose through the opener as needed rather than changing every reader implicitly.

Retain source valid depth separately from the reader's storage width. Reuse AVAudioFormat/ASBD and fields on the existing records; introduce no new format class. Derive lossless codec identity independently of whether its depth is known, so removing the assumed-24-bit answer does not accidentally classify an unknown-depth FLAC as lossy.

Move source-format facts needed by the opener out of macOS-only `OutputFormatRules.h` into the existing shared `AudioFileFormat.{h,m}`; leave device-selection policy under `Mac/Devices`. Loading must not import a macOS-only header or invent a second source-depth rule.

A failed precision-preserving open can fall back to the existing playable representation, but its actual narrowing must reach the report. It must not earn an exact status. Confirm that seeking, length, priming/padding and the same-format gapless continuation still behave correctly with the explicit reader.

### 3. Add sample-preserving storage and rendering to the existing bus

Give a bus one immutable PCM format for its lifetime, with sample size and valid precision fixed before publication. Support Int16, Int32, Float32 and Float64 through the existing slots, records, rings, decoder turns, voice identities, ramp adoption, boundary publication and drain.

Keep the internal buffers planar initially. Use byte-sized ring storage and format-aware buffer access; select the sample operation outside the inner loop. A unity-gain, sole audible voice copies at most two ring spans straight into the output. It does not add to a zeroed float buffer or run through an AVAudioConverter. This also preserves signed zero on a float copy path.

Ordinary playback retains the existing float32 vDSP sum and processing path. When exact delivery is impossible because of rate conversion or a channel fold, use the existing conversion owner and report the reason. Supporting new source formats must not accidentally run `VibeApplyMixMap` over an integer buffer: that processing branch first obtains the float representation it needs.

Treat the Declick setting explicitly:

- With Declick off, bit-perfect transport performs cuts. The typed copy path handles steady playback and same-format gapless joins with no sample arithmetic.
- With Declick on, preserve today's 10 ms edges. Only the affected spans use a preallocated wide scratch buffer for ramping/summing. Float64 arithmetic can carry every Int32 input exactly before gain; integer output is rounded and saturated once at the edge's output depth. This is processed edge audio, not a bit-perfect claim.
- Split at exact ramp endpoints. The unchanged remainder of a callback returns to direct copy immediately; do not convert a whole callback or track merely because part of it fades.
- Keep several retiring voices and rapid seeks/skips correct. Cut/retire adoption occurs before deciding a span can be copied. No unchecked integer addition, clipping, or accidental second unity voice may hide inside the copy branch.

Preserve the current render admission, deferred teardown, decoder ownership, acquire/release publication and realtime compiler checks. This feature changes sample operations, not the lifetime protocol fixed by the PR reviews.

Remove `VibeBitPerfectDecodesAsInteger16`, `decodesAsInteger16OnQueueForFile:`, the `quantizesToInt16OnQueueForFile:` policy and per-voice/successor `quantizeToInt16` flags, and the expand-to-float loop when the general format path replaces them. Do not retain them as a parallel fallback mechanism.

### 4. Negotiate the whole output format and restore it safely

Evolve the existing format-selection rule to take the selected decoded PCM format plus known source precision. Rank candidates in this order: the same representation at the source rate; an exact widening or packing change; a playable converted fallback with its reason reported. A float32 lossy decode must not qualify for unchanged delivery merely because `VibeSourceBitDepth` returns zero. Integer output cannot generally preserve arbitrary float PCM.

Carry one resolved format choice through device preparation, bus construction, the output-unit client format and reporting. Reuse `followOutputFormatOnQueue:` and the existing rebuild/restore owner; generalize the rate-only entry points rather than adding a second rebuild sequence. Validate and read back the accepted client format after unit initialization.

One choice means one consistent set of stage formats, not an assumption that every stage has identical packing. Keep the native ring and HAL client representation where accepted even when the device uses a different container. If the output requires a representation change, perform it once at the existing output boundary, preferably as exact packing/widening. A narrowing or float-to-integer conversion belongs there, not back in the lossy decoder. For a Vibe-owned integer conversion, use a preconfigured bounded C operation with nearest-even rounding and saturation; keep implicit dither disabled. Preserve the float decoder's headroom until that boundary; never introduce dither into an exact copy or widening path. Converted fallback is reported as such, whether the conversion is Vibe's or the verified HAL conversion. No AVAudioConverter object calls, allocations or device queries may enter the render callback.

Audit the full ASBD: rate, integer/float representation, valid bits, signedness, packing/alignment, byte order, bytes per frame/packet, interleaving, channel count and channel layout. Extend `VibePCMFormatsMatch` where the current common-format comparison loses those distinctions. Never compare raw ASBD padding/reserved bytes.

Update master slicing, callback validation, silence filling and buffer offsets from negotiated geometry. Configure a matching planar HAL client format where supported; if interleaved delivery is required, use a bounded packing operation at the existing output boundary. Retain source channel count in the native bus when the device's verified map can carry it, including mono and supported multichannel layouts. A downmix or duplicated mono output remains a reported channel conversion.

Inspect virtual and physical stream formats. If a supported virtual-format change is needed and proves effective, retain its original value in the existing restoration owner alongside the physical format. Restore every format Vibe changes on mode off, device change and normal termination; retain failed obligations for retry. Watch same-rate format changes as well as nominal-rate changes through the existing listener lifecycle. Precision/packing changes must invalidate the prepared path even when the sample rate is unchanged.

If the only OS path includes float32, a 16/24-bit integer file may still be value-exact; a 32-bit integer file cannot receive an exact claim. A new direct AudioDeviceIOProc backend is outside this plan unless the initial measurements prove it necessary, effective, and worth replacing the HAL unit. Do not add another output backend speculatively.

### 5. Integrate transport, observers and truthful reporting

Use the existing playback settlement and `ensureSourceSegmentOnQueueRebuilt:` to change sample format, retaining position and Playing/Paused intent. Rebuild on a format change even when the rate is unchanged. A prefetch may discover the next format; it must not reconfigure the device while the current track is still playing.

Keep gapless when the next file can be carried by the current ring/client/device formats without numerical loss. For example, a wider integer carrier can accept a narrower integer successor by exact alignment, without renegotiation. If the selected policy requires a different carrier or device format, take the existing settlement path and accept a format-switch gap. Never promise gapless continuity through a DAC relock, and never silently reduce precision to preserve a splice.

Exercise same-rate depth changes, integer/float changes, channel-layout changes, short successors, late successor publication, cancellation after the decoder's claim, and mode/device changes during a pending open. The new format comparison must participate in the same successor compatibility decision already used by the bus and transport.

For the equalizer and beta signal capture, convert a read-only copy into the analyzer's current float representation. Allocate any scratch at setup; run no observation work when there is no demand. For float playback, retain the direct observation path. Meter toggles and diagnostics must never alter the bytes delivered to the carrier. Include diagnostic signal logging in the audit, not only the visible equalizer.

Extend the existing `audioPathSnapshot`, `dump_audio_path`, bit-perfect report and Advanced Audio rows to describe:

- Source codec, known source precision, and reader output format.
- Ring format, HAL client format, stream virtual format and physical format.
- Exact packing/widening, resampling, channel mixing, integer quantization, or narrowing where each occurs.
- Whether decoded samples are preserved; independently, whether the source is lossless and whether Declick modifies edges.

Keep the existing report as the single model. Lossy input retains its lossy-source explanation, while a narrowed decoder output reports the actual conversion instead of appearing fully preserved. Unknown source depth or an unconfirmed format cannot produce a precision guarantee. Apply new user-facing wording through `VibeStrings.h` and the existing localization workflow.

### 6. Prove preservation with an independent reference

Upgrade verification before enabling the new exact claims. The current manual pump reads `floatChannelData`, and `verify-bit-perfect.swift` uses `[[Float]]` and rejects references wider than float32. Merely removing that rejection would let the same truncation affect reference and capture and produce a false pass.

Extend the existing generator, pump, capture writer and comparator to retain Int32/Float64 precision end to end. Compare source integer values after explicitly verified packing/alignment, and float bit patterns on paths that claim representation preservation. Use original generated PCM as the reference for lossless codecs, not a second decode through the production reader. For lossy files, compare against the selected decoder's preserved PCM, not the pre-encode source.

Add cases to the existing test classes/files:

- All 16-bit values and adversarial 20/24/32-bit values: extrema, signs, one-LSB differences, seeded full-width noise and the existing `24,641,537` counterexample.
- Float32/Float64 values whose low bits reveal narrowing, signed zero, and finite headroom values that reveal integer clipping. Invalid/nonfinite input behavior is tested separately from an exact-audio claim.
- Ring wrap, partial/oversized render requests, underrun zero fill, end-of-file, per-buffer byte limits and unused hardware-channel silence for every supported representation.
- Exact playback from the first frame with Declick off; with it on, changes confined to the prescribed edge frames, including a ramp ending mid-callback.
- Meter/diagnostic capture enabled and disabled yielding identical playback output; no scratch conversion while inactive.
- Same-rate 16 → 24 → 32 → float transitions, rate changes, lossless/lossy boundaries, playing/paused mode toggles, seeks, EOF and rapid-skip storms.
- Real open-worker cancellation, late delivery, prefetch reuse and admission saturation with the new reader selection.
- Format-write rejection, accepted-but-ignored writes, failed read-back, same-rate external changes and restoration failure/retry.
- A held old render across a sample-format replacement, and slot reuse/snapshots under ThreadSanitizer, retaining the existing review regressions.

The comparator must fail when a single low bit is deliberately corrupted. A float32-only BlackHole loopback cannot validate full-width Int32 or Float64 output. Retain its useful existing coverage, and extend the existing driver-fixture generator or use an independently verified digital loopback whose playback **and capture** representations preserve the tested precision. If that coverage is unavailable, report software-path success and hardware precision as unverified; do not turn an expected downgrade into an exact pass.

Run `make test`, `make test-audio`, both Debug builds, `make analyze CONFIG=Release`, layout/vocabulary/strings/translation checks, and targeted ASan/TSan runs for the changed memory and threading paths. Run live acceptance with `make test-bit-perfect`, the hardware loopback/device checks and the iOS simulator loop using the [vibe-debug skill](../../.claude/skills/vibe-debug/SKILL.md). Use the existing stress workflow for repeated depth/rate/mode changes and device flaps; require settled teardown, no unexpected render refusals/dropouts and bounded resources. Hardware/driver acceptance remains opt-in, outside regular CI.

## Delivery and complexity budget

Use six reviewable commits following the steps above, keeping each commit's supported behavior and tests coherent. The capability/reference work lands first; native playback remains unselected until its reader, bus, carrier and report agree. Keep the final reporting and acceptance work in the same feature before presenting it as complete.

Budget: **zero new production files, zero new test files, zero new types**. Extend the existing bus/record/master/output structures and tests. If implementation reveals a need for a new type or backend, revisit the design before writing it.

The feature must remove the device-selected Int16 lossy special path and unify format choice, compatibility and precision reporting around the same actual PCM formats. Replace the existing float-only assumptions in place; do not maintain two transports, two decode schedulers, or competing format/rebuild owners. Re-read the touched files and consolidate after the behavior works.

Report the measured additions, deletions, net lines, new files and types for each implementation commit and the final feature. No implementation line-count estimate is presented as a result here. Completion means demonstrated source precision on supported paths, explicit reasons on converted paths, preserved transport/recovery behavior, and the wider comparator capable of catching the precision loss this work addresses.

This update checked the plan against the current implementation and tests. The earlier renderer’s green checks do not validate these proposed wider formats; the capability table, independent precision oracle and hardware acceptance still have to be established.
