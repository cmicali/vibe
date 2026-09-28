# Audio quality

This page explains what Vibe does to your music between the file and your speakers or DAC, what it never does, and how we know. Every number comes from an automated test that runs on every change, or from a measurement described next to it.

## The short version

- **Vibe does not change your audio unless it has to.** At full volume, with the pitch fader at 0% and no DJ effect in use, the samples that reach the output are exactly the samples decoded from the file. Turning the effects on without using them changes nothing: an effect that is not in use is removed from the audio path completely.
- **The one thing Vibe must sometimes change is the sample rate.** If a file's sample rate is different from your output's (a 44.1 kHz file on a 48 kHz output, say), Vibe converts it. It uses r8brain-free-src, which measured better than Apple's own converter on every test and uses a fraction of the CPU.
- **Bit-perfect output (macOS) avoids even that.** Vibe switches your device to the file's sample rate and to a format with enough bits, so the DAC receives the file's samples untouched.
- **Vibe never cuts lossy files down to 16 bits.** An AAC file decodes to more detail than 16 bits can hold, and Vibe keeps it. MP3s decode with Vibe's own full-precision decoder, dr_mp3, which keeps that detail too. Apple's built-in MP3 decoder, still a choice in Settings > Advanced on the Mac, decodes to exactly 16 bits.

## A few terms

- **Sample rate**: how many samples per second a recording has, such as 44.1 kHz (CD) or 96 kHz.
- **Bit depth**: how finely each sample is measured. 16 bits is CD quality; 24 bits and 32-bit float are finer. More bits means a lower noise floor.
- **Resampling**: converting audio from one sample rate to another. Doing it well takes careful filtering; doing it badly adds noise, distortion and false tones.
- **dB and dBFS**: a way of measuring levels. 0 dBFS is the loudest a digital signal can be. Each −20 dB is ten times quieter, so −140 dB is ten million times quieter than the music. Most of the errors measured here are far below anything you can hear; the numbers show which method is *more exact*.
- **Aliasing**: false tones that appear when sound above the new sample rate's limit is not filtered out. A good resampler removes them.

## Where the audio goes

<picture><source media="(prefers-color-scheme: dark)" srcset="audio-quality/signal-path-dark.svg"><img alt="The signal path in regular output, bit-perfect output and on iOS" src="audio-quality/signal-path-light.svg"></picture>

Every file is first decoded to 32-bit floating point. After that, each dashed step in the diagram only runs when it is needed. When it is not needed, it is skipped entirely. It does not "process at 100%"; the audio simply does not go through it.

- **Resample**: only when the file's sample rate is different from the output's.
- **Declick**: a 10-millisecond fade when you start, pause, seek or stop, so you never hear a click. It never touches the music in between. You can turn it off in Settings > Audio > Declick, and then those moments become clean cuts. A crossfade between tracks, if you turn one on, is the only longer fade.
- **Pitch**: only runs while the pitch fader is away from 0%. At 0% it is removed. We remove it rather than set it to "normal speed" because Apple's pitch processor still changes the samples slightly even at normal speed. The fader clicks into exactly 0% at its center.
- **DJ effects**: each effect only runs while you are using it, or while its echo or reverb is still dying away. Then it is reset and removed. When you release the low cut, it glides down, turns itself flat so there is no jump in sound, and a quarter of a second later is removed completely. We had a bug where a released low cut stayed in the path and slightly boosted the deep bass; a test now prevents that.
- **Volume**: Vibe's own volume fader. At full volume it does nothing at all.

The equalizer bars read a copy of the output. They never change it.

### Regular output

Vibe plays at whatever sample rate your output device is currently set to. A file at a different rate is converted once, by r8brain. The DJ effects and pitch fader are available. After Vibe, macOS mixes in any other apps' sound, converts to your device's format, and applies the system volume.

### Bit-perfect output (macOS)

Turn it on in Settings > Audio > Bit-perfect output. It is remembered for each device, and it needs a specific device chosen, not "System Output". Before each track plays, Vibe sets up your device:

- **The sample rate is set to the file's.** If your device can't run at that rate, Vibe uses the lowest exact multiple it can (a 44.1 kHz file on a device that only offers 88.2 kHz is doubled, cleanly). If there is no multiple either, it plays at the device's own rate, and the status says it is not bit-perfect.
- **The format is set to one with enough bits for the file.** A 16-bit file gets 16 bits, or 24 bits if the device has no 16-bit mode; that is still exact, because the extra bits are just zeros. A floating-point file gets a floating-point format. Files with more detail than 24 bits (32-bit integer or 64-bit float files, which are rare) are played at 24-bit precision, and the status says so.
- **Nothing else touches the audio.** The DJ effects and pitch fader are turned off. Crossfades are limited to the 10 ms declick, and with Declick off there is no fade at all.
- **Exclusive output** (a separate switch) locks the device so no other app can play through it at the same time.

