# Future: the MPEG decoder

**Status: under evaluation on `claude/apple-mp3-decoder-alternatives-17c658` (2026-09-28).** dr_mp3 is vendored and decodes MP1, MP2 and MP3 in `AudioFileHandle` for every float32 reader (the player, the waveform, the converter's probe); **Apple's decoder stays the default**; the mac's Settings > Advanced > MP3 decoder switches to dr_mp3, and `set_decoder` overrides either for a session on both platforms. Making dr_mp3 the default would reverse the root `AGENTS.md`'s "Apple frameworks only" rule a second time, after r8brain (`resampler.md`); the case for it is below.

## What Apple's decoder costs

Apple's `MPEG-1/2 Layer III Decoder` and its Layer II sibling offer exactly one output format, **16-bit signed integer** (`kAudioCodecPropertySupportedOutputFormats`; AAC offers float32, ALAC and FLAC up to their source depth). ExtAudioFile converts that to the float32 the reader asks for, so every MPEG file reached the bus on the 16-bit grid, measured: 882,000 of 882,000 samples through `AudioFileHandle`'s own float32 path. That costs three things, against mpg123, FFmpeg's `mp3float` and minimp3, which agree with each other at float32's floor (−136 dBFS RMS difference) and with Apple only at −100 dBFS:

- **Rounding without dither.** The error is white, at 16-bit quantization's level, and signal-correlated on quiet material: a passage at −70 dBFS carries it only 31 dB down, where dr_mp3's differs from mpg123 by 127 dB.
- **Clipping.** A master limited to full scale decodes above it, since the codec's filtering overshoots; Apple's decode hard-clips every such sample (36,188 on the 20 s test master) where a float decode keeps the +0.93 dBFS peaks for the volume stage, the FX or the resampler to bring back in range.
- **A truncated end.** An untagged file's last 529 frames (241 for Layer II) are the decoder's filterbank draining; Apple zero-fills them. On an MP2 whose audio runs to the last frame that is a step from 0.2 to silence.

## What is built

- **`Vibe/ThirdParty/dr_mp3/`**: dr_mp3 0.7.4 (dr_libs `dfe83776`), minimp3's decoder with a maintained API; MIT No Attribution or public domain, minimp3 itself CC0 (`THIRD-PARTY-NOTICES.md`). Only the frame decoder, `drmp3dec_decode_frame`, is called.
- **`AudioFileHandle`**: an MPEG file opened for float32 still goes through CoreAudio's parser, and ExtAudioFile still answers the length, so ID3 handling, the hinted-then-sniffed open, iTunSMPB and LAME gapless trims and durations are exactly Apple's. The parser serves packets (`AudioFileReadPacketData`), dr_mp3 decodes them, and the reads skip the parser's priming plus the decoder's own delay (529 frames, 241 for Layers I and II), which Apple's decoder removes itself, tagged or not. A seek starts a fresh decoder ten packets early, which refills the bit reservoir and the filterbank's history, so it decodes exactly what a continuous read does. After the last packet one silent frame on its header drains the filterbank. `AudioFileHandle.appleMPEGDecoder` (class, atomic, default YES) chooses; a handle keeps the decoder it opened with; `decoderName` reports it.
- **Setting** (macOS): Settings > Advanced > MP3 decoder, Apple or dr_mp3 (`AppSettings.drMP3Decoder`, default NO), pushed at launch before the player exists and by `VibeSettingsLiveEffectMP3Decoder`; it applies from the next file opened, as its caption says. iOS has no setting and decodes with Apple's.
- **Debug verb** (both platforms, `DebugCommonVerbs.m`): `set_decoder <apple|dr_mp3>`, a session override of the setting, applying from the next open, so replay the row to hear it. `dump_audio_path`'s source stage reports `decoder`.
- **`make test-audio`**: `testDrMP3DecodesWhatAppleRoundsTo16Bits` holds `cbr.mp3`, `vbr.mp3`, `lossy.mp2` and a new `hot.mp3` fixture (the render source limited to full scale) to one length with Apple, every sample within Apple's four LSBs but the zero-filled tail and Apple's clipped samples, most samples off the 16-bit grid, the hot master's overs kept, and seeks at seven places (frame 0, a packet edge, the last frame) exact. The existing lossy render comparisons (`testMP3CBR`, `testMP3VBR`, `testMP2`) pass exactly, their reference being the handle's own decode.

A standalone harness over the production `AudioFileHandle.m` also passed CBR 320, V0, V9, untagged, mono 32 kbps, 48 kHz 32 kbps, MPEG-2 22.05 kHz, MPEG-2.5 11.025 kHz 8 kbps, MP2, a two-packet file and the three `Assets/test_audio_files` MP3s: equal lengths and processing formats, −100 dBFS RMS against Apple (its rounding), interleaved and planar reads identical, and seeks exact at twelve points. On the tagged files dr_mp3 matches mpg123 to −136…−147 dBFS; mpg123 aligns untagged files differently, so there Apple's timeline is the reference.

## Cost

Decode only, `AudioFileHandle` reading the whole file, best of seven, M-series Mac: dr_mp3 0.030% of one core on a 120 s VBR file and 0.051% on 320 kbps CBR; Apple 0.064% and 0.103%. dr_mp3 is about twice as fast, and both are noise beside the resampler (`resampler.md`).

## Damaged and unusual files

- **Truncated or damaged files end where Apple's do.** CoreAudio's parser declares more packets than such a file serves; the reads stop at the last one it does, and the flush drains only the decoder's delay, so a file cut in half, one with a 20 KB hole and one with 300 random bytes flipped all read to Apple's frame count exactly (the render test pins the truncated case).
- **Free-format MP3 never reaches either decoder**: CoreAudio refuses a LAME `--freeformat` file at open (`typ?`) under both, so nothing regresses there.
- **MP2 on iOS**: the reader's comment says an MP2 on a platform without Apple's codec fails at the client-format set; dr_mp3 needs no codec, so an iOS setting would bring MP2 playback with it. Not run on the simulator.

## Open questions

- **A damaged frame's garbage is not clipped.** With 300 bytes flipped, dr_mp3 decoded a spike to 5.96 (+15.5 dBFS) where Apple's 16-bit output clipped it at 1.0. At full volume the device clips both alike; under the volume stage or an FX send, dr_mp3's spike is the louder click. Left unclamped by decision: the choice is the user's, and Apple's remains the default.
- **MP1** is untested: nothing here encodes Layer I. dr_mp3 decodes it, and the 241-frame delay is Layer II's filterbank, which Layer I shares.
- **The live app** was not driven for this prototype (another session's debug instance held the channel); `make test-audio` plays MP3 and MP2 through the production player.
- **iOS device** cost and a listening pass are not done.
