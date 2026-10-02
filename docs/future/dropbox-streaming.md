# Future: streaming Dropbox playback

**Status: planned, not implemented (written and reviewed against the code 2026-10-02).** Today a Dropbox track plays only once its whole file is local, its waveform starts only then, and a seek is anywhere in a complete file.

The goal: start playing once enough of a file has arrived, keep downloading while it plays, and draw the waveform as the bytes come in.

## Scope, and the platform no

**Dropbox only, iOS only.** Streaming needs a byte source the app controls. Vibe's Dropbox mirror is its own HTTP client (`Vibe/iOS/Dropbox/AGENTS.md`), so it qualifies. iCloud Drive and every other File Provider are all or nothing: a dataless file opens only after the system has materialized it whole (`CloudFileMaterializer materializeURL:`, `NSFileCoordinator`), and providers stage the download and swap it in at the end (`DownloadProgressMonitor.h`). There is no public partial-read API for them, so they are out of scope, not a later phase. The mirror exists only on iOS (`project.yml` excludes `iOS/**` from the mac).

**The full-download road stays for good.** Providers need it, and so does every file streaming declines. Streaming is therefore a second road beside it, never a replacement, and every rule below is written so that declining to stream is always safe: the file downloads whole, as today.

## What already exists

Each item was checked in the code.

- **The download is sequential and observable.** `DropboxClient`'s delegate session appends `didReceiveData` to a hidden part file from byte 0 (`downloadPath:`). The progress poll stats the part file's size while the target is still a placeholder (`DownloadProgressSourceAdapters.m`). Install is `chmod` plus `rename` over the placeholder (`VibeInstallPart`). A rename keeps the inode, so a descriptor opened on the part file survives the install.
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

## The spike that comes first (about a day)

Measure before building: which bytes does each decoder touch? Instrument `VibeHandleRead`, `VibeStreamRead`, and `VibeStreamSeek` to log the furthest offset and every jump past the current read point, during three things: the open, the first ten seconds of decode, and **seeks** (to 10 %, 50 %, and 90 %, and back). Seeks matter because dr_flac without a seek table bisects the byte range up to `_size`, and a probe can land past the download's edge even for a target behind it.

Run every format in `Assets/test_audio_files`, plus a sample of real library files: iTunes-encoded and ffmpeg-encoded M4A, LAME MP3 with and without a Xing frame, FLAC with and without STREAMINFO totals and seek tables, Ogg Vorbis and Opus, and WAV with `fmt ` after `data`.

The output is a table of format × encoder: for each, how many bytes past the read point the open touches, where, and in how many separate regions. That table decides which formats phase 1 serves, whether phase 2 is needed at all, and what its caps should be. Also record today's time from tap to first audio for the same files over a throttled link, as the number the feature must beat.

Expected, still unverified:

- **Streams from the head:** FLAC with a known total, WAV/AIFF, and MP3 with Xing/VBRI.
- **Touches the tail:** MP4/M4A with `moov` after `mdat`; MP3 without a Xing frame, where Apple's parser may walk every packet to count them; FLAC with an unknown total, where the patched `drflac__find_unknown_total_pcm_frame_count` reads the end; Ogg, whose duration is the last page's granule position; and ID3v1 and APE trailers.

## Phase 1: sequential streaming for the formats that stream from the head

Every format the spike marks "touches the tail" keeps today's full download. A read past the download's edge waits for it, so a seek ahead waits, and a CUE row deep in a large image starts when the download reaches it, as it does today.

