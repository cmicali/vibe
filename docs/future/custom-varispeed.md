# Future: a custom varispeed for the pitch fader

**Status: not started (measured 2026-10-07).** The pitch fader runs Apple's Varispeed unit. It measures about 50 dB worse than r8brain, the converter Vibe uses for sample rates. Its errors are far below hearing. A custom converter of about 150 lines matches r8brain for 0.3% of a CPU core. Do it only to hold the pitch path to the standard `docs/audio-quality.md` sets. It is low priority.

## What the fader does today

The fader sets the playback rate to 1 + pitch/100, up to ±8% or ±16%. Pitch and tempo move together, as on a turntable. `AudioPlayer+Pipeline.m` hosts Apple's Varispeed unit at its highest render quality (`hostVarispeedOnQueueWithFormat:`). The render puts the unit in the chain only while the pitch is off zero. It runs after the voice bus, at the output's rate. A file at another rate is therefore converted twice: once by r8brain and once by the Varispeed. The fader exists only on macOS, and never under bit-perfect output.

## Measurements

`scripts/varispeed-quality/` hosted the Varispeed as Vibe does: 48 kHz stereo float32, highest render quality, at most 4096 frames per slice, rendered in 512-frame slices. It did not run through Vibe's player. The reference is r8brain at the same fixed ratio, set up as `Audio/AudioResampler.mm` sets it up. Each output tone is fitted at its exact frequency, and everything left after the fit counts as distortion and noise. The fit lets each tone's gain and phase float. These numbers are therefore more lenient than `ResamplerQualityTests`' and cannot be compared with the tables in `docs/audio-quality.md`. The float32 test signal sets the floor: about −150 dB for one tone and −141 dB for twenty. Everything ran on an M4 Max.

Ranges cover fader settings from −16% to +16%. Tones at a filter's edge are left out. **More negative is better.**

| Measurement | Apple Varispeed | Custom converter | r8brain, fixed ratio |
| --- | --- | --- | --- |
| Distortion + noise, 1 kHz tone at −1 dBFS | −129 to −136 dB | −150 to −151 dB | −150 to −151 dB |
| Same, 10 kHz | −93 to −99 dB | −151 to −152 dB | −150 to −152 dB |
| Same, 20 kHz | −83 to −87 dB | −149 to −151 dB | −150 to −152 dB |
| Twenty tones at once | −96 to −99 dB | −141 dB | −141 dB |
| Noise under a 1 kHz tone at −60 dBFS | −189 to −196 dBFS | −209 to −211 dBFS | −209 to −210 dBFS |
| False tones when speeding up | −114 to −134 dB | −148 to −154 dB | −153 to −155 dB |

**Apple's error rises 12 dB per octave.** That is the shape of an interpolation error, such as a coarse filter table. No setting fixes it. The render quality is already at its maximum. Asking the unit for Apple's Mastering converter (`kAudioUnitProperty_SampleRateConverterComplexity`) fails with `kAudioUnitErr_InvalidProperty` (−10879).

**Apple's filter also cuts the top end early.** The level of a 20 kHz output tone, in dB:

| Fader | Apple Varispeed | Custom converter | r8brain, fixed ratio |
| --- | --- | --- | --- |
| +16% | −0.33 | 0.00 | 0.00 |
| +8% | −0.77 | 0.00 | 0.00 |
| +1% | −1.49 | 0.00 | 0.00 |
| −1% | −0.05 | 0.00 | 0.00 |
| −4% | −0.84 | −0.04 | 0.00 |
| −8% | −7.8 | −3.0 | 0.00 |

At 21 kHz, Apple's filter is 4 to 12 dB down when speeding up. The custom one is 0.12 dB down. Slowing down moves the top of the input down with everything else. At −16%, nothing above 20.2 kHz is left for any converter. A 44.1 kHz file carries nothing above about 21.8 kHz after r8brain. At −8% that edge lands at 20.1 kHz.

**Apple's unit applies a new rate as a step.** The test dragged the fader from 0 to +8% over 2 s and updated the rate every 512 frames. Under Apple's unit, side tones sat 60 to 63 dB below a 1 kHz or an 8 kHz tone. The custom converter stepped the same way measured the same. Ramped across each slice, it measured −98 dB at 8 kHz and −116 dB at 1 kHz.

**Cost**, as a share of one CPU core: medians of five 30-second stereo runs. **Lower is better.**

| Fader | Apple Varispeed | Custom, double | Custom, float32 | r8brain, fixed ratio |
| --- | --- | --- | --- | --- |
| −8% | 0.081% | 0.256% | 0.135% | 0.094% |
| +4% | 0.081% | 0.316% | 0.157% | 0.104% |
| +16% | 0.081% | 0.364% | 0.171% | 0.195% |

Float32 sums and a float32 table halve the cost. Distortion rises to −140 dB, twenty tones to −138 dB, and false tones to −141 dB. That is still about 40 dB better than Apple's.

Apple's unit declares 48 input frames of latency. The custom converter's latency is its kernel's half-width: 64 input frames, and 75 at +16%.

## Why not r8brain

- **Its ratio is fixed when it is made.** `CDSPResampler` takes both rates in its constructor and builds its filter chain for that pair.
- **It runs ahead of playback.** The voice bus converts on the decode queue, into a ring the render reads later. Folding the pitch into that conversion would make the fader lag by the decode-ahead. The alternative is a new converter on every fader tick. A new converter allocates and must be primed every time.
- **Its method could take a varying step in principle.** It oversamples by two and then interpolates with short fractional-delay filters. Making that step vary means carrying our own changes to its internals. A custom converter is smaller than that.

