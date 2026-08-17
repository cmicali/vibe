# Metadata and artwork

Tags, the disk cache, the two-stage playlist scan, embedded album art and the folder-art fallback.

## The map

Read this before changing anything here. Every individual hop is commented at its site; what follows is the shape those comments cannot show — **five entry points, two lanes, and three delivery channels.**

```
ENTRY POINTS                                      LANE
─────────────────────────────────────────────────────────────────────────────
playTracks: ────────┐
didStartPlaying: ───┴─→ startPendingMetadataLoad
                          └─→ loadMetadata:        ──→ scan lane, 4 workers, utility
didBeginLoading: ───┐
didStartPlaying: ───┼─→ loadMetadataNow:           ──→ priority lane, 4 workers,
didConvertTrack: ───┘                                  user-initiated, never cancelled
closeFile: ───────────→ cancelAll                      drops the scan loader entirely
playlist cell draw ───→ cachedThumbnail          ──→ folder-art resolver, serial queue

SCAN LANE
─────────────────────────────────────────────────────────────────────────────
loadMetadata:
 └ one setup op (high priority)          builds the work list ON the queue, not on main
    └ per-track STAGE 1 (high)           cacheCheckOneTrack:
       ├ hit  → loadTrackFromDiskCache: ─────────────────────→ publishTrack:
       └ miss → enqueue STAGE 2          wide queue, or the CLOUD LANE (serial,
          │                              holdable) for a dataless placeholder
          └ parseOneTrack: → MetadataParseRunner.runForParticipant:key:   (key = track.url)
             ├ claimParseForKey: → Waiter | AlreadyOwner → return, the owner fans out to it
             └ Owner:
                  re-check isResolved / serveFromCache   ← another lane may have won
                  parseRunnerReadAndCache:   TagLib → prewarmEmbeddedThumbnail → PINCache write
                  completeClaim     released BEFORE either publish, so a duplicate row's
                                    next attempt never queues behind a publish
                  parseRunnerPublish: ───────────────────→ publishTrack:
                  serveWaiters:     each served from the entry just written, never from
                                    the holder's own object — two rows for one file must
                                    own separate metadata, its art state being per-row

DELIVERY — three channels, one destination
─────────────────────────────────────────────────────────────────────────────
1. didLoadMetadata:            (AudioTrackMetadataCacheDelegate)
                               → updateUI if current, else reloadTrack:
2. FolderArtDidResolveNotification
                               → coalesced over a short delay → reloadVisibleTracks
3. artDidResolveHandler        (ArtworkDisplayController, after a background art load)
                               → updateUI
```

**The two stages exist for one reason:** stage 1 touches a stat and a small disk read and *never* the audio data, so the whole sweep drains at disk speed even on a playlist of cloud placeholders. Only stage 2 can block on a download.

## The cloud lane

**A dataless file's parse pulls the whole file through the file provider**, so four at once is not four busy threads, it is four transfers competing with the one the user is waiting on. Those parses therefore run on a **serial cloud lane** of their own.

**`setCloudParsesHeld:` suspends that lane outright while the player's own open is materializing a file** — the foreground open outranks every background parse that would download something. Local parses and both lanes' stage-1 cache checks are untouched, so rows keep filling from cache while the current track lands. Both shells set the hold where they start the download monitor and clear it where they cancel it (`didBeginLoading:` / `didStartPlaying:` / the error path). **The flag lives on the cache, not the loader**, because `loadMetadata:` mints a fresh loader — a sweep starting mid-open must not lose the hold.

It pairs with the deferring both shells do: neither starts the sweep at all until the picked track's open settles (`MainPlayerController.scheduleDeferredMetadataLoad`, `PlaybackController.scheduleDeferredMetadataLoad`).

**A parse on that lane can be abandoned mid-download**, which an ordinary read never can: stage 2 there is materialize-then-parse (`CloudFileMaterializer`, `Vibe/System/`), so the hold cancels the transfer in flight rather than only refusing to start the next one.

**What a failed materialization does next is `CloudMetadataRetryRules.h`, and the two cases are not alike.** A parse cancelled by the hold re-queues at its *current rank* and spends no attempt budget — nothing about the file failed, and the sweep has no second pass. It cannot spin, because the hold suspends the queue *before* it cancels. Any other failure re-queues at the *bottom* of the lane instead, with a budget of `kVibeCloudMetadataMaxAttempts` (3) per path: retrying a terminal provider error at rank would monopolize the serial lane forever, while abandoning the track on its first failure would cost a row its tags for the whole sweep over a transient blip — the only later retry being a new playlist or an append. A deferred entry stays at the bottom however the neighborhood moves, so re-ranking cannot promote a known-bad file in front of tracks that have not been tried at all.

