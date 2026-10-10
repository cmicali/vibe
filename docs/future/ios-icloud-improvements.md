# iCloud Drive on iOS: folder setup, cached artwork and browser follow-ups

**Status: the folder setup and the cached artwork are built, 2026-10-08. The browser follow-ups below are still open.** The setup is not the separate row proposed below. Add Folder… gained the caption "From iCloud Drive, a drive, or another app.", which replaced the Locations footer, and a granted folder now opens in the browser. A separate iCloud row opened the same picker under a second name, so it was dropped. Current behavior is in [the iOS subsystem doc](../../Vibe/iOS/AGENTS.md) and [the metadata doc](../../Vibe/Audio/Metadata/AGENTS.md). One check is still to run on a device: whether a real iCloud eviction keeps the size and modification date the cache key reads. The simulator proved the rest with the fake cloud provider.

Two improvements make an iCloud music folder feel at home in Vibe. The system picker becomes a setup step. Previously cached artwork stays visible when the audio is no longer downloaded.

The same Files browser also owns the unresolved usability follow-ups below. They apply across local folders, Dropbox and granted provider folders; they do not depend on the two iCloud improvements.

## Make the picker a setup step

### Current behavior

The Files tab already supports persistent Locations. `BrowserViewController.presentPickerForLocation:` opens the system folder picker, and `SearchFolderStore` saves the selected folder's bookmark and restores access on later launches. The folder and its descendants can then be browsed in Vibe. The separate Browse Files action uses the picker for an individual open.

The missing piece is discoverability: someone wanting to connect their iCloud music collection should be led to the persistent folder flow, rather than repeatedly opening tracks through the system picker.

### Proposed experience

1. Make connecting an iCloud music folder an explicit choice in the Files tab's existing source setup. Suggested wording: **Add iCloud Drive Folder…**.
2. Explain at that entry point that the user chooses a music folder once, then browses and searches it in Vibe. This is a folder permission, with no separate account sign-in.
3. Present the existing system folder picker. The user navigates to iCloud Drive and chooses the folder containing their music.
4. Save it through `SearchFolderStore` and open that folder in Vibe's browser when the grant is ready. Connecting a folder does not start playback.
5. On later visits and launches, the saved Location opens directly in Vibe. Ask for the folder again only when access actually needs to be restored.

The picker is still required for the initial grant. Apple permits a selected directory's contents and descendants to be accessed through its security-scoped URL and a saved bookmark; it does not give this flow unrestricted access to the user's entire Drive. Access can later be revoked. See [Apple: Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories).

### Implementation shape

- Keep this in `BrowserViewController` and `SearchFolderStore`. The iCloud entry funnels into the same persistent-location picker and bookmark handling as other folders; it does not create another source store or account model.
- Preserve the generic folder entry for other providers and external drives. The system picker may let the user choose one of those even from the iCloud entry; save the actual folder without labelling it iCloud merely because of the entry they tapped.
- Use only public picker configuration. Do not hard-code an iCloud container path or depend on an undocumented URL to force the picker into iCloud Drive.
- Reuse the store's existing coverage and deduplication behavior. Cancelling adds nothing. A folder already covered by a Location does not create a duplicate.
- Keep grant resolution and folder listing off main, as they are now. If a stored Location cannot be reached, distinguish a request to restore permission from a temporary provider failure; a failed listing alone is not proof that the grant is gone.
- Final wording belongs in `VibeStrings.h`, following `vibe-strings`, with `make strings` when implemented. The wording above is proposed copy only.

## Show cached artwork for files still in iCloud

### Current behavior

`BrowserViewController.reloadFromDisk` builds `_localFiles` from audio whose bytes are on the device. `loadArtForVisibleRows` considers only those files and calls `AudioTrackMetadataCache.loadMetadata:` for visible rows plus a small margin.

That restriction prevents browsing from downloading tracks: the ordinary metadata load falls through to a tag parse on a cache miss. It also hides a previously cached thumbnail when the source file becomes dataless again, even if its metadata archive still matches.

The loader already has the useful primitive: `AudioTrackMetadataLoader.readCachedMetadataForTrack:` reads file attributes and the metadata archive without reading audio data. The browser needs access to that behavior through the cache owner, with a miss that ends the request.

### Proposed behavior

- A visible cloud file with a valid cached metadata entry shows its cached embedded-art thumbnail, even while the audio remains undownloaded.
- A miss, an entry without artwork, an invalid archive, or an unavailable cache key leaves the existing file tile. None of these outcomes starts a download or a ranged tag read.
- Locally available files retain their existing metadata-loading behavior. Artwork does not change the file's download state or imply it is available offline.
- Keep the work bounded to visible rows and the existing margin. Looking up artwork must not scan or download the whole folder.

### Implementation shape

Expose a narrow asynchronous cache-only operation through `AudioTrackMetadataCache`, reusing the loader's archive lookup and validation. Keep one implementation of that lookup; do not read PINCache directly from the browser or add a second artwork store.

