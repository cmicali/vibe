# Metadata and artwork

Tags, the disk cache, the two-stage playlist scan, embedded album art and the folder-art fallback.

## The map

Read this before changing anything here. Every individual hop is commented at its site; what follows is the shape those comments cannot show — **five entry points, two lanes, and three delivery channels that all end at `MainPlayerController`.**

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

**The cloud lane is serial, so its ORDER is the whole of what it decides.** A listener reaches the next track long before the folder's tail, and the sweep left to itself works in filename order however far that is from where they actually are — so the lane is re-ranked in place on every track change: next, then the one after, then the one behind, then everything else. The ranking itself is `setNeighborhoodAroundIndex:inTracks:`, on the cache, and each shell sends a playlist position to it from its one current-index funnel — `PlaybackController.updateMetadataNeighborhood` on iOS, `PlaylistController.currentIndexDidChangeHandler` on the mac. **The offsets live on the cache, not in the shells, because that is what a shell can silently fail to do**: it was `setNeighborhoodURLs:` with the table copied into each shell, and the mac's copy was never written, so every cloud parse there ranked Low and the sweep ran in filename order however far the listener had moved. `NSOperationQueue` honors a `queuePriority` written any time before an operation starts, which is what makes re-ranking a queued sweep possible at all; the pending operations are kept for exactly that, and pruned of any that have already begun, since those can no longer be moved. Measured on a 61-track cloud folder: tapping track 56 moved the very next parses to 57, 58 and 55, skipping the L-to-S range the sweep was about to work through.

**And a parse on that lane can be abandoned mid-download**, which an ordinary read never can: stage 2 there is materialize-then-parse (`CloudFileMaterializer`, `Vibe/System/`), so the hold cancels the transfer in flight rather than only refusing to start the next one. A cancelled parse re-queues itself at its current rank — the sweep has no second pass, so the row would otherwise keep its filename fallback until the whole playlist was re-queued — and it cannot spin, because the hold suspends the queue *before* it cancels.

**And the download is the unit of contention, not the worker thread**, which is why stage 2 splits again. A dataless file's parse pulls the *whole* file through the file provider, so four of them at once is not four busy threads, it is four transfers competing with the one the user is waiting on — the difference between a Dropbox folder starting a track in a second and starting it in a minute. Those parses therefore run on a **serial cloud lane** of their own, and `setCloudParsesHeld:` suspends that lane outright while the player's own open is materializing a file: **the foreground open outranks every background parse that would download something.** Local parses and both lanes' stage-1 cache checks are untouched by the hold, so rows keep filling from cache while the current track lands. Both screens set the hold where they start the download monitor and clear it where they cancel it (`didBeginLoading:` / `didStartPlaying:` / the error path), and the flag lives on the cache rather than the loader because `loadMetadata:` mints a fresh loader — a sweep starting mid-open must not lose the hold. It pairs with the deferring the two shells do on their side: neither starts the sweep at all until the picked track's open settles (`MainPlayerController.scheduleDeferredMetadataLoad`, `PlaybackController.scheduleDeferredMetadataLoad`).

### The art accessors state their own contract

| Call | Contract |
| --- | --- |
| `cachedArt`, `cachedThumbnail` | **Non-blocking**, already-decoded only. Safe on the main thread; safe in a cell draw. |
| `[… loadArtBlocking]` | **Blocking** — reads the audio file and decodes it. Background queues only. |
| `artNeedsLoad` | YES when a background load would produce something the cached accessors cannot. |
| `artLoadDispatched` | UI-side in-flight marker, set before dispatching and cleared when the load lands. |

`AudioTrackMetadata+ArtLoad`'s `dispatchArtLoadIfNeededStillWanted:completion:` is the **only** caller of `loadArtBlocking`, always on a user-initiated queue, gated by the two flags above. `AudioTrack` deliberately exposes no blocking accessor at all. Both screens go through that one category — `ArtworkDisplayController` on macOS, `PlayerViewController` on iOS — because the mechanism is identical (dispatch once, clear the marker, demote the decode when the user has moved on) while what each does with the art is not: the mac header applies `ArtworkDisplayRules`, whose keep-previous case exists only because one header view is shared across tracks, and the iOS pager needs no such rule because the outgoing track keeps its own page — what it has instead is an art window, several pages wide, since a page must arrive already drawn rather than resolve after it does.

These were all called `albumArt*` until the contract went into the names — and the sharp edge was that `AudioTrack.albumArt` (non-blocking) and `AudioTrackMetadata.albumArt` (blocking, a file read) were **the same selector name one hop apart**, with nothing but a comment to tell them apart. The `cached…` prefix matches `FolderArtResolver`, which already named its non-blocking accessors that way.

## Tags and the cache

