# Future: streaming from any source

**Status: planned 2026-10-03, not started. Builds on streaming Dropbox playback (`dropbox-streaming.md`, PR 134), and changes nothing in it until phase 1.**

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

`dropbox-streaming.md` says other File Providers have "no public partial-read API". That sentence is imprecise, and this section replaces it.

Measured on macOS 27 with a probe that opens a dataless file, reads 64 KB with a plain `pread`, and then `fstat`s it:

| Provider | The first 64 KB read | On disk while it blocked | On disk after |
| --- | --- | --- | --- |
| Dropbox's File Provider, 72 MB WAV | blocked 4.0 s | not sampled | the whole file, no longer dataless |
| iCloud Drive, 106 MB WAV | blocked 2.6 s | not sampled | the whole file |
| iCloud Drive, 180 MB MP3 | blocked 12.3 s | 0 bytes, sampled every 0.4 s | the whole file |

- **macOS File Providers can deliver ranges, and neither of these two does today.** `NSFileProviderPartialContentFetching` (macOS 12.3) lets a provider answer a POSIX read of a dataless file with only the range read. The header lets it answer with any range covering the request, "including the entire item", so implementing the protocol promises nothing.
- **Dropbox has built it and switched it off.** Its extension (273.4) implements `fetchPartialContents` behind a per-domain "streaming gate" set by live configuration, with a fallback its strings call "gate off; falling back to full hydration". The live log of the probe shows the system asking the extension for exactly 65,536 bytes and the extension answering with the whole file. So Dropbox on the Mac can start streaming with no change on this machine but a flag.
- **iCloud Drive has not built it.** Its extension's binary carries the whole-file fetch and no partial one.
- **Only a POSIX read can get a range.** Apple's documentation: "If you clone the entire file, or read the file using file coordination, the system requests the entire file." Vibe's provider road is `NSFileCoordinator` (`CloudFileMaterializer materializeURL:`), so today Vibe would be handed whole files even by a provider that streams. An app can neither request a range nor learn ahead of the read whether it will get one. The probe is the detector: a file still dataless after a read returned came from a provider that streams.
- **iOS File Providers cannot.** The iOS 27 SDK marks the protocol `API_UNAVAILABLE(ios)`, and Apple's developer support says the same on the forums (thread 776780): macOS only, "no alternative on iOS". A provider there hands over whole files.
- **Apple's sample provider (FruitBasket) implements it**, so a provider written from the sample streams. OneDrive, Box, and Google Drive are not installed here and are unverified.
- **A network filesystem already reads by range.** An SMB, NFS, AFP, or WebDAV mount holds ordinary files, not dataless ones, and each `pread` fetches its bytes over the wire. No whole-file transfer happens, so nothing needs downloading: what is missing is the four rows above. Not measured here, since no share was mounted.
- **Unverified: what the Files app's SMB and USB volumes are on iOS.** They may be live mounts read in place (paths under `LiveFiles/`) rather than provider copies. Phase 0 settles it with the probe on a device, and the design below needs no answer: a mount is read ahead, a dataless file takes the provider road.

## What already exists

- **The wait is already source-blind.** `AudioFileHandle` asks one question, `waitForBytesAt:length:windowInto:capacity:copied:interrupted:error:`, and knows nothing of Dropbox. Its header says so: "a source of bytes changes what answers it, not who asks".
- **A wait can already be answered from memory.** The tail window is copied into the reader's buffer by the wait itself, with no `pread` (`VibeHandleAwait`, the three read paths). A source that serves every byte that way needs no new read path.
- **Interruption, buffering, the stall's pause, and the estimated MP3 length** are all keyed on the handle having an availability, not on Dropbox (`_availability`, `waitingForBytes`, `updateBufferingOnQueue`, `VibeUncountedMPEGPackets`).
- **The coordinator already passes every open an `interrupted:` block** and wakes the file's waiters on cancel. For a whole file it has nothing to interrupt.
- **The Dropbox plan already names the next shape.** "The window generalizes to a block cache keyed by offset, behind the same wait."

## What the code makes hard

Each was found reading the code, and each is a way the feature fails if missed.

