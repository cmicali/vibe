# Future: the resampler's cost

**Status: not planned (measured 2026-09-28).** Apple's converter is most of what ordinary playback costs whenever the device runs at another rate than the file, and a third-party resampler measured far cheaper at the same quality. Adopting one would reverse the root `AGENTS.md`'s "Apple frameworks only" rule for playback, so it needs a reason stronger than CPU on a Mac.

## What it costs

- **macOS** converts at `kAudioConverterQuality_Max`, always (`Audio/AGENTS.md`). A Time Profiler pass on an optimized build (silent real HAL, 44.1 kHz FLAC and MP3 into the built-in speakers at 48 kHz) put steady playback at 3.4% of one core, about 70% of it in Apple's `Resampler2::ConvertSIMD_SmallIntegerRatio`; FLAC decode was about 5%, the per-tick position UI about 3%. A file at the device's rate converts nothing.
- **iOS** lowered its default to `kAudioConverterQuality_High` for cost (#74): 1.8% of a core against 3.3% at Max on device, flat to 21 kHz with the same alias rejection.

## The alternative

r8brain-free-src matched Apple's quality and cost 4–8× less CPU than Apple at High. The bus already hides the converter behind `VibeConverterSupplyInput` and the voice's chunk production (`AudioVoiceBus.m`), so a swap is local; the SRC tail `TRAP:` there is Apple's behavior and would need re-measuring, not porting. Worth revisiting if iOS battery life under long sessions becomes a complaint, or if a profile shows conversion dominating somewhere the rate cannot be matched.
