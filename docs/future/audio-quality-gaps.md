# Future: audio quality gaps

**Status: Not built.** This is an audit of the playback path from decode to device, made in October 2026. The vendored libraries hold up. Replacing any of them would not raise quality anyone could measure. The gaps are elsewhere. Two of them are bugs in Apple decoders Vibe still uses. Both were reproduced on macOS 27.0.1 on an M1 Max. [audio-quality.md](../audio-quality.md) has the measurements behind the current choices.

**Suggested order:** findings 1 and 2 first. They are bugs. Then 4, then the depth rule in 6. Decide 3 and 5 together. Both need peak handling.

## The current choices

| Component | Verdict | Why |
| --- | --- | --- |
| dr_mp3 | Keep | It is 105 times inside the ISO limit. FFmpeg, the best, is 112 times. The difference is 0.6 dB at −141 dBFS. mpg123 is LGPL. That is awkward to link statically in an App Store app. |
| dr_flac, dr_wav | Keep | They are lossless and match Apple's decoders bit for bit on more than 12,000 library files. libFLAC cannot sound better. Vibe's copies are already more robust than upstream's. |
| r8brain | Keep | Its error is already at the floor set by float32 output. libsoxr is LGPL and no better. libsamplerate and Apple's converter measure worse. |
| The pitch fader's converter | Keep | It measures about −150 dB, the same float32 floor. |
| Apple's AAC and ALAC decoders | Keep | AAC decodes to float and keeps overs. ALAC is lossless. FAAD2 is GPL. fdk-aac has license problems and no quality advantage. |
| Apple's Opus decoder | Keep, and fix the gain | It decodes to float and handles pre-skip. See finding 2. |
| Apple's Vorbis decoder | Replaced by libvorbis | Its samples are accurate, but its timeline is wrong. See finding 1. |

**Apple's Opus and Vorbis decoders have no 16-bit trap.** Asked for their output formats (`kAudioCodecPropertySupportedOutputFormats`, as `testAppleMPEGDecodersOutputInt16OnlyOnArm64AndAACOutputsFloat` asks the MPEG and AAC decoders), both offer only 32-bit float on arm64. Their decodes of the test files below had 0.01% of samples on the 16-bit grid, the same as the source. Apple's Opus decode matched libopus's to −138 dB, with the same length.

## 1. Apple's Vorbis decoder drops the first 128 frames (macOS)

**Every Ogg Vorbis file tested lost its first 128 frames.** In Apple's decode, sample *i* is the source's sample *i* + 128. ffmpeg's decode of the same file lines up with the source exactly.

| Encoder | Rate | Frames Apple declares | Frames Apple decodes | Shift |
| --- | --- | --- | --- | --- |
| libvorbis, q6 | 48 kHz | 240,000 | 239,872 | 128 |
| libvorbis, q9 | 48 kHz | 240,000 | 239,872 | 128 |
| libvorbis, q3 | 44.1 kHz | 220,500 | 220,500 | 128 |
| ffmpeg's own Vorbis encoder | 44.1 kHz | 220,544 | 220,544 | 128 |

The 48 kHz files decode 128 frames shorter than Apple's own declared length. The 44.1 kHz file keeps its length. It ends with 128 frames from past the end of the audio. Those should have been trimmed.

- **What a listener got:** about 3 ms cut from the start of every track. On a gapless Vorbis album, every join skipped 3 ms of the next track. At 44.1 kHz the track before the join also ended with 3 ms that should have been trimmed.
- **Why the tests missed it:** `testOggVorbis` compared the player against `AudioFileHandle`'s own decode. That decode was Apple's. The shift was on both sides.

**Fixed.** libvorbis and libogg are vendored (`Vibe/ThirdParty/vorbis/`, `ogg/`) and decode Ogg Vorbis on both platforms, through the handle's callbacks in `AudioFileHandle+Stream.m`. CoreAudio's parser never opens a Vorbis file. So Vorbis now plays on iOS too. `testOggVorbis` checks the decode against the source and against Apple's decode moved by 128 frames. That half is a canary, which fails once Apple's decoder lines up.