`AudioTrackMetadata` uses TagLib to extract title, artist, album art and codec information. `AudioTrackMetadataCache` persists through PINCache with `NSSecureCoding`; `parsedOK` marks failed parses, which are shown but never cached.

Misses re-enqueue as parses, dataless placeholders demoted below local files so a cloud-heavy folder cannot pin all four workers. A URL has one cross-lane parse holder — `MetadataParseCoordinator`, Foundation-only so its contention contract is unit-tested rather than asserted in a comment, including the window where a row claims while the holder completes. The *order* a parse runs in is `MetadataParseRunner`'s, split out for the same reason: it takes the claim, prefers an answer that is already there, parses only when there is none, and fans the result out, with the loader's four effects — is it resolved, serve from cache, read and cache, publish — behind a delegate so the ordering is tested against fakes rather than TagLib, PINCache and the file system. It is a **runner** rather than a "flow" because that word was doing two jobs at two scales: this class is one box inside the map above, which is the flow. Its tests mutate each rule to prove it is load-bearing.

Duplicate rows register as waiters, held weakly so a discarded playlist is not pinned for a cloud parse's duration. A failed parse wrote nothing, so its waiters keep the filename fallback the holder shows rather than polling behind a wedged cloud file. A duplicate row is only a waiter while a holder exists, so a row whose parse op runs *after* the holder settled re-reads the disk cache under its own claim rather than re-parsing the file a second time, and a waiter already served by a re-drop's sweep is left alone rather than republished.

The current track skips the scan: `loadMetadataNow:` from `didBeginLoading:` and `didStartPlaying:`, in a persistent user-initiated lane, so the header's tags and art never queue behind the sweep. On a miss it skips the parse while the file is still dataless — the player's own open is materializing it — and the `didStartPlaying:` call retries once local.

## Embedded album art

The disk cache stores only a 128px thumbnail JPEG; full-resolution art decodes on demand, capped at 1024px through ImageIO, for the tracks actually shown at that size, and `discardDecodedArt` demotes it when they stop being shown. No lock is ever held across file I/O or an image decode — a cloud file can block a read indefinitely.

`AudioTrackArtwork`'s ivars are all `_embedded*` because every one of them holds the file's *own* art exclusively; the folder's cover is deliberately not state of that class (see below). `embeddedThumbnail` is what the archive takes, never the folder's.

**The thumbnail is for list rows, and only for list rows**: the mac playlist table's art cells, and on iOS the library rows and the mini player. Both platforms decode, hold and archive it. The iOS *pager* deliberately draws none of it — a page shows the full-size decode and nothing standing in for it (`Vibe/iOS/CLAUDE.md`), 128px being fine under the blur but visibly soft in the art card — so the thumbnail's cost is paid for the rows, never for the page.

It was macOS-only until the iOS shell grew a list to draw it in, and the note is worth keeping because the cost is real and was the reason: a 128px decode per scanned track, a re-encode per cache write, an eager decode per cache hit, and cache entries of 5-20KB rather than about 700 bytes. That is the price of a table with art cells, and it is the same price macOS has always paid.

**`hasEmbeddedArt` is archived as a flag of its own** rather than inferred from the thumbnail's presence, which is what the archive used to mean by it. It has to be: an entry written while iOS kept no thumbnail carries no JPEG, and inferring from it would read that entry as artless — no art at all, and on macOS a folder cover handed to a file that has its own. Entries written before the flag carry no key and fall back to the old inference, so every form reads on both platforms. It is the `known` column of the state table in `AudioTrackArtwork.h`, and no discard clears it: the bytes go, the fact that the file has art does not.

An entry written on iOS *before* the thumbnail was enabled carries no JPEG and never self-heals, since a cache hit does not re-parse: those rows draw the placeholder until the file itself changes. The app being unreleased, that is a `clear_caches` rather than a migration.

## Folder art

**Folder art is macOS-only.** `FolderArtResolver` compiles into both targets, but `AudioTrackArtwork` leaves its `folderArt` handle nil on iOS, so all four folder-art accessors below are messages to nil: no cover image, and `needsBackgroundLoadForAudioFilePath:` answers NO, so nothing is scheduled either. iOS therefore shows a file's embedded art alone. `AppSettings.useFolderArt` is macOS-only to match, and the resolver's own enabled provider returns NO off-mac as a second line of defence.

**Folder art** (`FolderArtResolver`, `AppSettings.useFolderArt`, default on) is the fallback for a file carrying none of its own: a cover image beside it, `cover`/`folder`/`album`/`front`/`albumart`/`art` as jpg/png/jpeg/webp (`FolderArtRules.h`, header-only and tested — the stems are the ones Picard, beets, foobar2000, Windows Media Player, Plex and Navidrome write, so a library tagged elsewhere is found as-is; that file records what was deliberately left out and why). `AudioTrackArtwork` keeps **no state for it at all** — `loadArtBlocking`, `cachedArt` and `cachedThumbnail` simply fall back to the shared resolver, while the archive keeps taking `embeddedThumbnail`, the file's own art — so there is nothing per track to demote on a track change, to keep in step with the setting, or to leak into the cache.