Separate permission to **look in the cache** from permission to **parse the source** in `loadArtForVisibleRows`. Cloud files may do the former; the current local-file restriction continues to govern the latter. Preserve the stack's shared cache and the existing metadata-delivery and thumbnail-notification paths. Rows continue to use `AudioTrack.cachedThumbnail` and the shared bounded 128px decode cache.

Use the existing size, mtime and resolved-path cache key. A failed stat or changed key is a miss; do not fall back to a filename or path-only match that could display another version's art. Attribute and archive reads remain off main. Treat a hit after iCloud eviction as something to verify on a device, since it depends on the provider preserving the attributes used by the key.

Match asynchronous results to the browser's current listing and track before applying them. A late result must not repaint a different row after navigation, filtering or refresh. Avoid repeatedly checking the same miss on every scroll callback; retain only bounded state for the current listing and allow a fresh lookup when the listing or metadata changes.

The cache-only behavior is useful for Dropbox placeholders and other Files providers too. Apply the same rule wherever the browser already has a usable file identity, without an iCloud-specific artwork path. If implementation changes the `TRAP:` beside `loadArtForVisibleRows`, update its counterpart in `Vibe/iOS/AGENTS.md` in the same change.

## Other browser follow-ups

These unresolved items come from the 2026-10-02 iPhone simulator audit of PR #132, reviewed against code on 2026-10-04. The completed audit checklist is retired; current behavior belongs in [the iOS subsystem doc](../../Vibe/iOS/AGENTS.md), and its regression cases are retained in [the shell test plan](ios-shell-unit-tests.md#browser-regression-cases).

| Follow-up | Current behavior and decision still needed |
| --- | --- |
| Empty folder Add or Play | A swipe, context-menu or multi-select Add of a folder containing only subfolders adds nothing; a nonrecursive context-menu Play can also land nothing silently. Play/Add with Subfolders already exists, bounded at about 2,000 songs or 500 folders. Decide how an empty result should explain or offer that action without making an ordinary folder action recurse automatically. |
| Duplicate additions | Files already in the playlist are skipped without a message or a row mark. Decide how to distinguish an all-duplicate Add from an empty folder, and whether rows should show playlist membership. |
| Download-progress legibility | The card already draws transfer progress along the waveform line. The audit saw a download lasting less than a second and did not establish whether that line is readable during a slow transfer. Measure with a constrained link before changing it. |
| Add feedback outside Files | Files rows animate when added; Recents and Search adds do not, while iPad rows fade in place. Decide whether those surfaces need additional confirmation, including empty and duplicate results. |
| Replace confirmation | The Replace / Add Instead / Cancel guard for a hand-built playlist is implemented. Removing it remains a product proposal, not a pending fix; retain the current behavior unless that decision changes. |
| Older Recents names | New records save their folder's display name. Records predating that field still derive it from the stored path and can expose an old container or account name. Decide whether to migrate or improve that fallback without requiring a fresh grant or remote lookup merely to draw a row. |

The original audit did not cover iPad, Dynamic Type, VoiceOver, offline/error paths, the system pickers, Location removal or a slow transfer. It is not evidence that those cases pass. Check the affected cases when implementing a follow-up, and update the corresponding regression expectation when a product decision changes.

## Verification when implemented

- Connect an iCloud folder, browse a descendant, relaunch, and open the saved Location without another picker. Check cancellation, duplicate coverage, revoked access and a temporarily unavailable provider. Connecting must leave playback alone.
- Play a track with embedded art so its metadata is cached, remove its local download through Files, then browse its folder in Vibe. The thumbnail should return while the source remains undownloaded.
- Repeat with an uncached track, a cached track without art, a changed source file and an unavailable cache key. Each must remain a tile without fetching audio. Verify while browsing only, with playback and metadata work otherwise idle, so unrelated downloads cannot obscure the result.
- Scroll, filter, refresh and navigate away while cache reads and thumbnail decodes complete. Check row identity and that revisiting the listing does not accumulate retained tracks or repeated cache work.
- Exercise the same cache-hit and cache-miss cases with Dropbox placeholders. Use the debug command channel for running-app checks and a real device for iCloud behavior; a simulator alone does not establish provider behavior.
- Add focused coverage for the cache-only miss never reaching a parse or materialization, after reading `Tests/AGENTS.md`. Read `vibe-perf` and measure the affected browse/cache work before and after implementation.
- For a browser feedback change, exercise an empty folder, a folder of subfolders, an all-duplicate Add and a mixed selection in Files, Recents and Search. Check a hand-built and a restored playlist, older Recents records and slow transfers as relevant; distinguish retained behavior from any newly chosen policy.

## Scope and complexity

Implementation budget: zero new source files and zero new types. The picker work shares the existing Location flow; the artwork work reuses the existing archive reader and thumbnail pipeline. Neither needs a new cross-directory guarantee. Report the actual net line count and what was consolidated when each change lands.

Offline album downloads, a persistent folder-listing cache and streaming are separate proposals. The two iCloud changes improve setup and browsing without requiring a new iCloud transport; the other follow-ups stay in the existing browser, session and presentation owners.