## 2. CoreAudio ignores the Opus header's output gain

**An Opus file's header carries an output gain, and players must apply it** ([RFC 7845, section 5.1](https://www.rfc-editor.org/rfc/rfc7845#section-5.1)). It is a signed 16-bit value in 1/256 dB at byte 16 of the `OpusHead` packet. Loudness taggers can write it in place of a tag.

A test file's header gain was set to −6 dB. ffmpeg, through libopus, played it 6.0 dB quieter. Apple's decoder played it unchanged. So Vibe played such files at the wrong level.

**Fixed.** `AudioFileHandle` reads the gain when the file opens and scales Apple's decode by it (`VibeOpusOutputGain`). Its samples are then bounded at +12 dBFS, as a damaged MP3 frame's are. `testOpusPlaysAtItsHeaderOutputGain` checks three gains, and ends with a canary that fails once Apple applies the gain itself.

R128 gain tags in Opus files are relative to this header gain. Finding 3 would need it applied first.

## 3. No loudness normalization

This is not a bug. It is the largest missing feature for listening quality. Tracks from different masters differ in loudness by 10 dB or more. Users ride the volume to even them out. Vibe reads no ReplayGain or R128 tag.

- **Vibe's float path is the right base.** A positive gain cannot clip inside Vibe. It can still clip at the device (finding 5).
- **The gain belongs to each voice, not to the master volume.** A crossfade overlaps two tracks at different gains. The voice mix already multiplies each voice by its gain. The scale can join that multiply.
- **The gapless successor is the hard part.** It continues on its predecessor's voice. So in track mode the scale must change at the boundary the decoder publishes. In album mode, the tracks of one album share a gain, and a gapless album needs no change.
- **The tags:** `REPLAYGAIN_TRACK_GAIN`, `_ALBUM_GAIN` and their peaks, and `R128_TRACK_GAIN` and `R128_ALBUM_GAIN` in Opus. TagLib already parses the frames and comments that hold them. Use the peak tags to cap a positive gain.
- **Untagged files** could be measured with libebur128 (MIT). The whole-file waveform pass already decodes every sample.
- **Bit-perfect output** already reports a gain below full as VolumeScaled. Normalization would either show that status or switch off under the mode.

This is a feature with new settings. It needs a decision before any design.

## 4. iOS never asks for the file's sample rate

Nothing calls `AVAudioSession.setPreferredSampleRate:`. iOS usually runs the route at 48 kHz unless an app asks for another rate. So r8brain converts every 44.1 kHz file, even on a USB DAC that runs at 44.1 kHz. A 96 or 192 kHz file is converted down to the route's rate too.

- **The fix:** ask for the file's rate before the session activates (`AudioSessionController.activateSession`) or at the play's settlement. The existing follow (`followOutputRateOnQueue`) then takes whatever rate iOS grants. The built-in speaker and Bluetooth stay where iOS puts them.
- **Keep the mac's gapless rule.** Never change the rate under a queued successor. A successor at another rate takes the settlement and its gap, as it does under the mac's bit-perfect output.
- **It needs a real device** with a USB DAC. The simulator does not show what iOS grants.

## 5. Overs survive inside Vibe, then clip at the device

Several stages make samples above 0 dBFS:

- dr_mp3 and Apple's AAC decoder keep a loud master's overs. dr_mp3's reached +0.93 dB on the test master.
- r8brain rebuilds the peaks between samples. `ResamplerQualityTests` carries a tone whose true peak is +3 dBFS.
- The 5.1 downmix uses Apple's matrix unnormalized (`kAudioFormatProperty_MatrixMixMap`, `VibeMixMap`). Left gets L + 0.707 C + 0.707 Ls. That sum can reach +7.7 dB.

All of that stays exact in float inside Vibe. But Vibe's volume control is off by default. At full volume the device's conversion to integer clips every over.

