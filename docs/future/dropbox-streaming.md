# Future: streaming Dropbox playback

**Status: planned, not implemented (written 2026-10-02).** Today a Dropbox track plays only once its whole file is local, its waveform starts only then, and a seek is anywhere in a complete file.

The goal: start playing once enough of a file has arrived, keep downloading while it plays, and draw the waveform as the bytes come in.

## Scope, and the platform no

**Dropbox only, iOS only.** Streaming needs a byte source the app controls. Vibe's Dropbox mirror is its own HTTP client (`Vibe/iOS/Dropbox/AGENTS.md`), so it qualifies. iCloud Drive and every other File Provider are all or nothing: a dataless file opens only after the system has materialized it whole (`CloudFileMaterializer materializeURL:`, `NSFileCoordinator`), and providers stage the download and swap it in at the end (`DownloadProgressMonitor.h`). There is no public partial-read API for them, so they are out of scope, not a later phase. The mirror exists only on iOS (`project.yml` excludes `iOS/**` from the mac).

## What already exists

Much of the groundwork is in place. Each item below was checked in the code.

- **The download is sequential and observable.** `DropboxClient`'s delegate session appends `didReceiveData` to a hidden part file from byte 0 (`DropboxClient.m`, `downloadPath:`). The progress poll stats the part file's size while the target is still a placeholder (`DownloadProgressSourceAdapters.m`). Install is `chmod` plus `rename` over the placeholder (`VibeInstallPart`). A rename keeps the inode, so a descriptor opened on the part file survives the install.
- **The total size and the cache key are known before any bytes arrive.** The placeholder is a sparse file of the remote size and `server_modified`, and the install keeps both. So `NSURL+Hash.cacheKey` is the same before and after the download, and a waveform computed while streaming can be filed under the final key.
- **Every decoder except one reads through Vibe's callbacks.** In `AudioFileHandle`, `AudioFileOpenWithCallbacks` (`VibeHandleRead`/`VibeHandleSize`), dr_flac and dr_wav (`VibeStreamRead`/`VibeStreamSeek`) all read `pread` over one descriptor and a `_size` fixed at open. dr_mp3 takes its packets from the Apple parser. The exception is QuickTime/MooV, which falls back to path-based `AudioFileOpenURL`. This is the single seam a streaming source plugs into.
- **Decode runs on worker queues, not the render.** `AudioVoiceBus` decodes on user-interactive GCD queues; `VibeVoiceBusRender` is the realtime thread. A read that blocks at a download frontier is structurally allowed.
- **An underrun is already a pause in place.** The render zero-fills, holds the position and counts the underrun; the voice stays live and resumes when the ring refills. Today, though, a *short read* means end of stream (`VibeStreamDrained`), so a reader that returned short at the frontier would end the track early and cleanly.
- **The waveform is already progressive.** `AudioWaveformLoader` delivers a snapshot about every 0.1 s, with `percentComplete`. It persists only a complete result, and BPM and key ride the same pass. Receivers match by `sourceKey`. The renderers already draw partial data, because every local decode is partial for its first second.
- **Ranged reads exist.** `CloudFileMaterializer.remoteRead` is a blocking `(url, offset, length) → NSData` backed by `files/download` with a `Range` header. The metadata scan uses it through `VibeRangedStream` (64 KB blocks, a 384 KB first read) at about three requests per file.

## The spike that comes first (about a day)

Measure before building: which bytes does each decoder touch while opening and during the first ten seconds? Instrument `VibeHandleRead`, `VibeStreamRead` and `VibeStreamSeek` to log the furthest offset and every jump past the current read point. Run every format in `Assets/test_audio_files`, plus a sample of real library files (iTunes-encoded and ffmpeg-encoded M4A, LAME MP3 with and without a Xing frame, FLAC with and without STREAMINFO totals, Ogg Vorbis and Opus, WAV with `fmt ` after `data`).

The output is a table of format × encoder, each row marked **streams from the head** or **touches the tail**, with the tail size. That table decides which formats phase 1 serves and which phase 2 option fits.

Expected, still unverified:

- **Streams from the head:** FLAC with a known total, WAV/AIFF, and MP3 with Xing/VBRI.
- **Touches the tail:**
  - MP4/M4A with `moov` after `mdat` (and these take the path-based QuickTime fallback today anyway);
  - MP3 without a Xing frame, where Apple's parser may walk every packet to count them;
  - FLAC with an unknown total, where the patched `drflac__find_unknown_total_pcm_frame_count` reads the end;
  - Ogg, whose duration is the last page's granule position;
  - ID3v1 and APE trailers.

## Phase 1: sequential streaming for the formats that stream from the head

Every format the spike marks "touches the tail" keeps today's full download. Seeking past the frontier waits for the download to reach it.