**Nobody asks for this artwork, so it is built to cost as close to nothing as possible**, and every rule below follows from that:

- **Per folder, never per track.** One album folder resolves once however many tracks it holds, and they share the images.
- **Beside the audio file, and only beside it** — no parent is ever consulted. The known cost, expected rather than an oversight (`FolderArtRules.h` records it): a multi-disc album with the cover at `Album/cover.jpg` and the audio in `Album/CD1` shows nothing. Walking up would have to pick a depth — one level is arbitrary, further turns a stray `cover.jpg` in `~/Music` into the artwork for a whole library — and would cost a probe per level on folders that mostly hold nothing.
- **It never pays for a listing of its own**, and which strategy a folder gets depends on what the user opened:
  - **A folder** — the expansion in `NSURLUtil.expandDirectory:` is already touching every entry, so the cover is picked out of that walk for the cost of a rank lookup per name (`VibeFolderArtCandidateRank`, a length test then a dictionary hit, which rejects an audio filename without allocating). Every directory walked is settled on the way past, the ones with no cover included, so a dropped folder costs **zero** syscalls of ours and gets case-insensitive matching over all twelve spellings for free. The walk does not call the resolver: it hands the harvest to `VibeWalkedDirectoriesHandler`, which `AppDelegate` wires to `noteListedDirectories:artFilenameByDirectory:` at launch — `Vibe/Util` is the future-shared, no-AppKit group, so a path utility must not reach into an app singleton behind a setting and a sandbox grant. Same shape, and same reason, as the playlist grant handler beside it. The bulk-open marking (`VibeBulkOpenDirectoriesHandler` → `preferListingForDirectories:`) is wired the same way.
  - **More than one file** — the folders are marked (`preferListingForDirectories:`) and resolved with one `contentsOfDirectoryAtPath:` each, lazily, if anything actually asks. A bulk open is already bulk I/O.
  - **One file on its own** — nothing to piggyback on, so it probes: `stat` per candidate, best first, stopping at the first hit. `cover.jpg` is one syscall and a coverless folder costs `kVibeFolderArtStatProbeCount` (3) — the three spellings actually worth asking about blind. `stat` also answers the size question in the same call. The rest of the list is only ever matched against a listing, where it is free; the price is that `front.png` beside a single opened file is not found.
  - The probes are lower case: macOS volumes are case-insensitive by default, so the file system matches `Folder.JPG` itself, and the listing paths fold case explicitly.
