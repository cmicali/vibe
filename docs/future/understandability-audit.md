# Audit: understandability by a human

Written 2026-08-14, from a read of `Vibe/` (35,601 lines across 834 non-vendored files), the nested `CLAUDE.md` set, and `docs/future/naming-vocabulary.md`. Scope is comprehension only — nothing here is a bug report, and every proposal is behavior-preserving unless it says otherwise.

**The headline.** This codebase is not hard to read because it is sloppy. It is hard to read because it is *unusually well documented at the wrong granularity*: 26% of all lines are comments, the invariants live in six `CLAUDE.md` files totaling ~400 lines of dense prose, and the hardest subsystem (metadata + artwork) is explained beautifully in three places and diagrammed in none. A newcomer can learn *why* every line is the way it is long before they can answer "what happens when I drop a folder?"

Sections are lettered, items numbered, so fixes can be cherry-picked by ID.

---

## A. Naming and vocabulary

> **Status: done, 2026-08-15.** Executed with three corrections to what is written below, each forced by checking the code rather than trusting the plan:
> - **A1's claim that `_generation` is file-private is wrong.** It is declared in `AudioPlayerInternal.h` and bumped from `AudioPlayer+Devices.m`, so the rename touched three files, not one.
> - **`AudioCachePolicy.h` is not a pure-logic header** and never belonged in A2's table — it constructs a `PINCache`. It became a category instead, `PINCache+VibeAudioCache`, which dissolves the naming question: a category is *expected* to carry a factory plus an instance method, so no suffix has to describe both. A subclass was rejected because `PINCache` has six `initWithName:…` initializers, leaving five holes an un-policied instance could come through.
> - **`NowPlayingMath.h` returns a `BOOL`**, so it is a rule, not math.
>
> A4 landed only in part: `archivableThumbnail` → `embeddedThumbnail` and the glossary terms. **The `FolderArt` / `FolderArtwork` split is still open** — see the note at the end of A4.

### A1. `docs/future/naming-vocabulary.md` was written and never executed — do it

Verified at writing time: 24 bare `_generation` hits remain across `Vibe/`, `Vibe/Settings/DefaultAppClaim.{h,m}` still exists, and root `CLAUDE.md` has no `### Vocabulary` section. That plan is correct as written and is the cheapest legibility win available. Execute steps 1–3 verbatim.

One amendment: step 3 places the glossary in root `CLAUDE.md`. Put it there, but *also* make it enforceable — see A6.

### A2. Five different suffixes name one concept: the pure-logic header

Thirteen header-only files hold static-inline decision logic split out so tests reach it without linking the app. They are named five ways:

| Suffix | Files |
| --- | --- |
| `*Rules.h` | `ArtworkDisplayRules`, `FLACConvertRules`, `FolderAccessRules`, `FolderArtRules`, `SettingsRules` |
| `*Math.h` | `CueJumpMath`, `GaplessSpliceMath`, `NowPlayingMath`, `TransportMath` |
| `*Rate.h` | `UIUpdateRate` |
| `*Policy.h` | `AudioCachePolicy` |
| `*Curve.h` | `VibeFadeCurve` |

There is no rule distinguishing them. `NowPlayingMath` (a republish-or-not predicate) is a *rule*; `FolderArtRules`' `VibeFolderArtCandidateRank` is *math*. The suffix carries no information, so a reader cannot guess where a given piece of logic lives, and — worse — cannot tell from a filename that these are the app's *testable seams*, which is the one fact about them worth knowing.

**Proposal.** Collapse to two, on a rule a reader can apply blind:

- `*Rules.h` — returns a decision (a `BOOL`, an enum action, a name). Absorbs `NowPlayingMath` → `NowPlayingRules`, `AudioCachePolicy` → `AudioCacheRules`.
- `*Math.h` — returns a number in the problem's units. Absorbs `UIUpdateRate` → `UIUpdateMath`, `VibeFadeCurve` → `FadeMath`, `FolderArtRules`' rank helper stays put (it feeds a decision).

`MusicalKey.h` is the odd one out and should keep its name: it is a *type* plus its formatters, not a seam. Cost: 5 renames, ~15 import sites, one `xcodegen generate`.

### A3. The `Vibe` prefix means nothing right now

