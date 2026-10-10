# Future: streaming from any source

**Status: planned 2026-10-03. Phases 1 and 2 built together, 2026-10-09.** Builds on Dropbox streaming, implemented in [PR #134](https://github.com/cmicali/vibe/pull/134). Current behavior lives in the [audio](../../Vibe/Audio/AGENTS.md), [Dropbox](../../Vibe/iOS/Dropbox/AGENTS.md), [file-loading](../../Vibe/Loading/AGENTS.md) and [waveform-loading](../../Vibe/Audio/Waveform/AGENTS.md) docs. Google Drive has a [separate feasibility study](ios-google-drive.md). The plan below is kept as it was written. Where the build differs, this status says so.

**Built.**

- `CloudFileAvailability` takes any writer. It holds blocks instead of one window. A writer with no part file notes the size late and can shorten the end. The writer's wait for work reports a blocked range and the reader's position. `progressBytes` only grows. Dropbox's path is unchanged.
- A file on a network mount reads ahead when its opener can be interrupted: the coordinator's opens and the waveform loader's. The kernel's mount table decides (`VibeMountReadsAhead`). A thread per handle fetches 256 KB blocks up to 8 MB ahead of the reader.
- The waveform loader's read-ahead publishes its first snapshot at once, as a stream's does, and a cancel frees its slot on a dead mount. That is phase 3's first half.
- A running-app debug verb for a slow volume, `set_slow_volume`, on both platforms. It makes every file opened from then on read ahead. It can throttle, stall or fail the read-ahead's reads.
- A dropped server holds the play, then pauses it in place with "Connection lost" within the stall span. A server back within the span plays on. Seek, skip and stop stay responsive. The mac publishes rate 0 to Now Playing during a hold. It draws no buffering on screen.
- Three changes from the plan below. A read error is retried until the handle goes and is never a failure. A dead server ends in the stall's pause. The bound counts orphaned threads, not live ones. At eight, a new read-ahead open waits until one exits. The open deadline still bounds that wait. An MP3 on a share is counted exactly at open, as a local file is. A headerless mix that takes longer than the open deadline to cross the wire fails to open.

**Deferred.**

- Renaming `CloudFileAvailability`. It waits for the first writer that is not a file.
- One shared table of live availabilities in place of `setRemoteRoot:`'s lookup block. A read-ahead is per handle and needs no lookup.
- Deleting the two shells' open-deadline relays. The open deadline still hears only the transfer registry, so a read-ahead's open gets the 60 s no-progress span.
- Metadata and TagLib reads on a share. They stay direct reads on sweep workers.
- Read-ahead on local external volumes. It is unmeasured.
- Skipping the dataless `stat` probe on network mounts. On a dead mount the probe and the thread's `open` still take the SMB timeout, about 30 s.
- The main thread's `noteNewRecentDocumentURL:` stat at each track start. Another change fixes it.

**Still needs the user.**

- The SMB cable-pull rerun on the Mac, with this build.
- On an iOS device, whether `getfsstat` answers in the sandbox. If it does not, iOS takes the direct road.

Today the streaming model serves one source: a file Vibe's own Dropbox client is downloading on iOS. Every other open is a whole-file open, whose reads block in the kernel for as long as the volume takes.

The goal: any source whose bytes arrive slowly reads through the same model, starting with ordinary files on network shares and slow disks, and written so the next source (a provider that learns to deliver ranges, another service's client) is a new writer behind an unchanged reader.

## What the model gives, and who lacks it

The model is four things, each built for Dropbox and each missing on a slow volume today.

| The streaming model | A file on a share or slow disk today |
| --- | --- |
| **Every wait for bytes can be interrupted**, so a seek, skip, or stop during a stall returns at once | A `pread` on a stalled mount cannot be interrupted. The open strands one of the six handle runs, a decode turn strands its queue, and `stopReadingThen:` waits out the stall (`Loading/AGENTS.md`, `AudioVoiceBus.h`) |
| **A source that falls behind buffers in place and plays on once**, and a stall pauses with an error | The render underruns and resumes on any frames, so a slow link stutters in fragments, and a dead one hangs the play with no error. The mac shell draws no buffering at all |
| **An MP3 with no Xing, Info, or VBRI frame opens on a length taken from its head** | CoreAudio counts its packets by reading every frame header to the end, so the open reads the whole file over the wire. Arithmetic, not measured: a 300 MB mix is 3 s at 100 MB/s, 10 s at 30 MB/s, and a minute at 5 MB/s |
| **Bytes arrive ahead of the decode** (the download runs at full speed) | Reads fetch only what the decoder asks for, when it asks, so every hiccup on the link reaches the ring, which holds seconds |

## The platform facts, measured

Vibe currently materializes File Provider files whole before opening them. Partial reads depend on the platform and provider; these probes establish what the tested versions actually delivered.

Measured on macOS 27 with a probe that opens a dataless file, reads 64 KB with a plain `pread`, and then `fstat`s it:

| Provider | The first 64 KB read | On disk while it blocked | On disk after |
| --- | --- | --- | --- |
| Dropbox's File Provider (273.4), 72 MB WAV | blocked 4.0 s | not sampled | the whole file, no longer dataless |
| Dropbox's File Provider (274.3), 150 MB MP3 | blocked about 6 s | 0 bytes, sampled every 0.5 s | the whole file, all at once |
| iCloud Drive, 106 MB WAV | blocked 2.6 s | not sampled | the whole file |
| iCloud Drive, 180 MB MP3 | blocked 12.3 s | 0 bytes, sampled every 0.4 s | the whole file |

- **macOS File Providers can deliver ranges, and neither of these two does today.** `NSFileProviderPartialContentFetching` (macOS 12.3) lets a provider answer a POSIX read of a dataless file with only the range read. The header lets it answer with any range covering the request, "including the entire item", so implementing the protocol promises nothing.
- **Dropbox has built it and switched it off.** Its extension implements `fetchPartialContents` behind a per-domain "streaming gate" set by live configuration, with a fallback its strings call "gate off; falling back to full hydration" (log prefix `[PARTIAL_HYDRATION]`). The live log of the probe shows the system asking the extension for exactly 65,536 bytes and the extension answering with the whole file. So Dropbox on the Mac can start streaming with no change on this machine but a flag. The flag is probably the feature flag `desktop_sync_streaming_sync_enabled`, which sits beside `refreshStreamingSyncGate` in the binary; that the partial path reads it is inferred, not confirmed. Still off on 274.3.4801 (2026-10-03), the second Dropbox row above.
- **The bytes downloaded so far are out of reach.** While the visible file stays dataless with 0 blocks, the download grows in 4 MB steps in a scratch file under `~/Library/Application Support/FileProvider/<domain>/state/scratch_files/`, and is moved into place at the end. macOS refuses even a listing of that folder ("Operation not permitted") while its siblings list, so a sandboxed app is further still. The folder is undocumented, and whether it fills from the front is unknown. The progress feed (`addSubscriberForFileURL:`, `DownloadProgressMonitor.h`) is a count of bytes, not the bytes. Nothing on the consumer's side reads a growing prefix.
- **iCloud Drive has not built it.** Its extension's binary carries the whole-file fetch and no partial one.
- **Only a POSIX read can get a range.** Apple's documentation: "If you clone the entire file, or read the file using file coordination, the system requests the entire file." Vibe's provider road is `NSFileCoordinator` (`CloudFileMaterializer materializeURL:`), so today Vibe would be handed whole files even by a provider that streams. An app can neither request a range nor learn ahead of the read whether it will get one. The probe is the detector: a file still dataless after a read returned came from a provider that streams.
- **iOS File Providers cannot.** The iOS 27 SDK marks the protocol `API_UNAVAILABLE(ios)`, and Apple's developer support says the same on the forums (thread 776780): macOS only, "no alternative on iOS". A provider there hands over whole files.
- **Apple's sample provider (FruitBasket) implements it**, so a provider written from the sample streams. OneDrive, Box, and Google Drive are not installed here and are unverified.
- **A network filesystem already reads by range.** An SMB, NFS, AFP, or WebDAV mount holds ordinary files, not dataless ones, and each `pread` fetches its bytes over the wire. No whole-file transfer happens, so nothing needs downloading: what is missing is the four rows above. Measured below, on the Mac.
- **The Files app's SMB volume on iOS is a live network mount.** Measured 2026-10-08 on an iPhone 17 Pro with the `--dataless-diag` probe. A folder picked from an SMB server lives under `/private/var/mobile/Library/LiveFiles/com.apple.filesystems.smbclientd/<server>/`. Its mount is a `lifs` filesystem without `MNT_LOCAL`. Its files carry no dataless flag. So a read fetches its bytes over the wire, as on the Mac, and the read-ahead applies to iOS too. A 44.1 kHz FLAC opened in 87 ms and played 98 ms after the play was submitted. A sleeping or dropped server was not tried.
- **Unverified: what a USB drive is on iOS.** It is probably a live local mount under `LiveFiles/` too. The same probe settles it. The design below needs no answer: a network mount is read ahead, and a dataless file takes the provider road.

## Recorded decoder probes (2026-10-02)

The original spike logged every requested read of `VibeHandleRead` and `VibeStreamRead` through the production `AudioFileHandle` while opening, decoding the first ten seconds, and seeking (to 10 %, 50 %, 90 %, and back), over 69 files: the fixtures plus generated 6-minute and 60-minute files from ffmpeg, LAME, and afconvert. Measured on macOS 27; the same harness in the iOS 27 simulator gave identical read sequences for every file it opens. The initial probe did not cover device CoreAudio, files from Apple's own encoders, VBRI, APE tags, or RF64; later MP3 device observations are recorded below.

| Format | The open reads | A seek reads |
| --- | --- | --- |
| M4A/ALAC with `moov` first (afconvert's default, ffmpeg `+faststart`), CAF, WAV, W64, AIFF | the head only, at most 354 KB | one region at the target |
| FLAC with a known total | the head only | with a seek table, 2 to 4 regions just before the target; **without one (ffmpeg and afconvert write none), a bisection of 3 to 10 regions reaching 11 % of the file past the target** |
| MP3 with a Xing or Info frame | the head, plus 4 to 128 bytes at the end (an ID3v1 check on every open) | **every frame header between the furthest byte read and the target**: the parser ignores the Xing table |
| M4A with `moov` last (ffmpeg's default) | the head, plus one tail region: 61 KB at 6 minutes, 608 KB at 60 | one region at the target |
| FLAC with an unknown total | the head, plus 64 KB at the end | as FLAC |
| WAV with `fmt ` after `data` | the head, plus 24 bytes at the end | one region |
| WAV, W64, AIFF, or CAF with a chunk after its audio, such as a tag with its cover (measured 2026-10-09) | the head, plus the header of each chunk after the audio | one region |
| Ogg Vorbis and Opus, ADTS AAC, MP3 with no Xing or Info frame | **the whole file, in order** | direct |

The last row's MP3 is no longer the open's but the count's: CoreAudio answers the packet count, ExtAudioFile's length and the maximum packet size of an MP3 with no Xing, Info or VBRI frame by reading every frame header to the end, while the bit rate, the data offset and size, the packet table and the packet size bound read a few frames. On a device, eight of ten long DJ mixes opened only when their download completed for this reason. Such a stream now opens uncounted on a count from its head's frames (`Audio/AGENTS.md`): a constant-rate head's from its bit rate, a VBR one's from the frames' average size, either an estimate, since a headerless file can change rate after its intro, settled where the reads reach the stream's end or at the first read once the download is complete, where the parser's count reads every frame header from disk. Measured on an M-class Mac with a 151 MB VBR file through the handle's 64 KB block cache, that count reads the file once, 2,447 fills: 36 ms warm, 140 ms from a cold APFS clone (without the block cache, 919,000 reads and 270 ms). The estimate's error is the head's: within 2% for an encode of steady material, but a quiet intro estimates long and a loud one short, so the decode reads past or short of it, and the player republishes the settled duration once. A device run's `MP3 stream:` lines say which files took the estimate, how far off it was, and how long the count took.

### Tail-window tests and latency

Recorded host-less tests opened an MP3 with an Info frame and ID3v1 tag, LAME CBR and VBR files, an index-last ALAC M4A and a FLAC with no STREAMINFO sample count on a 64 KB head and an 80 KB test window, then decoded the same PCM as the local file. A WAV did not read the window. A WAV, AIFF, W64, or CAF with a chunk after its audio does. Its open reads that chunk's header. On a Dropbox AIFF with a tag, that header was 235 KB from the end. Production uses larger windows, sized by `VibeAudioFileTailWindowBytes` in `AudioFileOpenRules.h`; its current policy is documented with the Dropbox mirror.

A device experiment that delayed the tail request until the first download response added 1.0–2.4 seconds to its arrival. Starting the tail and download together removed that extra round trip. A tail costs one extra request for eligible transfers and up to one window downloaded twice; an index larger than the window still waits for the sequential download.

The recorded probes found backward seeks stayed within bytes already read. MP3 seeks ahead scan intervening frame headers, and FLAC without a seek table probes beyond the target. Measure an actual library before paying for arbitrary range fetching. These are historical results, not measurements repeated when this plan was consolidated on 2026-10-04.

## What already exists

- **The wait is already source-blind.** `AudioFileHandle` asks one question, `waitForBytesAt:length:windowInto:capacity:copied:interrupted:error:`, and knows nothing of Dropbox. Its header says so: "a source of bytes changes what answers it, not who asks".
- **A wait can already be answered from memory.** The tail window is copied into the reader's buffer by the wait itself, with no `pread` (`VibeHandleAwait`, the three read paths). A source that serves every byte that way needs no new read path.
- **Interruption, buffering, the stall's pause, and the estimated MP3 length** are all keyed on the handle having an availability, not on Dropbox (`_availability`, `waitingForBytes`, `updateBufferingOnQueue`, `VibeUncountedMPEGPackets`).
- **The coordinator already passes every open an `interrupted:` block** and wakes the file's waiters on cancel. For a whole file it has nothing to interrupt.

## What the code makes hard

Each was found reading the code, and each is a way the feature fails if missed.

- **`CloudFileAvailability` assumes a part file written from byte 0 and one window installed once.** A plain file has no part file, no prefix on disk, and a window that must follow the reader.
- **"Complete" is load-bearing.** `finishWithError:nil` makes every range ready and sends readers to the disk. `awaitExactLength:` (the waveform's open of a VBR MP3 with no header) waits for it. A read-ahead never completes while a reader lives, so that wait would never return.
- **The stall deadline's progress is `bytesWritten`.** For a transfer it is the download's edge. A read-ahead that seeks has no edge, so it needs a count that only grows.
- **The open deadline's progress comes from the transfer registry**, forwarded by each shell (`noteOpenProgressForOpenRequestIdentifier:`). A plain file is not in the registry and must not be: a row shows the loading bar only for a transfer. So a slow open that is moving looks silent, as it does today, and gets the 60 s no-progress span and no more.
- **That forwarding is the same ~40 lines in both shells** (`PlaybackController+PlayerEvents.m`, `MainPlayerController+PlayerEvents.m`: `_loadingURL`, `_loadingPath`, `_loadingOpenRequestIdentifier`, `_loadingProgress`, `cloudTransferRegistryDidChange:`, `didMoveTransferForPath:`, `endLoadingProgress`), each turning a registry path back into the open identifier the player minted itself. The player could observe `CloudTransferRegistry` on main for its own open's path and extend its deadline directly, deleting both relays and the public `noteOpenProgressForOpenRequestIdentifier:`; each shell keeps only the one-line maximum it paints. Phase 2 gives the deadline a second progress source (the read-ahead's count), which is the moment to make the player the one listener rather than teach two relays a second source.
- **Classifying the volume must not touch it.** `statfs` on a path under a dead mount blocks, which is the very hang being removed. The mount table read with `getfsstat(MNT_NOWAIT)` does not.
- **`open`, `fstat`, and `close` block on a dead mount too.** Moving only `pread` off the opening thread leaves the open strandable.
- **CoreAudio's QuickTime reader has no callback open** (the `TRAP:` in `initParserForReading:`): MooV and `.qta` parse through the URL, so CoreAudio reads the file itself and nothing can wait on Vibe's terms. Mac only.
- **The tail window and TagLib's range cache serve different lifetimes.** `CloudFileAvailability` holds one contiguous region shared by stream handles; `VibeRangedStream` fetches 64 KB blocks on demand for one metadata parse. Re-evaluate that overlap before adding a cache for arbitrary reads.
- **Two readers of one file read different places.** A play at 1:00 and its waveform decode at 40:00 share a transfer's part file happily, since every byte behind the edge is on disk. They cannot share one sliding window.
- **The mac shell implements no buffering.** Only iOS answers `didChangeBuffering:forTrack:` and draws `VibeAudioErrorConnectionLost`, whose string names a download.
- **TagLib opens a local file by path.** The metadata sweep's reads on a slow share stay blocking reads on sweep workers.

## The design: one wait, many writers

**The reader's side does not change.** A handle waits for the range it is about to read and gets one of three answers: ready, failed, or interrupted.

**The writer's side is what generalizes.** Today an availability has one kind of writer, a transfer that notes a growing prefix, installs one tail window, and finishes. Four additions make it serve any writer:

1. **The wanted range.** When a wait is about to block, the availability records the range and wakes its writer. A writer that can only go forward ignores it, as the Dropbox download does today. A writer that can fetch out of order reads it next.
2. **Blocks, plural.** A small ordered set of in-memory blocks keyed by offset replaces the single window. Dropbox's tail is one block installed once. A read-ahead installs blocks ahead of the reader and drops those behind it.
3. **No part file required.** With none, nothing is on disk, every byte comes from a block, and the handle keeps no descriptor of its own.
4. **Complete is optional.** A writer with no end either fails or is ended by its last reader. `awaitExactLength:` and the VBR settle must not wait on a completion that cannot come (phase 2).

**A source is then anything that writes into an availability.** The handle, the voice bus, the player's buffering, and both shells see only the wait.

| Writer | Prefix on disk | Blocks | Serves the wanted range | Completes |
| --- | --- | --- | --- | --- |
| Dropbox download (built) | yes, the part file | one, the tail | no | yes |
| File read-ahead (phase 2) | no | sliding, ahead of the reader | yes | no |
| Dropbox ranged reads for a seek ahead (phase 4) | yes | on request | yes | yes |
| A partial-fetch File Provider (phase 4, on evidence) | no | sliding | yes | no |
| Google Drive client ([under research](ios-google-drive.md)) | to decide | to decide | to decide | to decide |

### The file read-ahead

**One thread per handle that reads a slow volume, and the only thread that enters the kernel for that file.** It opens the file, stats it, and then loops: take the wanted range if there is one, otherwise the next block after the reader's position, up to a limit ahead; `pread` it; install it. The handle's reads are waits and copies.

- **Per handle, not per file.** Each reader has its own position, so each has its own read-ahead and its own blocks. Nothing is shared, so there is no lookup, no reader count, and no `holdStream` for it. The read-ahead ends with its handle.
- **Everything strandable is on that thread.** A dead mount strands the read-ahead inside `open`, `pread`, or `close`. The handle's wait is interrupted and returns, so the open run, the decode queue, and the waveform slot are all free at once.
- **Stranded threads are bounded.** A process-wide count of live read-aheads, refused past a small ceiling (provisionally eight, the probe slots' number) with the admission error, before a thread is made.
- **A read error fails the availability for good**, as a failed transfer does: `EIO`, `ENOTCONN`, or `ESTALE` after a share drops or a disk is pulled. The play pauses in place with the stall's error and a replay opens afresh.
- **Provisional sizes, tuned in phase 0:** 256 KB blocks, 8 MB ahead of the reader (45 s of CD-rate WAV, minutes of MP3), and two blocks kept outside the run so an open's head, tail, head sequence does not refetch. At most 8.5 MB a handle, and three handles on a slow volume at once.

### Which files read ahead

**A decision from the mount table, in `AudioFileOpenRules.h`.** The handle finds the mount its path lies under from `getfsstat(MNT_NOWAIT)` and asks the rule. A network mount (not `MNT_LOCAL`) reads ahead. Whether external and removable local volumes do is phase 0's measurement. The internal volume never does, so the common open pays one cached table lookup and nothing else. The QuickTime reader's files keep the URL road on any volume.

A debug seam forces the rule and throttles, stalls, or fails the read-ahead's reads, so every test below runs on a local file with no share (`Vibe/Debug/`, as `setDatalessProbe:` does).

### What the listener gets

- A long MP3 mix on a share starts on its head, not after the whole file crosses the wire.
- A slow or sleeping volume shows the loading indicator, then plays on once, on both platforms.
- A dropped share pauses in place with an error within the stall span. Seek, skip, and stop stay responsive throughout.
- A waveform decode on a dead share gives up its slot when cancelled.

## Phases

### Phase 0: measure

Nothing is built until these are in hand. Each decides something.

- **A real share and a slow disk** (SMB over gigabit and over Wi-Fi, a USB spinning disk): time from tap to audio per format today, underruns during play, and what hangs for how long when the cable is pulled or the disk sleeps. Decides whether phases 2 and 3 are worth building, and the read-ahead's sizes.

  **Results, 2026-10-09: SMB over Wi-Fi.** A MacBook Pro (M4 Max) played from a Raspberry Pi's SMB share over Wi-Fi. The Debug build ran on the built-in speakers, kept silent. Opens went through the debug channel, so Launch Services was not in the time.

  | | Local disk | SMB share |
  | --- | --- | --- |
  | Open to first audio, CD FLAC of 30 to 69 MB | 34 to 41 ms | 63 to 78 ms |
  | Seek to the file's middle, before that part was read | 30 to 44 ms | 115 to 209 ms |
  | Underruns over 10 s of play | none | none |

  - **A healthy share needs no read-ahead to play.** It costs about 30 ms an open and about 150 ms a cold seek. Nothing underran.
  - **A Finder open of a file on the share takes about 1.1 s, and Vibe is 18 ms of it.** A temporary log line timed the hand-off: Launch Services took 1.13 s to deliver the URL, against 0.14 s for a local file. Opens from the playlist, a drag, or the Open dialog do not pay it.
  - **A dropped server fails silently, which is the case for phases 1 and 2.** The Pi went off the network while a track played. A seek into a part not yet read then stopped the audio. The voice underran 525,824 frames, about 12 s, while `dump_state` still said playing, with `buffering` false and no error. The player cannot see a mount read that blocks, so nothing reported it.
  - **An open of a file never read failed after about 30 s,** with POSIX error 60, "Operation timed out", from the SMB client. Vibe then showed its error state. The debug channel's own `open` verb stats the path on main (`DebugCommonVerbs.m`), so the main thread was blocked for those 30 s too. That is the test tool, not the app's open.
  - **The app's main thread stats a playing file at every track start.** `performPerTrackRefreshForStartedTrack:` calls `noteNewRecentDocumentURL:`, and AppKit reads the file's attributes there. With the server flaky this blocked main for 350 to 430 ms. A server that stops answering could hold main for the SMB timeout.
  - **Recovery needed nothing.** Once the Pi was back, an open of the file that had failed played in 280 ms.
  - Not measured yet: gigabit Ethernet, a USB spinning disk, and a disk asleep on the server.
- **The read-ahead's cost on a fast volume** (`make bench-components`, the open, decode, and seek benchmarks with the rule forced on). Decides how wide the rule is, and whether one road for every file is affordable.
- **iOS, on a device:** what a file picked from the Files app's SMB server and from a USB drive is: its path, its mount, and whether it is dataless. Decides whether iOS gains anything.
- **The probe is the dataless diagnostics, not a new script.** On the Mac, `set_dataless_diag on` and then `dump_dataless_diag` report each directory's verdicts and its mount. On a phone, a Debug build launched with `--dataless-diag` logs the same thing, one line per directory (the `vibe-debug` skill's on-device log section). So a new provider or OS release is one run to re-check.

### Phase 1: the availability takes any writer

The four additions above, with Dropbox the only writer and its behaviour unchanged: the tail becomes the first block, the wanted range is recorded and ignored. The type loses "Cloud" from its name. **One table of live availabilities in shared code**, which a writer registers into, replaces the per-backend lookup block (`setRemoteRoot:`'s fourth argument) if the mirror's own table can go with it.

Done when the streaming tests, the full `dropbox-streaming.sh` scenario suite, and the PCM comparisons pass untouched.

### Phase 2: the file read-ahead, for playback

1. The read-ahead and its bound, in `AudioFileHandle.m`, and the rule in `AudioFileOpenRules.h`.
2. **Length without completion.** A CBR estimate settles where the reads reach the end, as now. A VBR estimate has no download to wait for, so the handle that needs an exact length counts through its own read-ahead (the waveform's does, and it reads the whole file anyway), and that count settles the player's duration.
3. **Progress that only grows:** the bytes the read-ahead has installed feed the stall deadline. The open deadline gets the same count, by a feed that does not pass through the transfer registry.
4. **The mac shell draws buffering** and the stall's pause, and the stall's string stops naming a download (`vibe-strings`).
5. `Audio/AGENTS.md` and `Loading/AGENTS.md` say "a file still arriving" where they say "a remote transfer".

Done when a throttled file plays through the render pump sample-identical to the direct open, seeks included, and a stalled one never hangs a seek, skip, or stop.

### Phase 3: the other readers

- **The waveform loader** gets it for free, since it opens an `AudioFileHandle`: its own read-ahead, and a cancel that frees its slot on a dead mount. Verify the 20 s claim wait and the decode-slot arithmetic.
- **The metadata sweep stays as it is.** Its reads already hold no lane, and routing TagLib through a waiting stream is a second project. Revisit only if phase 0 shows the sweep hanging the app.

### Phase 4: writers that serve the wanted range, each on evidence

- **Dropbox seeks ahead by range.** A ranged read answers the wanted range into a block, by the pinned `rev`. It helps M4A, WAV, and FLAC with a seek table, and offers little benefit for the MP3 and seek-table-less FLAC behavior in the [recorded decoder probes](#recorded-decoder-probes-2026-10-02). Compare the in-memory approach with sparse storage below before adding another mechanism.
- **A File Provider that delivers ranges.** The file read-ahead over a dataless file, skipping the `NSFileCoordinator` download, which is the only way the system hands out a range. Only for a provider the probe has shown to stream, since on any other the first read downloads the whole file with no cancel. Dropbox's Mac extension is the likeliest first: the code is shipped and gated off. Build it when a provider in users' hands passes the probe, not before, and re-run the probe on each Dropbox release until then.
- **Another service's own client** is a separate product decision. [Google Drive](ios-google-drive.md) is under research. Its version-consistency probe must pass before it can publish a stream safely. A sequential client can use today's availability without waiting for this generalization.

## Further options, only on evidence

- **A format-specific pre-scan.** Locate the index before opening: MP4 atoms give `moov`'s offset with 8–16 byte reads; MP3's ID3v2 header and first frame locate the audio and Xing/VBRI data (a headerless file's size/bitrate gives only an estimate); FLAC uses STREAMINFO or its last ~64 KB; Ogg its last ~64 KB; WAV/AIFF a chunk walk. This fetches the exact index, but duplicates five parsers' format knowledge and still needs storage for the fetched bytes. For the measured head-and-tail opens, one tail window avoids that extra format-specific parser. Revisit for files that exceed it.
- **Sparse storage for seeks ahead.** Write ranged bytes into the part file at their offsets and track coverage, allowing the sequential download to restart from a seek point. It can help formats that seek directly, as can phase 4's in-memory range cache. Sparse storage adds two writers, a cross-thread coverage map, gap filling and persisted-or-discarded coverage. Either option must remain behind the same range wait and justify its cost with measurements.
- **`AudioFileStream` for ADTS AAC.** Apple's push parser can parse packets as bytes arrive and estimate duration, avoiding the measured whole-file ADTS open. Headerless MP3 already streams by postponing its exact packet count, so it does not need a second parser path; Ogg gains nothing from this option. Keep it in reserve until ADTS files prove common in real libraries.
- **A separate download-coverage display.** Progressive waveform reveal and streaming prefetch already exist. If the UI also draws downloaded coverage, distinguish it from decoded waveform extent: compression and container indexes mean their fractions need not match.

## Options weighed and not taken

- **Warm the page cache and keep `pread` on the decode thread.** Smaller: no copy and no blocks. But the decoder still enters the kernel on the slow volume, and an evicted page or a lost SMB lease makes a "ready" range block again. Interruption would be likely, not guaranteed.
- **One read-ahead per file, shared by its readers.** It mirrors a transfer, but two readers at different positions fight over one window.
- **Every file through the read-ahead, one road.** It would delete the whole-file branch from the handle. It costs a thread and a copy on every open of a fast disk, across a library scan's thousands. Phase 0 measures it. Expected answer: no.
- **Owned by the coordinator as a stage-1 run.** The waveform and metadata opens do not pass through the coordinator, and a slow file is not a transfer: it has no lane to hold and no fraction to show.
- **A source protocol with a class per writer.** Two new types to express what a missing part file and a writer's loop already say.
- **Keep metadata head blocks for future plays.** At the measured 230–360 KB per file, a 954-track folder leaves about 300 MB of hidden blocks outside the download budget. The 24-hour part sweep deletes them; keeping them would need version stamps, persisted coverage and eviction, creating another cache to save one round trip per play.
- **Let `AVPlayer` stream a Dropbox temporary link.** It bypasses the voice bus, r8brain resampling, DJ FX, gapless prefetch, the level meter and the shared engine's bit-perfect output path. A temporary link could still be evaluated as an HTTP transport feeding the existing engine; its lifetime and version-pinning behavior remain unverified.

## Costs, and the cross-directory guarantees it touches

- **"The handle-open ceiling"** changes, and should get shorter. Its four spare runs are "for whole-file opens stranded in the OS". An open on a read-ahead volume no longer strands a run, so what can strand is an internal-volume open, a provider's, and the QuickTime reader's. The derivation and its tests are redone, and the stranded read-ahead bound is stated beside it. "Every wait can be interrupted" stays true and covers more.
- **"A row shows the loading bar only while a transfer is running"** must stay exactly true: a read-ahead publishes nothing to `CloudTransferRegistry`.
- **"The equalizer has no ongoing work while inactive"** already treats a buffering hold as no output audio. Verify on the mac, which has never held.
- **No new guarantee is expected.** If one is needed, it replaces the ceiling's stranded-open clause, not adds to the list.
- **Memory:** up to 8.5 MB a handle on a slow volume.
- **Two roads remain**, direct and waiting, as now. The waiting road has more than one writer.

**The budget.** New files: none planned. New types: none planned, since the read-ahead is a function and a thread in `AudioFileHandle.m` and the rule joins an existing rules header. Renamed: one type. Removed or unified: the single-window special case, and the per-backend lookup block with the mirror's stream table if phase 1 finds they can go. Honest gap: the whole-file branch in the handle stays.

## Testing

- **Host-less, over the debug seam:** a throttled file reads ahead, waits, and resumes. An interrupt returns a blocked open, read, and seek without ending or failing them. A read error fails for good. A stalled `pread` strands only its read-ahead, and the ninth is refused.
- **`make test-audio`:** every format through a throttled read-ahead against the direct open, PCM-identical, with seeks behind, inside, and beyond the blocks held.
- **The Dropbox suite, unchanged,** at every phase: `DropboxMirrorTests`, streaming handles and streaming PCM comparisons, including changed revisions, cancelled waits, short/error responses, failed tails, same-inode resume and install races. Run `dropbox-streaming.sh` with `set_fake_dropbox` and `fake_dropbox_fault`; `set_fake_cloud` covers the separate File Provider materialization path.
- **`vibe-stress`:** skip, seek, and stop during a stall. A hang on any of them is the interrupt rule broken.
- **On hardware:** pull the cable mid-play, let a disk sleep, wake the Mac with the share gone, and eject a volume under a playing track. On iOS over a constrained link, recheck tap-to-audio, one resume per stall, the lock-screen clock, background buffering, skip/seek cancellation, gapless prefetch and progressive waveform growth.
- **`make bench-components`** before and after, so the direct road is shown not to have moved.