**TRAP: the hold verdict rests on `CloudFileMaterializer` reporting every cancellation as `NSCocoaErrorDomain`/`NSUserCancelledError`.** A second cancellation spelling there would silently send hold-cancelled tracks down the attempt-spending path.

**Because the lane is serial, its order is the whole of what it decides.** The lane is re-ranked in place on every track change: next, then the one after, then the one behind, then everything else. The ranking is `AudioTrackMetadataCache.setNeighborhoodAroundIndex:inTracks:`, and each shell sends a playlist position to it from its one current-index funnel — `PlaybackController.updateMetadataNeighborhood` on iOS, `PlaylistController.currentIndexDidChangeHandler` on the mac. **The offsets live on the cache, not in the shells**, because a shell can silently fail to supply them. `NSOperationQueue` honors a `queuePriority` written any time before an operation starts, which is what makes re-ranking a queued sweep possible; pending operations are kept for exactly that and pruned of any that have begun.

**TRAP: `cancelAll` must lift the hold before it drains.** A suspended queue never starts its cancelled operations, and an operation that never runs never releases the track it captured — so lifting the hold lets them drain (each returns immediately on `isCancelled`) rather than pinning the discarded playlist for the loader's lifetime.

## The art accessors state their own contract

| Call | Contract |
| --- | --- |
| `cachedArt`, `cachedThumbnail` | **Non-blocking**, already-decoded only. Safe on the main thread; safe in a cell draw. |
| `loadArtBlocking` | **Blocking** — reads the audio file and decodes it. Background queues only. |
| `artNeedsLoad` | YES when a background load would produce something the cached accessors cannot. |
| `artLoadDispatched` | UI-side in-flight marker, set before dispatching and cleared when the load lands. |

`AudioTrackMetadata+ArtLoad`'s `dispatchArtLoadIfNeededStillWanted:completion:` is the **only** caller of `loadArtBlocking`, always on a user-initiated queue, gated by the two flags. `AudioTrack` deliberately exposes no blocking accessor at all. Both screens go through that one category — `ArtworkDisplayController` on macOS, `PlayerViewController` on iOS — because the mechanism is identical while what each does with the art is not.

The naming is the contract: `AudioTrack.cachedArt` (non-blocking) and `AudioTrackMetadata.loadArtBlocking` (a file read) were once the same selector name one hop apart, with nothing but a comment to tell them apart.

## Tags and the cache

`AudioTrackMetadata` (ObjC++) uses TagLib to extract title, artist, album art and codec information. `AudioTrackMetadataCache` persists through PINCache with `NSSecureCoding`; `parsedOK` marks failed parses, which are shown but never cached.

Misses re-enqueue as parses, dataless placeholders demoted below local files. A URL has one cross-lane parse holder — `MetadataParseCoordinator`, Foundation-only so its contention contract is unit-tested rather than asserted in a comment. The *order* a parse runs in is `MetadataParseRunner`'s: it takes the claim, prefers an answer that is already there, parses only when there is none, and fans the result out, with the loader's four effects behind a delegate so the ordering is tested against fakes rather than TagLib, PINCache and the file system.

Duplicate rows register as waiters, **held weakly** so a discarded playlist is not pinned for a cloud parse's duration. A failed parse wrote nothing, so its waiters keep the filename fallback rather than polling behind a wedged cloud file. A duplicate row is only a waiter while a holder exists, so a row whose parse op runs *after* the holder settled re-reads the disk cache under its own claim rather than re-parsing the file.

The current track skips the scan: `loadMetadataNow:` from `didBeginLoading:` and `didStartPlaying:`, in a persistent user-initiated lane, so the header's tags and art never queue behind the sweep. On a miss it skips the parse while the file is still dataless — the player's own open is materializing it — and the `didStartPlaying:` call retries once local.

## Embedded album art

The disk cache stores only a 128px thumbnail JPEG; full-resolution art decodes on demand, capped at 1024px through ImageIO, and `discardDecodedArt` demotes it when a track stops being shown. **No lock is ever held across file I/O or an image decode** — a cloud file can block a read indefinitely.

`AudioTrackArtwork`'s ivars are all `_embedded*` because every one holds the file's *own* art exclusively; the folder's cover is deliberately not state of that class. `embeddedThumbnail` is what the archive takes, never the folder's.