## Why not a library

- **libsamplerate** (BSD 2-clause) handles a changing ratio and ramps it smoothly. Its best mode is [documented at 97 dB SNR](https://libsndfile.github.io/libsamplerate/api_misc.html). That is Apple's level, not r8brain's.
- **libsoxr** has an experimental variable-rate mode. It is [LGPL 2.1](https://ports.macports.org/port/soxr/summary/). App Store static linking cannot meet the LGPL. This is why Vibe uses TagLib under the MPL.
- **zita-resampler** has a variable-ratio class. It is GPL.
- **BASS** was already rejected for sample rates on quality and license (`docs/audio-quality.md`).

## The custom converter

The prototype that produced the numbers above:

- **A Kaiser-windowed sinc**, β 15.6 (about 150 dB of stopband), with 64 zero crossings on each side: 128 taps.
- **A cutoff of 22 kHz at 48 kHz** (the −6 dB point). The passband is flat to 20 kHz. The stopband starts at 23.9 kHz.
- **A kernel stretched by the ratio above 1.** The cutoff then follows the output's Nyquist, and false tones stay out. At +16% the kernel has 150 taps.
- **A polyphase table of 128 phases per input sample.** A cubic combines the four phases around the position into one weight vector. Both channels then take one dot product each with their history.
- **Sums in double precision.**
- **The ratio ramped across each slice**, from the last value to the new one.

A ratio of 1 or less uses one table. A ratio above 1 needs a table for its stretch, which takes 0.08 to 0.10 ms to build. The table interpolation is not the limit. Cubic interpolation over 128 phases measured the same as 512 phases and as an 8192-point linear table.

A wider kernel failed. Ninety-six zero crossings with the cutoff at 22.9 kHz kept 20 kHz flat at −8%. But its stopband started too close to Nyquist, and at +1% a 23.8 kHz input came back at −101 dB. Tune the cutoff and the width together if the top end matters.

## What it changes in Vibe

- **`VibeVarispeedHost` holds the table, the position, and the ratio** in place of the `AudioUnit`. No new type is needed.
- **Removed:** hosting the unit and reading back its quality, the unit's input callback (`VibeMasterBusVarispeedInput`), the priming render in `VibeMasterBusEngageVarispeed`, whose outputs are discarded, and the latency read.
- **The history ring becomes the converter's input.** Engaging sets the position in it. Disengaging still replays the frames the converter read ahead.
- **The zero-pitch bypass stays.** This kernel is not a pass-through at a ratio of 1 either.
- **`applyPitchOnQueue:` builds a table for a ratio above 1** on the player queue and publishes it through the hosting's pointer. The old table is freed once the render has left it (`afterRenderLeavesOnQueue:`), as a hosting is now.
- **The latency changes.** The `TRAP:` on the Signal probe's padding (`AudioPlayer+Diagnostics.m`, `Audio/AGENTS.md`) says 48 frames at any ratio. It becomes the kernel's half-width, which grows above a ratio of 1. Change both copies.
- **`hostedUnitCountOnQueue` loses the Varispeed.**
- **The pitch path gets a quality test.** Today `testPitchFrequencyDurationAndReset` checks only frequency and length. Measure ±1%, ±8%, and ±16% in the style of `ResamplerQualityTests`. Keep `testZeroPitchRendersTheBusDirectlyAndTogglesAreClickFree`.
- **`docs/audio-quality.md`** gets the measurements and a new Pitch bullet.

It fits in `AudioPlayer+Pipeline.m` with no new files. The kernel design could move to a `*Math.h` seam if a test needs it alone. That would be the one new file, and it must be argued. Expect about 150 lines in and 80 out.

## Will anyone hear it?

Probably not. Apple's worst error is −84 dB, under a full-scale 20 kHz tone. Music carries little energy there. Below 1 kHz the error is under −129 dB. The top end it loses is mostly above 20 kHz. The side tones during a drag are the most audible part, and they last only while the fader moves.

The case for doing it is consistency. Vibe chose r8brain over Apple's converter on a margin of 3 to 8 dB near −145 dB. By that standard, the pitch stage is the weakest in the chain by about 50 dB. It is also the one stage of ordinary playback that `docs/audio-quality.md` does not measure.

## Key lock is a different feature

Key lock changes the tempo and keeps the key. It needs a time-stretcher, not a resampler. r8brain cannot do it. The options are Apple's built-in time-pitch unit, [Signalsmith Stretch](https://doc.qt.io/QT-6/qtmultimedia-attribution-signalsmith-stretch.html) (MIT), Rubber Band ([GPL or a paid license](https://bugs.openmpt.org/view.php?id=1808)), and SoundTouch (LGPL, with libsoxr's App Store problem). Every time-stretcher adds audible artifacts. A varispeed adds none.

## Measuring again

`scripts/varispeed-quality/run.sh` builds the measurement tool into `build/varispeed-quality/` and runs it. It needs no app and no audio device.

- `run.sh quality apple r8brain custom custom-float` prints each engine's tables at every fader setting.
- `run.sh drag` measures the side tones while the fader moves.
- `run.sh cpu` times all four engines.

`VS_T`, `VS_FC`, `VS_BETA`, and `VS_P` change the custom kernel. A new design can be tried this way before it is built into the pipeline. The custom engine in `measure.c` is the shape a render would run: the polyphase table, the cubic across phases, and the ramp across each slice.