1. **A download frontier.** One per streaming file, owned by `DropboxMirror` and keyed by path. It publishes "bytes written so far" from `didReceiveData`, lets readers wait on it, and wakes them with an error on failure or cancel. This is likely the feature's one new type, and its proposal must make that case.
2. **Resumable downloads.** Today a retry after `expired_access_token` or a throttle truncates and restarts from byte 0 (`DropboxClient` `didReceiveResponse` and the resend). With a live reader that corrupts the file under it. A retry must continue from the frontier with `Range: bytes=<frontier>-` and append. A network drop after a long stall resumes the same way.
3. **A streaming mode for `AudioFileHandle`.** Open the part file, take `_size` from the placeholder's size rather than `fstat`, and make the read callbacks wait at the frontier instead of returning short. They return short only at the true end, or with an error once the frontier reports failure. The 64 KB block cache in `VibeHandleRead` must not cache a block past the frontier.
4. **An early ready in the coordinator.** Stage 1 settles **ready to stream** once the frontier passes the open threshold: the format's header plus a few seconds of audio, sized by the bitrate the metadata scan already found. The run itself stays open until the download completes: it keeps its lane, the foreground hold, the `CloudTransferRegistry` entry and the row's loading bar, because the transfer is still running. That splits today's single "Ready" into *readable* and *complete*.
5. **A buffering state.** `AudioPlayer`'s states are Stopped, Loading, Playing and Paused, with nothing for "playing but starved". A reader waiting at the frontier, or a run of underruns, raises a modeled **buffering** flag. The transport and mini player draw it, and it clears by itself. A stall past a deadline, on the same no-progress model as `AudioFileOpenTimeoutMath.h`, becomes an error ("Lost connection") that pauses rather than skips.
6. **The waveform on the same source.** Remove the iOS `isDatalessFile:` skip (`PlayerViewController+Pager.m`) for a streaming file. The loader opens the same frontier-aware handle and so fills in as the download proceeds, and it still persists only when complete. BPM and key still finish at EOF.
7. **Re-key on a changed version.** If the download's `Dropbox-API-Result` `server_modified` differs from the listing's (re-uploaded since the listing), the track's memoized `cacheKey` is stale. Streaming makes this case more common rather than causing it, so it is fixed here: invalidate and re-key when the install's version differs from the placeholder's.

## Phase 2: the tail, and seeking ahead

Phase 1 leaves two gaps. Formats whose open touches the tail wait for the whole download, and a seek past the frontier waits too. These are the options.

### Option A: a pre-scan, before streaming starts

Before the open, read exactly the regions the format needs (its header and its end index) with ranged reads, write them into the part file at their real offsets, then start the sequential download after the header. The reader's coverage becomes **one head prefix that grows, plus a fixed set of islands**, not just one frontier.

Each format locates its index from a few bytes, so the pre-scan is a short, bounded walk rather than a guess:

- **MP4/M4A:** walk the top-level atoms at 8 to 16 bytes a read (`ftyp`, `free`, `mdat`). `mdat`'s size gives `moov`'s exact offset, so one ranged read fetches `moov` whole. That is a few hundred KB for a long file, and enough for the parser. These files also need the QuickTime fallback replaced by the callback open (or proof that the callback parser handles them), or they cannot stream at all.
- **MP3:** the ID3v2 header gives the audio start. The first frame says Xing/VBRI/LAME or CBR. With neither, the duration is size ÷ bitrate, exact for CBR. A real VBR file without a Xing frame is rare and keeps the full download. The last 128 bytes (ID3v1) and an APE footer are one tail read.
- **FLAC:** STREAMINFO's total. When it is 0, fetch the last ~64 KB for the final frame header, which is the region the dr_flac patch reads.
- **Ogg:** the last ~64 KB for the final page's granule position.
- **WAV/AIFF:** the chunk walk by ranged reads, which finds a `fmt ` after `data` without the whole file.

**The pre-scan can be nearly free, because the metadata scan already does most of it.** `VibeRangedStream` fetches each placeholder's head (and, through TagLib, ID3v1 and APE trailers) during the sweep and then discards the blocks with the parse. If the scan deposited those blocks into the sparse part file instead of dropping them, most files in an opened Dropbox folder would already hold their header by the time they are played, and time to first audio would drop to almost nothing. The pre-scan then fetches only what the scan did not read (an `moov`, an Ogg tail) and costs one or two requests per play.

Pros: bounded and predictable, about two requests. Each format's rule is small, testable, and sits beside the parsers it serves. It reuses requests the sweep already makes.

Cons: one rule per format, a new chance of mis-parsing, and on its own it does nothing for seeking ahead.

### Option B: a range map, with reads fetched on demand

