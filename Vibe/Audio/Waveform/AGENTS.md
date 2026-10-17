# Waveform data

This directory owns the waveform *data*: the decode that generates it, and its persistence. The data structure and its reads are `Packages/WaveformCore/`. Rendering is `Vibe/WaveformUI/`. The BPM and key analyzers that ride this decode pass are `Vibe/Audio/Analysis/`.

`AudioWaveform` is WaveformCore's summary (`Packages/WaveformCore/AGENTS.md`), named for Vibe in `AudioWaveform.h`. **Its bins are a fixed span of frames, counted from the start of the decoded window**: 256 frames, a finer power of two for a file too short to fill 8,192 bins, or a coarser one for a file too long to fit 2^18. A decode settles its bin size from the expected length before its first bin, so a length that turns out different moves no bin. Per bin it stores the mix's peak min and max, and the energy as a sum of squared samples. When its decode was asked for them, it stores the same sum for each of three frequency bands. Reads go through a pyramid the builder keeps as bins arrive. `AudioWaveformLoader` generates the data asynchronously through `AudioFileHandle` and hands immutable snapshots to main for progressive rendering. A snapshot costs the same however far the decode has got (`Packages/WaveformCore/AGENTS.md`). `AudioWaveformCache` owns the loader lifecycle and persists through PINCache.

## The reads

Every read takes frames, never bins, so no caller depends on the bin size. The core's header states each one's contract.

- **`column`** is a stretch of frames: its peaks as an exact union. A straddling bin's peaks count whole, so a peak never falls between two columns. **A level is never read from a column's peaks.**
- **A column's `loudest` is its level**: the RMS of the loudest 20 ms window centred on a bin it covers, in the mix and in each band. It is a union like the peaks, so no hit is averaged away and its height does not depend on where a resize put the edges. Over the whole track it is Normalize's reference, which no view can move.
- **`tentBandMeanSquares`** is the bands under a tent centred on each column, which Spectrum's colors read.

**The pyramid, its loudest windows and the tent's running sums are kept while the summary stands.** A shared summary never changes, so each is built once behind one lock. The iOS widget draws a waveform off main, and the views draw it on main.

## What rides the pass is an input, not a setting this layer reads

`AudioWaveformLoader` takes a `VibeWaveformAnalysis` value: the tempo and key analyzers and the bands. `AudioWaveformCache` holds the `VibeWaveformAnalysisProvider` block and asks it **once per request, on main**. The cache lookup and the decode then agree on the bands, and a provider reading main-confined settings is never called off main. The cache's owner installs it: `MainPlayerController` from the two analysis settings and the theme's style, `PlayerViewController` on iOS from `analyzeBPM` and the card's and widget's styles. An unset provider runs none of it, which is what the tests get.

## The decode pass

The decoder and optional analysis both contribute to the pass cost. The loader **pipelines decoding and processing**: block N+1 decodes while block N runs through the mono mix, the analyzers and the summary on a serial queue one block behind. Two buffers ping-pong, gated by per-slot semaphores. The serial queue keeps the stream order the analyzers' framing depends on, so the output is exact. All processing-side state, the progress throttle included, lives on that queue and is read only after the final drain.