C functions and structs are prefixed (`VibeArtworkDisplayActionFor`, `VibeFolderArtEntry`, `VibeUIUpdateHzForPlayhead`, `VibeMusicalKey`), ObjC classes are not (`AudioPlayer`, `FolderArtwork`, `Playlist`) — except two files that carry it in the *filename* only (`VibeStrings.h`, `VibeFadeCurve.h`), and one class that carries it (`VibeFLACConversionRecord`).

The convention that is actually operating is a good one: **`Vibe` marks C-linkage symbols, which have no namespace; ObjC classes don't need it.** State it and fix the three exceptions — rename `VibeFadeCurve.h` per A2, leave `VibeStrings.h` (it is a registry of `Vibe`-prefixed macros, so the name is honest), and let `VibeFLACConversionRecord` keep it or drop it, but say which in the glossary.

### A4. "Art" vs "artwork" vs "cover" vs "album art"

One feature, four nouns, and they are not synonyms in the code even though they read as synonyms:

- `albumArt` — the track's **display-size** image, from *either* the file's tag or the folder.
- `thumbnailAlbumArt` — the 128px one, same dual source.
- `archivableThumbnail` — the thumbnail from the **file only**, never the folder. The distinction is load-bearing (the cache key can't see a sidecar image) and is carried entirely by the word "archivable".
- `FolderArtwork.displayImageForAudioFilePath:` — the folder's cover, display size.
- `FolderArtRules` / `FolderArtwork` — `Art` in one, `Artwork` in the other, same feature.
- `ArtworkDisplayController` — the *view* side, unrelated to `AudioTrackArtwork`, the *model* side.

**Proposal.** Three words, each meaning exactly one thing, added to the A1 glossary:

| Term | Means exactly | Never used for |
| --- | --- | --- |
| `embedded` | art carried in the audio file's own tag | the folder cover |
| `cover` | the sidecar image beside the audio file | embedded art |
| `art` | whichever of the two a caller ends up with | either one specifically |

**Done:** `archivableThumbnail` → `embeddedThumbnail`, which also collapsed a three-method tangle (`archivableThumbnail` was a pure alias of the private `embeddedThumbnailAlbumArt`) down to `embeddedThumbnail` + `prewarmEmbeddedThumbnail`.

**Done — the whole feature is now `FolderArt*`.** `FolderArtwork` → `FolderArtResolver`, `FolderArtRules` kept, `VibeFolderArt*` regularized, `AppSettings.useFolderArtwork` → `useFolderArt`, the debug verb `set_folder_artwork` → `set_folder_art`, and the log and comment prose with them. Six files renamed, ~261 sites.

The real defect was never `Folder` vs `Cover` — it was `FolderArt` vs `FolderArt**work**`, ragged enough that `VibeFolderArtEntry` and `VibeFolderArtworkFileInfo` sat in the same header. A `CoverArt*` pass was tried first, for the precision that `cover` names the sidecar file where "folder artwork" is ambiguous between artwork *of* a folder and artwork *from* one, and was **reverted** on three counts:

- **The class's API is directory-shaped** — six of its ten public members say `Directory` (`settledArtPathForDirectory:`, `preferListingForDirectories:`, `invalidateDirectoriesSettledWithoutGrant`, …). `CoverArt` put a noun in the class name that appears nowhere in its interface.
- **The product language already says "folder"** — the Settings dropdown reads "File first, then search folder", and the persisted key is `Audio.folderArtwork`. Code, UI and storage now agree.
- **`Resolver` is the word the codebase had already chosen**: "the resolver" appears 34 times in the docs and comments, against 3 for "the loader", and the API is saturated with `scheduleResolveOfDirectory:`, `resolveIfUnknown:`, `…DidResolveNotification`, `unresolved`. `FolderArtLoader` was considered and rejected for naming the phase the design works hardest to *avoid* — settling a folder records a path and opens nothing, so a fully tagged library loads no cover at all — and because `*Loader` already means "per-job worker owned by a cache" here (`AudioTrackMetadataLoader`, `AVFAudioWaveformLoader`), which this shared cache is not.

Inside `AudioTrackArtwork` the private ivars moved too — `_albumArt*` → `_embedded*` — because every one of them holds **embedded** state exclusively (the cover "is deliberately not state of this class"), yet they carried the generic word. The invariant is now visible on each line instead of stated once in a comment. The *public* accessors stay generic (`albumArt`, `thumbnailAlbumArt`) because they genuinely return either; renaming those is B4, about threading contracts.

TRAP recorded at the site: **`SETTING_COVER_ART`'s stored key string stays `@"Audio.folderArtwork"`.** The macro name may follow a rename; the persisted `NSUserDefaults` key never can, or every existing user's setting silently resets. The mechanical rename *did* rewrite it, and it had to be put back by hand.

`AudioTrackArtwork`, `ArtworkDisplayController` and `ArtworkImageView` keep the generic word — they hold or draw *whichever* art won, which is exactly what `art` should mean.

### A5. `Coordinator` names three unrelated contracts

`PlaybackRequestCoordinator` (request identity), `MetadataParseCoordinator` (single-flight ownership), `OpenRequestCoordinator` (ordered delivery). `naming-vocabulary.md` considered renaming these and rejected it on churn grounds. That call was right for a rename-only change, but it leaves the reader with a word that predicts nothing.

**Cheaper alternative that gets most of the value:** leave the class names and add each one's *contract* as the first line of its header comment, in a fixed three-word form — `// Single-flight ownership.`, `// Ordered delivery.`, `// Request identity.` — and list all three in the A1 glossary under `Coordinator` with the note that the suffix is deliberately generic. A reader who sees a fourth `*Coordinator` then knows to check which of the three shapes it is.

### A6. Make the glossary enforceable, not aspirational

A glossary in `CLAUDE.md` decays. Add a `make check-vocabulary` target, modeled on the existing `make check-strings`, asserting the mechanical half:

```
grep -rn '_generation\b' Vibe --include='*.m' --include='*.mm'   # must be empty (A1)
grep -rn 'DefaultAppClaim' Vibe Tests                            # must be empty (A1)
```

plus the A2 suffix rule (every header-only file matching `static inline` in `Vibe/` ends in `Rules.h`, `Math.h`, or is on a short allowlist). Wire it into `make test`. Anything not mechanically checkable stays prose — but then it is prose about judgment, which is what prose is good at.

---

## B. Control flow: metadata and artwork

This is the section that answers the complaint. The subsystem is correct, well tested, and genuinely hard to follow — and the difficulty is structural, not cosmetic.

### B1. There is no map, and the map is the missing artifact

Loading metadata and art for one track touches **five entry points, three delivery channels, and two independent duplicate-row fan-outs**, spread over eight files:

```
Entry points
  playTracks:              → scheduleDeferredMetadataLoad (2s timer + generation)
  didBeginLoading:         → loadMetadataNow:            (priority lane)
  didStartPlaying:         → loadMetadataNow:            (retry once local)
  didLoadMetadata:         → updateUI → art accessors    (re-entrant)
  playlist cell draw       → thumbnailAlbumArt           (schedules a cover resolve)

Scan path
  AudioTrackMetadataCache.loadMetadata:
    → AudioTrackMetadataLoader (scan lane, 4 workers)
      → setup op → per-track stage-1 op
        → cacheCheckOneTrack: → loadTrackFromDiskCache: → publishTrack:   [HIT]
        → re-enqueue stage-2 op                                            [MISS]
          → parseOneTrack: → MetadataParseFlow.runForParticipant:key:
            → MetadataParseCoordinator.claimParseForKey:      (owner/waiter/already)
            → 4 delegate callbacks back into the loader
              isResolved / serveFromCache / parse / publishParsed
            → serveWaiters: (+ optional serveWaiter:fromHolder: for cue rows)

Delivery channels
  1. AudioTrackMetadataCacheDelegate.didLoadMetadata:   → MainPlayerController
  2. FolderArtworkDidResolveNotification               → MainPlayerController (coalesced)
  3. ArtworkDisplayController.artDidResolveHandler     → MainPlayerController → updateUI

Duplicate-row fan-out — TWO mechanisms
  a. MetadataParseFlow.serveWaiters:            (Metadata/MetadataParseFlow.m:62)
  b. MainPlayerController.shareMetadataAcrossRowsOfFile:  (MainPlayerController.m:1191)
```

Every individual hop is commented. The *shape* is written down nowhere. `Vibe/Audio/CLAUDE.md` describes it in ~1,400 words of continuous prose, which is the wrong medium for a graph.

**Proposal (do this one first — it is the highest value-per-hour item in the audit).** Add `Vibe/Audio/Metadata/CLAUDE.md` whose first screen is the diagram above, followed by a one-line-per-hop table. Then *cut* the corresponding prose out of `Vibe/Audio/CLAUDE.md` and leave a pointer — see D2. No code changes.

### B2. Duplicate-row fan-out lives in two places, one of them the view controller

`MetadataParseFlow.serveWaiters:` serves rows that were *waiting on a claim*. `MainPlayerController.shareMetadataAcrossRowsOfFile:` serves rows that *were never queued at all*, because the scan's setup op deduplicates cue rows by URL (`AudioTrackMetadataCache.m:133`). Both exist for the same user-visible reason (a cue sheet's rows share one image), both have careful comments explaining that reason, and neither mentions the other.