- **`CloudFileAvailability` assumes a part file written from byte 0 and one window installed once.** A plain file has no part file, no prefix on disk, and a window that must follow the reader.
- **"Complete" is load-bearing.** `finishWithError:nil` makes every range ready and sends readers to the disk. `awaitExactLength:` (the waveform's open of a VBR MP3 with no header) waits for it. A read-ahead never completes while a reader lives, so that wait would never return.
- **The stall deadline's progress is `bytesWritten`.** For a transfer it is the download's edge. A read-ahead that seeks has no edge, so it needs a count that only grows.
- **The open deadline's progress comes from the transfer registry**, forwarded by each shell (`noteOpenProgressForOpenRequestIdentifier:`). A plain file is not in the registry and must not be: a row shows the loading bar only for a transfer. So a slow open that is moving looks silent, as it does today, and gets the 60 s no-progress span and no more.
- **Classifying the volume must not touch it.** `statfs` on a path under a dead mount blocks, which is the very hang being removed. The mount table read with `getfsstat(MNT_NOWAIT)` does not.
- **`open`, `fstat`, and `close` block on a dead mount too.** Moving only `pread` off the opening thread leaves the open strandable.
- **CoreAudio's QuickTime reader has no callback open** (the `TRAP:` in `initParserForReading:`): MooV and `.qta` parse through the URL, so CoreAudio reads the file itself and nothing can wait on Vibe's terms. Mac only.
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
| Another service's client (not planned) | either | either | either | either |

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
- **The read-ahead's cost on a fast volume** (`make bench-components`, the open, decode, and seek benchmarks with the rule forced on). Decides how wide the rule is, and whether one road for every file is affordable.
- **iOS, on a device:** what a file picked from the Files app's SMB server and from a USB drive is: its path, its mount, and whether it is dataless. Decides whether iOS gains anything.
- **The probe, kept as a script** beside the vibe-debug skill's, so a new provider or OS release is one command to re-check.

### Phase 1: the availability takes any writer

The four additions above, with Dropbox the only writer and its behaviour unchanged: the tail becomes the first block, the wanted range is recorded and ignored. The type loses "Cloud" from its name. **One table of live availabilities in shared code**, which a writer registers into, replaces the per-backend lookup block (`setRemoteRoot:`'s fourth argument) if the mirror's own table can go with it.

Done when the streaming tests, `dropbox-streaming.sh`'s 28 scenarios, and the PCM comparisons pass untouched.

### Phase 2: the file read-ahead, for playback

1. The read-ahead and its bound, in `AudioFileHandle.m`, and the rule in `AudioFileOpenRules.h`.
2. **Length without completion.** A CBR estimate settles where the reads reach the end, as now. A VBR estimate has no download to wait for, so the handle that needs an exact length counts through its own read-ahead (the waveform's does, and it reads the whole file anyway), and that count settles the player's duration.
3. **Progress that only grows:** the bytes the read-ahead has installed feed the stall deadline. The open deadline gets the same count, by a feed that does not pass through the transfer registry.
4. **The mac shell draws buffering** and the stall's pause, and the stall's string stops naming a download (`vibe-strings`).
5. `Audio/AGENTS.md`, `Loading/AGENTS.md`, and `System/AGENTS.md` say "a file still arriving" where they say "a remote transfer".

Done when a throttled file plays through the render pump sample-identical to the direct open, seeks included, and a stalled one never hangs a seek, skip, or stop.

### Phase 3: the other readers

- **The waveform loader** gets it for free, since it opens an `AudioFileHandle`: its own read-ahead, and a cancel that frees its slot on a dead mount. Verify the 20 s claim wait and the decode-slot arithmetic.
- **The metadata sweep stays as it is.** Its reads already hold no lane, and routing TagLib through a waiting stream is a second project. Revisit only if phase 0 shows the sweep hanging the app.

### Phase 4: writers that serve the wanted range, each on evidence

- **Dropbox seeks ahead by range.** A ranged read answers the wanted range into a block, by the pinned `rev`. It helps M4A, WAV, and FLAC with a seek table, and not MP3 or seek-table-less FLAC (the Dropbox plan's spike). This is that plan's option C without the sparse file.
- **A File Provider that delivers ranges.** The file read-ahead over a dataless file, skipping the `NSFileCoordinator` download, which is the only way the system hands out a range. Only for a provider the probe has shown to stream, since on any other the first read downloads the whole file with no cancel. Dropbox's Mac extension is the likeliest first: the code is shipped and gated off. Build it when a provider in users' hands passes the probe, not before, and re-run the probe on each Dropbox release until then.
- **Another service's own client** is a product decision, not this plan's. Its transfer would be one more writer.

## Options weighed and not taken

- **Warm the page cache and keep `pread` on the decode thread.** Smaller: no copy and no blocks. But the decoder still enters the kernel on the slow volume, and an evicted page or a lost SMB lease makes a "ready" range block again. Interruption would be likely, not guaranteed.
- **One read-ahead per file, shared by its readers.** It mirrors a transfer, but two readers at different positions fight over one window.
- **Every file through the read-ahead, one road.** It would delete the whole-file branch from the handle. It costs a thread and a copy on every open of a fast disk, across a library scan's thousands. Phase 0 measures it. Expected answer: no.
- **Owned by the coordinator as a stage-1 run.** The waveform and metadata opens do not pass through the coordinator, and a slow file is not a transfer: it has no lane to hold and no fraction to show.
- **A source protocol with a class per writer.** Two new types to express what a missing part file and a writer's loop already say.

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
- **The Dropbox suite, unchanged,** at every phase.
- **`vibe-stress`:** skip, seek, and stop during a stall. A hang on any of them is the interrupt rule broken.
- **On hardware:** pull the cable mid-play, let a disk sleep, wake the Mac with the share gone, and eject a volume under a playing track.
- **`make bench-components`** before and after, so the direct road is shown not to have moved.
