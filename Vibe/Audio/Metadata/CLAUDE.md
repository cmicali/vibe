# Metadata and artwork

Tags, their disk cache, embedded artwork, and the macOS folder-cover fallback.

## Ownership

| Type | Owns |
| --- | --- |
| `AudioTrackMetadataCache` | The public facade, disk-cache lifetime, scan replacement, the persistent priority loader, and the foreground materialization hold. |
| `AudioTrackMetadataLoader` | Cache checks, the playlist scan, materialization requests, TagLib scheduling, duplicate-row installation, and delivery. It is internal to the cache. |
| `MetadataParseCoordinator` | Only the per-URL owner/waiter table. It does no I/O, parsing, installation, or delivery. |
| `AudioTrackMetadata` | One immutable set of tags plus the display-facing artwork facade. TagLib and cache coding live here because this is the only ObjC++ object in the flow. |
| `AudioTrackArtwork` | One metadata row's embedded-art state and the shared bounded full-art loader. It is private behind `AudioTrackMetadata`. |
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

The scan registers exactly one `MetadataScan` materialization at a time. Ready files parse on the configured utility worker queue. The priority lane is persistent, user-initiated, and separate so the current track never waits behind the sweep. File > Close calls `cancelScan`; it drops pending scan entries and detaches their central tokens without cancelling a same-path foreground owner.

Both shells defer the first scan until the selected track's open settles. From play submission until that settlement they also call `setBackgroundMaterializationHeld:YES`. Cache checks continue while held, but no unrelated scan miss may start a provider transfer. The cache owns this state because replacing a scan loader must not lose the hold.

Materialization results, not error text, decide retries:

- `Yielded` spends no attempt and waits for the hold to release.
- `Failed` spends the bounded per-path budget and re-enters below untried rows.
- `AdmissionExhausted` spends the same budget after a 0.25–2 second delay.

`MetadataRetryRules.h` contains those tested decisions. A loader snapshots `AudioLoadingConfiguration`; changing settings retires the priority loader after its submitted work and affects only newly created loaders.

Pending scan misses are app-owned records, not pre-submitted operations. `MetadataScanOrderRules.h` selects the best record by deferred state, live neighborhood rank, then playlist index. The callback queue performs one linear selection instead of sorting: a real playlist can contain more than 100,000 misses, and track changes must only replace the small locked neighborhood snapshot and enqueue a coalesced kick.

## Duplicate rows and delivery

`MetadataParseCoordinator` gives one row the parse claim for a URL and holds duplicate rows weakly as waiters. The owner rechecks the disk cache after claiming because another lane may already have won. A successful result is copied into every unresolved waiter while the holder still gates new owners; the last empty drain releases the claim before publication. Each copy has independent mutable artwork state.

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

`AudioTrackArtwork` owns that entire request lifecycle. Across all rows it keeps at most seven active materialization/worker requests: two reads or decodes can run and five can remain scheduler-pending. A separate desired queue holds at most seven deduplicated, revalidated current-window requests. When capacity returns it admits wanted entries; this prevents uncancellable stale reads from losing newly visible iOS pages.

Only a source-file extraction asks for `MetadataPriority` materialization. An in-memory ImageIO decode or a known-artless file's folder-cover fallback uses the same bounded worker admission without rematerializing the song. `Yielded`, central `AdmissionExhausted`, and worker-admission rejection retry at capped 0.1–1 second backoff without spending the three-failure budget; `Failed` spends it. A generation captured at admission must still match before a worker may claim source extraction or store its result.

Parsed metadata is compact before publication: it encodes a 128px embedded thumbnail, then releases the original art bytes. Rows retain only those compact bytes; decoded thumbnails live in one exact 128-entry/8 MiB LRU that only the display request path populates — construction and archive encoding decode once on their metadata worker without touching it, so a playlist-wide scan cannot evict visible rows' pixels. A cache miss never decodes from a drawing path: one per-row request enters a two-running, 126-pending worker bound, then a main-thread notification redraws only visible rows still showing that metadata. Thumbnail staleness has one fence: every data transition replaces the row's identity key (and clears the single-flight pending flag), so a decode is current exactly when its captured key is still installed. Full art is decoded on demand at no more than 1024px. The thumbnail is for macOS playlist rows plus iOS library and mini-player rows; the iOS now-playing page deliberately shows only full art.

**Compaction also cuts a display-art rendition beside the metadata entry** — a `#displayArt`-suffixed key in the same disk store, on the same LRU and age terms. It is sized per platform to be quality-equivalent to the display decode it stands in for (`kVibeArchivedDisplayArtDimension`: 640 for the mac header's ≤~525px render, 1024 for the iOS page — the same bound as the live full-art decode). Original bytes whose longest side is within the bound are archived verbatim, with no decode and no recompression; larger art is downscaled to it, aspect preserved — the square crop stays display-time policy, and Now Playing keeps receiving uncropped art. The rendition is **disk-resident only**: rows never retain it (the stash is consumed by the one cache write), so per-row memory stays at the 128px bytes, whatever the sidecar weighs.

**The rendition is both display surfaces' decode source.** The loader stamps `archivedDisplayArtProvider` on rows whose thumbnail proves the art decodable, on both platforms. The full-art ladder reads decoded art → in-memory bytes → **archived rendition** → source-file extraction; the rendition's read is a small cache hit, so its request never registers materialization — a track change (or an iOS page swipe) re-shows art without re-reading (or, on a dataless cloud file, re-downloading) the song. A provider whose read comes back empty or undecodable — an independently evicted or corrupt sidecar — is dropped and the load takes the demotion fence, so the registry's `finishRequest` re-requests a still-wanted row and the fresh pass reaches extraction with proper materialization: one extra hop, never a stall, and never `_embeddedUndecodable` (the file's own art may be fine).

Embedded extraction is tri-state: art found, conclusively no art, or read failed. Only conclusive no-art opens the folder fallback. A failed read remains unknown and retryable, capped at three reads per display pass and a two-second per-row backoff. `hasEmbeddedArt` is archived separately from the thumbnail so an entry without encoded thumbnail bytes cannot be mistaken for artless — and such an entry's row thumbnail decodes from the archived display rendition, so a failed 128px re-encode at parse cannot strand a row on the placeholder.

No artwork monitor may be held across file I/O or image decoding. A provider read can block indefinitely. An entered TagLib read is uncancellable, keeps its fixed scheduler slot, and is allowed to finish; demotion only fences its store and re-enters bounded admission if the same metadata becomes wanted again.

## Folder art

Folder art is macOS-only. `FolderArtResolver` builds for both targets, but `AudioTrackArtwork` leaves its resolver nil on iOS. The resolver supplies a cover only after the audio file is conclusively known to carry no embedded art, and its answer is never written to the metadata cache.

The resolver owns one `FolderArtEntry` per directory. Keeping that state aggregate separate makes its revision, resolve claim, decode pins, grant result, read-failure count, and access clock auditable. `FolderArtFileIO` separately owns the POSIX no-follow/nonblocking-open trap. Neither is a metadata-loading layer.

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

**TRAP: the resolver caches `AppSettings.useFolderArt`.** Both writers must go through `MainPlayerController.refreshFolderArt`, which calls `folderArtSettingDidChange`; a direct defaults write is not observed.