- **Asked and answered, for as long as the answer is worth keeping.** No cover, no grant, or undecodable — all settle the folder, and a settled folder is never probed again while its answer is held. **A cover that fails to *read* is the one thing that does not settle it**, because that is a fact about the moment rather than about the image: a file-provider placeholder not yet materialized, an interrupted read, a volume that went away. Those keep the answer and try again, capped at `kMaxArtReadFailures` (3) so a file that will never open stops costing every draw an open. The reader is built for that distinction too — `O_NONBLOCK` goes on the *open*, so a FIFO named `cover.jpg` cannot wedge the resolver, and is cleared again before the reads, since a non-resident regular file answers `EAGAIN` and taking that for an answer lost the cover for good.
- **One entry per directory holds every fact about it.** `VibeFolderArtEntry`: the settled path, the revision, the resolve claim, the decode pins, the without-grant and prefer-listing marks, the read-failure count and the access clock. Eviction and both invalidations are then one pass over one dictionary — the parallel-collection-per-fact shape it replaced is what made "did I remember to prune that one too?" a question. The answers are a *bounded* most-recently-used history (`kRecordedDirectoryLimit`, 4096 folders), because one library walk can name hundreds of thousands of directories; over the limit it evicts in a single batch down to `kRecordedDirectoryFloor` rather than one folder per new arrival, since the trim runs under the lock the main thread also takes to draw cells. **Only background paths trim**: `scheduleResolveOfDirectory:` is O(1) under the lock and its job does the claim and the trim on the resolver queue, and `needsBackgroundLoadForAudioFilePath:` is a pure read, because both are reached from a cell draw or `updateUI`. An evicted folder costs the same handful of stats it cost the first time; an entry with a resolve or a decode in flight is never evicted, since the landing work checks the revision eviction would drop. Decoded images are bounded separately (`NSCache`: 64 thumbnails, 4 display images), so an evicted image costs a read, never a re-probe.
- **Knowing a cover is there is not loading it.** Settling a folder records a path and opens nothing; the file is read and decoded only when a track that carries no art of its own needs pixels, gated by `AudioTrackArtwork.knownToCarryNoArtLocked` — which is NO while the file's own art is merely *unknown*, so a cover can never stand in front of a track's own art, not even in the window before that art decodes. A library whose files are all tagged therefore opens no cover at all, however many sit beside them, and the display size is read only for the track on screen. That read produces **both** sizes: the header's decode also yields the row thumbnail from the same bytes, so a folder costs one open, not one per size. Only that direction is free — 128px cannot be enlarged to 1024 — so a folder whose rows draw before its header still pays two. `readArtAtPath:` is the single place a cover file is opened and logs each load, so "did anything actually load?" is one `log stream` away; it is split from `decodeArtData:` precisely so the two failures above stay distinguishable.
- **Nothing on the scan's path.** The metadata loaders do not touch it; `publishTrack:` says so and why. Resolution is lazy, from the accessors: `cachedThumbnail` is non-blocking and schedules a background resolve for the folders whose rows are actually drawn, and the current track's header rides the background art load `ArtworkDisplayController` already runs. `FolderArtDidResolveNotification` brings the rows back to be redrawn, coalesced into one pass per short delay — not per run-loop turn, which would coalesce nothing, since the resolver is serial and consecutive folders land in different turns — and that pass reloads the *visible* rows alone (`PlaylistController.reloadVisibleTracks`), since off-screen rows build their cell view afresh on the way back in. **The notification fires for "this folder has none" as well as for a cover**, which is not symmetry for its own sake: the header deliberately holds the previous track's art while the answer is pending, so a coverless folder that stayed silent left that stale art up until some unrelated event ran `updateUI`. That happened whenever the header's own load lost the resolve claim to a cell draw's background job, which is a race the two paths run into constantly.
- **A folder with no *active* grant is left alone, not probed** (`FolderAccessManager.canReadInsideDirectory:`, thread-safe for exactly this). A denial is silent, but Desktop, Documents, Downloads and removable or network volumes answer an unsanctioned read with a system consent panel, and unasked-for work must never raise one. So a single file opened out of a folder finds nothing, by design. *Active* is the operative word: a stored bookmark authorizes nothing until restoration has started its security scope, and `FolderAccessManagerDidChangeNotification` is what says otherwise. The directory it is asked about comes off a track URL rather than a canonicalized open, so this test folds case where the auto-add's duplicate check must not — `readablePath:isCoveredByAnyOf:` against `path:isCoveredByAnyOf:`, in `Mac/Settings/`.
- **Never persisted.** The metadata cache is keyed by the *audio* file's size and mtime, which no sidecar image can move: an archived cover would outlive its file by up to the six-month age limit, and an archived "artless" would suppress the lookup forever. Dropping a cover into a scanned folder therefore just works at the next launch.

**Neither thing that changes under the resolver forgets a settled answer, and that is the point.** Both were once a full wipe, and both times the wipe was the bug.

- The **album-art setting** goes through `MainPlayerController.refreshFolderArt` → `folderArtSettingDidChange`, which re-reads the setting (it is cached — see below) and drops the decoded images, worth some 20MB and useless while it is off. The *answers* stay, because the setting governs whether the fallback is consulted at all and never what a folder contains. Wiping them meant that turning the feature off and on again demoted every walked folder to the lone-file stat probes, which know three of the candidate names — so a `cover.png` library lost its art to a round trip through the checkbox.
- A **grant** change goes through `invalidateDirectoriesSettledWithoutGrant`, which forgets only the folders the resolver left alone for want of a grant — the only answers a grant can affect, since it can unlock a folder but never change a cover already found. The controller observes `FolderAccessManagerDidChangeNotification` itself, because the grant usually comes from a drop or an open with the Files pane never opened. TRAP: a folder open auto-adds that folder's grant *asynchronously*, a moment after the open's own walk has harvested its cover for free, so the broad form threw that harvest away — and on the **first** open of any folder, a cover named anything but `cover.jpg`, `folder.jpg` or `album.jpg` silently did not exist, appearing only if the folder was opened a second time.

`invalidate`, which does forget everything, is diagnostic surface for the tests alongside `recordedDirectoryCount` and `settledArtPathForDirectory:`. No app path wants it: a settled answer only goes stale if the disk changes under it, which the next launch settles anyway.

**The setting is cached in the resolver**, because `directoryForAudioFilePath:` gates every accessor on it and those run on every playlist cell draw and every `updateUI` pass — far too hot for an `NSUserDefaults` read apiece. `folderArtSettingDidChange` is the one thing that drops the cache, so **a write to `AppSettings.useFolderArt` that does not go through `refreshFolderArt` is not observed at all**. Both writers (the Files pane, the debug channel's `set_folder_art`) do.
