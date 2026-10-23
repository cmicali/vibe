# File loading and metadata: behavioral spec

What the file-load and metadata subsystem does, as observable behavior. It spans `Vibe/Loading/`, vibe-libs' `files/FileLoading` and `media/Metadata`, the player and both shells. Their `AGENTS.md` files describe the mechanism. Code, tests and the `vibe-stress` scenarios cite items here by letter and number (`spec D7`, `J8`), so an item keeps its label. A removed item leaves a gap.

The spec does **not** constrain mechanism. Holds or preemption, one coordinator or two, which object owns a timer: all are free, as long as every numbered behavior survives. File references are pointers for verification.

Where this spec and `vibe-libs/files/FileLoading/AGENTS.md` overlap, this spec is the authority for behavior and its policy numbers. `vibe-libs/files/FileLoading/AGENTS.md` is the authority for how the code works.

---

## A. Definitions

- **A1. Local and dataless.** A file is *local* when its contents are on disk. It is *dataless* when it is a File Provider or app-owned remote placeholder that needs a transfer (`PlaceholderFiles.isDatalessFile:`). Every rule that bounds or suspends downloads binds *transfers*. A local file never starts one and is exempt from all of them.
- **A2. Materialization.** Making a standardized path local: a provider or remote download, or a no-op for a local file. A remote stream can become readable before that operation completes. **At most one materialization operation exists per standardized path at any time.** Every interested party joins it rather than starting a second transfer. This is the most load-bearing rule in the subsystem.
- **A3. Open.** Producing a usable `AudioFileHandle` for a purpose: playback or prefetch. Gapless opens nothing (B6). Purposes hold **independent handles** for the same path, since a handle has one stateful read position.
- **A4. Roles.** Work competing for transfers is playback, prefetch, metadata for the current track ("priority"), metadata for the playlist sweep ("scan"), or artwork extraction. Playback and prefetch are *foreground*. The rest are *background*.
- **A5. Submission identity.** Every play submission gets a fresh identity. A replayed row reuses the same `AudioTrack` **and** the same URL, so no content-based check can tell a stale settlement from a current one. Identity is the only correct guard.

## B. Playback opens

- **B1.** A local open needs no transfer or permission prompt. App-owned waits must be interruptible. OS calls can still stall a worker (J9).
- **B2.** Playing a dataless file downloads it, as one transfer (A2). A provider file opens after materialization. A remote stream may open and play before completion. An accepted provider-dataless classification shows Loading at once. Other opens show it after **0.5 s** (`kWaitIndicatorDelaySeconds`). The row's transfer bar appears only while its transfer runs, not while it is queued. Play or pause during Loading toggles whether the open lands playing or parked. A seek during Loading retargets the start position.
- **B3. Progress and the deadline.** Download progress is observable (the loading bar), and progress feeds liveness. An open is abandoned after **60 s with no progress**, extended to **60 s past each positive byte movement** (`AudioFileOpenTimeoutMath.h`). A moving transfer is never abandoned. Deadlines extend and never shorten. Progress is matched by *open identifier*, not by path or track. A replay therefore cannot inherit a stale monitor, and a retry cannot extend a dead one.
- **B4. Abandonment.** A timed-out open reports a timeout error naming the file, and stops cleanly with no auto-resume. The abandoned pick is **not** chased. It returns to the sweep as an ordinary candidate at its ordinary rank. Under extend-on-movement deadlines an abandoned transfer has been silent for its full 60 s, so there is no "still moving" pick to chase. Scenario S12b pins this.
- **B5. Prefetch.** On every track start `Playlist.trackEndSuccessor` is pre-opened, at depth 1. Prefetch shares foreground transfer capacity and the handle-run ceiling with playback (B8). A play with the same `AudioTrack.sourceKey` consumes the parked prefetch handle. Another CUE window of that file is a different source. Whichever of a racing prefetch and playback open succeeds first serves the play. The loser's park state is retired, so the current track cannot become its own successor.
- **B6. Gapless.** The parked prefetch handle is queued as the current voice's successor when the crossfade is at minimum or the next CUE row continues the recording. Bit-perfect output also requires matching processing formats and no device switch. There is no second open. The parked handle is already usable, even when it reads a still-downloading stream.
- **B7. "On track end" is enforced at prefetch and at advance** (root `AGENTS.md`). Changing Pause, repeat or shuffle re-evaluates the parked successor.
- **B8. Admission is bounded end to end.** Concurrent transfers, pending transfer work and live handle runs are all bounded (numbers in H). Transfer work may wait only within its pending bound and grace. A seventh distinct handle run is refused at once as "admission exhausted", with no queue, pending allowance or grace. A never-returning OS call stays one of the six live runs until process restart. It consumes no transfer capacity and cannot become unbounded worker growth.
- **B9. Stop and Close fire no transport or track-end callback** (root `AGENTS.md`). They supersede any in-flight open. A Loading track never starts after either action.
- **B10. Classification is bounded and state-isolated.** Initial classifications use eight running and sixteen pending slots. One stalled probe leaves the other running slots free. Saturation can make a healthy pending probe fail after five seconds as admission exhausted, which for metadata spends D7's budget. That replaces an unbounded worker tail. A delayed or readmitted dataless refresh begins only after reserving its transfer lane, and does not use those slots. It has no expiry, so a never-returning refresh holds that lane (J9). Neither phase blocks request registration or coordinator state.