**The thumbnail is for list rows only**: the mac playlist's art cells, and on iOS the library rows and the mini player. Both platforms decode, hold and archive it. The iOS *pager* deliberately draws none of it (`Vibe/iOS/CLAUDE.md`).

**`hasEmbeddedArt` is archived as a flag of its own** rather than inferred from the thumbnail's presence. An entry written while iOS kept no thumbnail carries no JPEG, and inferring from it would read that entry as artless — no art at all, and on macOS a folder cover handed to a file that has its own. Entries written before the flag carry no key and fall back to the old inference. No discard clears it: the bytes go, the fact that the file has art does not. The state table is in `AudioTrackArtwork.h`.

**On-demand extraction is tri-state:** art found, conclusively no art, or read failed. Only the conclusive no-art answer opens the folder fallback. A failed read is re-armed when the track leaves the header, so a provider or volume failure never permanently turns known embedded art into a folder cover.

**A failed read is bounded twice, because the two limits stop different things.** `kMaxEmbeddedArtExtractionFailures` (3) bounds how many reads one display pass spends; `kEmbeddedArtExtractionRetryBackoff` (2s, from when the failed read *returned*) bounds how fast it spends them. The count alone was not enough: `updateUI` fires several times in quick succession at a track start — begin loading, start playing, metadata, art — so all three attempts went back to back, each blocking a user-initiated worker for however long the failing read takes, and nothing about an unreachable provider changes between two calls milliseconds apart. The delay is what makes the second and third attempts worth making. Nothing schedules a retry; the window only decides whether the next pass that asks may try, and `artNeedsLoad` applies it too so a pass inside the window does not spend the dispatch flag on a load that would immediately no-op. `AudioTrackArtwork.clock` injects the clock for the tests and is nil in production.

## Folder art

**Folder art is macOS-only.** `FolderArtResolver` compiles into both targets, but `AudioTrackArtwork` leaves its `folderArt` handle nil on iOS, so every folder-art accessor is a message to nil: no cover, and `needsBackgroundLoadForAudioFilePath:` answers NO so nothing is scheduled either. `AppSettings.useFolderArt` is macOS-only to match, and the resolver's enabled provider returns NO off-mac as a second line of defence.

Folder art is the fallback for a file carrying none of its own: a cover image beside it, `cover`/`folder`/`album`/`front`/`albumart`/`art` as jpg/png/jpeg/webp (`FolderArtRules.h`, header-only and tested). `AudioTrackArtwork` keeps **no state for it at all** — `loadArtBlocking`, `cachedArt` and `cachedThumbnail` fall back to the shared resolver — so there is nothing per track to demote on a track change, keep in step with the setting, or leak into the cache.

**Nobody asks for this artwork, so it is built to cost as close to nothing as possible.** Every rule follows from that:

- **Per folder, never per track.** One album folder resolves once however many tracks it holds.
- **Beside the audio file, and only beside it** — no parent is ever consulted. Known cost, expected rather than an oversight: a multi-disc album with the cover at `Album/cover.jpg` and audio in `Album/CD1` shows nothing.
- **It never pays for a listing of its own**, and the strategy depends on what the user opened:
  - **A folder** — `NSURLUtil.expandDirectory:` is already touching every entry, so the cover is picked out of that walk for the cost of a rank lookup per name (`VibeFolderArtCandidateRank`). Every directory walked is settled on the way past, coverless ones included, so a dropped folder costs **zero** syscalls of ours and gets case-insensitive matching over all twelve spellings for free. The walk hands its harvest to `VibeWalkedDirectoriesHandler`, which `AppDelegate` wires to `noteListedDirectories:artFilenameByDirectory:` at launch — `Vibe/Util` must not reach into an app singleton behind a setting and a sandbox grant.
  - **More than one file** — the folders are marked (`preferListingForDirectories:`) and resolved with one `contentsOfDirectoryAtPath:` each, lazily, if anything asks.
  - **One file on its own** — nothing to piggyback on, so it probes: `stat` per candidate, best first, stopping at the first hit. A coverless folder costs `kVibeFolderArtStatProbeCount` (3). The rest of the list is only matched against a listing; the price is that `front.png` beside a single opened file is not found. Probes are lower case — macOS volumes are case-insensitive by default, and the listing paths fold case explicitly.
