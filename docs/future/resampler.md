# Future: the resampler's cost

**Status: under evaluation on `claude/r8brain-resampler` (2026-09-28).** r8brain-free-src is vendored and wired into the voice bus beside Apple's converter, selectable per player and switched live by a debug verb; **r8brain is the default on both platforms while it is tested**, Apple's converter one `set_resampler apple` away. Adopting r8brain would reverse the root `AGENTS.md`'s "Apple frameworks only" rule for playback, so the decision needs a reason stronger than CPU on a Mac. The measurements below say it costs nothing in quality and saves a great deal of CPU; what is left is the decision and an iOS device measurement. BASS was measured as a third candidate and ruled out (below).

## What Apple's converter costs

- **macOS** converts at `kAudioConverterQuality_Max`, always (`Audio/AGENTS.md`). A Time Profiler pass on an optimized build (silent real HAL, 44.1 kHz FLAC and MP3 into the built-in speakers at 48 kHz) put steady playback at 3.4% of one core, about 70% of it in Apple's `Resampler2::ConvertSIMD_SmallIntegerRatio`; FLAC decode was about 5%, the per-tick position UI about 3%. A file at the device's rate converts nothing.
- **iOS** lowered its default to `kAudioConverterQuality_High` for cost (#74): 1.8% of a core against 3.3% at Max on device, flat to 21 kHz with the same alias rejection. With r8brain the default, that trade and its Settings > Playback > Resampling picker are gone: Apple's converter, when selected, runs at Maximum on both platforms, and neither resampler has a quality setting.

## What is built

- **`Vibe/ThirdParty/r8brain/`**: r8brain-free-src at upstream `9e73d2dd`, with its PFFFT double-precision FFT (`Vibe/ThirdParty/AGENTS.md` has the build flags and why).
- **`Audio/AudioResampler.{h,mm}`**: `VibeConverter`, one opaque converter holding either resampler — Apple's `AudioConverterRef` (Mastering, Maximum) or r8brain (one `CDSPResampler24` per channel, pulled until a fill is met) — behind one create, fill (`AudioConverterFillComplexBuffer`'s shape), report and dispose. The bus's record holds one converter whichever it is, its one input proc (`VibeConverterSupplyInput`) drives both, and the stream-end, hold-open and flush logic reads only whether a converter is present.
- **`AudioPlayer.resampler`** (`VibeResamplerR8brain` default, `VibeResamplerApple`), pushed to the bus, applying from the next conversion; `dump_audio_path`'s conversion stage reports `resampler`.
- **Debug verbs** (both platforms, `DebugCommonVerbs.m`): `set_resampler <apple|r8brain>` switches and re-voices the current track at its position (a seek), so the change is heard at once; `dump_resampler_costs [reset]` reports each resampler's decode-thread CPU (the fill less the file reads inside it), the bus audio it produced and `corePercent`, the real-time cost, since the bus was made or the last reset. A rebuilt bus starts from zero.
- **`Tests/ResamplerQualityTests.m`** (`make test`): both resamplers through the production bus at 44.1→48, 48→44.1, 44.1→96, 96→44.1, 88.2→44.1, 96→48, 192→48 and 44.1→192, each held to the same bounds and the measured table attached to the result bundle as "resampler quality". It covers stepped sines (ripple, −0.1/−3 dB edges, THD, THD+N, stopband, phase delay and linear phase), a −60 dBFS noise floor, a continuous sweep to the source's Nyquist (every spur, in band and past the output's Nyquist), a band-limited sawtooth (everything that is not a harmonic), a twenty-tone null against the ideal with no fit, the round trip there and back, CCIF and SMPTE intermodulation, the impulse response's magnitude and phase every 10 Hz, a sine with +3 dBFS inter-sample peaks, silence, DC, exact duration and CPU. Each signal is synthesized once per rate pair and read by both resamplers, the CPU is read off those same conversions, and `testTheSpectralAnalysisResolvesBelowItsBounds` checks once that the sweep and saw analyses resolve at least 10 dB below every spur bound. `AudioVoiceBusTests`' `testTheResamplerContinuesAtEveryRatePairAndPullSize` runs both resamplers across a gapless boundary, the successor named early or late, at 63, 1024 and 4096-frame pulls. The metric list follows the measures practitioners name for SRC quality (dsp.stackexchange #92001; KVR "resampler quality" thread 614986), less memory footprint.

## Settings chosen, and why

From r8brain's README and class documentation:

- **`CDSPResampler24`** (`r8brr24`, about 180 dB stopband): documented for "24-bit resampling (including 32-bit floating point resampling)", and the bus is float32. The 206.91 dB default is for double-precision output nothing here keeps.
- **Transition band 1%**, half upstream's default (2%, the tight end of its "2 to 3 … most cases" range): −0.1 dB at 21.72 kHz and −3 dB at 21.83 kHz from a 44.1 kHz source, level with Apple's Mastering/Max filter (21.72 and 21.77 kHz) where 2% stopped at 21.39 and 21.61. Measured both ways through the whole quality suite: every noise, distortion and aliasing measure is unchanged (the mean shift per measure is under 0.4 dB either way, run-to-run noise at −150 dB), and the cost rises about 20%, a few thousandths of a percent of a core. The longer filter's startup is compensated inside, like the rest of its latency.
- **Linear phase**: the tests read zero phase delay and flat group delay at every pair, the latency removed inside.
- **`aMaxInLen` 4096**, the most the bus's proc supplies in one call.
- **`R8B_PFFFT_DOUBLE`** (Ooura's precision; the single-precision `R8B_PFFFT` is "not recommended" for professional audio) with **`PFFFT_ENABLE_NEON`**. PFFFT's NEON path is opt-in: without the macro arm64 silently builds its scalar fallback, which the vendored files' suppressed warnings hide (x86_64 picks SSE2 on its own). Intel IPP does not apply on Apple silicon.
- **`R8B_EXTFFT` off.** At 2% it paid (3–5% cheaper), but the 1% filter already runs large FFT blocks, and its extra zero-padding then costs 3–10% more at every pair (the table below). Measure it again if the transition band changes.
- **`-O3` in every configuration** for the two vendored translation units, since Debug is where the comparison runs and Apple's converter is always optimized.

**Performance audit.** Every SIMD path is live: r8brain's own NEON (`R8B_NEON`, from `__aarch64__`; SSE2 on x86_64) in the interpolator and half-band filters, and PFFFT's NEON FFT and block convolution once `PFFFT_ENABLE_NEON` is set (`clang -H` also confirms the vendored set is exactly what compiles). Upstream deliberately leaves its shuffled interpolation off on Apple silicon ("inefficient on M1"). A standalone benchmark of the production shim, 120 s per pair, median of three, % of one core, at the shipped 1% transition band (the last column is the 2% configuration it replaced):

| pair | **PFFFT NEON (shipped)** | NEON + EXTFFT | PFFFT scalar + EXTFFT | Ooura + EXTFFT | Ooura (stock) | at 2%: NEON + EXTFFT |
| --- | --- | --- | --- | --- | --- | --- |
| 44.1→48 | **0.092** | 0.102 | 0.110 | 0.098 | 0.107 | 0.077 |
| 48→44.1 | **0.098** | 0.105 | 0.116 | 0.101 | 0.114 | 0.080 |
| 96→44.1 | **0.119** | 0.126 | 0.139 | 0.126 | 0.142 | 0.095 |
| 44.1→96 | **0.124** | 0.131 | 0.141 | 0.127 | 0.137 | 0.106 |
| 192→48 | **0.113** | 0.117 | 0.126 | 0.117 | 0.127 | 0.096 |
| 44.1→192 | **0.175** | 0.181 | 0.202 | 0.191 | 0.211 | 0.152 |

A voice's first fill costs at most 0.45 ms, and making a resampler is under 0.1 ms, its filters cached across voices. Not taken: `-ffast-math`, which reorders float math in a path measured to −150 dB; and AVX for Intel Macs, which would need app-wide per-architecture flags where SSE2 already runs.

**No dither.** r8brain computes in double and hands float32 to a float32 bus, whose rounding error scales with the signal rather than sitting at a fixed floor dither would decorrelate: the −60 dBFS tone's residual is −209 dBFS with both resamplers, THD at 1 kHz near −160 dB, no truncation harmonics. The one integer requantization is the output's float → device conversion (`Audio/Mac/Devices/AGENTS.md`), downstream of the resampler and shared with Apple's path; dithering there is a separate question that matters only for a 16-bit device, and it could never apply under bit-perfect output. The README's PRVHASH suggestion is for requantizing to integers, which the resampler never does.

Nor would dither close the cases where Apple measures better (all below −157 dB). Each was rerun with r8brain in double precision, then rounded to float32 three ways, measured as the test measures (dB; the rounded column reproduces the test's figures):

| Case | Apple | r8brain in double | r8brain rounded (shipped) | r8brain, TPDF ±1 ULP |
| --- | --- | --- | --- | --- |
| CCIF IMD 44.1→48 | −173.1 | −172.4 | −167.5 | −173.7 |
| CCIF IMD 44.1→96 | −171.1 | −172.4 | −166.6 | −171.8 |
| SMPTE IMD 48→44.1 | −160.0 | −162.6 | −158.4 | −161.8 |
| THD 6 kHz 48→44.1 | −165.8 | −169.7 | −161.6 | −170.0 |
| THD 1 kHz 192→48 | −161.7 | −165.9 | −157.2 | −165.6 |
| *everything else (noise)* | | −153 to −180 | −150 to −157 | −147 to −148 |

In double r8brain matches or beats Apple in every case, so the gap is the rounding to float32, not the resampler. Dither decorrelates that rounding: the products drop 3–9 dB, past Apple's, but the broadband noise rises 3–9 dB, taking r8brain's worst THD+N from −149…−152 dB to Apple's −147…−148 and giving up its lead on the measures that count for eight cosmetic ones, for a random number per sample. Not taken.

## Measured (Apple Silicon Mac, unit test, Debug build with the resamplers optimized)

The charts are drawn from one `make test` run of `ResamplerQualityTests` and, for the frequency response, an impulse through each resampler at the bus's settings; `resampler/*.svg` are their light and dark versions.

<picture><source media="(prefers-color-scheme: dark)" srcset="resampler/cpu-dark.svg"><img alt="CPU per rate pair, Apple against r8brain" src="resampler/cpu-light.svg"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="resampler/response-dark.svg"><img alt="Frequency response from an impulse, 44.1 to 96 kHz" src="resampler/response-light.svg"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="resampler/noise-dark.svg"><img alt="Noise and distortion at every rate pair" src="resampler/noise-light.svg"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="resampler/alias-dark.svg"><img alt="Aliasing and intermodulation" src="resampler/alias-light.svg"></picture>


Worst THD+N across the passband tones, the multitone null against the ideal, the round trip, and the CPU to keep up in real time:

| pair | Apple THD+N | r8brain THD+N | Apple null | r8brain null | Apple round trip | r8brain round trip | Apple core % | r8brain core % |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 44.1→48 | −145.8 | −149.2 | −145.6 | −149.0 | −143.3 | −149.9 | 0.89 | 0.098 |
| 48→44.1 | −146.2 | −150.0 | −146.0 | −149.1 | −143.2 | −149.4 | 0.90 | 0.116 |
| 44.1→96 | −145.9 | −149.6 | −145.6 | −149.0 | −145.7 | −151.3 | 1.77 | 0.127 |
| 96→44.1 | −148.1 | −151.2 | −148.2 | −150.3 | −144.3 | −148.9 | 1.76 | 0.121 |
| 88.2→44.1 | −148.7 | −152.4 | −147.3 | −151.7 | −142.7 | −150.2 | 1.59 | 0.061 |
| 96→48 | −148.9 | −152.6 | −147.3 | −151.7 | −142.5 | −150.2 | 1.74 | 0.068 |
| 192→48 | −147.9 | −152.5 | −150.3 | −151.7 | −145.8 | −149.5 | 3.49 | 0.115 |
| 44.1→192 | −146.2 | −149.6 | −145.7 | −148.9 | −148.0 | −151.8 | 3.53 | 0.180 |

r8brain is equal or better on every quality measure, band edge included, and wins 90 of the 103 per-pair noise, distortion and aliasing comparisons (Apple 8, ties 5); Apple's eight are all between −157 and −173 dB. It rejects aliases 4–9 dB further and costs 8–30× less CPU (these unit-test figures run with the suite's classes in parallel; the benchmark above is the quieter measure); power-of-two ratios take its half-band path and are cheapest. In the running Debug app (`--no-audio-hw`, 96 kHz FLAC to the pump's 44.1 kHz), `dump_resampler_costs` read Apple at 4.1–4.7% of a core and r8brain at 0.56% (measured at 2%). Both pass every bound in the test; the full table is the result bundle's attachment.

**On an iPhone 17 Pro** (Debug build, 2026-09-28): a 44.1 kHz file to the phone's 48 kHz output, `--silent` (the real RemoteIO output, samples zeroed), 60 s per resampler, twice, `dump_resampler_costs` read over USB (the debug channel's command and response files copied through `devicectl device copy to/from` the app's `tmp/`):

| resampler | round 1 | round 2 |
| --- | --- | --- |
| r8brain | 0.54% of a core | 0.56% |
| Apple, Mastering at Maximum | 3.39% | 3.27% |

About 6× less; Apple's figure matches the 3.3% at Maximum #74 measured, and against the 1.8% of the old iOS default (High) r8brain is still about 3× less.

## BASS, measured and ruled out (2026-09-28)

**BASS 2.4.18.3 with BASSmix 2.4.13** (un4seen's macOS dylibs) was measured as a third candidate the same way: a decoding BASSmix mixer resampling a `STREAMPROC` source, run as two more converters behind the shim through the production bus in `ResamplerQualityTests`, and the same benchmark (120 s per pair, median of three, stereo noise through the shim). Neither the patch nor the binaries were kept. Two `BASS_ATTRIB_SRC` levels: **2, its default** with NEON (16-point sinc), and **6, its highest** — 7 and above render identically, and its 126-frame lookahead says 256 points. BASS removes its own latency (an impulse lands at N × ratio), holds DC gain at 1 and every conversion came out at exactly round(N × ratio).

**It passes 63 (16-point) and 67 (256-point) of the suite's 184 checks; Apple and r8brain pass all 184.** BASS columns are 16-point / 256-point, dB unless marked; "past Nyquist" is the sweep's worst alias when downsampling; CPU is the benchmark's, % of one core:

| pair | −3 dB Hz | worst THD+N | noise dBFS | past Nyquist | multitone null | CPU: Apple / r8brain / 16-pt / 256-pt |
| --- | --- | --- | --- | --- | --- | --- |
| 44.1→48 | 17398 / 21565 | −34.1 / −38.6 | −132.7 / −133.0 | — | −15.6 / −47.1 | 0.864 / 0.090 / 0.081 / 1.159 |
| 48→44.1 | 17213 / 21525 | −46.3 / −46.6 | −132.7 / −127.1 | −31.5 / −88.8 | −15.5 / −47.4 | 0.883 / 0.096 / 0.073 / 1.048 |
| 44.1→96 | 18667 / 21565 | −19.8 / −43.2 | −128.8 / −129.2 | — | −20.5 / −50.1 | 1.751 / 0.121 / 0.157 / 2.274 |
| 96→44.1 | 15899 / 20999 | −52.7 / −56.0 | −141.8 / −140.8 | −15.4 / −81.0 | −16.2 / −62.9 | 1.759 / 0.119 / 0.079 / 1.063 |
| 88.2→44.1 | 16107 / 21079 | −141.6 / −138.3 | −208.2 / −200.5 | −16.2 / −84.5 | −16.2 / −94.7 | 1.588 / 0.059 / 0.077 / 1.052 |
| 96→48 | 16810 / 22943 | −144.4 / −139.0 | −207.4 / −199.5 | −16.2 / −84.2 | −18.1 / −109.6 | 1.738 / 0.065 / 0.084 / 1.148 |
| 192→48 | 15436 / 21545 | −145.8 / −142.5 | −212.3 / −201.0 | −9.9 / −76.3 | −17.8 / −90.4 | 3.481 / 0.108 / 0.091 / 1.160 |
| 44.1→192 | 18667 / 21565 | −19.8 / −39.9 | −126.1 / −126.2 | — | −20.5 / −45.1 | 3.535 / 0.176 / 0.323 / 4.712 |

- **The passband.** At 16 points the response is never within 0.1 dB of flat, drooping from low frequencies to −3 dB at 15.4–18.7 kHz; at 256 points it holds 0.1 dB to 20.0–22.1 kHz, against 21.72 kHz for both of the others.
- **The filter's transition straddles the Nyquist**, so near-Nyquist content images and aliases: a 20 kHz tone's image at 24.1 kHz is why the worst THD+N sits at −20 to −56 dB wherever the ratio is not an integer. Downsampling, the worst alias is −10 to −32 dB at 16 points and −76 to −89 dB at 256, against −148 to −160 dB for Apple and r8brain.
- **A −126 to −142 dBFS noise floor at every non-integer ratio, at both levels**, where the others reach −206 to −212. The exact 2:1 and 4:1 ratios reach −200 to −212, so the floor is BASS's coefficient interpolation, not float32.
- **What it would sound like.** At 256 points, almost nothing: THD at 1 kHz is −113 to −153 dB, aliases −76 to −89 dB and the −130 dBFS floor are all below hearing, and the worst THD+N figures come from one image of a 20 kHz tone. At the default 16 points the treble is audibly down, −3 dB by 15–19 kHz. BASS is ruled out by the comparison, not by audibility: r8brain passes every bound at about the cost of BASS's lowest level.
- **Cost is the filter's length, not the shim.** BASS on its own (a noise `STREAMPROC` into the mixer, 60 s, median of three) reads what the shim does, doubling per level and scaling with the output rate — a direct convolution, where Apple and r8brain buy their long filters with multi-stage and FFT designs:

  | pair | 16-pt | 32-pt | 64-pt | 128-pt | 256-pt |
  | --- | --- | --- | --- | --- | --- |
  | 44.1→48 | 0.078 | 0.155 | 0.310 | 0.603 | 1.215 |
  | 48→44.1 | 0.072 | 0.145 | 0.276 | 0.551 | 1.100 |
  | 44.1→96 | 0.152 | 0.301 | 0.610 | 1.212 | 2.432 |
  | 96→44.1 | 0.074 | 0.142 | 0.280 | 0.558 | 1.105 |
  | 192→48 | 0.079 | 0.155 | 0.306 | 0.610 | 1.204 |
  | 44.1→192 | 0.309 | 0.628 | 1.256 | 2.420 | 4.855 |

  Against the others, 16 points costs about what r8brain does (0.7–1.8×) at far lower quality; 256 points costs about what Apple does (0.3–1.3×, more than Apple at 44.1→48, →96 and →192) and still misses Apple by 60–80 dB on aliasing and, at non-integer ratios, on noise. r8brain beats both levels on every measure at about the 16-point level's cost.
- **And it is closed source**, free only for non-commercial use: an App Store app needs a paid licence, on top of the playback rule r8brain already asks to reword.

## What is left

- **Battery on iOS**: measured for CPU (below); an Instruments energy pass over a long session is the one thing not yet done.
- **The decision**: keep r8brain the default, return it to opt-in, or remove it (iOS's Resampling setting is already gone, since only Apple's converter read it). Adopting it means rewording the root `AGENTS.md`'s playback rule. The SRC tail `TRAP:` describes Apple's flush bug, which r8brain does not have — but r8brain has no end-of-stream call at all, and feeding zeros until the input's length × ratio is out is upstream's own way to take its tail (`example.cpp`), so the bus's silence flush is already its native path and there is no Apple-only work to strip from it. If Apple's converter were removed, only the `TRAP:`'s wording would change.
- **Listening**: `set_resampler` switches live for an A/B at any rate the device refuses.
