# Future: the MP3 decoder

**Status (2026-09-28):** built and tested on branch `claude/apple-mp3-decoder-alternatives-17c658`. dr_mp3 is now the default on the Mac and the iPhone. On the Mac, Settings > Advanced > MP3 decoder can switch back to Apple's built-in decoder.

## Summary

- Apple's MP3 decoder only outputs 16-bit audio. That loses precision, clips loud masters, and cuts the last few milliseconds of some files.
- dr_mp3 is a small open-source MP3 decoder. It outputs 32-bit float audio. On the official ISO test streams it is about 100 times more accurate than the ISO's own "full accuracy" limit. Apple is right on that limit.
- dr_mp3's license (MIT No Attribution, or public domain) is safe for the App Store.
- FFmpeg, libmad and mpg123 decode just as accurately, but their licenses (GPL or LGPL) don't fit an App Store app.
- BASS, a commercial library, is just as accurate too. It is built on minimp3, like dr_mp3, but it is closed source, needs a paid license, and used about 15% more CPU than dr_mp3.
- dr_mp3 is also cheaper to run. It uses about 2.5 times less CPU, half the energy, and a third of the memory per open file (see System performance). Both decoders are so cheap that neither would show up in Activity Monitor during playback.
- The plan: ship dr_mp3 as the default, keep Apple's decoder one setting away on the Mac, and confirm it on real devices and real music.

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
| BASS | Commercial, closed source | Full ISO accuracy; built on minimp3 | Needs a paid license, and uses more CPU than dr_mp3 |
| Helix MP3 | RPSL | Fixed point | Awkward license |
| Symphonia | MPL 2.0 | Good | Written in Rust; would add a Rust toolchain to the build |
| Apple | Built in | 16-bit only | The current default |

## Measurements

### 1. The ISO compliance test

The ISO standard for MP3 (ISO/IEC 11172-4) comes with official test streams and reference output. It defines two grades:

- **Full accuracy:** average (RMS) error below 8.81e-6, and no single sample off by more than 6.10e-5.
- **Limited accuracy:** average error below 1.41e-4.

The full-accuracy limit is exactly the size of 16-bit rounding. So any decoder that outputs 16-bit audio lands right on the line.