- **Asked and answered.** No cover, no grant, or undecodable all settle the folder, and a settled folder is never probed again while its answer is held. **A cover that fails to *read* is the one thing that does not settle it** — that is a fact about the moment (an unmaterialized placeholder, an interrupted read, a volume that went away), so those keep the answer and retry, capped at `kMaxArtReadFailures` (3).
- **One entry per directory holds every fact about it** (`VibeFolderArtEntry`): settled path, revision, resolve claim, decode pins, without-grant and prefer-listing marks, read-failure count, access clock. Eviction and both invalidations are one pass over one dictionary. The history is a bounded MRU (`kRecordedDirectoryLimit` 4096), evicted in one batch down to `kRecordedDirectoryFloor` (3072) rather than one folder per arrival, since the trim runs under the lock the main thread also takes to draw cells. **Only background paths trim**: `scheduleResolveOfDirectory:` is O(1) under the lock and its job does the claim and the trim on the resolver queue, and `needsBackgroundLoadForAudioFilePath:` is a pure read — both are reached from a cell draw or `updateUI`. An entry with a resolve or decode in flight is never evicted. Decoded images are bounded separately (`NSCache`: 64 thumbnails, 4 display images), so an evicted image costs a read, never a re-probe.
- **Knowing a cover is there is not loading it.** Settling a folder records a path and opens nothing; the file is read and decoded only when a track carrying no art of its own needs pixels, gated by `knownToCarryNoArtLocked` — which is NO while the file's own art is merely *unknown*, so a cover can never stand in front of a track's own art. That read produces **both** sizes: the header's decode also yields the row thumbnail from the same bytes. Only that direction is free — 128px cannot be enlarged to 1024 — so a folder whose rows draw before its header pays two. `readArtAtPath:` is the single place a cover file is opened and logs each load; it is split from `decodeArtData:` so a read failure and a decode failure stay distinguishable.
- **Nothing on the scan's path.** The metadata loaders do not touch it. Resolution is lazy, from the accessors. `FolderArtDidResolveNotification` brings rows and the header back to be redrawn, coalesced into one pass per short delay — not per run-loop turn, which would coalesce nothing, since the resolver is serial and consecutive folders land in different turns. The observer reloads the *visible* rows and runs `updateUI`, so it wakes both the row that skipped its own job behind the header's claim and the header that got nothing back while a row owned it. Both the scheduled row path and the header's blocking path post it, for that reason. **The notification fires for "this folder has none" as well as for a cover**, because the header deliberately holds the previous track's art while the answer is pending. It is not posted for a *failed* decode of an already-settled cover: nothing new became drawable, so there is no redraw edge to give.
- **A folder with no *active* grant is left alone, not probed** (`FolderAccessManager.canReadInsideDirectory:`, thread-safe for exactly this). Desktop, Documents, Downloads and removable or network volumes answer an unsanctioned read with a system consent panel, and unasked-for work must never raise one. *Active* is the operative word: a stored bookmark authorizes nothing until restoration has started its security scope.
- **Never persisted.** The metadata cache is keyed by the *audio* file's size and mtime, which no sidecar image can move: an archived cover would outlive its file, and an archived "artless" would suppress the lookup forever.

**TRAP: `O_NONBLOCK` belongs on the *open* and nowhere else** (`FolderArtFileIO.m`). It keeps a FIFO or a device named `cover.jpg` from wedging the resolver on the open itself — `S_ISREG` cannot be tested until that open returns. Left set across the reads it means something else entirely: a regular file whose bytes are not resident answers `EAGAIN`, which says nothing about the image. `VibeReadFolderArt` clears it with `fcntl` before reading.

**TRAP: neither invalidation may be a full wipe.**
- The **album-art setting** goes through `MainPlayerController.refreshFolderArt` → `folderArtSettingDidChange`, which re-reads the cached setting and drops the decoded images. The *answers* stay: the setting governs whether the fallback is consulted, never what a folder contains. Wiping them demotes every walked folder to the lone-file stat probes, which know three of the candidate names — so a `cover.png` library loses its art to a round trip through the checkbox.
- A **grant** change goes through `invalidateDirectoriesSettledWithoutGrant`, which forgets only the folders left alone for want of a grant — the only answers a grant can affect. A folder open auto-adds that folder's grant *asynchronously*, a moment after the open's own walk has harvested its cover for free, so a broad wipe throws that harvest away.

`invalidate`, which does forget everything, is diagnostic surface for the tests alongside `recordedDirectoryCount` and `settledArtPathForDirectory:`. No app path wants it.

**TRAP: the resolver caches `AppSettings.useFolderArt`**, because `directoryForAudioFilePath:` gates every accessor on it and those run on every playlist cell draw and every `updateUI` pass. `folderArtSettingDidChange` is the one thing that drops that cache, so **a write to the setting that does not go through `MainPlayerController.refreshFolderArt` is not observed at all.** Both writers (the Files pane, the debug channel's `set_folder_art`) do.
