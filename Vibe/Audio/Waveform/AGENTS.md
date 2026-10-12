# Waveform data

This directory owns the waveform *data*: generation, chunking and persistence. Rendering is `Vibe/WaveformUI/`. The BPM and key analyzers that ride this decode pass are `Vibe/Audio/Analysis/`.

`AudioWaveform` is a C++ structure. Per chunk it stores the peak min/max and the energy, a sum of squared samples plus a frame count, so merges stay exact in any order. When its decode was asked for them, it stores the same sum for each of three frequency bands. `AudioWaveformLoader` generates the data asynchronously through `AudioFileHandle` and hands immutable snapshots to main for progressive rendering. `AudioWaveformCache` owns the loader lifecycle and persists through PINCache.

## Two reads: a column's peaks, and a bar's energy

`getChunkAtIndex` combines a column's whole chunks, and is what a shape is drawn from. A peak must never fall between two columns. **A level is never read from it.** `getBarMeanSquares` answers every bar's mean square at once, the mix's or the bands', in one pass. A bar's own window is the bar exactly, and a chunk counts by the part the bar covers. **With reach, a bar takes the loudest of the five bar-long windows a quarter bar apart around its own.** One of those holds a kick whole, so its height does not depend on where a resize put the edges. Reach is the caller's, 0 to 1. When to fade it out is the renderers' rule (`WaveformUI/Renderers/AGENTS.md`). A window past the track's edge, or past the front of a load still streaming, is the mean of the frames it covers.

## What rides the pass is an input, not a setting this layer reads

`AudioWaveformLoader` takes a `VibeWaveformAnalysis` value: the tempo and key analyzers and the bands. `AudioWaveformCache` holds the `VibeWaveformAnalysisProvider` block and asks it **once per request, on main**. The cache lookup and the decode then agree on the bands, and a provider reading main-confined settings is never called off main. The cache's owner installs it: `MainPlayerController` from the two analysis settings and the theme's style, `PlayerViewController` on iOS from `analyzeBPM` and the card's and widget's styles. An unset provider runs none of it, which is what the tests get.

## The decode pass

The pass is decode-bound. The file's decoder (`Audio/AGENTS.md`) is the floor of its cost. So the loader **pipelines the decode against the processing**: block N+1 decodes while block N runs through the mono mix, the analyzers and the chunker on a serial queue one block behind. Two buffers ping-pong, gated by per-slot semaphores. The serial queue keeps the stream order the analyzers' framing depends on, so the output is exact. All processing-side state, the progress throttle included, lives on that queue and is read only after the final drain.

**A local file's first progressive snapshot waits the same 0.1 s of decoding as every later one.** An immediate one would show only a sliver of the track. Completion bypasses the throttle. A file whose reads wait for bytes (`waitsForBytes`: a stream, or a network mount's read-ahead) keeps the immediate first snapshot, since its next read can stall.

## The three bands are decoded only when asked for

3-Band (`WaveformUI/Renderers/AGENTS.md`) is their only reader. So **a decode splits them only when its request asks** (`VibeWaveformAnalysis.bands`, from `WaveformRendererRegistry readsBandsForIdentifier:`). They cost about four times the rest of the processing, which a cheap WAV cannot hide. The chunker hands each chunk's slice of the mono stream to `AudioWaveformBandSplit`, which filters it into low, mid and high. **The four biquad sections run side by side in one double-precision vector.** Mid's lowpass is fed its highpass's output from two samples back, so no lane waits on another. A sample then costs one section's latency, where `vDSP_biquad` runs sections in series at 2.6x the cost. The mid band lags by two samples, which no chunk can see. The crossovers are 2nd-order Butterworth at 300 Hz and 2.5 kHz, the handovers cdj3k-mods measured off a CDJ-3000's 3-band display. **One split per decode, on the serial queue**, since its filters carry state across slices.