## C. The foreground/background rule

- **C1. The rule.** While the coordinator has a foreground claim, **metadata-only dataless work yields**. A foreground claim is a playback or prefetch waiter, or a readable stream still downloading under a handle it served. The sweep also defers its remote ranged reads. A successful streaming open does not end the hold, since the user's transfer still needs the bandwidth. The coordinator derives the hold from its claim table.
- **C2. Local work flows through.** While the rule is in force, cache checks, parses of local files and local materializations continue (A1). On a partly downloaded folder, every local row's tags keep landing during a cloud open.
- **C3. Same-path join.** A metadata request for the very file playback is downloading joins that materialization and waits for completion. Remote tag parsing uses ranged reads instead, reusing an active stream's bytes where it can. It never needs a second whole-file download.
- **C4. The hold follows live claims.** Completing or cancelling one request cannot release another's foreground work. A stream stays foreground while downloading under a served reader. An abandoned stream is cancelled once it has neither waiters nor readers. Shells match play settlements by submission identity (A5) when starting deferred metadata work. They keep no second transfer hold.
- **C5. Teardown drops the old work.** Close or replacement cancels the old sweep, its pending work and the old open. An old callback cannot release a new request's claim or start the discarded playlist's sweep.
- **C6. Preemption at assertion.** Asserting the rule stops a running scan transfer. The sweep's in-flight download is cancelled, not waited out. A yielded transfer spends no retry budget.
- **C7. The successor is foreground too.** A prefetch waiter, or its still-downloading served stream, enforces C1 as playback does. Registering it preempts an existing metadata-only transfer, so a scan cannot keep a successor waiting on its own download.

## D. Metadata loading

- **D1. Cache first.** A cached row gets tags, duration and thumbnail without reading audio content. Computing its cache key still reads file attributes. On a playlist of placeholders, every cached row lands at disk speed before any download is chosen. Stage 1 of the scan checks every row against the cache. Only stage 2 may download.
- **D2. The cache key follows the audio file** (root `AGENTS.md`, Key patterns). A changed size, mtime or path misses. A rewrite preserving all three is undetectable. A sidecar image cannot move it. A remote install that changes the placeholder's stamp re-keys its tracks.
- **D3. Current track first.** The playing or loading track's tags and art are produced ahead of the sweep, at user-initiated priority, whether or not a sweep runs. The mac header, the iOS now-playing page and Now Playing all read them.
- **D4. The sweep is deferred** until the picked track's open settles, with a **2 s** fallback so a wedged open cannot leave the playlist unpopulated. A parked restore with no play starts the sweep directly. C1 still gates dataless work.
- **D5. Sweep order follows the listener.** Among pending misses: **local files first**, since their materialization is free. Then untried before deferred, so a failed-once record sorts last. Then neighborhood rank: **next, next+1, previous** in play order, shuffle included. Then playlist index as the stable tie-break. The order is re-evaluated on every track change and every submit. Selection is one O(n) pass, since real playlists reach 10⁵ misses: no sorting, and no per-entry pre-submission.
- **D6. One scan materialization at a time.** The sweep keeps at most one materialization in flight. Pending misses stay app-owned, re-rankable records, never pre-submitted to a bounded queue. Remote ranged parses bypass the materialization claim and enter the bounded parse stage directly. While C1 is in force the sweep submits no dataless record at all, even the file playback is downloading (J4).
- **D7. Retries are result-driven and bounded,** per path, across lanes. A *yield* (suspended by C1) spends nothing. A *failure* spends one of **3 total attempts** and re-enters below untried rows. *Admission exhaustion* spends one after a **0.25–2 s** escalating delay. *Success clears the path's spend.* A path that exhausts its budget is dropped until a fresh playlist load.
- **D8. Duplicate rows resolve together.** One URL parses once. Every row holding it receives an independent copy, rows that subscribed mid-parse included. Waiting rows are held weakly, so an in-flight cloud parse never pins a discarded playlist.
- **D9. Failed parses still produce display metadata.** Available fields are kept, with filename fallback for a missing title. The result is never cached and cannot overwrite a racing success.
- **D10. Fresh playlist, fresh sweep.** Opening or replacing a playlist drops the old sweep outright: its pending records, its in-flight transfer and its strong track references. That includes the current-track lane's pending work. Entered parses can still finish (D11).
- **D11. An entered TagLib read is uncancellable** and is allowed to finish. Parses run at most **4** wide. A slow file stalls only its own worker.

