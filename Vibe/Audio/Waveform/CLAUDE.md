# Waveform data

This directory owns the waveform *data*: generation, chunking and persistence. Rendering is `Vibe/WaveformUI/`; the BPM and key analyzers that ride this decode pass are `Vibe/Audio/Analysis/`.

`AudioWaveform` is a C++ structure storing one min/max float pair per chunk. `AVFAudioWaveformLoader`, backed by `AVAudioFile`, generates the data asynchronously and hands immutable snapshots to the main thread for progressive rendering. `AudioWaveformCache` owns the loader lifecycle and persists through PINCache.

## Whether the analyzers ride at all is an input, not a setting this layer reads

`AudioWaveformLoader` takes a `VibeWaveformAnalysisProvider` block, asked once per `load:` so a settings change lands on the next decode. `AudioWaveformCache` stamps its own onto every loader it creates, and the cache's owner installs it — `MainPlayerController` from the two analysis settings, and **nothing on iOS**, which does not analyze. An unset provider means neither analyzer runs, which is also what the tests get.

Same shape as `FolderArtResolver`'s enabled provider, for the same reason: a decode pass that reached into a settings singleton could not be tested without one.

## The decode pass

The pass is decode-bound — CoreAudio's MP3 and FLAC codecs cost several times everything downstream combined, and the read block size does not move that floor — so the loader **pipelines the decode against the processing**: block N+1 decodes while block N runs through the mono mix, the analyzers and the chunker on a serial queue one block behind, ping-ponging two buffers whose reuse per-slot semaphores gate. Wall time comes down to roughly the decode alone, and the output is exact, because the serial queue preserves the stream order the analyzers' framing depends on.

All processing-side state — the progress throttle and its snapshots included — lives on that queue and is read only after the final drain.

Cache-key stats, serial cache lookups, opens and decodes pass through **fixed-slot utility `AudioWorkScheduler`s**. `stat` and `AVAudioFile` open have no cancellation point and can block for minutes on a cloud placeholder, so fixed admission slots are the resource bound. A stat keeps its slot while it synchronously visits the serial cache queue, so a wedged cache lookup cannot grow a tail there either. Playback has a separate user-initiated scheduler again, so background analysis cannot starve the open the user is waiting on.

**Two lanes here, not one, because the stages block on different things.** The lookup lane (cache-key stat plus the serial cache lookup) runs two; the decode lane (open plus decode) runs `kMaxDetachedWaveformLoads + 1` = three. They must be independent because a decode is submitted from *inside* a lookup that still holds its slot: sharing one scheduler let a burst of lookups fill the pending list and then reject or expire the very decode they had asked for — delivered to the delegate as that file failing to load, when nothing about the file had failed.

Pending work is held inside the scheduler — never submitted to `NSOperationQueue` or libdispatch until a slot is free — with an explicit four-item memory bound. Cancellation removes a still-pending block synchronously. If all three slots remain occupied for ten seconds, the pending request fails *admission* without pretending its file open ran and timed out. A truly never-returning OS call still owns its fixed slot for the process lifetime; only process restart (or future killable helper-process isolation) can reclaim that thread, but retries cannot multiply it.

## A superseded load is detached, not aborted

`cancelLoad` and a new `loadWaveformForTrack:` stop the old load's *deliveries* but let its decode run to completion and persist, so a skip-ahead — or the iOS pager peeking at a neighbour — turns the next request for that file into a disk hit instead of throwing the work away.

Up to `kMaxDetachedWaveformLoads` (2) detached decodes run behind the active one, bounding concurrent decodes at three; beyond that the oldest loader is cancelled outright. Standardized-path claims are independent of that UI lifecycle: a claim stays registered until its executing stat/open/decode worker really returns. Re-requesting a file whose live detached decode is still running **reattaches** it; re-requesting one whose loader was permanently cancelled parks one replacement and starts it only after the old worker settles. Work which has not acquired a scheduler slot is removed with its claim immediately, so skip storms cannot build an unbounded queue behind wedged workers.

**The claim is unbounded; the wait on it is not.** A worker blocked in an uncancellable stat or open keeps its slot and its path claim until it returns, which nothing in-process can force — but a request parked behind it would otherwise hold the waveform view in its loading state forever, since this path has no equivalent of the player's per-file open timeout. After `kWaveformClaimWaitSeconds` (20) the *wait* is given up rather than the claim: the parked request is dropped and the delegate gets its ordinary terminal failure, while the worker keeps its slot and settles normally whenever it returns. The parked request is dropped rather than left armed deliberately — a retry starting later would deliver a waveform for a track the user has already been told has none.

**TRAP: `detachCurrentLoader` must detach even a loader that reads `isComplete`.** `isComplete` is set on the decode thread *before* its final delivery block reaches the main queue, so "complete" can still have a live delivery in flight, and the detach flag is what `deliverCompleteWaveform` checks on main. Skipping the detach there let that delivery land as a live one on whatever track had superseded it. (The completed loader is then not pooled — its decode is done and persists on its own.)

The flag is checked **on delivery, not at enqueue**, so a reattach landing first correctly turns it back into a live one.

Progress is different: detached and cancelled loaders do not construct or enqueue progressive snapshots. A reattached loader resumes them from its live decode position. The final waveform still persists while detached.

## Every delivery carries the URL it was loaded for

`audioWaveform:didLoadData:forURL:`, the terminal-failure callback, and the BPM and key twins — because a delivery can land after the track has changed. Receivers must match it against their current track rather than assume it: `MainPlayerController+Delivery` and the iOS `PageWaveformCoordinator` each do. Failure is delivered only while that loader is still current; it makes the attempt terminal before delivery so a same-file request starts fresh. The BPM and key twins are optional and iOS implements neither, since analysis is macOS-only.

The cache captures that URL when the load starts (`_currentLoadURL`) rather than reading it back at delivery time, and **the reattach path must set it too**, or a resumed decode would deliver under the URL it was detached from.

## Language

`.mm` files, because the waveform types are C++. Keep them out of ObjC headers: `AudioWaveformCache.h` forward-declares `CodableAudioWaveform` rather than importing `AudioWaveform.h`, so the UI layer compiles as plain ObjC.
