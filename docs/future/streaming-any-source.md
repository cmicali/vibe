# Future: streaming from any source

**Status: Partly built.** `CloudFileAvailability` takes any writer, and a file on a network mount reads ahead through it. The waveform loader's read-ahead and the stall's pause on a dropped server are built too. Current behavior is in `Loading/AGENTS.md` (the availability, `VibeMountReadsAhead`), `Audio/AGENTS.md` (the read-ahead, buffering and the stall), `Audio/Waveform/AGENTS.md` and `Debug/AGENTS.md` (`set_slow_volume`). This plan keeps only what is not built.

## Not built

- **Renaming `CloudFileAvailability`.** Wait until there is a writer that is not a file.
- **One shared table of live availabilities** in place of the lookup block passed to `setRemoteRoot:fetch:read:availability:`. A read-ahead is per handle and needs no lookup. Do it only if the mirror's own stream table can go with it.
- **Deleting the two shells' open-deadline relays.** Each shell forwards registry movement to `noteOpenProgressForOpenRequestIdentifier:` (`PlaybackController+PlayerEvents.m`, `MainPlayerController+PlayerEvents.m`). The player could observe `CloudTransferRegistry` directly. It would still match movement to the current open identifier. The deadline still hears only the registry, so a read-ahead's open gets the 60 s no-progress span. A read-ahead must never publish to the registry, since a row shows the loading bar only for a transfer.
- **Metadata and TagLib reads on a share.** They stay direct, blocking reads on sweep workers. Routing TagLib through a waiting stream is a second project. Revisit only if a share is shown to hang the app.
- **Read-ahead on local external volumes.** Unmeasured.
- **Skipping the dataless `stat` probe on network mounts.** On a dead mount the probe and the read-ahead thread's `open` still take the SMB timeout, whose duration the app cannot bound.
- **The main thread's `noteNewRecentDocumentURL:` at each track start** (`performPerTrackRefreshForStartedTrack:`). AppKit stats the file there. A server that stops answering can block main in that call.
- **The mac draws no buffering on screen.** It publishes rate 0 to Now Playing during a hold. The waveform's loading indicator would wipe the waveform and its click-seek, so it is not used for this.

## Needs a device

