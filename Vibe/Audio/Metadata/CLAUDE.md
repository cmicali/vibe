# Metadata and artwork

Tags, their disk cache, embedded artwork, and the macOS folder-cover fallback.

The lettered items cited below (`spec A1`, `J4`, `J6`) are `docs/file-loading-spec.md`'s, which is where the decisions behind this directory's admission and retry rules were settled.

## Ownership

| Type | Owns |
| --- | --- |
| `AudioTrackMetadataCache` | The public facade, disk-cache lifetime, scan replacement, and the current track's priority continuity across replacements. |
| `AudioTrackMetadataLoader` | Cache checks, the playlist scan, materialization requests, TagLib scheduling, duplicate-row installation, and delivery. It is internal to the cache. |
| `MetadataParseCoordinator` | Only the per-path owner/waiter table. It does no I/O, parsing, installation, or delivery. |
| `AudioTrackMetadata` | One immutable set of tags plus the display-facing artwork facade. TagLib and cache coding live here because this is the only ObjC++ object in the flow. |
| `AudioTrackArtwork` | One metadata row's embedded-art state and the shared bounded full-art loader. It is private behind `AudioTrackMetadata`. |
| `ArtworkLoadRegistry` | The bounded-admission state machine behind those loads — the running/pending counts, the retry backoff and the generation fence. A file boundary, not an owner: `AudioTrackArtwork` is its only client and the flow stays that class's. |
| `FolderArtResolver` | Shared, per-directory discovery and caching of macOS sidecar covers. |

Do not add a runner, driver, or second coordinator for these flows. Straight-line metadata work stays in the loader; per-row art work stays in `AudioTrackArtwork`.

## Metadata flow

```
loadMetadata: / loadMetadataNow:
    disk-cache check                         never reads audio contents
      ├─ hit  → atomically install → main-thread delivery
      └─ miss → central materialization
                   └─ Ready → TagLib parse → compact result
                                ├─ best-effort cache write
                                ├─ atomically install
                                └─ main-thread delivery
```

A metadata *request* may start before a file is materialized; an actual TagLib parse may not. The early part is the cheap cache lookup that lets known playlist rows populate without touching their audio files. On a miss, `AudioFileMaterializationCoordinator` must report `Ready` before the parse enters a worker. `loadMetadataNow:` uses `MetadataPriority`, so a current-track miss joins a same-path foreground open instead of starting another provider transfer.

The playlist scan has two stages. Stage 1 checks every row against the disk cache. An operation-queue barrier waits for both enumeration and all discovered checks before stage 2 admits misses. This preserves fast cache hits across a playlist of placeholders; only stage 2 can download audio.