We decoded seven ISO streams (from FFmpeg's test-file mirror) with six decoders, one of them in two builds. `compl` is the −20 dB sine sweep that Underbit's well-known compliance table is based on. This is the worst stream for each decoder, best first:

| Decoder | Worst average error | Worst single error | Distance below the full-accuracy limit | Result |
| --- | --- | --- | --- | --- |
| FFmpeg `mp3float` | 7.9e-8 (−142.1 dBFS) | 7.2e-7 | 112× | full accuracy on all 7 |
| libmad 0.15.1b, accuracy build | 8.3e-8 (−141.6 dBFS) | 7.3e-7 | 106× | full accuracy on all 7 |
| mpg123 1.33.7 | 8.3e-8 (−141.6 dBFS) | 7.0e-7 | 106× | full accuracy on all 7 |
| dr_mp3 0.7.4 | 8.4e-8 (−141.5 dBFS) | 7.1e-7 | 105× | full accuracy on all 7 |
| BASS 2.4.18 | 8.8e-8 (−141.1 dBFS) | 6.9e-7 | 100× | full accuracy on all 7 |
| libmad 0.15.1b | 9.8e-8 (−140.2 dBFS) | 9.2e-7 | 90× | full accuracy on all 7 |
| Apple | 9.1e-6 (−100.8 dBFS) | 2.4e-5 | 1.0× | full on 3, limited on 4 |

What this shows:

- **Every decoder with float output is equally accurate,** BASS included. They are within about 2 dB of each other. That is close to the precision of the reference files themselves, so this test can't rank them any further.
- **Apple is exactly on the line**, because its output is 16-bit.
- **libmad is not more accurate than dr_mp3.** Underbit's table (2001–2004) shows MAD far ahead, but back then most decoders output 16-bit audio. MAD output 24-bit, which was its advantage. Float decoders remove that advantage. We read MAD at its full internal precision, which is even finer than the 24-bit output Underbit scored.
- For fairness, Apple's and BASS's scores are lined up 529 samples later, because both remove the decoder delay on purpose, and Apple's leaves out its silent ending.

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

### 4. BASS, a cousin of dr_mp3

BASS (un4seen, version 2.4.18) is a commercial audio library with its own MP3 decoder. Its notes say that decoder is based on minimp3, the same code dr_mp3 comes from. We decoded to float with BASS's own file reader.

- **Its output is nearly the same as dr_mp3's.** About a third of the samples are identical, bit for bit. The rest differ by at most 2.2e-7 (about −134 dBFS), the last bit or two of a 32-bit float. That is what two builds of the same decoder look like.
- **Quiet passages and loud masters:** the same as dr_mp3. On the −70 dBFS passage, BASS's error was 127 dB below the music. On the loud test master it kept the same 36,125 samples above full scale, peaking at +0.93 dBFS.
- **Speed:** about 15% more CPU than dr_mp3, and about half of Apple's (see System performance).
- **Why not BASS:** it is closed source and needs a paid license for an app that is sold, and it is no more accurate than dr_mp3.

### 5. Speed

dr_mp3 is about two and a half times as fast. The next section has the full measurements.

## System performance

**Short answer: dr_mp3 is cheaper than Apple's decoder on every measure except app size.** BASS, timed for comparison, came between the two. It uses about 2.5 times less CPU, half the energy, and a third of the memory. It opens files faster and seeks slightly faster. It reads far less from the file, in about as many read calls as Apple's.

Both decoders are very cheap. Playing a 320 kbps MP3 takes about 0.1% of one core with Apple's decoder and 0.04% with dr_mp3. **Neither choice will change how the app feels during normal playback.** The difference shows up in work that decodes a whole file at once, such as drawing the waveform, and on slower cores.

These numbers include two changes to how Vibe feeds dr_mp3 (see Tuning dr_mp3 below). Without them, dr_mp3 was about 2.1 times cheaper than Apple instead of 2.5.

### How we measured

- **What ran:** Vibe's own file reader (`AudioFileHandle.m` from this branch), switching decoders with the same setting the app uses. It was built with the app's Release settings: `-Os` for Vibe's code, `-O3` for dr_mp3. Each test alternated between Apple and dr_mp3 run by run, so both decoders saw the same conditions.
- **Machine:** Mac with an Apple M4 Max, macOS 27. Other work was running on it (load average 4–6), which is why a repeated measurement can move by about 5%. The comparisons within a row are fair; the alternation takes care of that.
- **BASS:** version 2.4.18, decoding to float with its own file reader, in the same session as the CPU, energy and whole-file tests below. Those three tests were run again for this, so their Apple and dr_mp3 numbers are from that run. They came within 5% of the first run's.
- **Files:** one real 6.5-minute track, encoded nine ways (LAME 4.0 for MP3, FFmpeg for MP2), plus two real 320 kbps tracks from a music library. That covers high and low bitrates, CBR and VBR, 48 kHz, mono, MPEG-2 (22.05 kHz), MPEG-2.5 (11.025 kHz), and MP2.
- **Two kinds of core:** every CPU test ran on the fast performance cores. The decode, seek, and chunk tests also ran on the slower efficiency cores, which were forced with the lowest thread priority. Efficiency cores are the closest thing on a Mac to a phone saving battery. **No iPhone was measured.**
- **Read shapes:** playback reads 4,096 frames at a time into separate left and right buffers. The waveform reads 65,536 frames at a time, interleaved. We tested both.
- **Caveats:** the files were already in memory (the operating system's file cache), so no test waited on a disk. Energy is macOS's own per-process CPU energy estimate, which is approximate. The test programs are not committed. They were single files in a scratch folder that linked `AudioFileHandle.m` and `dr_mp3.c` directly.

### Summary

For a 320 kbps stereo MP3, the most common kind:

| Measure | dr_mp3 | BASS | Apple | Which is better |
| --- | --- | --- | --- | --- |
| CPU to play, performance core | 0.042% of one core | 0.050% | 0.096% | dr_mp3, 2.3× less than Apple |
| CPU to play, efficiency core | 0.12% of one core | 0.14% | 0.32% | dr_mp3, 2.8× less than Apple |
| Energy to decode one hour of music, performance core | 8.1 J | 9.6 J | 16.8 J | dr_mp3, 2.1× less than Apple |
| Time to decode a whole 6.5-minute track for the waveform | 161 ms | 188 ms | 361 ms | dr_mp3, 2.2× faster than Apple |
| Opening a file | 0.06 ms | not measured | 0.09 ms | dr_mp3 |
| Seeking, then reading the first 4,096 frames | 0.15 ms | not measured | 0.17 ms | About the same |
| Memory per open file | 60 KB | 30 KB (see Memory) | 177 KB | BASS, then dr_mp3 |
| File reads per second of music | 9.6 | 5.5 | 9.6 | BASS |
| Bytes read from the file, 15 MB file | 17 MB | 15.7 MB | 235 MB | BASS and dr_mp3, 14× less than Apple |
| Extra app size | 48 KB of code | a 0.9 MB library | none (built into macOS) | Apple |

Across all 11 files, dr_mp3 used on average **2.5× less CPU on performance cores and 3.1× less on efficiency cores** than Apple's decoder. It won on every file. The gap is smallest on mono files and largest on MP2. BASS used on average 17% more than dr_mp3 on performance cores and 15% more on efficiency cores.

### CPU to play a file

Share of one CPU core needed to keep up with playback, measured as the fastest of seven whole-file decodes. Decoders are listed best first. **Lower is better.**

| File | dr_mp3, performance core | BASS, performance core | Apple, performance core | dr_mp3, efficiency core | BASS, efficiency core | Apple, efficiency core |
| --- | --- | --- | --- | --- | --- | --- |
| CBR 320 kbps | 0.042% | 0.050% | 0.096% | 0.12% | 0.14% | 0.32% |
| CBR 128 kbps | 0.031% | 0.037% | 0.082% | 0.090% | 0.12% | 0.28% |
| VBR V0 (about 280 kbps) | 0.042% | 0.048% | 0.100% | 0.14% | 0.14% | 0.42% |
| VBR V5 (about 130 kbps) | 0.031% | 0.036% | 0.082% | 0.094% | 0.12% | 0.32% |
| CBR 256 kbps, 48 kHz | 0.039% | 0.046% | 0.097% | 0.12% | 0.12% | 0.36% |
| Mono 64 kbps | 0.019% | 0.023% | 0.042% | 0.065% | 0.066% | 0.17% |
| MPEG-2, 22.05 kHz, 64 kbps | 0.017% | 0.019% | 0.043% | 0.047% | 0.052% | 0.16% |
| MPEG-2.5, 11.025 kHz, 16 kbps | 0.007% | 0.007% | 0.018% | 0.021% | 0.021% | 0.065% |
| MP2 256 kbps, 48 kHz | 0.023% | 0.030% | 0.066% | 0.092% | 0.095% | 0.29% |
| Real track A, 320 kbps | 0.043% | 0.049% | 0.097% | 0.11% | 0.14% | 0.33% |
| Real track B, 320 kbps | 0.042% | 0.048% | 0.096% | 0.11% | 0.14% | 0.34% |

What this shows:

- **dr_mp3 does less work, not the same work faster.** It ran 2.3 to 2.9 times fewer CPU instructions than Apple's decoder on every stereo file (2.1 times fewer on mono). That is why the saving holds on both kinds of core.
- **Efficiency-core numbers are noisier.** Their clock speed varies from run to run, so compare the decoders within a row, not rows with each other. dr_mp3 beat Apple in every row. On efficiency cores dr_mp3 and BASS were within 3% of each other on four files, which is inside that noise.
- **For scale:** converting 44.1 kHz to 48 kHz with r8brain costs about 0.09% of a performance core (`docs/audio-quality.md`). So on a 48 kHz output, playing a 44.1 kHz 320 kbps MP3 costs about 0.19% of a core with Apple's decoder and 0.13% with dr_mp3.
- **The iPhone:** not measured. `docs/audio-quality.md` found r8brain about six times as expensive on an iPhone 17 Pro as on this Mac. If the decoders scale the same way, playing an MP3 would cost roughly 0.6% of a phone core with Apple's decoder and 0.3% with dr_mp3. That is an estimate only.

### Energy

macOS's estimate of the CPU energy used to decode, per minute of music. Decoders are listed best first. **Lower is better.**

| File | dr_mp3, performance core | BASS, performance core | Apple, performance core | dr_mp3, efficiency core | BASS, efficiency core | Apple, efficiency core |
| --- | --- | --- | --- | --- | --- | --- |
| CBR 320 kbps | 136 mJ | 159 mJ | 279 mJ | 19 mJ | 19 mJ | 41 mJ |
| CBR 128 kbps | 104 mJ | 129 mJ | 233 mJ | 16 mJ | 16 mJ | 34 mJ |
| MP2 256 kbps | 86 mJ | 106 mJ | 183 mJ | 14 mJ | 14 mJ | 28 mJ |
| Real track B, 320 kbps | 133 mJ | 157 mJ | 269 mJ | 19 mJ | 22 mJ | 39 mJ |

dr_mp3 used about **half the energy** of Apple's decoder on both kinds of core. BASS used about 18% more than dr_mp3 on performance cores and about the same on efficiency cores. The saving is real but very small. On efficiency cores, an hour of 320 kbps playback costs about 2.5 J to decode with Apple's decoder and 1.2 J with dr_mp3 or BASS. An iPhone battery holds roughly 50,000 J.

Efficiency cores used about six times less energy than performance cores for the same decode. So where the decode thread runs matters far more to battery life than which decoder runs on it.

### Decoding a whole file (the waveform)

The waveform decodes the whole track as fast as it can, 65,536 frames at a time. Time from opening the file to the last sample, median of seven runs, performance core. Decoders are listed best first. **Lower is better.**

| File (all 6.5 minutes unless noted) | dr_mp3 | BASS | Apple | dr_mp3's speed-up over Apple |
| --- | --- | --- | --- | --- |
| CBR 320 kbps | 161 ms | 188 ms | 361 ms | 2.2× |
| CBR 128 kbps | 117 ms | 140 ms | 302 ms | 2.6× |
| VBR V0 | 163 ms | 185 ms | 369 ms | 2.3× |
| MP2 256 kbps | 90 ms | 116 ms | 254 ms | 2.8× |
| Real track B, 320 kbps, 7.3 minutes | 185 ms | 209 ms | 403 ms | 2.2× |

The waveform loader does more than decode, so its total time falls by less than this. The decode part of it more than halves.

### Each 4,096-frame read during playback

Playback's decode thread reads 4,096 frames at a time into a buffer. At 44.1 kHz, each read covers 93 ms of music, so a read must finish in well under 93 ms. **Lower is better.**

| File | Core | dr_mp3 typical | Apple typical | dr_mp3 slowest 1% | Apple slowest 1% | dr_mp3 slowest | Apple slowest |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CBR 320 kbps | performance | 0.042 ms | 0.100 ms | 0.08 ms | 0.25 ms | 0.15 ms | 2.1 ms |
| CBR 320 kbps | efficiency | 0.17 ms | 0.48 ms | 0.53 ms | 1.3 ms | 2.0 ms | 76 ms |
| Real track B | performance | 0.042 ms | 0.097 ms | 0.06 ms | 0.13 ms | 0.13 ms | 0.41 ms |
| Real track B | efficiency | 0.11 ms | 0.32 ms | 0.32 ms | 0.84 ms | 3.0 ms | 2.9 ms |

- **On performance cores, neither decoder comes close to the budget.** dr_mp3's slowest read on any file was 0.75 ms, and Apple's 2.4 ms.
- **On efficiency cores, both decoders had rare slow reads:** up to 77 ms for Apple and 45 ms for dr_mp3, each on a different file. They come from the test's lowest thread priority making it wait for other work on a busy machine, not from decoding. The app's decode threads run at the highest priority, and each track's buffer holds at least a second of audio, so one late read would not be heard.

### Opening and seeking

Median of 100 opens and of 300 random seeks, performance core. Each seek is followed by one 4,096-frame read, as when the user scrubs or jumps to a cue.

| File | Open, dr_mp3 | Open, Apple | Seek and read, dr_mp3 | Seek and read, Apple |
| --- | --- | --- | --- | --- |
| CBR 320 kbps | 0.06 ms | 0.09 ms | 0.15 ms | 0.17 ms |
| CBR 128 kbps | 0.06 ms | 0.10 ms | 0.11 ms | 0.16 ms |
| VBR V0 | 0.06 ms | 0.09 ms | 0.17 ms | 0.21 ms |
| MPEG-2, 22.05 kHz | 0.07 ms | 0.10 ms | 0.08 ms | 0.14 ms |
| MP2 256 kbps | 11.2 ms | 11.4 ms | 0.07 ms | 0.10 ms |
| Real track B, 320 kbps | 0.08 ms | 0.11 ms | 0.16 ms | 0.16 ms |

- **Opening is faster with dr_mp3** because Vibe skips setting up Apple's decoder and format converter.
- **Seeking is about the same on performance cores and faster on efficiency cores.** dr_mp3 decodes ten extra frames before each seek target to be sample-exact (see How it works). On performance cores that costs about as much as Apple's own seek. On efficiency cores dr_mp3 was faster on all 11 files, and a typical seek took about 1 ms or less with both.
- **Some slow cases belong to macOS's file parser, not to either decoder.** For the MPEG-2.5 and MP2 files, opening took 5 ms and 11 ms with both decoders. For the other files, the first seek further into the file than the parser had yet read took 6–15 ms with both decoders. In each case, the parser was reading through the file to build its table of frame positions. It does this once per open file.

### Memory

Extra heap memory for each open, playing file, averaged over 20 open files. **Lower is better.**

| File | dr_mp3 | Apple |
| --- | --- | --- |
| Stereo MP3 (any bitrate) | 60 KB | 177 KB |
| Mono MP3 | 59 KB | 134 KB |
| MPEG-2.5, 11.025 kHz | 80 KB | 196 KB |
| MP2 256 kbps | 104 KB | 221 KB |

Most of dr_mp3's 60 KB is its own: 23 KB of decoder state, about 21 KB to hold 16 compressed frames read ahead, and 9 KB for one frame of decoded audio. The rest is macOS's file parser, which both decoders use. Vibe keeps at most two files open for playback (the current track and the next one), so the saving is about 230 KB. That is small but real on an iPhone.

BASS took 30–32 KB per open file on the same files, measured the same way. That is less, but it isn't a like-for-like number: BASS reads the file itself, while both of Vibe's decoders share macOS's parser. BASS also keeps a file's tags in memory, so a real track with embedded artwork took 174–414 KB.

### File reads

How often each decoder asks for data from the file, for one whole playthrough.

| File | dr_mp3, reads | Apple, reads | dr_mp3, total bytes read | Apple, total bytes read | File size |
| --- | --- | --- | --- | --- | --- |
| CBR 320 kbps | 3,777 (9.6 per second of music) | 3,781 (9.6 per second) | 17 MB | 235 MB | 15 MB |
| CBR 128 kbps | 957 | 3,781 | 15 MB | 234 MB | 6 MB |
| MP2 256 kbps | 33,780 | 36,850 | 28 MB | 28 MB | 12 MB |
| Real track B, 320 kbps | 4,512 | 4,233 | 20 MB | 262 MB | 17 MB |

- **Apple's decoder** reads MP3s 64 KB at a time and rereads the same part of the file many times, so it reads 15 to 40 times the file's size over one playthrough.
- **dr_mp3** asks macOS's parser for 16 frames at a time and reads little more than the file itself.
- **MP2 is read in small pieces with both decoders.** macOS's MP2 parser reads that way however many frames are asked for.
- **BASS**, reading the file itself, read each file about once: 15.7 MB for the 15 MB file, in 5.5 reads per second of music, and 12.7 MB in 1,656 reads for the MP2.

Because the file sits in the operating system's cache, none of these reads touch the disk. The reads took about 1–3 ms per 6.5-minute MP3 track with dr_mp3, and about 10 ms with Apple's decoder. We didn't test a network share or a slow drive with an empty cache, but dr_mp3 now makes about as many read calls as Apple's decoder, and reads far fewer bytes.

## Tuning dr_mp3

We looked for ways to make dr_mp3 cheaper: its build options, its use of the CPU's vector instructions (NEON), Apple's Accelerate library, and how Vibe feeds it the file. Two small changes in Vibe's own code were worth making. dr_mp3 itself is unchanged.

### Where dr_mp3 spends its time

A profile of dr_mp3 decoding a 320 kbps file:

| Part of the decode | Share of the time | Already uses vector instructions? |
| --- | --- | --- |
| Reading the compressed bitstream (Huffman decoding, bit reading, scale factors) | about 47% | No, and it can't: each value depends on the one before |
| The synthesis filterbank, which turns frequencies back into samples | about 35% | Yes, hand-written NEON |
| The IMDCT, a transform on each block | about 9% | Mostly |
| Everything else | about 9% | Some |

At 128 kbps the bitstream share was higher, over half. That profile caught fewer samples than expected, so treat its figure as approximate.

### Build options

Time for dr_mp3 alone to decode the 6.5-minute 320 kbps track, with every frame already in memory:

| How dr_mp3 is built | Time | Code size | Output |
| --- | --- | --- | --- |
| `-O3` (what we ship) | 161 ms | 48 KB | reference |
| `-O2` | 160 ms | 44 KB | identical |
| `-Os` | 173 ms (8% slower) | 30 KB | identical |
| `-mcpu=apple-m1` | 162 ms | 48 KB | identical |
| `-ffast-math` (allows fused multiply-add) | 160 ms | 47 KB | slightly different |
| NEON turned off | 187 ms (16% slower) | 53 KB | slightly different |

None of the options helps. dr_mp3's other build switches either remove things Vibe needs (MP1 and MP2 support) or change nothing measurable.

### Vector instructions and Accelerate

- **Fused multiply-add changed nothing.** The filterbank is limited by moving data in and out of memory, not by arithmetic.
- **Accelerate can't speed up the decoder.** Its transforms are tiny: a 32-point DCT, 36 times per frame. The cost of each Accelerate call would outweigh the work, and dr_mp3's own NEON code already processes four time slots per instruction.
- **What is left is small.** A few loops inside dr_mp3 are still scalar (sign flips, small DCTs, the edges of the synthesis step), about 10% of the time in total. Vectorizing them might save 3–5%, at the cost of keeping our own modified copy of dr_mp3. We didn't do it.
- **Accelerate does help in Vibe's own code.** dr_mp3 outputs left and right samples interleaved, and playback wants them in separate buffers. One `vDSP_ctoz` call now splits them, replacing a sample-by-sample loop. That saves about 3% for stereo playback. The waveform reads interleaved audio and is unaffected.

### Reading 16 frames at a time

Vibe used to ask macOS's parser for one MP3 frame at a time, and the parser made about four small file reads per frame: 60,188 reads for one 6.5-minute track, about a tenth of the whole decode time. Vibe now asks for 16 frames at once and hands them to dr_mp3 one by one.

Whole-file decode in playback's read pattern, fastest of nine runs, before and after, alternating run by run:

| File | Before | 16 frames per read | 16 frames per read, plus `vDSP_ctoz` |
| --- | --- | --- | --- |
| CBR 320 kbps | 196 ms | 175 ms | 170 ms (−13%) |
| CBR 128 kbps | 151 ms | 131 ms | 124 ms (−18%) |
| Real track B, 320 kbps | 220 ms | 198 ms | 190 ms (−14%) |
| Mono 64 kbps | 98 ms | 80 ms | 80 ms (−18%) |
| MP2 256 kbps | 106 ms | 101 ms | 92 ms (−13%) |

- **The instructions dr_mp3 runs per second of music fell 16%** for a 320 kbps track. Unlike time, this count doesn't depend on how busy the machine is.
- **Vibe's own code is now about 5% of the decode**, down from about 18%. Nearly all the rest is dr_mp3 itself: the time for the 320 kbps track (170 ms) is close to dr_mp3's 161 ms working on frames already in memory.
- **The output is unchanged, bit for bit.** We compared every sample from 18 files, reading straight through and after 60 random seeks each, in both read shapes. That included a file cut in half, a VBR file cut short, a file with 300 random bytes changed, and a file with 20 KB missing from the middle.
- **Memory:** each open file holds 16 compressed frames, about 21 KB at 320 kbps instead of one 4 KB frame. That is why dr_mp3 now uses 60 KB per file instead of 43 KB.
- **16 is enough.** Asking for 4 frames at a time saved about half as much, and 64 saved no more than 16.

## How it works

- **Where the code is:** dr_mp3 is vendored at `Vibe/ThirdParty/dr_mp3/` (version 0.7.4, dr_libs commit `dfe83776`). All the Vibe code is in `Vibe/Audio/AudioFileHandle.m`.
- **macOS still reads the file.** Its file parser still opens it, skips ID3 tags, splits it into frames, reads the gapless tags (LAME and iTunes), and reports the length. dr_mp3 only turns each frame into samples. So lengths and gapless playback are the same as with Apple.
- **Decoder delay.** Every MP3 decoder outputs its audio 529 samples late (241 for MP1 and MP2). Apple removes this delay itself, so Vibe removes the same amount when dr_mp3 decodes. The timelines then match.
- **Seeking.** A seek starts dr_mp3 ten frames before the target and throws those frames away. MP3 frames borrow data from earlier frames, so this warm-up makes the result exactly the same as reading from the start.
- **Reading the file.** Vibe asks the parser for 16 frames at a time and hands them to dr_mp3 one by one. For playback, one `vDSP_ctoz` call splits dr_mp3's interleaved stereo into separate left and right buffers.
- **MP3 or MP2 inside a WAV.** macOS gives such packets no descriptions of their own, because they are all one size. Vibe works out each packet's place from that size. macOS opens these files only when every frame is the same size, which 48 kHz CBR is; it refuses 44.1 kHz and VBR ones.
- **The ending.** After the last frame, Vibe decodes one silent frame. This flushes the decoder's last 529 samples instead of replacing them with silence.
- **Which readers use it:** everything that reads float audio through `AudioFileHandle`: playback, the waveform, and the FLAC converter's probe.

## MP2 on the iPhone

iOS has no Apple MP2 decoder. Listing the decoders the iOS runtime offers (in the iOS 27 Simulator) shows AAC, MP3, ALAC and FLAC, and no MP2; macOS lists one. The iOS app has declared MP2 files (`public.mp2`) since it was first built, so it offered to open them, but they could never play. dr_mp3 decodes MP2 itself, so with it as the default MP2 now plays on the iPhone. Three MP2 files (192 kbps, 384 kbps, 48 kHz mono) played on an iPhone 17 Pro.

## How to use it

- **Mac:** Settings > Advanced > MP3 decoder: "Vibe (dr_mp3 HQ)", the default, or "Apple built-in". The hint under it says "Changes applied from next track". A file already open keeps its decoder, so a change re-opens the next track, which Vibe opens ahead of time. If that early open was still running when the choice changed, it is re-opened again once it finishes.
- **iOS:** no setting. It always uses dr_mp3.
- **Debug builds:** `set_decoder apple` or `set_decoder dr_mp3` overrides the choice for the session, on both platforms. `dump_audio_path` shows which decoder is in use.

## Tests

- `testDrMP3PassesTheISOComplianceStreamAtFullAccuracy` (`make test-audio`): decodes the ISO `compl` stream with both decoders. dr_mp3 must be at least 50 times inside the full-accuracy limit, so a slip back to 16-bit output fails it. Apple must stay within limited accuracy. The stream and its reference belong to ISO, so they are not committed: the fixture generator downloads them from FFmpeg's test-file mirror, checks their SHA-256 hashes, and the test skips if the download fails. The comparison leaves out the last 529 samples, because the stream ends with a cut-off frame that the reference decoded and macOS doesn't read.
- `testDrMP3DecodesWhatAppleRoundsTo16Bits` (`make test-audio`): on CBR, VBR, MP2 and a loud master, dr_mp3 must match Apple's length, stay within Apple's rounding, not be 16-bit, keep the loud master's peaks, seek exactly, and end truncated files where Apple does.
- The existing MP3 and MP2 playback tests pass unchanged.

## Decisions

- **dr_mp3 over minimp3:** the same decoder, with a maintained API and a public-domain or MIT-0 license.
- **Not libmad, mpg123 or FFmpeg:** no more accurate than dr_mp3, and their GPL or LGPL licenses don't fit the App Store. libmad is also unmaintained, with memory-safety bugs (CVE-2017-8372, -8373 and -8374) fixed only in Linux distributions' patches.
- **dr_mp3 is the default:** it is more accurate, keeps loud peaks, ends files properly, and uses less CPU, energy and memory. That is the strong reason the project's "Apple frameworks for playback" rule asks for, as r8brain was. Apple's decoder stays one setting away on the Mac.
- **No clamp on damaged-frame spikes:** a clamp would also have to leave room for real peaks above full scale, and damaged files are rare.
- **The ISO files are downloaded, not committed:** they belong to ISO.

## Plan

1. Ship dr_mp3 as the default on both platforms, with Apple's decoder one setting away on the Mac.
2. Do a listening test on real music: quiet passages, fade-outs, and loud modern masters, with the volume control below full.
3. Test on an iPhone: playback, seeking, gapless and CPU.
4. Decide whether iOS needs a setting of its own.

## Not yet tested

- **MP1 files:** we have no MP1 encoder. dr_mp3 decodes MP1, and it uses MP2's 241-sample delay, which MP1 shares.
- **The live app:** the setting was not clicked through in the running app. Another session's debug app was using the debug channel. `make test-audio` plays MP3 and MP2 through the real player.
- **iOS device speed and a listening test.** An iPhone build is being tested.