**The options.** Each one trades level for clean peaks. Each one needs a decision.

- A fixed headroom, such as −3 dB, applied only when the path already changes samples: resampling, a downmix, FX or pitch. Bit-exact playback is untouched.
- A normalized downmix matrix.
- The peak cap from finding 3.

Mono is fine. Apple's matrix sends mono to each channel at 0.707, but `VibeMixMap` sends it at 1.0.

## 6. 16-bit device formats are rounded without dither

**Bit-perfect output is fixed.** It picked the smallest integer depth that carries the source. A 16-bit FLAC got a 16-bit device format even when the DAC offered 24 or 32 bits. Any change to the samples was then rounded to 16 bits without dither: the opt-in volume control, and the declick at transport edges. It now picks the widest integer depth (`VibeBitPerfectChooseFormat`, `OutputFormatRules.h`). At full volume the output is identical, with the extra bits zero. The DAC's display shows 24 or 32 bits instead of 16. A DAC that decodes HDCD no longer sees a 16-bit stream.

- **Regular output can land on 16 bits too.** The physical format is whatever Audio MIDI Setup holds, and Vibe does not read it there. Resampling, FX and pitch are then rounded to 16 bits. TPDF dither in the last stage of `VibeMasterBusRender` would fix that. It is not known whether macOS dithers this conversion itself. Measure first with the loopback verifier (`scripts/test/verify-bit-perfect.swift`). Play a −90 dBFS tone at volume 0.5 into a 16-bit format, and look for its harmonics.
- **Priority is low.** The volume control is off by default, and most DACs default to 24 bits.

## 7. Pre-emphasis is ignored

Some CDs from the 1980s were mastered with pre-emphasis, and a rip keeps the flag. Played without de-emphasis, the treble is too loud by up to 10 dB at 20 kHz. The CUE reader skips `FLAGS`, and with it `PRE` (`PlaylistFile+CUE.m`). FLAC's own CUESHEET block also carries the flag. This audit did not check whether Vibe reads that block's flag.

The fix is a fixed de-emphasis filter, the standard 50/15 µs shelf, for each flagged row. It is niche.

## What was checked and is fine

- **AAC gapless.** Files from ffmpeg's encoder and from `afconvert` decode to the source's exact length and alignment. ffmpeg's encoder writes an edit list.
- **MP3 gapless.** A LAME file decodes to the exact length and alignment.
- **Opus pre-skip.** The decode lines up with the source at the exact length.

## Not worth doing

- **A float64 pipeline.** Float32 already keeps every 24-bit sample exactly. Its rounding is far below hearing.
- **Minimum-phase or "apodizing" resampling filters.** r8brain offers minimum phase (`fprMinPhase`). It removes pre-ringing and adds phase shift near the cutoff. There is no measured gain, and it would add a setting.
- **Upsampling to the device's highest rate.** A DAC oversamples on its own.
- **Bigger buffers, playing from memory, or "integer mode".** None of these changes a sample.

## Beyond quality

- **Key lock** needs a time-stretching algorithm. Signalsmith Stretch (MIT) is the permissive option. Rubber Band is GPL or commercial.
- **Formats** Vibe does not play: DSD (DSF and DFF), WavPack and Monkey's Audio.
- **Multichannel output.** The bus is stereo. A 5.1 file is always folded to two channels.

## How the Apple findings were measured

Test signals came from ffmpeg 8.0: a sine plus pink noise, five seconds of stereo float32 at 48 kHz, and a 44.1 kHz copy. They were encoded with libvorbis, ffmpeg's own Vorbis encoder, libopus and ffmpeg's AAC encoder. A small C program read each file through `ExtAudioFile` to float32, as `AudioFileHandle` does for these formats. It reported the declared and decoded lengths, the level and the share of samples on the 16-bit grid. A second program found the lag between two decodes by least-squares alignment, and measured the residual and any frames past the shorter one's end. ffmpeg's decodes were the references.
