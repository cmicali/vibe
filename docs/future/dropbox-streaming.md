# Future: streaming Dropbox playback

**Status: in progress on the `dropbox-streaming` branch (planned and measured 2026-10-02).** Today a Dropbox track plays only once its whole file is local, its waveform starts only then, and a seek is anywhere in a complete file.

The goal: start playing once enough of a file has arrived, keep downloading while it plays, and draw the waveform as the bytes come in.

## Scope, and the platform no

**Dropbox only, iOS only.** Streaming needs a byte source the app controls. Vibe's Dropbox mirror is its own HTTP client (`Vibe/iOS/Dropbox/AGENTS.md`), so it qualifies. iCloud Drive and every other File Provider are all or nothing: a dataless file opens only after the system has materialized it whole (`CloudFileMaterializer materializeURL:`, `NSFileCoordinator`), and providers stage the download and swap it in at the end (`DownloadProgressMonitor.h`). There is no public partial-read API for them, so they are out of scope, not a later phase. The mirror exists only on iOS (`project.yml` excludes `iOS/**` from the mac).

**The full-download road stays for good.** Providers need it, and so does every file streaming declines. Streaming is therefore a second road beside it, never a replacement, and every rule below is written so that declining to stream is always safe: the file downloads whole, as today.

## What already exists

Each item was checked in the code.

- **The download is sequential and observable.** `DropboxClient`'s delegate session appends `didReceiveData` to a hidden part file from byte 0 (`downloadPath:`). The progress poll reads the transfer's written count while the target is still a placeholder (`DownloadProgressSourceAdapters.m`). Install is `chmod` plus `rename` over the placeholder (`VibeInstallPart`). A rename keeps the inode, so a descriptor opened on the part file survives the install.
- **The total size and the cache key are known before any bytes arrive.** The placeholder is a sparse file of the remote size and `server_modified`, and the install keeps both. So `NSURL+Hash.cacheKey` is the same before and after the download, and a waveform computed while streaming can be filed under the final key.
- **On iOS every decoder reads through Vibe's callbacks.** In `AudioFileHandle`, `AudioFileOpenWithCallbacks` (`VibeHandleRead`/`VibeHandleSize`), dr_flac, and dr_wav (`VibeStreamRead`/`VibeStreamSeek`) all read `pread` over one descriptor and a `_size` fixed at open; dr_mp3 takes its packets from the Apple parser. The path-based `AudioFileOpenURL` fallback is for CoreAudio's QuickTime reader, which iOS does not have (the `TRAP:` in `initParserForReading:`), so on the only platform that streams there is one seam and no exception. M4A opens through the callbacks.
- **Decode runs on worker queues, not the render.** `AudioVoiceBus` decodes on user-interactive GCD queues; `VibeVoiceBusRender` is the realtime thread. A read that waits for bytes is structurally allowed.
- **An underrun is already a pause in place.** The render zero-fills, holds the position, and counts the underrun; the voice stays live and resumes when the ring refills. Today, though, a *short read* means end of stream (`VibeStreamDrained`), so a reader that returned short at the download's edge would end the track early and cleanly.
- **The waveform is already progressive.** `AudioWaveformLoader` delivers a snapshot about every 0.1 s with `percentComplete`, persists only a complete result, and carries BPM and key on the same pass. Receivers match by `sourceKey`. The renderers already draw partial data.
- **Ranged reads exist.** `CloudFileMaterializer.remoteRead` is a blocking `(url, offset, length) → NSData` backed by `files/download` with a `Range` header. The metadata scan uses it through `VibeRangedStream` (64 KB blocks, a 384 KB first read) at about three requests per file.

## What the code makes hard

These were found reading the code, and each is a way the feature fails if it is missed.