**The band sums are an allocation and an archive key of their own** (`getBandMeanSquares` for the archive, `getBarMeanSquares` for bars). Widening the chunk instead made every style's per-bar merges dearer (+73% instructions on a Detailed resize). In memory they are float32 sums. **The archive keeps each chunk's mean squares in float16**, multiplied back by the chunk's frames on read. It stores means because a long chunk's sum overflows float16. The optional `bands` key needs no version bump: an entry without it is one no band request decoded.

**An entry without the bands is a miss only for a request that wants them.** Likewise an entry decoded without the tempo or key analyzer is a miss for a request that runs it (`CodableAudioWaveform.bpmAnalyzed`/`keyAnalyzed`; an archive without the flags reads analyzed). That decode replaces the entry, so nothing is ever invalidated for what it lacks. A request that finds a decode lacking what it asks for in flight for the same window cancels it and waits on its claim. **An owner that comes to want more asks for its track again**: the mac when the style becomes 3-Band or a detection switch turns on (`VibeSettingsLiveEffectWaveformStyle`, `VibeSettingsLiveEffectTrackAnalysis`), the iOS card when the card's or the widget's style does.

## A cue row's waveform is its window

The loader decodes only the row's window (`cueStart`/`cueEnd` through `VibeCueWindow`), at full chunk resolution, and the analyzers ride the same window. A DJ mix gets a waveform, a tempo and a key per track. Everything keyed per file is keyed per window here: the claim (`AudioTrack.standardizedSourceKey`), the detached-loader pool and the disk entry all append the window through `AudioTrack.keyByAppendingWindowTo:`. Metadata stays the file's. Slicing one whole-file waveform was rejected: a four-minute row of a 74-minute image would get about 440 of its 8192 chunks.

## Admission

Cache-key stats, cache lookups, opens and decodes pass through **fixed-slot utility `AudioWorkScheduler`s** (`Loading/Claim/`). `stat` and the open can block for minutes on a cloud placeholder and have no cancellation point, so fixed slots are the resource bound. A stat keeps its slot while it visits the serial cache queue. Playback opens never pass through these schedulers, so background analysis cannot starve the open the user is waiting on.

**Lookups and decodes use separate lanes.** The lookup lane runs two, the decode lane `kMaxDetachedWaveformLoads + 1` = three. A decode is submitted from *inside* a lookup that still holds its slot. Sharing one scheduler would let a burst of lookups expire the decode they asked for, delivered as that file failing to load. The lookup and decode lanes each hold at most four pending items. A pending request whose lane stays full for ten seconds fails *admission*. A never-returning OS call still owns its slot for the process's life, but retries cannot multiply it.

`cachedWaveformForTrack:completion:` shares entry validation but has its own preview lane: one running, two pending. So a neighbor's uncancellable stat cannot occupy a lookup slot. It starts no open or decode. It answers on main, nil on a miss or admission failure, and rejects a hit invalidated during the read. Its `AudioWorkToken` cancels still-pending work with no completion. The iOS pager uses it only for neighboring previews.

## A superseded load is detached, not aborted

`cancelLoad` and a new `loadWaveformForTrack:` stop the old load's *deliveries* but let its decode finish and persist. A skip-ahead, or the iOS pager peeking at a neighbour, then turns the next request for that file into a disk hit.

Up to `kMaxDetachedWaveformLoads` (2) detached decodes run behind the active one. Beyond that the oldest loader is cancelled. A claim stays registered until its stat, open or decode worker really returns. Re-requesting a file whose detached decode still runs **reattaches** it. Re-requesting one whose loader was cancelled parks one replacement until the old worker settles. Work not yet holding a scheduler slot is removed with its claim at once, so skip storms cannot queue behind wedged workers.

**The claim is unbounded; the wait on it is not.** A worker blocked in an uncancellable stat or open keeps its slot and claim until it returns. After `kWaveformClaimWaitSeconds` (20) the parked request is dropped with an ordinary terminal failure, and the worker settles whenever it returns. A retry starting later would deliver a waveform for a track the user was told has none.

