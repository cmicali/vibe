# Future: the MP3 decoder

**Status (2026-09-28):** built and tested on branch `claude/apple-mp3-decoder-alternatives-17c658`. Apple's decoder is still the default. On the Mac, Settings > Advanced > MP3 decoder lets the user switch to dr_mp3.

## Summary

- Apple's MP3 decoder only outputs 16-bit audio. That loses precision, clips loud masters, and cuts the last few milliseconds of some files.
- dr_mp3 is a small open-source MP3 decoder. It outputs 32-bit float audio. On the official ISO test streams it is about 100 times more accurate than the ISO's own "full accuracy" limit. Apple is right on that limit.
- dr_mp3's license (MIT No Attribution, or public domain) is safe for the App Store.
- libmad, mpg123 and FFmpeg decode just as accurately, but their licenses (GPL or LGPL) don't fit an App Store app.
- The plan: ship the setting with Apple as the default, collect listening and device results, and then decide whether dr_mp3 should become the default.

## The problem with Apple's decoder

Apple's MP3 decoder (and its MP2 decoder) can only output one format: **16-bit integers**. Vibe asks for 32-bit float, so macOS converts the 16-bit output to float. The precision is already lost by then. We checked: every one of 882,000 decoded samples was exactly a 16-bit value.

Apple's AAC decoder is different. It outputs float directly, so AAC is not affected.

This causes three problems:

1. **Lost precision.** The rounding to 16 bits adds noise at about −100 dBFS (dBFS means decibels below the loudest possible sample). On loud music you can't hear it. On quiet passages it is much closer to the music: on a passage at −70 dBFS, the error was only 31 dB quieter than the music. With dr_mp3 it was 127 dB quieter.
2. **Clipping.** A loud, limited master often decodes slightly *above* full scale, because MP3 encoding overshoots. A 16-bit value can't go above full scale, so Apple cuts those peaks off. On our 20-second test master, Apple clipped 36,188 samples. dr_mp3 kept the true peaks (up to +0.93 dBFS), so Vibe's volume control, effects or resampler can bring them back down cleanly.
3. **A cut-off ending.** For a file without gapless information (no LAME or iTunes tag), the last 529 samples (241 for MP2) should come from the decoder's final flush. Apple fills them with silence instead. On an MP2 whose music runs to the very end, that is a jump from loud to silent: a click.

## The options

| Decoder | License | Accuracy | Verdict |
| --- | --- | --- | --- |
| **dr_mp3** | MIT No Attribution or public domain | Full ISO accuracy, float output | **Chosen.** One header file, maintained, App Store safe |
| minimp3 | CC0 | Same code as dr_mp3 | Fine too; dr_mp3 is the same decoder with a maintained API |
| mpg123 | LGPL 2.1 | Full ISO accuracy | LGPL is hard to meet with a statically linked App Store app |
| FFmpeg (`mp3float`) | LGPL | Full ISO accuracy | Same license problem, and very large |
| libmad (MAD) | GPL 2 or later | Full ISO accuracy | GPL can't ship in this app; unmaintained since 2004 |
| Helix MP3 | RPSL | Fixed point | Awkward license |
| Symphonia | MPL 2.0 | Good | Written in Rust; would add a Rust toolchain to the build |
| Apple | Built in | 16-bit only | The current default |

## Measurements

### 1. The ISO compliance test

The ISO standard for MP3 (ISO/IEC 11172-4) comes with official test streams and reference output. It defines two grades:

- **Full accuracy:** average (RMS) error below 8.81e-6, and no single sample off by more than 6.10e-5.
- **Limited accuracy:** average error below 1.41e-4.

The full-accuracy limit is exactly the size of 16-bit rounding. So any decoder that outputs 16-bit audio lands right on the line.