The consequence for a reader: "who gives row 7 its metadata?" has two answers depending on timing, and finding the second one requires knowing to look in the *window controller*.

**Proposal.** Move `shareMetadataAcrossRowsOfFile:` behind the `Playlist` model as `Playlist.shareMetadataAcrossRowsOfFile:` (it already needs only `indexesOfTracksWithURL:` and `trackAtIndex:`, both playlist operations), have `didLoadMetadata:` call it there, and cross-reference the two in one sentence each. The controller then does what it should: route a delivery, not implement a sharing policy.

Larger alternative, if you want one mechanism instead of two: register the deduplicated cue rows as *waiters* at setup time rather than skipping them, so the flow's existing fan-out serves them. That is a real behavior change (a waiter is served on completion, not on the next delivery) and needs its own tests — noted, not recommended for this pass.

### B3. Artwork is a state machine with ~23 fields and no state diagram

Mutable state governing "what image does the header show":

| Owner | Fields |
| --- | --- |
| `AudioTrackArtwork` | `_albumArt`, `_albumArtData`, `_thumbnailAlbumArt`, `_albumArtExtractionAttempted`, `_albumArtUndecodable`, `_artGeneration` |
| `AudioTrackMetadata` | `albumArtLoadDispatched` |
| `ArtworkDisplayController` | `_displayedArt`, `_showingDefaultArt`, `_initialized`, `_tintGeneration`, `_dominantArtColor` |
| `VibeFolderArtEntry` (per folder) | `artPath`, `revision`, `resolving`, `decoding`, `scheduled`, `lastAccess`, `settledWithoutGrant`, `preferListing`, `readFailures` |
| `FolderArtwork` | 2 `NSCache`s, cached `useFolderArtwork` |