## E. Artwork

- **E1. Embedded art beats folder art** (root `AGENTS.md`). The folder cover is macOS-only. It fills in after the file is found to have no usable embedded picture.
- **E2. Extraction is tri-state**: art found, no usable picture, or read failed. No picture and undecodable image bytes both open the folder fallback. A failed read stays unknown and retries: at most **3 reads** per display pass, with a **2 s** per-row backoff.
- **E3. The 128 px thumbnail is for list rows** (root `AGENTS.md`). Rows keep compact encoded bytes only. Decoded pixels live in one shared **16k-entry** LRU that only the display path fills. A cache miss never decodes on a drawing path.
- **E4. The archived display rendition** is both big art surfaces' decode source (root `AGENTS.md`). It sits beside the metadata entry, on disk, never retained per row. A cached rendition avoids reading the song again on a track change or page swipe. A missing or corrupt rendition falls back to source extraction off main. It does not mark the file's own art as undecodable.
- **E5. Art requests are bounded and current-only**: at most 2 running and 5 pending across all rows. Only source-file extraction may take a transfer, and it obeys C1. In-memory decodes never rematerialize. Demotion (a row scrolled away) cancels parked work and fences running work, so a stale decode cannot install.
- **E6. Background work never raises a permission panel.** On macOS, no active sandbox grant means no probe and no cover read.

## F. Deliveries and staleness

- **F1. Every delivery lands on main and names one track.** The receiver must drop it when it no longer matches the current state (root `AGENTS.md`, async deliveries). Waveform, BPM, key, metadata and art deliveries all race track changes.
- **F2. Play settlements are matched by submission identity** (A5), decided at delivery on main, never by track or URL.
- **F3. Metadata installs are atomic and revalidated.** Installation and publication compare the exact installed object, so a queued stale delivery drops instead of publishing twice.

## G. Lifecycle edges

- **G1. Successful cloud play.** Foreground registration (C1), then the transfer with progress (B3), a usable handle, sound, and the successor prefetch (C7). Tags can land alongside (C3). The deferred sweep starts at settlement (D4). Its dataless work waits for every foreground claim to end (C4), streams still downloading after sound starts included. It then walks the neighborhood (D5).
- **G2. Timeout.** The deadline fires (B3), then the stopped state and an error string (B4). The rule lifts once no foreground claim remains, and the sweep's dataless work resumes. The failed pick is an ordinary candidate (B4), and its metadata failure spends budget normally (D7).
- **G3. Rapid next.** Each superseded open is cancelled before the next begins. Stale settlements and their prefetch acknowledgements drop. Old work cannot lift the hold of a new claim (C4), and unused streams release their lanes.
- **G4. Same-row replay.** Same track, same URL, new submission identity. Every stale-settlement rule in F2 and C4 still holds.
- **G5. Close** (macOS). No transport callbacks (B9). Old background work and opens are cancelled (C5). The next folder's sweep starts clean.
- **G6. Playlist replacement.** D10, plus G5's rule that old transfers must not compete with the new pick. iOS has explicit Clear Playlist and replacement paths. Backgrounding alone does not close the playlist or stop background audio. A restored folder that lands parked starts its sweep without a play settlement.

## H. Policy numbers

Current production values, all reviewable.