The caption under the switch tells you whether the current track really is bit-perfect, and the format your device is using. If it isn't, it gives the reason: the sample rate, a change in the number of channels, a device that can't take the file's bit depth, a muted device, a volume below full (Vibe's, the system's, or the balance), another app holding the device, or a lossy file (which is decoded before it can be played, so it can't be "bit-perfect" to the file itself).

Only direct connections can be bit-perfect: built-in audio, USB, FireWire, Thunderbolt, PCI, HDMI, DisplayPort, AVB and virtual devices. Bluetooth and AirPlay can't, because they re-compress the audio, and neither can aggregate devices.

### iOS

On iPhone and iPad, iOS decides the output's sample rate based on where the sound is going (the speaker, headphones, a USB DAC). Vibe converts to that rate with r8brain when needed, and otherwise works like regular output. There is no bit-perfect mode on iOS.

## Lossy files and bit depth

**MP3 and AAC files don't have a bit depth.** They store the sound in a compressed form, and the decoder rebuilds the waveform when you play it. Some players send MP3s to the DAC as 16-bit on the idea that "MP3s are 16-bit". But a decoder that works at full precision produces more detail than 16 bits can hold, and its loudest moments can go slightly above the digital maximum. Cutting that down to 16 bits adds noise, and chopping off the peaks adds distortion.

So in bit-perfect mode, Vibe gives lossy files your device's floating-point format if it has one, and otherwise its highest bit depth. It never picks 16 bits just because a file is lossy.

How much that matters depends on the decoder. Apple's built-in decoders behave very differently:

| Apple's decoder | What it can output | Samples that fit exactly in 16 bits | Peaks above the maximum (a loud master) | What sending it as 16-bit would do |
| --- | --- | --- | --- | --- |
| AAC | 32-bit float or 16-bit (Vibe asks for float) | 0.04% | kept: up to +0.79 dBFS | add a layer of noise (at −101 dBFS) and chop off every peak |
| MP3 and MP2 | 16-bit only | 100% | chopped off by the decoder itself | nothing, played unchanged: the decoder already made it 16-bit |

**AAC** is the format of iTunes purchases, Apple Music downloads and most lossy files on Apple devices, and it is where this choice matters. A floating-point output keeps the decoded AAC exactly, peaks and all. A 24-bit output keeps everything within the maximum level, with any change far below hearing (at −149 dBFS), but like any integer format it still chops off the peaks above the maximum; only floating point keeps those. A 16-bit output would add noise that sits only 33 dB below a quiet fade-out, compared with 81 dB below at 24 bits.

**MP3 and MP2** are different with Apple's decoder, which is why Vibe no longer uses it by default:

- **Apple's MP3 decoder can only produce 16-bit samples.** It rounds the audio to 16 bits and chops off any peaks above the maximum before Vibe receives it. There is no setting to ask it for more; we checked what it offers, and a test now checks it on every build.
- **Asking for floating-point output doesn't change that.** A common tip says you can get full-precision MP3s from Apple by requesting 32-bit float output (through `ExtAudioFile` or `AudioConverter`). We tried both. You do get floating-point numbers back, but every one of them is still a 16-bit value, and the loud peaks are still chopped off at the maximum. Core Audio converts the decoder's 16-bit output to float after the fact; it can't restore what was already rounded away. Vibe already requests float output for every file, which is what keeps AAC's full detail.
- **So in bit-perfect mode, the output format makes no difference for MP3.** When Vibe plays the decoded samples unchanged (at the file's own sample rate, full volume, no effects), 16-bit, 24-bit and floating-point outputs all carry exactly the same samples. That stops being true once Vibe changes the audio: converting the sample rate, lowering the volume or using an effect produces new, full-precision samples that no longer fit in 16 bits, and a wider output keeps them.
- **The only way to get more out of MP3s is a different decoder.** A full-precision MP3 decoder (we compared ffmpeg's) keeps the detail below 16 bits (only 0.03% of its samples fit exactly in 16 bits) and the peaks (up to +0.49 dBFS on the same file). Vibe uses one by default on the Mac and the iPhone: dr_mp3, an open-source decoder that passes the official ISO accuracy test with a wide margin. On the Mac, Settings > Advanced > MP3 decoder can switch back to Apple's built-in one. The measurements are in `docs/future/mp3-decoder.md`.

*How this was measured:* we made a test track that behaves like mastered music: tones and noise at CD quality (16-bit, dithered), loud for ten seconds with peaks just under the maximum, then fading out to −70 dB. A second, louder version was squashed right up to the maximum, like a modern loud master. We encoded them as MP3 (LAME at 320 kbps and V2) and AAC (Apple's encoder at 256 kbps), then decoded them the way Vibe does, and with ffmpeg for comparison.

## The resampler

Changing the sample rate is the one job where Vibe has to change the samples, so we hold it to the strictest standard. Vibe used Apple's converter at its highest quality setting until r8brain-free-src replaced it. We measured both through Vibe's own playback engine, with the same test signals, at the eight rate changes a music library is likely to need:

- **Pure tones** at nearly full level: whether the volume stays flat up to 20 kHz, where the top end starts to roll off, how much distortion and noise is added (THD+N: "total harmonic distortion plus noise"), and whether timing stays exact.
- **A very quiet tone**, to measure the noise floor underneath quiet music.
- **A tone sweeping from low to high**, to catch any false tone at any frequency.
- **A sawtooth wave**, rich in overtones, to catch anything that isn't one of its overtones.
- **Twenty tones at once, compared with a perfect mathematical copy.** No adjustment is allowed, so any error in level, timing or tone counts. Then the same converted there and back again.
- **Two standard intermodulation tests** (CCIF and SMPTE), which show distortion created when two tones interact.
- **A single click (impulse)**, to measure the exact frequency and timing response.
- **A tone whose peaks fall between samples** and go above the maximum, to check nothing is clipped.
- **Silence, a steady level, the exact length, and CPU use.**

**r8brain was equal or better on every quality measure.** Across 103 measurements of noise, distortion and false tones, it did better in 90. Apple's converter did better in 8, all at levels between −157 and −173 dB, which is far below hearing. r8brain also removed false tones 4–9 dB more thoroughly, and used 8 to 30 times less CPU.

In all four charts below, **lower is better** (less noise, less distortion, less CPU).

<picture><source media="(prefers-color-scheme: dark)" srcset="audio-quality/response-dark.svg"><img alt="Frequency response from an impulse, 44.1 to 96 kHz" src="audio-quality/response-light.svg"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="audio-quality/noise-dark.svg"><img alt="Noise and distortion at every rate pair" src="audio-quality/noise-light.svg"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="audio-quality/alias-dark.svg"><img alt="Aliasing and intermodulation" src="audio-quality/alias-light.svg"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="audio-quality/cpu-dark.svg"><img alt="CPU per rate pair, Apple against r8brain" src="audio-quality/cpu-light.svg"></picture>

The key numbers. The first six columns are in dB, where **more negative is better**: the worst distortion plus noise across all the tones, the twenty tones compared with their perfect copy, and the same after converting there and back. The last two columns are the share of one CPU core needed to keep up in real time, where **lower is better**; they were measured while other tests ran alongside, so they are a little noisy.

| Rate change | Apple distortion + noise | r8brain distortion + noise | Apple twenty tones | r8brain twenty tones | Apple there and back | r8brain there and back | Apple CPU % | r8brain CPU % |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 44.1→48 | −145.8 | −149.2 | −145.6 | −149.0 | −143.3 | −149.9 | 0.89 | 0.098 |
| 48→44.1 | −146.2 | −150.0 | −146.0 | −149.1 | −143.2 | −149.4 | 0.90 | 0.116 |
| 44.1→96 | −145.9 | −149.6 | −145.6 | −149.0 | −145.7 | −151.3 | 1.77 | 0.127 |
| 96→44.1 | −148.1 | −151.2 | −148.2 | −150.3 | −144.3 | −148.9 | 1.76 | 0.121 |
| 88.2→44.1 | −148.7 | −152.4 | −147.3 | −151.7 | −142.7 | −150.2 | 1.59 | 0.061 |
| 96→48 | −148.9 | −152.6 | −147.3 | −151.7 | −142.5 | −150.2 | 1.74 | 0.068 |
| 192→48 | −147.9 | −152.5 | −150.3 | −151.7 | −145.8 | −149.5 | 3.49 | 0.115 |
| 44.1→192 | −146.2 | −149.6 | −145.7 | −148.9 | −148.0 | −151.8 | 3.53 | 0.180 |

**On an iPhone 17 Pro**, converting a 44.1 kHz file to the phone's 48 kHz output: r8brain used 0.54–0.56% of a CPU core, and Apple's converter 3.27–3.39%. That's about six times less.

### How r8brain is set up

- **Its highest-precision setting**, made for 24-bit and floating-point audio. It removes false tones by about 180 dB.
- **A steep filter at the top of the range.** From a 44.1 kHz file, the response stays flat to 21.72 kHz and is 3 dB down at 21.83 kHz, matching Apple's converter. r8brain's default setting starts rolling off earlier, at 21.39 kHz. The steeper setting costs about 20% more CPU, which is still tiny.
- **Exact timing.** Every frequency comes out at the same moment it went in, with no delay added.
- **Full 64-bit precision internally**, rounded once to 32-bit float at the end.

**Why there is no dither.** Dither is a small amount of added noise that hides the effect of rounding. r8brain works at 64-bit precision and rounds once to 32-bit float, and that rounding error is already tiny: a very quiet tone's error measures −209 dBFS. We tested whether dither would help in the few cases where Apple's converter measured better. It would lower those particular distortion figures, but it would also raise the overall noise by the same amount, which makes the more important measurements worse. In the table, **more negative is better**:

| Measurement | Apple | r8brain before its final rounding | r8brain as shipped | r8brain with dither |
| --- | --- | --- | --- | --- |
| CCIF intermodulation, 44.1→48 | −173.1 | −172.4 | −167.5 | −173.7 |
| CCIF intermodulation, 44.1→96 | −171.1 | −172.4 | −166.6 | −171.8 |
| SMPTE intermodulation, 48→44.1 | −160.0 | −162.6 | −158.4 | −161.8 |
| Distortion of a 6 kHz tone, 48→44.1 | −165.8 | −169.7 | −161.6 | −170.0 |
| Distortion of a 1 kHz tone, 192→48 | −161.7 | −165.9 | −157.2 | −165.6 |
| Everything else (noise) | | −153 to −180 | −150 to −157 | −147 to −148 |

Before its final rounding, r8brain matches or beats Apple's converter everywhere, so these few gaps come from rounding to 32-bit float, not from r8brain itself. All of them are far below hearing.

**CPU use in detail**, from a separate, quieter benchmark (two minutes of stereo audio per rate change, the middle of three runs, as a share of one CPU core; **lower is better**). The first column is what Vibe ships; the others are setups we tried and rejected:

| Rate change | Shipped | With extra FFT padding | With padding, without Apple silicon's vector instructions | With a different FFT library | r8brain's default filter, with padding |
| --- | --- | --- | --- | --- | --- |
| 44.1→48 | **0.092** | 0.102 | 0.110 | 0.107 | 0.077 |
| 48→44.1 | **0.098** | 0.105 | 0.116 | 0.114 | 0.080 |
| 96→44.1 | **0.119** | 0.126 | 0.139 | 0.142 | 0.095 |
| 44.1→96 | **0.124** | 0.131 | 0.141 | 0.137 | 0.106 |
| 192→48 | **0.113** | 0.117 | 0.126 | 0.127 | 0.096 |
| 44.1→192 | **0.175** | 0.181 | 0.202 | 0.211 | 0.152 |

r8brain's default filter is cheaper, but it starts rolling off the top end earlier, so we use the steeper one. Starting a conversion takes under half a millisecond.

### BASS, tested and not used

**BASS** (version 2.4.18.3, with its BASSmix add-on) is a popular audio library used by many players. We tested its resampler the same way, at its default setting (16-point) and its highest (256-point). It keeps the level and length right, but it passed only 63 (default) and 67 (highest) of the 184 checks. Apple's converter and r8brain both pass all 184.

In both charts, **lower is better**.

<picture><source media="(prefers-color-scheme: dark)" srcset="audio-quality/resamplers-quality-dark.svg"><img alt="Noise, distortion and aliasing for Apple, r8brain and BASS at every rate pair" src="audio-quality/resamplers-quality-light.svg"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="audio-quality/resamplers-cpu-dark.svg"><img alt="CPU to resample in real time for Apple, r8brain and BASS" src="audio-quality/resamplers-cpu-light.svg"></picture>

The numbers, shown as default / highest. The first column is where the top end is 3 dB down (**higher is better**, up to about 22 kHz). The rest are in dB (**more negative is better**). "False tones" is the loudest false tone when converting down to a lower rate:

| Rate change | Top end, −3 dB (Hz) | Worst distortion + noise | Noise under a quiet tone (dBFS) | False tones | Twenty tones vs. perfect copy |
| --- | --- | --- | --- | --- | --- |
| 44.1→48 | 17398 / 21565 | −34.1 / −38.6 | −132.7 / −133.0 | — | −15.6 / −47.1 |
| 48→44.1 | 17213 / 21525 | −46.3 / −46.6 | −132.7 / −127.1 | −31.5 / −88.8 | −15.5 / −47.4 |
| 44.1→96 | 18667 / 21565 | −19.8 / −43.2 | −128.8 / −129.2 | — | −20.5 / −50.1 |
| 96→44.1 | 15899 / 20999 | −52.7 / −56.0 | −141.8 / −140.8 | −15.4 / −81.0 | −16.2 / −62.9 |
| 88.2→44.1 | 16107 / 21079 | −141.6 / −138.3 | −208.2 / −200.5 | −16.2 / −84.5 | −16.2 / −94.7 |
| 96→48 | 16810 / 22943 | −144.4 / −139.0 | −207.4 / −199.5 | −16.2 / −84.2 | −18.1 / −109.6 |
| 192→48 | 15436 / 21545 | −145.8 / −142.5 | −212.3 / −201.0 | −9.9 / −76.3 | −17.8 / −90.4 |
| 44.1→192 | 18667 / 21565 | −19.8 / −39.9 | −126.1 / −126.2 | — | −20.5 / −45.1 |

What the numbers mean:

- **The top end.** At its default setting, BASS starts rolling off the treble early: it is 3 dB down by 15–19 kHz, which you can hear. At its highest setting it stays flat to 20–22 kHz, like the others.
- **False tones near the top.** BASS's filter doesn't fully block sound near the sample rate's limit, so some of it comes back as false tones. That is why a 20 kHz test tone shows so much distortion. When converting down, BASS's loudest false tone is at −10 to −32 dB at the default setting and −76 to −89 dB at the highest. Apple's converter and r8brain keep it at −148 to −160 dB.
- **A higher noise floor.** For most rate changes BASS adds noise at about −126 to −142 dBFS, where the others reach about −206 to −212. For exact 2:1 and 4:1 changes, BASS is as quiet as the others, so this noise comes from how BASS calculates in-between samples, not from a lack of precision.
- **What you would hear.** At the highest setting, almost certainly nothing; these errors are below hearing. At the default setting, slightly dull treble. We didn't choose BASS because r8brain is more accurate on every measure, and at its highest setting BASS also uses more CPU than r8brain.
- **Why BASS gets expensive.** BASS's CPU use doubles with each quality step, because it does the filtering the direct way. Apple's converter and r8brain use smarter methods that stay cheap even with steep filters. BASS on its own, as a share of one CPU core (**lower is better**):

  | Rate change | 16-point | 32-point | 64-point | 128-point | 256-point |
  | --- | --- | --- | --- | --- | --- |
  | 44.1→48 | 0.078 | 0.155 | 0.310 | 0.603 | 1.215 |
  | 48→44.1 | 0.072 | 0.145 | 0.276 | 0.551 | 1.100 |
  | 44.1→96 | 0.152 | 0.301 | 0.610 | 1.212 | 2.432 |
  | 96→44.1 | 0.074 | 0.142 | 0.280 | 0.558 | 1.105 |
  | 192→48 | 0.079 | 0.155 | 0.306 | 0.610 | 1.204 |
  | 44.1→192 | 0.309 | 0.628 | 1.256 | 2.420 | 4.855 |

- **Licensing.** BASS is closed source and free only for non-commercial use.

## How we test it

These tests run automatically on every change, without any audio hardware:

- **Every sample is checked.** The real player plays into memory, and every sample of every channel is compared with the file. This covers 44.1 kHz to 192 kHz; 16-bit, 24-bit and float; mono and stereo; and every supported format. Bit-perfect and regular playback must match the file exactly. The only exception is the first 50 ms, while the declick fades in, and not even that when Declick is off. The check catches a single changed bit, a dropped or repeated sample, swapped channels, or flipped polarity.
- **Unused features change nothing.** The file must play back exactly with the effects turned on but unused, with the equalizer bars running, with the pitch fader at 0%, and after every effect has been used and released: each effect key, the boost, the iOS effects pad, and an effect switched off partway through. "Exactly" means exactly, not "within a tolerance". A released low cut left in the path changes the audio by about 0.0000000000007, and only an exact comparison catches that.
- **The resampler** must pass every measurement above at all eight rate changes. It must also continue seamlessly across gapless track changes, and match the same conversion done separately from the player, exactly.
- **Lossy files** must match their own decoded audio exactly. AAC is allowed a difference of four tiny rounding steps (below −126 dBFS), because two runs of Apple's AAC decoder can differ that much. The test also checks which formats Apple's decoders can output, so we'll know if that ever changes.

On macOS there is also an optional test that plays through a real output device and records it back, to prove the samples reach the hardware as rendered.