Keep a coverage map of present byte ranges for the sparse part file. A read that hits a missing range fetches it synchronously, the way `VibeRangedStream` does, while the sequential download continues. A seek ahead therefore costs one ranged read instead of a wait, and the sequential download can jump to the seek point and fill the gap later.

Pros: general. It needs no knowledge of any format, handles tails and seeks alike, and fails safe on a format nobody anticipated.

Cons: the most concurrency, with two writers into one sparse file, a coverage map shared by readers on different threads, and gap filling to schedule. Without a cap, a pathological format can turn into thousands of tiny reads. A seek must also not starve the sequential download it interrupts.

### Option C: Apple's push parser for MP3 and AAC

`AudioFileStream` (AudioToolbox) is made for progressive data. It parses packets as bytes arrive and estimates duration from the bitrate, which dr_mp3 could take as its packet source in place of `AudioFileReadPacketData`. It needs no tail for MP3 or ADTS AAC. It does not help MP4 with a trailing `moov`, FLAC, Ogg or WAV, and it is a second packet road beside the file parser for two formats.

### Option D: let AVFoundation stream (rejected)

Dropbox's `files/get_temporary_link` gives a plain HTTPS URL that supports Range for four hours, and `AVPlayer` or `AVAssetResourceLoader` would stream it with no code of ours. It is rejected because it bypasses everything Vibe's playback is: the voice bus, the r8brain resampler, the DJ FX, gapless prefetch, the level meter and bit-perfect output (`Audio/AGENTS.md`).

The temporary link is still worth evaluating as the **transport** for options A and B. One URL per file, with plain `GET` and `Range` and no per-request auth header or token refresh, simplifies resume and ranged reads alike.

### Option E: stop after phase 1

If the spike shows that most of the library streams from the head, the formats that touch the tail keep the full download, and seeking ahead waits for the frontier. That is honest and cheap. Its cost depends on the library: an iTunes-heavy M4A collection gets nothing.

### Recommendation

**A first, on B's storage.** Build the sparse part file with a coverage map once: a head prefix plus islands, with readers that wait on "is this range present". Option A's pre-scan then writes islands at known offsets, and the sweep deposits its head blocks into the same file. Add option B's on-demand fault later, behind a cap, for seeking ahead and for anything the pre-scan does not foresee. Phase 1's frontier becomes the special case of a coverage map with a single prefix, so that refactor is the whole migration. Keep C in reserve in case the spike shows the Apple parser walking packets in MP3s with no Xing frame. D stays rejected.

## Phase 3: polish

- **Draw the region not yet downloaded differently.** Today an unfilled chunk is zero and reads as silence, a flat hairline (`WaveformMorphEngine.h`). The delivery already carries `percentComplete`. A streaming delivery should also carry the downloaded fraction, so the renderer can dim or hatch the region past it on both the mac view and the iOS scrubber.
- **Streaming prefetch for gapless.** The successor needs only its header and a few seconds to be armed, and the rest can download while the current track plays. That changes the prefetch lane's budget: it may no longer hold the background lane for a whole file.
- **Buffering progress in the scrubber.** The downloaded range, drawn the way a video player draws its buffer bar.

## Costs, and the cross-directory guarantees it touches

- **"The open the user is waiting on outranks every background read"** must still hold while the open is readable but incomplete. The foreground hold stays raised until *complete*, not until *readable*. The sweep's deposit of head blocks (option A) happens only through its own ranged reads, which the hold already gates.
- **"The handle-open ceiling"** is derived from one player with two open sources. A streaming source holds its lane for the whole download while its handle is open, so the lane arithmetic and its tests have to be re-derived (`Audio/Loading/AGENTS.md`).
- **A new guarantee: a frontier wait happens only on decode and loader workers, never on the render thread or main.** It should replace an existing guarantee rather than add to the total. Retiring the stage-1 "Ready means the whole file" assumption, now written in `DropboxMirror.h` and `CloudFileMaterializer.h`, is the candidate.
- **New types:** the frontier (later the coverage map). Everything else fits the classes that already own the concern: `DropboxMirror`, `DropboxClient`, `AudioFileHandle`, the coordinator, `AudioPlayer` and the waveform loader.

## Testing

- `DropboxMirrorTests` already drives the client over a stubbed `NSURLProtocol`. Throttling its delivery gives deterministic slow downloads, mid-file failures, 401 and throttle resumes, and checks that a resume appends rather than truncates.
- `make test-audio` can play a streaming handle over a throttled byte source through the debug render pump and assert full PCM equality with the local file. Streaming must be sample-identical once it is complete.
- The vibe-stress cloud scenarios (`set_fake_cloud`) cover stall, resume, skip while buffering, and seek past the frontier.
- On a device, play a large FLAC and a long M4A over a constrained link, and check time to first audio, buffering recovery, and that the waveform fills as the download progresses.