**TRAP: `detachCurrentLoader` must detach even a loader that reads `isComplete`.** `isComplete` is set on the decode thread *before* its final delivery reaches main, and the detach flag is what `deliverCompleteWaveform` checks. Skipped, that delivery lands as a live one on the track that superseded it. The flag is checked **on delivery, not at enqueue**, so a reattach landing first turns it live again. Detached and cancelled loaders build no progressive snapshots. A reattached loader resumes them.

## A file still downloading rides the play's stream

**The loader opens a streaming file like any other** (`AudioFileHandle` finds the transfer's `CloudFileAvailability`). Its decode fills in as the bytes arrive and completes only once the last byte has. The entry is filed under the placeholder's size and mtime, which the install keeps. A download that installed another version re-keys every track (`Loading/AGENTS.md`).

**A guessed length is never persisted against.** A streaming MP3 with no VBR header opens on an estimated length (`AudioFileHandle.lengthIsEstimated`, `Audio/AGENTS.md`). The loader decodes on it, but **TRAP:** a pass sized by an estimate is complete only once the length is exact and within one chunk of the size it used (`decode:`). At its end it waits in `awaitExactLength:`, which `cancel` interrupts. If the two differ by a chunk or more it decodes again, from disk, on the exact length. Chunk i starts at i·T/N, so an estimate off by under a chunk moves each boundary by less than one chunk, which a short decode already tolerates. Nothing sized by an estimate is delivered complete or filed under the file's key. A progress tick stays short of 1, since a receiver reads 1 as completion (the iOS pager's `isCompleteAtIndex:`). A cue row past a short estimate is sized by `VibeCueWindow`'s rule and decoded again the same way.

**A waveform never holds a stream: the play's handles do** (`holdStream`, sent only to handles the coordinator serves). When the play lets go (a skip, a stall, a failed open), the coordinator cancels the transfer. The decode's next wait then fails as a read error, never complete, never persisted, and delivered as a failure only while current. So a detached streaming decode needs no rule of its own.

**A cancel ends a streaming decode's wait at once** (`cancel`: `interruptReads` on the handle, and the open's `interrupted` block with the file's waiters woken). The cap's eviction frees its slot now. An interruption is not logged. **TRAP: the loader holds that handle only until its load ends** (`load:`). A loader outlives its load, held by its claim and the claim's wait timer. Keeping the handle kept a descriptor and its read block per replay. **The 20 s claim wait is not a streaming timeout.** A streaming decode has no deadline of its own. The play's stall deadline and the transfer's request timeout bound it, through the cancel.

**A file on a network mount reads ahead for the loader too** (`Audio/AGENTS.md`), on a thread of its own apart from the play's. Only a `cancel` ends its waits. The play's stall lets go of the play's handle, not the loader's. **A read-ahead decode on a dead mount holds its decode slot until it is cancelled**, which the cap's eviction does once newer decodes push it out.

**One decode slot per window for the length of the download.** The claim and reattachment keep a second request off a second slot. Each cue row of a streaming image takes one.

## Every delivery carries the track it was loaded for

`audioWaveform:didLoadData:forTrack:`, `audioWaveformCache:didFailToLoadForTrack:` and the BPM and key twins all carry it, because a delivery can land after the track changed. Receivers match `sourceKey`, not the URL, since rows of one file share it (root `AGENTS.md`). `MainPlayerController+Delivery` and the iOS `PageWaveformCoordinator` do this. A tempo or key is stamped on every row sounding that window (`Playlist.stampTracksSounding:usingBlock:`). Failure is delivered only while the loader is current, and is made terminal first so a same-window request starts fresh. iOS implements the BPM twin (forwarded to `PlaybackController.noteDetectedBPM:forTrack:`) and not the key one.

The cache captures the track when the load starts (`_currentLoadTrack`). **The reattach path must set it too**, or a resumed decode delivers under the track it was detached from.

## Language

`.mm` files, because the waveform types are C++. `AudioWaveformCache.h` forward-declares `CodableAudioWaveform` rather than importing `AudioWaveform.h`, so the UI layer compiles as plain ObjC.