1. **One wait, shaped as a range.** The seam is a third block installed on `CloudFileMaterializer` beside the fetch and the ranged read: "block until `[offset, offset + length)` of this URL is readable, the transfer failed, or this wait was interrupted". `AudioFileHandle` calls it from its read callbacks and knows nothing of Dropbox, so a test feeds it a throttled local file. Asking for a range rather than a single "bytes so far" number costs nothing now and means phase 2 changes what answers the wait, not who calls it. Behind it, `DropboxMirror` keeps the bytes written so far per streaming path. Whether that needs a type of its own or is a field on the transfer the mirror already tracks is settled when it is written; the budget is zero new types, and a number plus a condition is not obviously one.
2. **A streaming mode for `AudioFileHandle`.** Open the part file, take `_size` from the placeholder rather than `fstat`, and wait for the requested bytes before each `pread`. A read returns short only at the true end. A failed transfer is `_streamReadFailed`, as any read error is. An interrupted wait is a third outcome that neither ends nor fails the stream: the turn ends, and the voice or the open that asked is already being torn down.
3. **A transfer that never restarts under a reader.** A resend after a 401 or a throttle, and a bounded number of retries after a network error, continue with `Range: bytes=<written>-` and append to the same file. The destination is created once per transfer, never per response. Every response's `Dropbox-API-Result` `rev` must equal the first response's; a mismatch fails the transfer, wakes its readers with an error, and deletes the part, since the file changed and nothing already read can be trusted. A cancel deletes the part, as today: resuming across launches would need a persisted version stamp, and nothing here needs it.
4. **Readable, then complete.** A stage-1 claim for a streamable file reports **readable** once its transfer's first response has been checked, and stays `Running` until the transfer is **complete**. Handle runs dispatch on readable. The claim keeps its lane, its `CloudTransferRegistry` entry, and its row's loading bar until complete, because the transfer is still running; and it counts toward the foreground hold while a playback or prefetch handle is reading from it, not only while a waiter is parked on it. The handle-run ceiling and the lane bounds are re-derived with this in mind, and their tests with them.
5. **Buffering, with one hysteresis.** `AudioPlayer` gains a modeled buffering flag beside its state, raised when the current voice's decode has waited for bytes past a short grace. While it is up the voice is held by the existing pause path, and released when the ring has refilled, so playback resumes once rather than in fragments. This is a decision the player makes from the voice's snapshot; the render is not touched. The transport and mini player draw it, and Now Playing publishes rate 0 for it. A stall past a no-progress deadline (the model `AudioFileOpenTimeoutMath.h` already has for opens) pauses with an error, "Lost connection", and never skips to the next track. **Verify on a device that buffering in the background does not trip the iOS output's idle stop** (`Audio/iOS/AGENTS.md`): a suspended app's download dies, so the output must stay running while a stream buffers.
6. **When to start.** Correctness comes from the waiting reads alone: the open and the first decode turn simply wait for what they need, and the voice goes live at its usual threshold. A start threshold is only there to avoid a stutter in the first second, so it is a fixed number of bytes past the open's last read, tuned by measurement. It never depends on a scanned bitrate.
7. **The waveform on the same source.** The iOS `isDatalessFile:` skip (`PlayerViewController+Pager.m`) is lifted only for a file with a live stream, never for any placeholder: a neighbouring page must not start a download by being swiped past. The loader opens its own streaming handle and fills in as the download proceeds, and it still persists only when complete. Its parked-wait timeout becomes progress-based for a streaming decode, as the open deadline is. BPM and key still finish at EOF. One decode slot is held for the length of the download; with one playing track that leaves two, which is acceptable, but a streaming prefetch (phase 3) must not take a second.
8. **Re-key on a changed version.** If the transfer's `server_modified` differs from the listing's (re-uploaded since the listing), the track's memoized `cacheKey` is stale, and its waveform and metadata would be filed under it. Streaming does not cause this, but it should be fixed here: invalidate and re-key when the installed version differs from the placeholder's.

**What phase 1 removes.** The assumption "Ready means the whole file" leaves `DropboxMirror.h`, `CloudFileMaterializer.h`, and `Loading/AGENTS.md`, replaced by readable and complete. The transfer's restart-from-zero path goes: one resumable road serves streaming and ordinary downloads alike, which also makes a large ordinary download survive a throttle without starting over.