**A local file's first progressive snapshot waits the same 0.1 s of decoding as every later one.** The interval is wall time, which is safe only because a snapshot costs about what main's did. An immediate one would show only a sliver of the track. Completion bypasses the throttle. A file whose reads wait for bytes (`waitsForBytes`: a stream, or a network mount's read-ahead) keeps the immediate first snapshot, since its next read can stall.

## The three bands are decoded only when asked for

3-Band and Spectrum (`WaveformUI/Renderers/AGENTS.md`) are their only readers. So **a decode splits them only when its request asks** (`VibeWaveformAnalysis.bands`, from `WaveformRendererRegistry readsBandsForIdentifier:`). The split adds four filters per sample. The summary's builder filters each bin's slice of the mono stream into low, mid and high (the core's `BandSplit`). **One split per decode, on the serial queue**, since its filters carry state across slices.

## The archive

`CodableAudioWaveform` is the cache entry. It keeps the summary's own archive under the `summary` key, beside the tempo, the key and the analysis flags. **The summary's archive is a header and float16 planes**: peaks, each bin's RMS, and the bands' RMS when the decode kept them. It stores RMS because a long bin's sum overflows float16 and a quiet bin's mean square underflows it. The core's decode refuses anything malformed or non-finite, since the archive has no checksum. **Only a complete summary is filed**, and an incomplete one is refused on read. A 4:40 track takes about 250 KB, a 33-s loop about 30 KB, and an hour-long mix about 3 MB.

**An entry without the bands is a miss only for a request that wants them.** Likewise an entry decoded without the tempo or key analyzer is a miss for a request that runs it (`CodableAudioWaveform.bpmAnalyzed`/`keyAnalyzed`; an archive without the flags reads analyzed). That decode replaces the entry, so nothing is ever invalidated for what it lacks. A request that finds a decode lacking what it asks for in flight for the same window cancels it and waits on its claim. **An owner that comes to want more asks for its track again**: the mac when the style becomes 3-Band or Spectrum or a detection switch turns on (`VibeSettingsLiveEffectWaveformStyle`, `VibeSettingsLiveEffectTrackAnalysis`), the iOS card when the card's or the widget's style does. Switching between 3-Band and Spectrum asks for nothing, since both read the same entry.

## A cue row's waveform is its window

The loader decodes only the row's window (`cueStart`/`cueEnd` through `VibeCueWindow`), and the analyzers ride the same window. A DJ mix gets a waveform, a tempo and a key per track. Everything keyed per file is keyed per window here: the claim (`AudioTrack.standardizedSourceKey`), the detached-loader pool and the disk entry all append the window through `AudioTrack.keyByAppendingWindowTo:`. Metadata stays the file's.

## Admission

Cache-key stats, cache lookups, opens and decodes pass through **fixed-slot utility `AudioWorkScheduler`s** (`Loading/Claim/`). `stat` and the open can block for minutes on a cloud placeholder and have no cancellation point, so fixed slots are the resource bound. A stat keeps its slot while it visits the serial cache queue. Playback opens never pass through these schedulers, so background analysis cannot starve the open the user is waiting on.

**Lookups and decodes use separate lanes.** The lookup lane runs two, the decode lane `kMaxDetachedWaveformLoads + 1` = three. A decode is submitted from *inside* a lookup that still holds its slot. Sharing one scheduler would let a burst of lookups expire the decode they asked for, delivered as that file failing to load. The lookup and decode lanes each hold at most four pending items. A pending request whose lane stays full for ten seconds fails *admission*. A never-returning OS call still owns its slot for the process's life, but retries cannot multiply it.

`cachedWaveformForTrack:completion:` shares entry validation but has its own preview lane: one running, two pending. So a neighbor's uncancellable stat cannot occupy a lookup slot. It starts no open or decode. It answers on main, nil on a miss or admission failure, and rejects a hit invalidated during the read. Its `AudioWorkToken` cancels still-pending work with no completion. The iOS pager uses it only for neighboring previews.

**Deep zoom's reads have a lane of their own** (`loadDetailBlocks:forTrack:waveform:completion:`): one running and one waiting. So a read stuck on a dead mount holds no decode slot, and a zoom cannot starve a decode. Each read opens the file as a decode does and reads the blocks asked for into the waveform's detail (`Packages/WaveformCore/AGENTS.md`). **A file not on disk is skipped**, a provider's or a remote placeholder, since a zoom must never start a download. Nothing is persisted. The iOS scrubber asks for the blocks its last draw lacked (`WaveformUI/iOS/AGENTS.md`).

## A superseded load is detached, not aborted

`cancelLoad` and a new `loadWaveformForTrack:` stop the old load's *deliveries* but let its decode finish and persist. A later request can use the completed decode from disk. Neighbor previews on iOS only read existing entries and do not start a decode.

Up to `kMaxDetachedWaveformLoads` (2) detached decodes run behind the active one. Beyond that the oldest loader is cancelled. A claim stays registered until its stat, open or decode worker really returns. Re-requesting a file whose detached decode still runs **reattaches** it. Re-requesting one whose loader was cancelled parks one replacement until the old worker settles. Work not yet holding a scheduler slot is removed with its claim at once, so skip storms cannot queue behind wedged workers.

**The claim is unbounded; the wait on it is not.** A worker blocked in an uncancellable stat or open keeps its slot and claim until it returns. After `kWaveformClaimWaitSeconds` (20) the parked request is dropped with an ordinary terminal failure, and the worker settles whenever it returns. A retry starting later would deliver a waveform for a track the user was told has none.

**TRAP: `detachCurrentLoader` must detach even a loader that reads `isComplete`.** `isComplete` is set on the decode thread *before* its final delivery reaches main, and the detach flag is what `deliverCompleteWaveform` checks. Skipped, that delivery lands as a live one on the track that superseded it. The flag is checked **on delivery, not at enqueue**, so a reattach landing first turns it live again. Detached and cancelled loaders build no progressive snapshots. A reattached loader resumes them.

## A file still downloading rides the play's stream

**The loader opens a streaming file like any other** (`AudioFileHandle` finds the transfer's `CloudFileAvailability`). Its decode fills in as the bytes arrive and completes only once the last byte has. The entry is filed under the placeholder's size and mtime, which the install keeps. A download that installed another version re-keys every track (`Loading/AGENTS.md`).

**A guessed length is never persisted against.** A streaming MP3 with no VBR header opens on an estimated length (`AudioFileHandle.lengthIsEstimated`, `Audio/AGENTS.md`). The loader decodes on it, but **TRAP:** a pass sized by an estimate is complete only once the length is exact (`decode:`). At its end it waits in `awaitExactLength:`, which `cancel` interrupts. **A bin never depends on the length, so the pass keeps everything it read.** It reads on to the exact length, or it already stopped where the file did. Only a cue window that moved with the exact length starts over. Nothing laid out on an estimate is delivered complete or filed under the file's key. A progress tick stays short of 1, since a receiver reads 1 as completion (the iOS pager's `isCompleteAtIndex:`).

**A waveform never holds a stream: the play's handles do** (`holdStream`, sent only to handles the coordinator serves). When the play lets go (a skip, a stall, a failed open, its track's end), the coordinator cancels the transfer. The decode's next wait then fails as a read error, never complete, never persisted, and delivered as a failure only while current. So a detached streaming decode needs no rule of its own.

**A cancel ends a streaming decode's wait at once** (`cancel`: `interruptReads` on the handle, and the open's `interrupted` block with the file's waiters woken). The cap's eviction frees its slot now. An interruption is not logged. **TRAP: the loader holds that handle only until its load ends** (`load:`). A loader outlives its load, held by its claim and the claim's wait timer. Keeping the handle would also retain its descriptor and read block. **The 20 s claim wait is not a streaming timeout.** A streaming decode has no deadline of its own. The play's stall deadline and the transfer's request timeout bound it, through the cancel.

**A file on a network mount reads ahead for the loader too** (`Audio/AGENTS.md`), on a thread of its own apart from the play's. Only a `cancel` ends its waits. The play's stall lets go of the play's handle, not the loader's. **A read-ahead decode on a dead mount holds its decode slot until it is cancelled**, which the cap's eviction does once newer decodes push it out.

**One decode slot per window for the length of the download.** The claim and reattachment keep a second request off a second slot. Each cue row of a streaming image takes one.

## Every delivery carries the track it was loaded for

`audioWaveform:didLoadData:forTrack:`, `audioWaveformCache:didFailToLoadForTrack:` and the BPM and key twins all carry it, because a delivery can land after the track changed. Receivers match `sourceKey`, not the URL, since rows of one file share it (root `AGENTS.md`). `MainPlayerController+Delivery` and the iOS `PageWaveformCoordinator` do this. A tempo or key is stamped on every row sounding that window (`Playlist.stampTracksSounding:usingBlock:`). Failure is delivered only while the loader is current, and is made terminal first so a same-window request starts fresh. iOS implements the BPM twin (forwarded to `PlaybackController.noteDetectedBPM:forTrack:`) and not the key one.

The cache captures the track when the load starts (`_currentLoadTrack`). **The reattach path must set it too**, or a resumed decode delivers under the track it was detached from.

## Language

`.mm` files, because the waveform types are C++. `AudioWaveformCache.h` forward-declares `CodableAudioWaveform` rather than importing `AudioWaveform.h`, so the UI layer compiles as plain ObjC.