The reachable states are far fewer than 2²³ — the comments make clear the author knows which — but nothing states them. `AudioTrackArtwork.m` is 33% comments and every one of them is a *transition* rule ("re-arm the on-demand re-read", "bump before the early return"). A reader reconstructs the state machine by reading transitions, which is the hard direction.

**Proposal.** In `AudioTrackArtwork.h`, replace the prose header block with a five-state table — `Unknown → Extracting → HasArt / Artless → Undecodable`, plus the orthogonal `decoded / bytes-only / discarded` axis — naming which field combination *is* each state, and which method effects each edge. Then most of the per-method comments in the `.m` can shrink to a state name. This is documentation-first; the code needn't move.

A follow-on worth considering separately: `albumArtLoadDispatched` is a *view* flag stored on the *model* (`AudioTrackMetadata.h:108`), which is why `ArtworkDisplayController` reads three fields across two objects to answer "is the art resolved" (`ArtworkDisplayController.m:224`). Moving it into a small `NSMapTable` on the display controller would put the whole in-flight question on one side of the boundary. Not free — cue rows share a metadata object, and the flag currently inherits that sharing for free.

### B4. Four art accessors, four contracts, one naming pattern

`albumArt` (blocking, may parse a file), `albumArtIfLoaded` (non-blocking, decoded-only), `albumArtNeedsLoad` (predicate), `thumbnailAlbumArt` (non-blocking *for the cover*, but can run an ImageIO decode for embedded bytes — `AudioTrackArtwork.m:285`). The names differ by suffix; the *threading contracts* differ by paragraph in the header. `FolderArtwork.h` states its non-blocking contracts in bold; `AudioTrackArtwork.h:63` defers all four to "the matching `AudioTrackMetadata.h` declarations", so a reader chasing a main-thread stall reads three headers to learn which call is safe.

**Proposal.** Encode the contract in the name, matching what `FolderArtwork` already does well:

- `albumArt` → `loadArtBlocking` (background threads only)
- `albumArtIfLoaded` → `cachedArt`
- `thumbnailAlbumArt` → `cachedThumbnail`, with the residual embedded decode either hoisted to the prewarm (it is prewarmed on both publish paths already, so the decode is nearly dead code) or renamed to admit it
- `albumArtNeedsLoad` unchanged — it already reads as a predicate

and put the one-line contract on each declaration in `AudioTrackArtwork.h` rather than delegating. Cost: ~15 call sites.

### B5. `AudioTrackMetadataCache.m` holds two classes and three lanes in 528 lines

`AudioTrackMetadataLoader` (lines 37–414) and `AudioTrackMetadataCache` (416–528) share a file, and the loader is really three behaviors selected by one `priorityLane:` BOOL: the scan's stage-1 sweep, the scan's stage-2 parse, and the current-track lane. The BOOL changes queue name, width, QoS, *and* the `_queuedTracks` retention policy (keep-forever vs in-flight-only, explained at line 56 and again at 196).

**Proposal.** Split `AudioTrackMetadataLoader` into its own file pair, and replace the `priorityLane:` BOOL with a named enum (`VibeMetadataLaneScan` / `VibeMetadataLaneCurrentTrack`) so the four coupled differences read as one decision at the call site. No behavior change. This also makes the file's own `#pragma mark - MetadataParseFlowDelegate` block (302–383) legible as what it is: the loader's four effects, which `MetadataParseFlow.h` documents as a protocol and which currently sit 250 lines from the class they belong to.

---

## C. Organization

### C1. Debug surface leaks into nine production headers — and there is already a better pattern in-tree

Nine debug-only members are declared inside `#if DEBUG` in shipping headers:

| Header | Member |
| --- | --- |
| `Common/AppDelegate.h:37` | `debugQueuedOpenCount` |
| `Common/OpenBurstCoalescer.h:50` | `debugQueuedURLCount` |
| `Common/OpenRequestCoordinator.h:65` | `debugBufferedResultCount` |
| `Audio/AudioPlayer.h:138,152` | `manualRenderingActive`, `debugEngineCounts` |
| `Audio/AudioPlayerInternal.h:47` | `_manualRenderingActive` |
| `Audio/Metadata/MetadataParseCoordinator.h:58` | `debugPendingCounts` |
| `Audio/Metadata/AudioTrackMetadataCache.h:54` | `debugPendingCounts` (a pure forward of the line above) |
| `Audio/Waveform/AudioWaveformCache.h:46` | pre-warm / per-file eviction |

Each is small. Cumulatively they mean **every production header a newcomer opens carries a conditional block about a tool that does not ship**, and one of them (`AudioTrackMetadataCache.debugPendingCounts`) exists only to forward another because the debug channel cannot reach a private property.

The repo already contains the right answer: `Main Window/MainPlayerController+Debug.h` — a declaration-only category, `#if DEBUG`-wrapped, no `@implementation`, re-declaring internals the channel reads. It works because ObjC dispatch does not need the implementation to be visible.

**Proposal.** Generalize it. One `+Debug.h` per class that needs one, living in `Vibe/Debug/` (not beside the class), each with the same header block explaining the no-implementation trick:

```
Vibe/Debug/Introspection/AppDelegate+Debug.h
Vibe/Debug/Introspection/AudioPlayer+Debug.h
Vibe/Debug/Introspection/MetadataParseCoordinator+Debug.h
...
```

Production headers then end up with **zero** `#if DEBUG`. Two members resist and should stay: `AudioPlayer.manualRenderingActive` (written by production code during init, not merely read), and `AudioWaveformCache`'s pre-warm (it runs the real load path and arguably wants to exist in Release for a future pre-warm feature — decide, then either promote it or move it). `AudioTrackMetadataCache.debugPendingCounts` disappears entirely: the category can reach `parseCoordinator` directly.

Verification is mechanical: `grep -rn '#if DEBUG' Vibe --include='*.h' | grep -v '^Vibe/Debug/'` must be empty. Add it to the A6 check target.

### C2. `Debug/DebugUtil.m` is 1,551 lines and seven programs

By `#pragma mark`, in one file: screenshot capture and glass-layer collection (46–174), state dictionary and view-tree dump (183–333), menu search and click (334–438), argument parsing (439–478), keyboard injection (479–640), mouse and drag injection (641–802), synthetic file drags (803–904), and a 440-line command table (963–1399) plus the file-watch transport (1400–1550).

**Proposal.** Split along the existing marks — the seams are already drawn:

```
Debug/DebugScreenshot.m      screenshot + glass layers
Debug/DebugStateDump.m       state dict, view tree, menu array
Debug/DebugInput.m           keyboard, mouse, drag injection
Debug/DebugDragAndDrop.m     synthetic file drags
Debug/DebugCommandTable.m    the table
Debug/DebugTransport.m       file watch, response write, dispatch
```

with the shared helpers (`VibeRestArgument`, `VibePathArgument`, `VibeExistingFileArgument`) joining `DebugShared.h`, which already exists for exactly this. Zero behavior change; `xcodegen generate` picks up the new files by glob. This also lets the vibe-debug skill point at one file per capability instead of line ranges in a 1,500-line file.

### C3. `Common/` is a junk drawer; `Util/` has a stated rule that two files break

`Common/` holds, with no organizing principle: the app delegate, two singletons (`AppSettings`, `AppStats`), the **playlist model** (`Playlist.h/.m`), the Now Playing bridge, two open-path classes (`OpenBurstCoalescer`, `OpenRequestCoordinator`), four pure-logic headers, the strings registry, `Info.plist`, the entitlements, and the prefix header.

`Util/` has an explicit and good rule — root `CLAUDE.md` calls it "the future-shared, no-AppKit group", which is why `NSURLUtil` hands its folder-art harvest to a handler block rather than calling the resolver. Two files sit in it that are not utilities by that rule: `PlaylistFile.h/.m` (597 lines of M3U and CUE *parsing* — a domain model, and the biggest single source of playlist semantics) and `UIUpdateTimer` (a UI-lifecycle object).

Meanwhile `Vibe/Playlist/` is UI-only (table, cells, drop zone), so a reader looking for "the playlist" finds the view layer, and must know that the model is in `Common/` and the file format in `Util/`.

**Proposal.** Move, don't restructure:

| From | To | Why |
| --- | --- | --- |
| `Common/Playlist.{h,m}` | `Playlist/PlaylistModel.{h,m}` | the model belongs with its feature; the rename also ends the `Playlist` / `PlaylistController` / `Vibe/Playlist/` three-way collision |
| `Util/PlaylistFile.{h,m}` | `Playlist/PlaylistFile.{h,m}` | M3U/CUE parsing is playlist domain logic |
| `Common/OpenBurstCoalescer`, `Common/OpenRequestCoordinator` | `Common/Open/` (new) | the open funnel is one story told by three files with `AppDelegate` |
| `Util/UIUpdateTimer.{h,m}` | `Main Window/` | its only client, and it is not AppKit-free |

`Common/` then means what it should: app lifecycle, settings, and cross-platform-shared bridges. Add a two-line rule for it in root `CLAUDE.md` next to `Util/`'s, so the next file has somewhere obvious to go. Requires `xcodegen generate`; `Vibe/Playlist/CLAUDE.md` gains a paragraph, `Vibe/Audio/CLAUDE.md` loses none.

### C4. `MainPlayerController` is still 1,554 lines after four categories

The categories (`+Menus`, `+NowPlaying`, `+Transport`, `+Convert`) each moved out a coherent feature, and worked. What remains is seven concerns: window construction (176–270), the UI tick and its rate scaling (418–503), display-state resolution (505–535), the playlist and open funnel (703–885), eight `AudioPlayerDelegate` methods (886–1183), metadata/waveform/BPM/key delivery (1184–1278), and ~20 miscellaneous actions (1279–1520). The class extension declares **eight** protocol conformances plus five more on the categories.

This is not a crisis — the file is well marked and the biggest method is ~65 lines. But two more extractions are clearly available and would each remove a whole vocabulary from the file:

- **`+Delivery`** — the four delegate methods at 1184–1278 (`didLoadMetadata:`, the waveform snapshot, `didDetectBPM:`, `didDetectKey:`). All four are "an async result landed; does it still match the current track?", all four implement the same cross-directory invariant, and none of them touch window state. Extracting them puts that invariant in one file with one header comment.
- **`+Window`** — construction, resize rules, occlusion, size presets, always-on-top, pitch-panel toggle. Pure geometry and AppKit lifecycle; shares nothing with playback.

That leaves ~700 lines of genuine coordination, which is the right size for a class whose job is coordination.

### C5. A stale worktree is shadowing the docs