## Phase 2: the tail, and seeking ahead

Phase 1 leaves two gaps. Formats whose open touches the tail wait for the whole download, and a seek past the download's edge waits too. The options, cheapest to maintain first.

### Option A: a ranged overlay, in memory (recommended)

A read past the download's edge that is **far** from it is served by a ranged read into an in-memory block cache; a read **near** it waits, as in phase 1. Nothing else changes: the sequential download keeps writing the one part file, from byte 0, with one writer. The cached blocks are dropped as the download passes them.

- **Format-blind.** The decoders are the format experts and already know where their index is. An M4A's parser reads `mdat`'s header, jumps to `moov`, and reads it; each jump is a block fetch with read-ahead, and a few hundred KB of `moov` arrives in one or two requests. The same holds for an Ogg tail, a FLAC end scan, and an ID3v1 trailer, with no rule written for any of them.
- **Seeking ahead comes with it.** A seek past the edge reads there, the overlay fetches ahead of the play position in larger blocks, and playback continues from memory until the download catches up.
- **Bounded, and it degrades to today.** Two caps: bytes fetched during an open, and blocks held in memory. An open that exceeds its cap (an MP3 with no Xing frame, whose parser walks every packet) abandons streaming for that file and waits for the whole download, which is today's behaviour. The spike's table sets the caps.
- **No new storage.** No sparse file, no coverage map, no second writer, nothing persisted, and nothing for the download budget or the 24-hour part sweep to learn about.
- **What it consolidates.** `VibeRangedStream`'s aligned block cache (fetch a run of missing blocks in one request, deeper for the first) is the same mechanism. It moves out of the TagLib adapter into one cache that both the tag parse and the handle use, rather than gaining a twin.
- **The cost: some bytes are downloaded twice.** Whatever plays from the overlay is fetched again by the sequential download. For an open's index that is a few hundred KB. For a seek to the middle right after starting, it is everything played before the download catches up. Measure it; if it matters, option C addresses exactly this and nothing else.

### Option B: a pre-scan, with a rule for each format

Before the open, read the regions the format needs with ranged reads, then stream. Each format can locate its index from a few bytes:

- **MP4/M4A:** walk the top-level atoms at 8 to 16 bytes a read; `mdat`'s size gives `moov`'s offset, and one read fetches it.
- **MP3:** the ID3v2 header gives the audio start, and the first frame says Xing/VBRI or CBR; with neither, the duration is size ÷ bitrate.
- **FLAC:** STREAMINFO's total, or the last ~64 KB when it is 0.
- **Ogg:** the last ~64 KB for the final page.
- **WAV/AIFF:** the chunk walk.

It makes the fewest requests, and each is predictable. But it is five parsers' worth of format knowledge that the decoders already have, each a new place to mis-parse and a new thing to keep in step with dr_flac, dr_wav, and Apple's parser. It needs somewhere to put the bytes it read (the sparse file of option C), and it does nothing for seeking ahead. Option A gets the same bytes by letting the decoder ask for them. Worth revisiting only if the spike shows a format the overlay serves badly.

**Not recommended: having the metadata scan deposit its head blocks for later plays.** The sweep already fetches each file's head, so keeping it looks free. It is not: at the measured 230 to 360 KB a file, a 954-track folder leaves about 300 MB of blocks the download budget does not count (it skips hidden files), which the 24-hour part sweep then deletes, and which need a persisted coverage record and a version stamp to be trusted days later. That is a second cache with its own eviction, bought to save one round trip per play.

### Option C: a sparse part file with a coverage map

Write ranged bytes into the part file at their offsets and track which ranges are present, so the sequential download can skip what is already there and restart from a seek point. This removes option A's double download. It costs the most: two writers into one file, a map shared across threads, gap filling to schedule, and coverage that must be persisted or discarded. Build it only on a measured need, and behind the same range wait, so no caller changes.