- **A blocked read must be interruptible, and interruption is a third read outcome.** One handle has one cursor, so a seek's new voice reads on the old voice's queue and waits until "its reads are stopped for good AND its last turn is over" (`decodeQueueReadingFile:`). A read parked waiting for bytes never ends its turn, so a seek, a skip, or a stop during buffering would hang behind it. The handle open is the same problem one level up: `Loading/AGENTS.md` calls it uncancellable, and a run stays one of the six until it returns, so an open parked on a stalled download strands a run. The wait must therefore wake on three things: the bytes arrived, the download failed, or the handle was interrupted (by the voice bus where it clears `readsAllowed`, and by the coordinator's cancel). Today a read has two outcomes, short for the end and `_streamReadFailed` for an error; **interrupted is neither**, and reporting it as either ends the track or fails it.
- **A retry today swaps the file under a reader.** `didReceiveResponse` removes and recreates the destination on every response, so a resend after a 401 or a throttle makes a new inode; a reader holding the old descriptor then waits on a file that will never grow. `finishDownload:` also deletes the destination on any error.
- **Nothing pins the version.** The directory index stores only each file's `id`, and a download by `id` answers whatever is current. A resume or a ranged read after the file was re-uploaded would splice two versions into one file, and it would decode as noise or as a plausible wrong file.
- **The foreground hold would drop too early.** It is derived from claims that still have a playback or prefetch waiter (`foregroundTransferActiveLocked`). A waiter delivered at "readable" leaves the claim, so the sweep's ranged reads would resume and compete with the very stream the user is hearing.
- **The lane rule is written the other way.** "A transfer lane ends when its materialization run settles and is never carried into a handle open" (`Loading/AGENTS.md`). A streaming file's transfer is still running while its handle is open, so that sentence, and the lane arithmetic under it, must be rewritten rather than worked around.
- **The audio core cannot import the mirror.** `AudioFileHandle` is in the shared `Vibe/Audio/`, and `DropboxMirror` is under `Vibe/iOS/`; a shared source may not import an iOS-only header (`make check-layout`). The wait must reach the handle the way the fetch and the ranged read already do: as a block installed on `CloudFileMaterializer`.
- **The block cache reads ahead of what was asked.** `VibeHandleReadBlock` fills up to 64 KB from the read's position. A wait sized by the fill rather than by the request would park a 16-byte header read until 64 KB more had arrived. The wait is for the requested bytes; the fill takes whatever is there.
- **A stream resumes too eagerly.** The 4096-frame live threshold applies once, when a voice is armed (`markLiveIfReadyForSlot:`). After an underrun the render plays as soon as any frames arrive, so a link slower than the bitrate stutters in fragments instead of pausing and catching up.
- **The lock screen's clock keeps running.** Now Playing publishes `rate` whenever the state is Playing (`NowPlayingController.m`), and the system extrapolates elapsed time from it, so a buffering track's lock-screen position would run ahead of the audio.
- **A metadata bitrate may not exist yet.** Each shell defers the sweep until the picked track's open settles (`scheduleDeferredMetadataLoad`), so the first track tapped in a fresh folder has no scanned bitrate. Nothing in the start decision may depend on one.
- **The waveform gives up after 20 seconds.** `kWaveformClaimWaitSeconds` abandons a parked wait, and a streaming decode runs as long as the download does. The decode also holds one of three decode slots for that long.

## What the spike measured

Every requested read of `VibeHandleRead` and `VibeStreamRead` was logged through the production `AudioFileHandle` while opening, decoding the first ten seconds, and seeking (to 10 %, 50 %, 90 %, and back), over 69 files: the fixtures plus generated 6-minute and 60-minute files from ffmpeg, LAME, and afconvert. Measured on macOS 27; the same harness in the iOS 27 simulator gave identical read sequences for every file it opens. Not measured: a device's CoreAudio, files from Apple's own encoders, VBRI, APE tags, and RF64.

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

What follows from it:

- **Phase 1 needs no format gate.** A whole-file opener reads strictly in order, so under waiting reads its open simply returns when the download completes: today's behaviour, with no rule to write. A tail read waits the same way. Streaming a file it cannot help costs nothing and decides nothing.
- **Every tail is one region within the last 900 KB.** No format jumps anywhere else during an open, and the first ten seconds of decode never jump at all.
- **No backward seek ever read past the furthest byte already read**, in any file. Forward seeks are the only seeks that wait.
- **Ranged reads cannot speed up an MP3 seek ahead**, since the parser wants every byte up to the target, and a FLAC without a seek table probes well past its target. Seeking ahead is therefore a wait for the download in the two most common lossy and lossless formats, whatever phase 2 builds.
- **A read at or past the known size is the end, at once.** AIFF and the `fmt `-last WAV each read at `offset == size`; the wait must answer that immediately rather than park on bytes that will never exist.

## Phase 1: sequential streaming

Every read past the download's edge waits for it. So a head-only format plays as soon as its head and first seconds arrive; a format that reads its tail or its whole file at open starts when the download gets there, as today; a seek ahead waits; and a CUE row deep in a large image starts when the download reaches it.

1. **One wait, shaped as a range.** The seam is a third block installed on `CloudFileMaterializer` beside the fetch and the ranged read: "block until `[offset, offset + length)` of this URL is readable, the transfer failed, or this wait was interrupted". `AudioFileHandle` calls it from its read callbacks and knows nothing of Dropbox, so a test feeds it a throttled local file. Asking for a range rather than a single "bytes so far" number costs nothing now and means phase 2 changes what answers the wait, not who calls it. Behind it, `DropboxMirror` keeps the bytes written so far per streaming path. Whether that needs a type of its own or is a field on the transfer the mirror already tracks is settled when it is written; the budget is zero new types, and a number plus a condition is not obviously one.
2. **A streaming mode for `AudioFileHandle`.** Open the part file, take `_size` from the placeholder rather than `fstat`, and wait for the requested bytes before each `pread`. A read returns short only at the true end. A read at or past `_size` never waits. A failed transfer is `_streamReadFailed`, as any read error is. An interrupted wait is a third outcome that neither ends nor fails the stream: the turn ends, and the voice or the open that asked is already being torn down.
3. **A transfer that never restarts under a reader.** A resend after a 401 or a throttle, and a bounded number of retries after a network error, continue with `Range: bytes=<written>-` and append to the same file. The destination is created once per transfer, never per response. Every response's `Dropbox-API-Result` `rev` must equal the first response's; a mismatch fails the transfer, wakes its readers with an error, and deletes the part, since the file changed and nothing already read can be trusted. A cancel deletes the part, as today: resuming across launches would need a persisted version stamp, and nothing here needs it.
4. **Readable, then complete.** A stage-1 claim for a streamable file reports **readable** once its transfer's first response has been checked, and stays `Running` until the transfer is **complete**. Handle runs dispatch on readable. The claim keeps its lane, its `CloudTransferRegistry` entry, and its row's loading bar until complete, because the transfer is still running; and it counts toward the foreground hold while a playback or prefetch handle is reading from it, not only while a waiter is parked on it. The handle-run ceiling and the lane bounds are re-derived with this in mind, and their tests with them.
5. **Buffering, with one hysteresis.** `AudioPlayer` gains a modeled buffering flag beside its state, raised when the current voice's decode has waited for bytes past a short grace. While it is up the voice is held by the existing pause path, and released when the ring has refilled, so playback resumes once rather than in fragments. This is a decision the player makes from the voice's snapshot; the render is not touched. The transport and mini player draw it, and Now Playing publishes rate 0 for it. A stall past a no-progress deadline (the model `AudioFileOpenTimeoutMath.h` already has for opens) pauses with an error, "Lost connection", and never skips to the next track. **Verify on a device that buffering in the background does not trip the iOS output's idle stop** (`Audio/iOS/AGENTS.md`): a suspended app's download dies, so the output must stay running while a stream buffers.
6. **When to start.** Correctness comes from the waiting reads alone: the open and the first decode turn simply wait for what they need, and the voice goes live at its usual threshold. A start threshold is only there to avoid a stutter in the first second, so it is a fixed number of bytes past the open's last read, tuned by measurement. It never depends on a scanned bitrate.
7. **The waveform on the same source.** The iOS `isDatalessFile:` skip (`PlayerViewController+Pager.m`) is lifted only for a file with a live stream, never for any placeholder: a neighbouring page must not start a download by being swiped past. The loader opens its own streaming handle and fills in as the download proceeds, and it still persists only when complete. It never holds the stream, only the play's handles do, so a skip or the play's stall deadline ends it through the transfer's cancel; the parked-wait timeout stays as it is, since it bounds a request behind a cancelled worker, which a cancel's interrupt now ends promptly. BPM and key still finish at EOF. One decode slot is held for the length of the download; with one playing track that leaves two, which is acceptable, but a streaming prefetch (phase 3) must not take a second.
8. **Re-key on a changed version.** If the transfer's `server_modified` differs from the listing's (re-uploaded since the listing), the track's memoized `cacheKey` is stale, and its waveform and metadata would be filed under it. Streaming does not cause this, but it should be fixed here: invalidate and re-key when the installed version differs from the placeholder's.

**What phase 1 removes.** The assumption "Ready means the whole file" leaves `DropboxMirror.h`, `CloudFileMaterializer.h`, and `Loading/AGENTS.md`, replaced by readable and complete. The transfer's restart-from-zero path goes: one resumable road serves streaming and ordinary downloads alike, which also makes a large ordinary download survive a throttle without starting over.

## Phase 2: the tail, and seeking ahead

Phase 1 leaves two gaps. Formats whose open touches the tail wait for the whole download, and a seek past the download's edge waits too. The options, cheapest to maintain first.

### Option A: a tail window, in memory (built)

**Built on the `dropbox-streaming` branch** (`DropboxMirror readTailOfPath:…`, `CloudFileAvailability installWindow:atOffset:`, `AudioFileHandle`'s three read paths). Measured in the host-less tests: an MP3 with an Info frame and an ID3v1 tag, LAME's CBR and VBR encodes, an ALAC M4A with its `moov` last, and a FLAC whose STREAMINFO counts no samples each open on a 64 KB head and an 80 KB window without waiting, and decode exactly as the whole file; a WAV never reads the window. Where it differs from the sketch below: **the window is sized per format** (`VibeAudioFileTailWindowBytes`): 128 KB for MP3, FLAC, WAV, AIFF, W64, CAF and anything unknown, twice the largest end read measured (FLAC's 64 KB); an MP4's is a 32nd of the file, from ~10 KB of `moov` a minute of AAC against 960 KB a minute of 128 kbps audio, between a 512 KB floor and a 1.5 MB cap that holds a two-hour mix's 1.2 MB index with headroom, so a longer index-last M4A waits for its download as before. A file at most twice its window skips it. **The tail read starts with the download, by the same id**, not at its first response by `rev:`: on a device that wait put the window 1.0–2.4 s after readable, one Dropbox first byte, and the MP3 opened only then. A read by id answers whatever version is current, so the window is installed only once both answers are in and name one rev, the download's size matching the listing's the offset came from. **Readable does not wait for the window**; a range straddling its start waits for the download; and the window is not `VibeRangedStream`'s cache moved (below, under costs). A tag read during a play takes the stream's bytes, waiting briefly for its head and window, so it adds no request.

When a stream starts, one ranged read fetches the file's tail into memory, and a read that falls inside that window is served from it instead of waiting. Everything else is phase 1: the sequential download keeps writing the one part file from byte 0, with one writer, and the window is dropped when the download reaches it.

- **It is exactly what the spike measured.** Every tail-reading open touched one region within the last 900 KB, at most 608 KB of it; 1.5 MB covers the `moov` of a two-hour AAC mix with headroom (inferred from 10 KB a minute). With it, an M4A with `moov` last, a FLAC with an unknown total, and every MP3's ID3v1 check open from the head.
- **Format-blind.** No rule per format and no sniffing: the decoders ask for their index and find it there.
- **It degrades to today.** A read past the edge and outside the window waits, so a `moov` larger than the window, or a format nobody measured, waits for the download as it does now.
- **No new storage.** No sparse file, no coverage map, no second writer, nothing persisted, and at most 1.5 MB a stream held in memory.
- **The cost:** one extra request per play, and 128 KB (an MP4: up to 1.5 MB) downloaded twice. A file at most twice its window skips it, since the download gets there as fast.

**Seeking ahead is left as a wait.** A general overlay that fetched any far read would serve only M4A, WAV, and FLAC with a seek table; the spike shows MP3 and seek-table-less FLAC cannot use it. That is not worth a second mechanism. If seeking ahead in those formats later matters, the window generalizes to a block cache keyed by offset, behind the same wait, and `VibeRangedStream`'s cache is the one to share.

### Option B: a pre-scan, with a rule for each format

Before the open, read the regions the format needs with ranged reads, then stream. Each format can locate its index from a few bytes:

- **MP4/M4A:** walk the top-level atoms at 8 to 16 bytes a read; `mdat`'s size gives `moov`'s offset, and one read fetches it.
- **MP3:** the ID3v2 header gives the audio start, and the first frame says Xing/VBRI or CBR; with neither, the duration is size ÷ bitrate.
- **FLAC:** STREAMINFO's total, or the last ~64 KB when it is 0.
- **Ogg:** the last ~64 KB for the final page.
- **WAV/AIFF:** the chunk walk.

It fetches exactly the index and nothing more. But it is five parsers' worth of format knowledge that the decoders already have, each a new place to mis-parse and a new thing to keep in step with dr_flac, dr_wav, and Apple's parser, and it needs somewhere to put the bytes it read (the sparse file of option C). The spike shows the tail window gets the same bytes with one blind request.

**Not recommended: having the metadata scan deposit its head blocks for later plays.** The sweep already fetches each file's head, so keeping it looks free. It is not: at the measured 230 to 360 KB a file, a 954-track folder leaves about 300 MB of blocks the download budget does not count (it skips hidden files), which the 24-hour part sweep then deletes, and which need a persisted coverage record and a version stamp to be trusted days later. That is a second cache with its own eviction, bought to save one round trip per play.

### Option C: a sparse part file with a coverage map

Write ranged bytes into the part file at their offsets and track which ranges are present, so the sequential download can restart from a seek point. This is the only option that makes a seek ahead fast, and only for the formats that seek directly. It costs the most: two writers into one file, a map shared across threads, gap filling to schedule, and coverage that must be persisted or discarded. Build it only on a measured need, and behind the same range wait, so no caller changes.

### Option D: Apple's push parser for MP3 and AAC

`AudioFileStream` parses packets as bytes arrive and estimates duration from the bitrate, so an ADTS file, which reads the whole file at open, would stream. An MP3 with no Xing frame, CBR or VBR, did not need it: the scan was our open asking for the count, and the file parser streams it once the count is taken from the head's frames and settled later (above). It is a second packet road beside the file parser, and it does nothing for Ogg. Hold it in reserve until those files prove common in a real library.

### Option E: let AVFoundation stream (rejected)

Dropbox's `files/get_temporary_link` gives a plain HTTPS URL, and `AVPlayer` would stream it with no code of ours. It is rejected because it bypasses everything Vibe's playback is: the voice bus, the r8brain resampler, the DJ FX, gapless prefetch, the level meter, and bit-perfect output (`Audio/AGENTS.md`). The link may still be worth evaluating as the **transport**: one URL per file with plain `GET` and `Range`, and no per-request token. Unverified: how long a link lasts, and whether it pins the version it was made for.

### Option F: stop after phase 1

Head-only formats and MP3 are served by phase 1 only if an MP3's 4-byte ID3v1 check is too: without the tail window every MP3 open waits for the whole file. So stopping here serves FLAC, WAV, AIFF, and `moov`-first M4A, and nothing else.

### Recommendation

**Phase 1, then option A, and nothing else until a measurement asks for it.** Option A is no longer optional in practice: CoreAudio reads the last bytes of every MP3 at open, so without the window the most common format never streams. It adds one request and one comparison to phase 1's read, and its failure mode is today's behaviour. Options B, C, and D each add a mechanism with its own state to keep correct, for cases the spike shows are narrower than they looked.

## Phase 3: polish

- **Draw the region not yet downloaded differently.** Today an unfilled chunk is zero and reads as silence, a flat hairline (`WaveformMorphEngine.h`). A streaming delivery should carry the downloaded fraction beside `percentComplete`, so the renderer can dim the region past it on both the mac view and the iOS scrubber. The same fraction is the scrubber's buffer bar.
- **Streaming prefetch for gapless.** The successor needs only its header and a few seconds to be armed. It must not hold the one-wide background lane for a whole file or take a second waveform decode slot, and it must not start a second stream while the current track is buffering.

## Costs, and the cross-directory guarantees it touches

- **"The open the user is waiting on outranks every background read"** must hold while a stream is readable but incomplete. The hold stays raised for as long as a playback or prefetch handle reads from a running transfer.
- **"The handle-open ceiling"** is derived from one player with two open sources and lanes that end before a handle opens. Both halves change, so the derivation and its tests are redone (`Audio/Loading/AGENTS.md`).
- **A new guarantee: a wait for bytes happens only on decode, loader, and open workers, never on the render thread or main, and every such wait can be interrupted.** It replaces the "Ready means the whole file" assumption rather than adding to the total.
- **New types: one.** `CloudFileAvailability` (`Vibe/System/`) is the wait: a byte count and a condition, shared code so the handle and its tests never see Dropbox. Everything else lands in the classes that own the concern. The tail window is two fields on it, not `VibeRangedStream`'s cache moved: that cache is a C++ map of 64 KB blocks behind TagLib's `IOStream`, each filled on demand by a blocking ranged read and kept for one parse, while the window is one contiguous region filled once, ahead of any read, shared by every handle on the stream, and dropped when the download reaches it. Sharing would have brought a block map, on-demand fetching and C++ into a Foundation-only wait to serve one region, so the two stay apart until seeking ahead (above) needs a block cache.
- **Two roads, permanently.** The full download remains for providers and for declined files, so every change must keep it working, and the tests run both.

## Testing

- `DropboxMirrorTests` already drives the client over a stubbed `NSURLProtocol`. Throttling its delivery gives deterministic slow downloads, mid-file failures, 401 and throttle resumes that append rather than truncate, and a `rev` that changes between responses.
- A streaming handle over a throttled local source, with no Dropbox at all: reads wait, an interrupt wakes them without ending or failing the stream, and a failure fails it.
- `make test-audio` plays a streaming handle through the debug render pump and asserts PCM equality with the local file: once complete, streaming must be sample-identical, seeks included.
- The vibe-stress cloud scenarios (`set_fake_cloud`) cover stall, resume, skip while buffering, seek while buffering, and seek past the download's edge. A hang on any of them is the interrupt rule broken.
- On a device, over a constrained link: time from tap to first audio against the spike's baseline, one resume per stall rather than a stutter, the lock-screen clock holding during buffering, buffering while backgrounded, and the waveform filling as the download proceeds.