We decoded seven ISO streams (from FFmpeg's test-file mirror) with six decoders. `compl` is the −20 dB sine sweep that Underbit's well-known compliance table is based on. This is the worst stream for each decoder:

| Decoder | Worst average error | Worst single error | Distance below the full-accuracy limit | Result |
| --- | --- | --- | --- | --- |
| dr_mp3 0.7.4 | 8.4e-8 (−141.5 dBFS) | 7.1e-7 | 105× | full accuracy on all 7 |
| libmad 0.15.1b | 9.8e-8 (−140.2 dBFS) | 9.2e-7 | 90× | full accuracy on all 7 |
| libmad 0.15.1b, accuracy build | 8.3e-8 (−141.6 dBFS) | 7.3e-7 | 106× | full accuracy on all 7 |
| mpg123 1.33.7 | 8.3e-8 (−141.6 dBFS) | 7.0e-7 | 106× | full accuracy on all 7 |
| FFmpeg `mp3float` | 7.9e-8 (−142.1 dBFS) | 7.2e-7 | 112× | full accuracy on all 7 |
| Apple | 9.1e-6 (−100.8 dBFS) | 2.4e-5 | 1.0× | full on 3, limited on 4 |

What this shows:

- **The five open-source decoders are equally accurate.** They are within about 2 dB of each other. That is close to the precision of the reference files themselves, so this test can't rank them any further.
- **Apple is exactly on the line**, because its output is 16-bit.
- **libmad is not more accurate than dr_mp3.** Underbit's table (2001–2004) shows MAD far ahead, but back then most decoders output 16-bit audio. MAD output 24-bit, which was its advantage. Float decoders remove that advantage. We read MAD at its full internal precision, which is even finer than the 24-bit output Underbit scored.
- For fairness, Apple's score leaves out the first 529 samples (the decoder delay Apple removes on purpose) and its silent ending.

### 2. dr_mp3 against Apple, sample by sample

We ran Vibe's own file reader (`AudioFileHandle`) with both decoders on 16 test files. They covered CBR 320, VBR V0 and V9, a file without a gapless tag, mono 32 kbps, 48 kHz 32 kbps, MPEG-2 (22.05 kHz), MPEG-2.5 (11.025 kHz, 8 kbps), MP2, a two-frame file, and three test-library MP3s.

- **Length:** identical on every file. Gapless trimming matches.
- **Samples:** they differ by about −100 dBFS on average. That is Apple's 16-bit rounding and nothing more. The largest difference was 4 steps of a 16-bit value.
- **Seeking:** after a seek, dr_mp3 produces exactly the same samples as reading from the start, at every position tested.
- **Against mpg123:** on tagged files, dr_mp3 and mpg123 agree to −136 dBFS or better.

### 3. Damaged and unusual files

- **Truncated or damaged files** (cut in half, a 20 KB hole, 300 random bytes changed) end at exactly the same sample as Apple's.
- **A damaged frame can produce a loud spike.** With 300 bytes changed, dr_mp3 produced a spike at +15.5 dBFS. Apple clipped the same spike at full scale because of its 16-bit output. We decided not to clamp it (see Decisions).
- **Free-format MP3s** (a rare type with no bitrate in the header) are refused by macOS before either decoder sees them. Nothing changes there.

### 4. Speed

Decoding a whole file, best of seven runs, on an M-series Mac:

| File | dr_mp3 | Apple |
| --- | --- | --- |
| 120 s VBR | 0.030% of one core | 0.064% |
| 20 s CBR 320 | 0.051% of one core | 0.103% |

dr_mp3 is about twice as fast. Both are tiny compared with the resampler.

## How it works

- **Where the code is:** dr_mp3 is vendored at `Vibe/ThirdParty/dr_mp3/` (version 0.7.4, dr_libs commit `dfe83776`). All the Vibe code is in `Vibe/Audio/AudioFileHandle.m`.
- **macOS still reads the file.** Its file parser still opens it, skips ID3 tags, splits it into frames, reads the gapless tags (LAME and iTunes), and reports the length. dr_mp3 only turns each frame into samples. So lengths and gapless playback are the same as with Apple.
- **Decoder delay.** Every MP3 decoder outputs its audio 529 samples late (241 for MP1 and MP2). Apple removes this delay itself, so Vibe removes the same amount when dr_mp3 decodes. The timelines then match.
- **Seeking.** A seek starts dr_mp3 ten frames before the target and throws those frames away. MP3 frames borrow data from earlier frames, so this warm-up makes the result exactly the same as reading from the start.
- **The ending.** After the last frame, Vibe decodes one silent frame. This flushes the decoder's last 529 samples instead of replacing them with silence.
- **Which readers use it:** everything that reads float audio through `AudioFileHandle`: playback, the waveform, and the FLAC converter's probe.

## How to use it

- **Mac:** Settings > Advanced > MP3 decoder: Apple (default) or dr_mp3. A change applies from the next track, because a file already open keeps its decoder.
- **iOS:** no setting. It always uses Apple's decoder.
- **Debug builds:** `set_decoder apple` or `set_decoder dr_mp3` overrides the choice for the session, on both platforms. `dump_audio_path` shows which decoder is in use.

## Tests

- `testDrMP3PassesTheISOComplianceStreamAtFullAccuracy` (`make test-audio`): decodes the ISO `compl` stream with both decoders. dr_mp3 must be at least 50 times inside the full-accuracy limit, so a slip back to 16-bit output fails it. Apple must stay within limited accuracy. The stream and its reference belong to ISO, so they are not committed: the fixture generator downloads them from FFmpeg's test-file mirror, checks their SHA-256 hashes, and the test skips if the download fails. The comparison leaves out the last 529 samples, because the stream ends with a cut-off frame that the reference decoded and macOS doesn't read.
- `testDrMP3DecodesWhatAppleRoundsTo16Bits` (`make test-audio`): on CBR, VBR, MP2 and a loud master, dr_mp3 must match Apple's length, stay within Apple's rounding, not be 16-bit, keep the loud master's peaks, seek exactly, and end truncated files where Apple does.
- The existing MP3 and MP2 playback tests pass unchanged.

## Decisions

- **dr_mp3 over minimp3:** the same decoder, with a maintained API and a public-domain or MIT-0 license.
- **Not libmad, mpg123 or FFmpeg:** no more accurate than dr_mp3, and their GPL or LGPL licenses don't fit the App Store. libmad is also unmaintained, with memory-safety bugs (CVE-2017-8372, -8373 and -8374) fixed only in Linux distributions' patches.
- **Apple stays the default:** dr_mp3 is new, and the project's rule is Apple frameworks for playback unless there's a strong reason. The setting lets people try it first.
- **No clamp on damaged-frame spikes:** a clamp would also have to leave room for real peaks above full scale. Since Apple is the default, the choice is left to the user.
- **The ISO files are downloaded, not committed:** they belong to ISO.

## Plan

1. Ship the setting with Apple as the default.
2. Do a listening test on real music: quiet passages, fade-outs, and loud modern masters, with the volume control below full.
3. Measure CPU on an iPhone.
4. Decide whether to add an iOS setting. It would also bring MP2 playback to iOS, which has no Apple MP2 decoder. That still needs a check on the simulator.
5. If those go well, make dr_mp3 the default. This would be the second exception to the "Apple frameworks only" rule, after r8brain (`resampler.md`). The code change is two lines: `AudioFileHandle`'s default and the setting's default.

## Not yet tested

- **MP1 files:** we have no MP1 encoder. dr_mp3 decodes MP1, and it uses MP2's 241-sample delay, which MP1 shares.
- **The live app:** the setting was not clicked through in the running app. Another session's debug app was using the debug channel. `make test-audio` plays MP3 and MP2 through the real player.
- **iOS device speed and a listening test.**