- The SMB cable-pull rerun on the Mac with the read-ahead.
- On iOS, whether `getfsstat` answers in the sandbox. If it does not, iOS takes the direct road.
- What a USB drive is on iOS. It is probably a live local mount under `LiveFiles/`. A Debug build launched with `--dataless-diag` settles it (the `vibe-debug` skill's on-device log section). The Mac equivalent is `set_dataless_diag on`, then `dump_dataless_diag`.
- Gigabit Ethernet, a USB spinning disk and a disk asleep on a server are unmeasured.

## Platform facts

Measured on macOS 27 with a probe that opens a dataless file, `pread`s 64 KB, then `fstat`s it.

| Provider | The first 64 KB read | After |
| --- | --- | --- |
| Dropbox File Provider, 72 MB WAV | blocked 4.0 s | the whole file |
| Dropbox File Provider, 150 MB MP3 | blocked about 6 s, 0 bytes on disk meanwhile | the whole file, all at once |
| iCloud Drive, 106 MB WAV | blocked 2.6 s | the whole file |
| iCloud Drive, 180 MB MP3 | blocked 12.3 s, 0 bytes on disk meanwhile | the whole file |

- **macOS File Providers can deliver ranges. These probes returned whole files.** `NSFileProviderPartialContentFetching` lets a provider answer a POSIX read of a dataless file with only the range read. A provider may still answer with the whole item, so the protocol promises nothing.
- **Dropbox's Mac extension has it, switched off.** It implements `fetchPartialContents` behind a server-set "streaming gate". The probe's log shows the system asking for 65,536 bytes and the extension answering with the whole file.
- **The bytes downloaded so far are out of reach.** The download grows in a scratch file under the provider's domain, which macOS refuses to list. The progress feed (`DownloadProgressMonitor.h`) is a count, not the bytes.
- **Only a POSIX read can get a range.** File coordination requests the whole file. Vibe's provider road is `NSFileCoordinator` (`CloudFileMaterializer materializeURL:`), so even a streaming provider hands Vibe whole files. An app cannot ask for a range or learn ahead of time whether it will get one. A file still dataless after a read returned came from a provider that streams.
- **This partial-fetch protocol is unavailable on iOS.** The SDK marks it `API_UNAVAILABLE(ios)`.
- **A network filesystem reads by range.** SMB, NFS, AFP and WebDAV mounts hold ordinary files. On iOS, a folder picked from the Files app's SMB server is a live `lifs` mount without `MNT_LOCAL`, with no dataless flag.

## Decoder reads

What the open and a seek read, from logging every read of `AudioFileHandle` over 69 files on macOS 27. The iOS simulator gave the same sequences.

| Format | The open reads | A seek reads |
| --- | --- | --- |
| M4A/ALAC with `moov` first, CAF, WAV, W64, AIFF | the head only, at most 354 KB | one region at the target |
| FLAC with a known total | the head only | with a seek table, 2 to 4 regions before the target. Without one (ffmpeg and afconvert write none), a bisection of 3 to 10 regions reaching 11 % of the file past the target |
| MP3 with a Xing or Info frame | the head, plus 4 to 128 bytes at the end (an ID3v1 check) | every frame header between the furthest byte read and the target. The parser ignores the Xing table |
| M4A with `moov` last (ffmpeg's default) | the head, plus one tail region: 61 KB at 6 minutes, 608 KB at 60 | one region |
| FLAC with an unknown total | the head, plus 64 KB at the end | as FLAC |
| WAV with `fmt ` after `data` | the head, plus 24 bytes at the end | one region |
| WAV, W64, AIFF or CAF with a chunk after its audio | the head, plus each later chunk's header | one region |
| Ogg Vorbis and Opus, ADTS AAC | the whole file, in order | direct |

An MP3 with no Xing, Info or VBRI frame opens on a length estimated from its head (`Audio/AGENTS.md`). Backward seeks stayed within bytes already read. Measure a real library before paying for arbitrary range fetching.

## Writers that serve the wanted range, each on evidence

- **Dropbox already reads ahead by range.** A ranged read answers the wanted range into a block, pinned to the `rev`. It helps M4A, WAV and FLAC with a seek table. It helps little for MP3 and for FLAC with no seek table. Compare it with sparse storage before adding a mechanism.
- **A File Provider that delivers ranges.** Use the read-ahead over a dataless file and skip the `NSFileCoordinator` download. Only for a provider the probe has shown to stream, since on any other the first read downloads the whole file with no cancel. Dropbox's Mac extension is the likeliest first. Re-run the probe on each Dropbox release.
- **Another service's own client** is a separate product decision ([Google Drive](ios-google-drive.md)). A sequential client can use today's availability as it is.

## Further options, only on evidence

- **A format-specific pre-scan** that locates the index before the open. It duplicates five parsers' format knowledge. One tail window already covers the measured head-and-tail opens. Revisit for files whose index exceeds it.
- **Sparse storage for seeks ahead.** Write ranged bytes into the part file at their offsets and track coverage. It adds two writers, a cross-thread coverage map, gap filling and persisted coverage. It must stay behind the same range wait.
- **`AudioFileStream` for ADTS AAC.** It avoids the whole-file ADTS open. Keep it in reserve until ADTS files prove common.
- **A download-coverage display.** If the UI draws downloaded coverage, keep it apart from the decoded waveform extent. Their fractions need not match.

## Options weighed and not taken

- **Warm the page cache and keep `pread` on the decode thread.** The decoder still enters the kernel on the slow volume. An evicted page or a lost SMB lease makes a "ready" range block again.
- **One read-ahead per file, shared by its readers.** Two readers at different positions fight over one window.
- **Every file through the read-ahead.** It costs a thread and a copy on every open of a fast disk, across a library scan's thousands of files.
- **Owned by the coordinator as a stage-1 run.** The waveform and metadata opens do not pass through the coordinator. A slow file is not a transfer: it has no lane to hold and no fraction to show.
- **A source protocol with a class per writer.** Two new types to say what a missing part file and a writer's loop already say.
- **Keep metadata head blocks for future plays.** A 954-track folder would hold about 300 MB of hidden blocks outside the download budget.
- **Let `AVPlayer` stream a Dropbox temporary link.** It bypasses the voice bus, r8brain, the DJ FX, gapless prefetch, the level meter and bit-perfect output.

## Testing

- Host-less, over `AudioFileHandle+Debug.h`'s mount-rule and before-read hooks: a throttled file reads ahead, waits and resumes. An interrupt returns a blocked open, read and seek.
- `make test-audio`: every format through a throttled read-ahead matches the direct open, with seeks behind, inside and beyond the held blocks.
- The Dropbox suite, unchanged, at every step: `DropboxMirrorTests`, `DropboxMirrorFetchTests`, `DropboxMirrorStreamingTests`, the streaming handle and PCM tests, and `dropbox-streaming.sh`.
- `vibe-stress`: skip, seek and stop during a stall. A hang on any of them breaks the interrupt rule.
- On hardware: pull the cable mid-play, let a disk sleep, wake the Mac with the share gone, and eject a volume under a playing track.
- `make bench-components` before and after, to show the direct road did not move.