The scan registers exactly one `MetadataScan` materialization at a time. Ready files parse on the configured utility worker queue. **The current track is not a second lane: it is the same record with its URL in the loader's priority set** — materialized through its own single slot beside the scan's (so it never waits behind the sweep's transfer), exempt from the stage-1 barrier, submitted even while the foreground rule is in force (a same-path playback claim serves it for free), and parsed at user-initiated per-operation QoS. Demotion is removal from the set, so no stale mark can survive a requeue. Every mark carries both a generation and the exact target track: off-lock locality probes and yielded completions revalidate the generation, while Ready/cache-hit settlement retires only a mark whose target it actually resolved. A repeat edge reactivates one submission so it can join a new same-path foreground claim; a scan already in flight for that target keeps its provider role but promotes the resulting parse. Every priority membership change invalidates an off-lock scan pick. The per-path terminal retry budget still wins over a newer mark once exhausted. A `loadMetadataNow:` before any sweep exists builds a loader over just that track; the real playlist sweep replaces it wholesale and the cache re-prioritizes the (weakly held) current track on the replacement. File > Close calls `cancelScan`; it drops pending records — the priority record included, which is what makes playlist replacement drop the old playlist's downloads by construction — and detaches their central tokens without cancelling a same-path foreground owner.

Both shells defer the first scan until the selected track's open settles. The foreground/background rule itself carries no shell or cache state at all: `AudioFileMaterializationCoordinator` derives "a foreground transfer is active" from its own claim table and yields metadata-only dataless work while it holds (root `CLAUDE.md`, Cross-directory guarantees). The sweep asks `isForegroundTransferActive` before submitting a dataless record — deliberately conservative, even for the file playback is downloading; the priority record covers that file (spec J4) — and re-asks on a bounded 1s clock while gated, which is also where priority records a yield made wait are re-judged. Cache checks continue while the rule is in force, and **the rule and the central transfer lanes bound provider downloads, which an already-local file never starts** — so a miss whose bytes are on disk keeps materializing and parsing straight through, on a partially downloaded cloud folder above all. The loader probes with `NSURLUtil.isDatalessFile:` at enqueue/submit/requeue edges. The coordinator receives the same classifier by injection, runs initial classification after claim installation on its bounded scheduler, and refreshes only delayed/readmitted dataless starts in their admitted worker; admission itself performs no I/O.

Materialization results, not error text, decide retries:

- `Yielded` spends no attempt. A scan record requeues at its rank. A yielded **priority** record is re-judged on every tick of the gated clock, and the tick sorts it into one of two cases:
  - **Local now** — the open made the file local, so it retries at once, hold or no hold. Its parse starts no transfer (spec A1's exemption), and waiting instead was measured costing the now-playing tags the length of the successor's whole prefetch.
  - **Still dataless** — it waits out foreground activity rather than re-picking. Re-picking would install a fresh `Probing` claim, occupy a bounded probe slot, repeat the filesystem probe, and yield again when the result lands. It demotes at the **first idle tick**: still dataless once the foreground has settled means the open failed, so it becomes an ordinary sweep candidate at its rank instead of re-downloading a dead pick behind its own error UI.
- `Failed` spends the bounded per-path budget and re-enters below untried rows.
- `AdmissionExhausted` spends the same budget after a 0.25–2 second delay.

Both slots spend the one per-path ledger; there is no separate priority budget. `MetadataRetryRules.h` contains those tested decisions. A loader snapshots `AudioLoadingConfiguration`; changing settings affects only newly created loaders.

Pending scan misses are app-owned records, not pre-submitted operations. `MetadataScanOrderRules.h` selects the best record by already-local first, then deferred state, live neighborhood rank, then playlist index. Locality is re-probed at every submit and requeue because the playback open routinely downloads the very file a yielded entry is parked on. The callback queue performs one linear selection instead of sorting: a real playlist can contain more than 100,000 misses, and track changes must only replace the small locked neighborhood snapshot and enqueue a coalesced kick.

Each shell sends that snapshot from its one current-index funnel through `setNeighborhoodAroundIndex:inTracks:`, which reads **three** rows and takes the playlist itself — `id<AudioTrackIndexedSource>`, which `Playlist` and `PlaylistController` already satisfy without adding a method. Not an array: the mac getter makes a defensive shallow copy, so handing it the list cost one atomic retain per track on every play, skip and auto-advance, to read three of them.

## Duplicate rows and delivery

`MetadataParseCoordinator` gives one row the parse claim for a standardized path — the spelling every other loader identity uses, so two spellings of one file cannot get two owners — and holds duplicate rows weakly as waiters. The owner rechecks the disk cache after claiming because another lane may already have won. A successful result is copied into every unresolved waiter while the holder still gates new owners; the last empty drain releases the claim before publication. Each copy has independent mutable artwork state.

Failed parses produce filename fallback metadata but are never cached. The holder and every extant waiter receive independent fallback copies, so no row remains unresolved. Installation and publication both compare the exact metadata object under the track monitor. A racing cache or parse success can replace a fallback, but the queued stale fallback delivery then drops instead of publishing the newer success twice.

Every delivery runs on main and revalidates that exact installed object while holding the track monitor through the delegate call. Delegates may synchronously update observers and UI; they must never wait for metadata workers.

## Embedded artwork

`AudioTrackMetadata` is the only display API:

| Call | Contract |
| --- | --- |
| `cachedArt`, `cachedThumbnail` | Non-blocking, already-decoded access. Safe during drawing. |
| `artNeedsLoad` | Whether full art still needs a file read or decode. |
| `artLoadPending` | Whether this metadata row already has a registered request. |
| `loadArtIfNeededStillWanted:completion:` | One bounded asynchronous request; completion is main-thread and current-only. |
| `discardDecodedArt` | Demotes an undisplayed row, cancels parked work, and generation-fences running work. |

`AudioTrackArtwork` owns that entire request lifecycle. Across all rows it keeps at most seven active materialization/worker requests: two reads or decodes can run and five can remain scheduler-pending. A request past that bound is dropped **before** it marks the row pending, so the next redraw or thumbnail notification re-requests it cleanly once capacity returns (spec J6 — the desired queue that used to park such requests defended a seven-surface pileup the app cannot produce).

Only a source-file extraction asks for `MetadataPriority` materialization. An in-memory ImageIO decode or a known-artless file's folder-cover fallback uses the same bounded worker admission without rematerializing the song. `Yielded`, central `AdmissionExhausted`, and worker-admission rejection retry at capped 0.1–1 second backoff without spending the three-failure budget; `Failed` spends it. A generation captured at admission must still match before a worker may claim source extraction or store its result.

Parsed metadata is compact before publication: it encodes a 128px embedded thumbnail, then releases the original art bytes. Rows retain only those compact bytes; decoded thumbnails live in one exact 16,384-entry LRU (flushed on an iOS memory warning) that only the display request path populates — construction and archive encoding decode once on their metadata worker without touching it, so a playlist-wide scan cannot evict visible rows' pixels. A cache miss never decodes from a drawing path: one per-row request enters a two-running, 126-pending worker bound, then a main-thread notification redraws only visible rows still showing that metadata. Thumbnail staleness has one fence: every data transition replaces the row's identity key (and clears the single-flight pending flag), so a decode is current exactly when its captured key is still installed. Full art is decoded on demand at no more than 1024px. The thumbnail is for macOS playlist rows plus iOS library and mini-player rows; the iOS now-playing page deliberately shows only full art.

**Compaction also cuts a display-art rendition beside the metadata entry** — a `#displayArt`-suffixed key in the same disk store, on the same LRU and age terms. It is sized per platform to be quality-equivalent to the display decode it stands in for (`kVibeArchivedDisplayArtDimension`: 640 for the mac header's ≤~525px render, 1024 for the iOS page — the same bound as the live full-art decode). Original bytes whose longest side is within the bound are archived verbatim, with no decode and no recompression; larger art is downscaled to it, aspect preserved — the square crop stays display-time policy, and Now Playing keeps receiving uncropped art. The rendition is **disk-resident only**: rows never retain it (the stash is consumed by the one cache write), so per-row memory stays at the 128px bytes, whatever the sidecar weighs.

**The rendition is both display surfaces' decode source.** The loader stamps `archivedDisplayArtProvider` on every art-bearing row, on both platforms. The full-art ladder reads decoded art → in-memory bytes → **archived rendition** → source-file extraction; the rendition's read is a small cache hit, so its request never registers materialization — a track change (or an iOS page swipe) re-shows art without re-reading (or, on a dataless cloud file, re-downloading) the song. A provider whose read comes back empty or undecodable — an independently evicted or corrupt sidecar — is dropped and the load takes the demotion fence, so the registry's `finishRequest` re-requests a still-wanted row and the fresh pass reaches extraction with proper materialization: one extra hop, never a stall, and never `_embeddedUndecodable` (the file's own art may be fine).

Embedded extraction is tri-state: art found, conclusively no art, or read failed. Only conclusive no-art opens the folder fallback. A failed read remains unknown and retryable, capped at three reads per display pass and a two-second per-row backoff. `hasEmbeddedArt` is archived separately from the thumbnail so an entry without encoded thumbnail bytes cannot be mistaken for artless — and such an entry's row thumbnail decodes from the archived display rendition, so a failed 128px re-encode at parse cannot strand a row on the placeholder.

No artwork monitor may be held across file I/O or image decoding. A provider read can block indefinitely. An entered TagLib read is uncancellable, keeps its fixed scheduler slot, and is allowed to finish; demotion only fences its store and re-enters bounded admission if the same metadata becomes wanted again.

## Folder art

Folder art is macOS-only. `FolderArtResolver` builds for both targets, but `AudioTrackArtwork` leaves its resolver nil on iOS. The resolver supplies a cover only after the audio file is conclusively known to carry no embedded art, and its answer is never written to the metadata cache.

The resolver owns one `FolderArtEntry` per directory. Keeping that state aggregate separate makes its answer generation, resolve claim, decode pins, grant result, read-failure count, and access clock auditable. `FolderArtFileIO` separately owns the POSIX no-follow/nonblocking-open trap. Neither is a metadata-loading layer.

Discovery is per directory and lazy:

- A folder open donates the directory listing already produced by `NSURLUtil.expandDirectory:`. Every walked directory is settled for no extra I/O.
- A multi-file open marks its directories for one lazy listing each.
- A single-file open probes only the three most likely lowercase names. Other candidates require a donated or preferred listing.

Candidate ranking is shared in `FolderArtRules.h`: `cover`, `folder`, `album`, `front`, `albumart`, then `art`, with jpg/png/jpeg/webp variants. A settled cover path is not opened until pixels are requested. The one read then produces both full and thumbnail decodes where possible.

No active sandbox grant means no probe or cover-file read; background work must never raise a permission panel. A known cover whose scope ended keeps its donated path but parks further reads until a grant change, while an unresolved folder settles "without grant." The album-art setting drops decoded images but preserves discovery answers. Folder answers are never persisted because the metadata cache key follows the audio file, not its sidecar image.

The entry history is a bounded MRU: 4,096 directories, trimmed in one background batch to 3,072. In-flight entries are not evicted. Decoded pixels are bounded separately by `NSCache` to 64 thumbnails and four display images.

`FolderArtDidResolveNotification` is coalesced before visible rows and the header redraw. It fires for a cover and for a conclusive no-cover answer because the header retains the previous track's art while resolution is pending.

**TRAP: `O_NONBLOCK` belongs on the cover file's `open` and nowhere else** (`FolderArtFileIO.m`). It prevents a FIFO or device named like a cover from wedging the resolver before `fstat`; it must be cleared before reading a regular file, where `EAGAIN` would merely mean bytes are not resident.

**TRAP: neither normal invalidation is a full wipe.** `folderArtSettingDidChange` preserves discovery answers while dropping decoded images. `invalidateDirectoriesSettledWithoutGrant` forgets unresolved no-grant answers and re-arms known paths whose reads were access-blocked; it preserves every discovered cover path. Full `invalidate` is test/diagnostic surface only.

**TRAP: the resolver caches `AppSettings.useFolderArt`.** Both in-process writers must request `VibeSettingsLiveEffectFolderArt`, whose mapping calls `folderArtSettingDidChange`; a direct defaults write is not observed.