`.claude/worktrees/worktree-folder-art/` contains a full second copy of the repo, including six older `CLAUDE.md` files (its `Vibe/Audio/CLAUDE.md` is 118 lines against the live 129). Any grep for an invariant returns both versions, and the stale one looks equally authoritative. Delete the worktree if it is finished, or add `.claude/worktrees/` to the ignore rules used by search tooling.

---

## D. The cross-cutting one: prose density

### D1. 26% of all lines are comments, concentrated exactly where the code is hardest

| File | Lines | Comment lines | % |
| --- | --- | --- | --- |
| `Audio/AudioPlayer.h` | 226 | 120 | 53% |
| `Main Window/TrackDisplayController.h` | 189 | 103 | 54% |
| `Audio/Metadata/AudioTrackMetadataCache.m` | 528 | 213 | 40% |
| `Main Window/ArtworkDisplayController.m` | 357 | 133 | 37% |
| `Audio/Metadata/AudioTrackArtwork.m` | 310 | 105 | 34% |
| `Audio/AudioPlayer.m` | 2,126 | 648 | 30% |

Root `CLAUDE.md` says: *"Comments only when required, and terse. A comment earns its place by stating what the code cannot show."* The comments here overwhelmingly *do* state what the code cannot show — they are traps, orderings, and hard-won whys, exactly as instructed. The problem is not any individual comment. It is that at 40% density the code is no longer skimmable: a reader scrolling `AudioTrackMetadataCache.m` for the parse path passes four screens of correct, valuable prose to reach it.

**Proposal — and this is a judgment call worth making explicitly.** Two moves, neither of which deletes knowledge:

1. **Hoist the file-level "why" to the header, leave only the pointer inline.** `AudioTrackMetadataCache.m` explains the two-stage scan three times (lines 18–34, 110–159, 161–189). One explanation in the header plus `// Stage 1; see the header.` inline would cut ~60 lines without losing a fact.
2. **Adopt a `TRAP:` marker convention.** The codebase already uses it in `CLAUDE.md` files but not in sources. Marking the ~40 genuinely load-bearing "if you change this it breaks" comments — and letting the rest shrink — gives a reader a way to skim for danger. `grep -rn 'TRAP:' Vibe` becomes the newcomer's first command.

Not proposed: any across-the-board comment cull. The `/clean_comments` skill in this repo will happily do one, and on this codebase that would be a net loss.

### D2. The `CLAUDE.md` files have outgrown their format

`Vibe/Audio/CLAUDE.md` is 129 lines of continuous prose covering playback, FLAC conversion, FX, metadata, folder artwork, devices, waveform data, and two analyzers — with individual paragraphs running past 400 words. It is accurate and it is the best single document in the repo. It is also the *only* place several invariants exist, and finding one means reading it linearly.

**Proposal.**

- Split by directory the way the code is: `Vibe/Audio/Metadata/CLAUDE.md` (with B1's diagram), `Vibe/Audio/Convert/CLAUDE.md`, `Vibe/Audio/Analysis/CLAUDE.md`, `Vibe/Audio/Waveform/CLAUDE.md`. Nested `CLAUDE.md` files load on demand, so this also cuts what a reader working on the FX graph has to hold.
- Leave `Vibe/Audio/CLAUDE.md` as the playback engine plus a subsystem index.
- In each, put the **invariant list first, as a list**, and the discursive "here is why we tried three things" second. The folder-artwork section is the clearest case: nine bullet-paragraphs of cost rules, each of which is a testable invariant, buried under a paragraph of motivation.

---

## Suggested order

Value per hour, highest first:

1. **B1** — the metadata/art map. Half a day, no code, and it is the thing that was actually asked for.
2. **A1** — execute the existing naming plan. It is already specified end to end.
3. **C1 + C2** — get debug out of production headers, split `DebugUtil.m`. Mechanical, verifiable by grep.
4. **D2** — split `Vibe/Audio/CLAUDE.md`; **C5** — kill the stale worktree.
5. **B3 + B4** — the art state table and the accessor renames.
6. **A2 + A4** — the suffix and art-vocabulary renames, once the glossary from A1 exists to justify them.
7. **B2, B5, C3, C4** — the structural moves. Each is a contained afternoon; none unblocks the others.
8. **A6** — the check target, once there is something to check.

Nothing in this list changes behavior. `make build CONFIG=Debug && make test` after each, plus `xcodegen generate` for anything that moves or renames a file.
