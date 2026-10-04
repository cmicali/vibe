# Future: Dropbox streaming follow-ups

**Status: core streaming implemented; remaining options below are unstarted (reviewed 2026-10-04).** Dropbox streaming merged in [PR #134](https://github.com/cmicali/vibe/pull/134), followed by the iOS browser work in [PR #132](https://github.com/cmicali/vibe/pull/132). Playback, prefetch and waveform decoding can now use a download before it finishes. The original phase-1 plan is retired; this document keeps its measurements and the follow-ups they motivate.

## What is implemented

The current behavior and its threading rules live in [Dropbox](../../Vibe/iOS/Dropbox/AGENTS.md), [file loading](../../Vibe/Audio/Loading/AGENTS.md), [System](../../Vibe/System/AGENTS.md) and [waveform loading](../../Vibe/Audio/Waveform/AGENTS.md). Those are the implementation references, rather than a second design spec here.

- **Sequential streaming and a tail window.** The download appends to one part file. `CloudFileAvailability` exposes the written prefix and a version-checked tail, and `AudioFileHandle` waits for unavailable bytes on worker threads. Every wait is interruptible; the render never waits. Seeking beyond available bytes still waits for the sequential download.
- **Readable is separate from complete.** The first accepted response supplies the actual size, which may differ from the listing. A stream becomes readable after 256 KB if it has not already completed; its transfer lane, registry progress and foreground hold remain until the transfer ends. Served playback/prefetch handles keep the stream alive; a waveform reader rides it without holding it. An unused stream is cancelled when neither waiters nor served readers remain.
- **Version-safe resume.** Retries append to the same inode and check the response revision. A cancel or exhausted connection retry keeps a revision-tagged part for the next fetch; invalid parts are discarded and the stale sweep removes kept parts after a day, by ctime. An install that changes the placeholder's stamp invalidates the tracks' cache keys.
- **Buffering, prefetch and waveform growth.** iOS models buffering and holds Now Playing's clock during it. The successor can be prefetched as a stream. The waveform decodes the existing stream progressively, without starting a neighbouring page's download. Both waveform views now reveal the decoded extent; only a complete result is persisted. This is decoded audio coverage, not a separate map of downloaded bytes.
- **Whole-file fallback remains.** A parser needing more than the available head and tail waits until the bytes arrive. Vibe's current File Provider path still materializes the whole file before opening it. That is the implemented path, not a claim that public partial-fetch APIs cannot exist: [streaming from any source](streaming-any-source.md) records the provider investigation and the probes still needed.

## The tail window that shipped

`VibeAudioFileTailWindowBytes` sizes the window: 128 KB normally; for MP4, a 32nd of the file clamped to 512 KB–1.5 MB. A file no larger than twice its window skips the extra request. The reader is format-independent; only this sizing rule depends on the extension.

The tail request starts beside the sequential download, by the same file ID. It is installed only when both responses identify the same revision and the download's size matches the listing used to calculate the offset. A missing or mismatched revision, changed size or failed tail request drops the window; it does not fail the download. Readable never waits for the tail. A read wholly within the window uses it; a range crossing its start waits for the sequential download. The window is discarded when that download reaches it.

Recorded host-less tests opened an MP3 with an Info frame and ID3v1 tag, LAME CBR and VBR files, an index-last ALAC M4A and a FLAC with no STREAMINFO sample count on a 64 KB head and an 80 KB test window, then decoded the same PCM as the local file. A WAV did not read the window. The production sizes above are larger. A device experiment that delayed the tail until the first download response added 1.0–2.4 seconds to its arrival; starting both requests together removed that extra round trip.

The cost is one extra request for eligible transfers and up to one window downloaded twice. It avoids storing a sparse coverage map or maintaining multiple part-file writers. An index larger than the window still waits for the download. These are recorded results, not measurements repeated during this documentation review.

## Recorded format probes (2026-10-02)

The original spike logged every requested read of `VibeHandleRead` and `VibeStreamRead` through the production `AudioFileHandle` while opening, decoding the first ten seconds, and seeking (to 10 %, 50 %, 90 %, and back), over 69 files: the fixtures plus generated 6-minute and 60-minute files from ffmpeg, LAME, and afconvert. Measured on macOS 27; the same harness in the iOS 27 simulator gave identical read sequences for every file it opens. Not measured: a device's CoreAudio, files from Apple's own encoders, VBRI, APE tags, and RF64.

| Format | The open reads | A seek reads |
| --- | --- | --- |
| M4A/ALAC with `moov` first (afconvert's default, ffmpeg `+faststart`), CAF, WAV, W64, AIFF | the head only, at most 354 KB | one region at the target |
| FLAC with a known total | the head only | with a seek table, 2 to 4 regions just before the target; **without one (ffmpeg and afconvert write none), a bisection of 3 to 10 regions reaching 11 % of the file past the target** |
| MP3 with a Xing or Info frame | the head, plus 4 to 128 bytes at the end (an ID3v1 check on every open) | **every frame header between the furthest byte read and the target**: the parser ignores the Xing table |
| M4A with `moov` last (ffmpeg's default) | the head, plus one tail region: 61 KB at 6 minutes, 608 KB at 60 | one region at the target |
| FLAC with an unknown total | the head, plus 64 KB at the end | as FLAC |
| WAV with `fmt ` after `data` | the head, plus 24 bytes at the end | one region |
| Ogg Vorbis and Opus, ADTS AAC, MP3 with no Xing or Info frame | **the whole file, in order** | direct |

The last row's MP3 is no longer the open's but the count's: CoreAudio answers the packet count, ExtAudioFile's length and the maximum packet size of an MP3 with no Xing, Info or VBRI frame by reading every frame header to the end, while the bit rate, the data offset and size, the packet table and the packet size bound read a few frames. On a device, eight of ten long DJ mixes opened only when their download completed for this reason. Such a stream now opens uncounted on a count from its head's frames (`Audio/AGENTS.md`): a constant-rate head's from its bit rate, a VBR one's from the frames' average size, either an estimate, since a headerless file can change rate after its intro, settled where the reads reach the stream's end or at the first read once the download is complete, where the parser's count reads every frame header from disk. Measured on an M-class Mac with a 151 MB VBR file through the handle's 64 KB block cache, that count reads the file once, 2,447 fills: 36 ms warm, 140 ms from a cold APFS clone (without the block cache, 919,000 reads and 270 ms). The estimate's error is the head's: within 2% for an encode of steady material, but a quiet intro estimates long and a loud one short, so the decode reads past or short of it, and the player republishes the settled duration once. A device run's `MP3 stream:` lines say which files took the estimate, how far off it was, and how long the count took.

## Unimplemented alternatives

### A pre-scan, with a rule for each format

Before the open, read the regions the format needs with ranged reads, then stream. Each format can locate its index from a few bytes:

- **MP4/M4A:** walk the top-level atoms at 8 to 16 bytes a read; `mdat`'s size gives `moov`'s offset, and one read fetches it.
- **MP3:** the ID3v2 header gives the audio start, and the first frame says Xing/VBRI or CBR; with neither, the duration is size ÷ bitrate.
- **FLAC:** STREAMINFO's total, or the last ~64 KB when it is 0.
- **Ogg:** the last ~64 KB for the final page.
- **WAV/AIFF:** the chunk walk.

It fetches exactly the index and nothing more. But it is five parsers' worth of format knowledge that the decoders already have, each a new place to mis-parse and a new thing to keep in step with dr_flac, dr_wav, and Apple's parser, and it needs somewhere to put the bytes it read (for example, the sparse file below). The spike shows the tail window gets the same bytes with one blind request.

**Not recommended: having the metadata scan deposit its head blocks for later plays.** The sweep already fetches each file's head, so keeping it looks free. It is not: at the measured 230 to 360 KB a file, a 954-track folder leaves about 300 MB of blocks the download budget does not count (it skips hidden files), which the 24-hour part sweep then deletes, and which need a persisted coverage record and a version stamp to be trusted days later. That is a second cache with its own eviction, bought to save one round trip per play.

### Seeking ahead: sparse storage or an in-memory range cache

Write ranged bytes into the part file at their offsets and track which ranges are present, so the sequential download can restart from a seek point. This can accelerate a seek ahead for formats that seek directly; an in-memory range cache is another option, proposed in [streaming from any source](streaming-any-source.md). It costs the most: two writers into one file, a map shared across threads, gap filling to schedule, and coverage that must be persisted or discarded. Build it only on a measured need, and behind the same range wait, so no caller changes.

### Apple's push parser for MP3 and AAC

`AudioFileStream` parses packets as bytes arrive and estimates duration from the bitrate, so an ADTS file, which reads the whole file at open, would stream. An MP3 with no Xing frame, CBR or VBR, did not need it: the scan was our open asking for the count, and the file parser streams it once the count is taken from the head's frames and settled later (above). It is a second packet road beside the file parser, and it does nothing for Ogg. Hold it in reserve until those files prove common in a real library.

### Let AVFoundation stream (rejected)

Dropbox's `files/get_temporary_link` gives a plain HTTPS URL, and `AVPlayer` would stream it with no code of ours. It is rejected because it bypasses everything Vibe's playback is: the voice bus, the r8brain resampler, the DJ FX, gapless prefetch, the level meter, and bit-perfect output (`Audio/AGENTS.md`). The link may still be worth evaluating as the **transport**: one URL per file with plain `GET` and `Range`, and no per-request token. Unverified: how long a link lasts, and whether it pins the version it was made for.

## Remaining work, only on evidence

The default remains the sequential download plus one tail window. The recorded probes found backward seeks stayed within bytes already read; MP3 seeks ahead scan intervening frame headers, and FLAC without a seek table probes beyond the target. Measure an actual library before paying for arbitrary range fetching. The options above address narrower cases than “every forward seek becomes instant.”

A separate download-coverage display is still a product option, but progressive waveform reveal and streaming prefetch are already implemented. Any new display must distinguish downloaded bytes from decoded waveform extent; container indexes and compression mean the two fractions need not match.

The tail window is two fields on the existing `CloudFileAvailability`, not TagLib's `VibeRangedStream` block cache: the former serves one region shared by all stream handles, while the latter fetches blocks on demand for one metadata parse. If arbitrary range reads are built, re-evaluate that overlap before adding another cache. The repo's complexity budget applies to any new file or type.

## Verification for a follow-up

- Keep the existing `DropboxMirrorTests` and streaming handle suites passing: version changes, cancelled waits, short/error responses, tail failures, resume without inode replacement, and install races.
- Keep the streaming PCM comparisons in `make test-audio` sample-identical to the local file, including seeks.
- Use `set_fake_dropbox` and `fake_dropbox_fault` through the debug channel's `dropbox-streaming.sh` scenarios for transport faults. `set_fake_cloud` exercises the separate File Provider materialization path; it does not replace the Dropbox fault suite.
- Recheck on a device over a constrained link: tap-to-audio, one resume per stall, the lock-screen clock, background buffering, skip/seek cancellation, gapless prefetch and progressive waveform growth. Earlier measurements do not establish those properties for a future change.