| Policy | Value | Where |
| --- | --- | --- |
| Slow-open indicator fallback (provider-dataless classification is immediate) | 0.5 s | `AudioPlayerInternal.h` |
| Open no-progress deadline | 60 s | `AudioFileOpenTimeoutMath.h` |
| Open progress-silence deadline | 60 s past last movement | `AudioFileOpenTimeoutMath.h` |
| Foreground transfers (running / pending / grace) | 3 / 1 / 5 s | `AudioLoadingConfiguration.m` |
| Background transfers (running / pending / grace) | 1 / 6 / 10 s | same |
| Initial classification probes (running / pending / grace) | 8 / 16 / 5 s | `AudioFileMaterializationCoordinator.m`, the grace `AudioLoadingConfiguration.m` |
| Live handle runs (shared production coordinator) | 6, refused at once, no pending, grace or configuration | `AudioFileMaterializationCoordinator+HandleOpen.m` |
| Prefetch depth | 1 | `AudioLoadingConfiguration.m` |
| Metadata attempts per path (total) | 3 | same (`metadataRetryCount` 2) |
| Admission-exhausted retry delay | 0.25 s → 2 s escalating | `MetadataRetryRules.h` |
| Parse concurrency | 4 | `AudioLoadingConfiguration.m` |
| Sweep deferral fallback | 2 s | both shells |
| Neighborhood offsets | +1, +2, −1 | `Playlist.neighborhoodTracks` |
| Art requests (running / pending) | 2 / 5 | `ArtworkLoadRegistry` |
| Art admission backoff | 0.1–1 s | same |
| Extraction retries / backoff | 3 reads / 2 s | `AudioTrackArtwork+Loading.m` |
| Thumbnail LRU | 16,384 entries | `EmbeddedThumbnailCache.m` |
| Thumbnail size | 128 px | — |
| Display rendition bound | 640 px mac / 1024 px iOS | `PlatformImage.h` |
| Full-art decode bound | 1024 px | — |
| Metadata and waveform disk budget | 1 GiB per cache, 180-day age limit | `PINCache+VibeAudioCache.m` |

## I. Platform differences

- **I1.** The macOS-only features and the shared ones are root `AGENTS.md`'s. Analysis rides the waveform decode pass. Tags take precedence through `AudioTrack.bpm` and `.key`, and a CUE row uses its window's analysis.
- **I2.** File > Close is macOS-only. iOS tears down through Clear Playlist and playlist replacement. Background audio keeps its session when the app leaves the foreground.
- **I3.** The iOS now-playing page deliberately draws no thumbnail, only full or rendition art.
- **I4.** Metadata and waveform cache size and clear controls are macOS-only. iOS has separate Dropbox download storage controls. Those files are not these caches.

## J. Decisions and open items

- **J4. The sweep never submits a dataless record while C1 is in force (DECIDED).** That holds even for the file playback is downloading, which C3 could reuse. The current-track request submits and joins instead. One rule beats two, and the current-track request covers the playing file (D6).
- **J6. No parking layer above the art scheduler (DECIDED).** A request past E5's bound is dropped before it marks its row pending, and the next redraw re-requests it.
- **J8. Transfer and open lifetimes are separate (DECIDED).** A transfer slot ends when its stage-1 materialization settles, never with the handle open. A stream keeps its slot until its download completes or fails. Handle runs are bounded apart, at six (B8). A stalled handle open cannot hold a transfer slot after materialization settles. The derivation, and what forces it to be redone, is `vibe-libs/files/FileLoading/AGENTS.md`'s (Admission has two lifetimes).
- **J9. A running stage-1 materialization has no deadline (OPEN).** Once stage 1 is `Running`, pending admission expiry no longer reaches it. Local reads hold no transfer lane, so a stalled SMB, NFS or disk read strands only its worker. A dataless provider operation or a delayed classification refresh can still hold its lane indefinitely. Metadata and artwork callers have no deadline that guarantees cancellation. The fix needs explicit provider, caller-deadline and retry policy ([issue #96](https://github.com/cmicali/vibe/issues/96)).

## K. Non-goals

- **K1.** How many coordinator objects exist, or where the C1 rule lives (hold object, refcount, role preemption).
- **K2.** Whether the current-track lane is a separate lane or a rank-0 record.
- **K3.** Which queue any decision runs on, as long as F1's main-thread delivery and B1's non-blocking local path hold.
- **K4.** The internal shape of retry bookkeeping, as long as D7's budgets hold.
- **K5.** Debug and stress instrumentation (fake cloud, trace events, scenario suite). The acceptance test for C, D and G is the whole `cloud-scenarios.py` registry passing (the `vibe-stress` skill names the clean report), not a fixed list of scenarios.