### Option D: Apple's push parser for MP3 and AAC

`AudioFileStream` parses packets as bytes arrive and estimates duration from the bitrate, so an MP3 without a Xing frame would stream. It helps two formats and is a second packet road beside the file parser. Hold it in reserve for exactly that case, if the spike shows it is common in the library.

### Option E: let AVFoundation stream (rejected)

Dropbox's `files/get_temporary_link` gives a plain HTTPS URL, and `AVPlayer` would stream it with no code of ours. It is rejected because it bypasses everything Vibe's playback is: the voice bus, the r8brain resampler, the DJ FX, gapless prefetch, the level meter, and bit-perfect output (`Audio/AGENTS.md`). The link may still be worth evaluating as the **transport**: one URL per file with plain `GET` and `Range`, and no per-request token. Unverified: how long a link lasts, and whether it pins the version it was made for.

### Option F: stop after phase 1

If the spike shows that most of the library streams from the head, stop. That is honest and cheap. Its cost depends on the library: an iTunes-heavy M4A collection gets nothing.

### Recommendation

**Phase 1, then option A if the spike's table shows tail-touching formats are common, and nothing else until a measurement asks for it.** Option A adds one decision to phase 1's read ("near: wait; far: fetch") and one shared block cache, and its failure mode is today's behaviour. Options B and C each add a mechanism with its own state to keep correct, and are justified only by numbers this plan does not have yet.

## Phase 3: polish

- **Draw the region not yet downloaded differently.** Today an unfilled chunk is zero and reads as silence, a flat hairline (`WaveformMorphEngine.h`). A streaming delivery should carry the downloaded fraction beside `percentComplete`, so the renderer can dim the region past it on both the mac view and the iOS scrubber. The same fraction is the scrubber's buffer bar.
- **Streaming prefetch for gapless.** The successor needs only its header and a few seconds to be armed. It must not hold the one-wide background lane for a whole file or take a second waveform decode slot, and it must not start a second stream while the current track is buffering.

## Costs, and the cross-directory guarantees it touches

- **"The open the user is waiting on outranks every background read"** must hold while a stream is readable but incomplete. The hold stays raised for as long as a playback or prefetch handle reads from a running transfer.
- **"The handle-open ceiling"** is derived from one player with two open sources and lanes that end before a handle opens. Both halves change, so the derivation and its tests are redone (`Audio/Loading/AGENTS.md`).
- **A new guarantee: a wait for bytes happens only on decode, loader, and open workers, never on the render thread or main, and every such wait can be interrupted.** It replaces the "Ready means the whole file" assumption rather than adding to the total.
- **New types: aim for none.** The wait is a block on `CloudFileMaterializer`; the bytes written live with the transfer; the block cache is `VibeRangedStream`'s, moved.
- **Two roads, permanently.** The full download remains for providers and for declined files, so every change must keep it working, and the tests run both.

## Testing

- `DropboxMirrorTests` already drives the client over a stubbed `NSURLProtocol`. Throttling its delivery gives deterministic slow downloads, mid-file failures, 401 and throttle resumes that append rather than truncate, and a `rev` that changes between responses.
- A streaming handle over a throttled local source, with no Dropbox at all: reads wait, an interrupt wakes them without ending or failing the stream, and a failure fails it.
- `make test-audio` plays a streaming handle through the debug render pump and asserts PCM equality with the local file: once complete, streaming must be sample-identical, seeks included.
- The vibe-stress cloud scenarios (`set_fake_cloud`) cover stall, resume, skip while buffering, seek while buffering, and seek past the download's edge. A hang on any of them is the interrupt rule broken.
- On a device, over a constrained link: time from tap to first audio against the spike's baseline, one resume per stall rather than a stutter, the lock-screen clock holding during buffering, buffering while backgrounded, and the waveform filling as the download proceeds.
