# Reopen last playlist on launch (macOS)

## Context

Vibe on macOS starts empty every time. Close the app mid-crate-dig and the playlist you
assembled — a folder walk, a handful of dragged-in files, wherever you were in it — is gone.
iOS already solves this: `FolderSession` persists a folder bookmark plus the last track's
filename, `VibeiOSSceneDelegate.m:38-51` restores it when no URL open is pending, and it lands
on `PlaybackController.parkCurrentTrack` — *"everything renders, nothing plays"*.

macOS has none of it. No playlist state is persisted anywhere (the only `NSUserDefaults`
writers are `AppSettings`, `AppStats` and `FolderAccessManager`; nothing uses Application
Support), and `PlaylistController.play:` is the only way to load a list — it unconditionally
calls `[self.audioPlayer play:track]`.

**Decisions taken during planning:**

| | |
| --- | --- |
| UI | A switch, not a dropdown — "Reopen last playlist", off by default |
| Behavior | Playlist restored, last-played track selected and rendered, **transport stopped at 0:00** |
| Scope | macOS-only; iOS's unconditional `FolderSession` restore is untouched |
| Sandbox | Per-file app-scoped bookmarks, minted only for files no granted folder covers, capped |
| Bad rows | Kept, not dropped — an unmounted volume comes back next time it's mounted |
| Store | A plist in the app's Application Support container |
| Scale | Must work at 50k+ tracks, so **no truncation** |

Bookmarking never raises a dialog: `bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope`
either succeeds or returns an error, which `FolderAccessManager.m:525-533` already relies on.
Minting only for files the process *already holds access to* — the drag, open-panel or Launch
Services extension that put them in the playlist is still live — keeps us clear of the standing
guarantee that unasked-for background work must never probe an ungranted folder. A file a granted
folder already covers needs no bookmark of its own and gets none; the two rules are the same rule
seen from each side.

---

# Part 1 — The parked display state

The hard half. Everything else is plumbing.

## 1.1 Why a sixth state is required

`VibeResolveTrackDisplayState` (`TrackDisplayRules.h:39`) has no representation for *"a row is
current but nothing was ever submitted"*. With `currentTrack` non-nil and `playerTrack` nil,
the gap test at `:66` returns **`Loading`** — permanently. A naive restore renders title,
artist and art correctly and then sits on `--:--` forever.

None of the five existing states fits:

- **`Track`** requires `playerTrack == currentTrack`, and `renderState:` takes duration from
  `audioPlayer.duration`, which is **0** — the right label would show `0:00`, not the length.
  `renderPosition:` would also admit ticks that clobber the resting pin.
- **`Loading`** renders `--:--` for both times *by design* (`TrackDisplayController.m:233-238`).
- **`Empty` / `LaunchGrace` / `Error`** all mask the track to nil in `displayedTrackForState:`
  (`MainPlayerController.m:404-414`).

So: add `TrackDisplayStateParked`, keyed off a **weak** `_parkedTrack` mark modelled exactly on
the existing `_erroredTrack` mask (`MainPlayerController.m:62`). Weak is load-bearing for the
same reason it is there: a playlist replacement deallocates the track and dissolves the mark.

```objc
typedef NS_ENUM(NSInteger, TrackDisplayState) {
    TrackDisplayStateTrack,
    TrackDisplayStateLoading,
    TrackDisplayStateParked,      // loaded and rendered; nothing was submitted
    TrackDisplayStateEmpty,
    TrackDisplayStateLaunchGrace,
    TrackDisplayStateError,
};
```

with a new `parkedTrack` argument resolved after the error test and before the gap test:

```objc
    // The relaunch restore's landing. The player was never asked for this row,
    // so its currentTrack is nil and the gap test below would read the park as
    // an open in flight, forever. The two marks are mutually exclusive by
    // construction: parking clears the error mask, and the play that can
    // produce an error clears the park.
    if (currentTrack == parkedTrack) {
        return TrackDisplayStateParked;
    }
```

Nothing serializes the raw enum values, so inserting mid-enum is safe. **Two header preambles
become false and must be corrected** — `TrackDisplayRules.h:10-13` (*"parks tracks the mac
never does"*) and its iOS twin `PlayerScreenRules.h:9-13`, which enumerates iOS's parks as *"a
relaunch restore, the end of the playlist, a media-services reset"* and says the mac has no
equivalent. The mac will have two of the three.

`displayedTrackForState:` returns the track for `Parked`, joining `Track`/`Loading`.

> *A `BOOL playRequested` input reusing `Track` was considered and rejected: `Track` sources its
> duration from the player, which holds no file, so the right label would read `0:00`.*

## 1.2 Rendering

A duration resolver beside `displayedTrackForState:`:

```objc
// What the header's right label and the Now Playing publish describe. Parked,
// the player holds no file at all, so its duration is 0 and the length must
// come from the track's own metadata — 0 until that lands, which renders as
// --:-- rather than 0:00.
- (NSTimeInterval)displayDurationForState:(TrackDisplayState)state track:(AudioTrack *)track {
    return state == TrackDisplayStateParked ? track.duration : self.audioPlayer.duration;
}
```

Used in `renderTrackPresentationForState:track:displayTrack:` (`:422`) and
`updateRateDependentUI` (`:824`).

**`updateRateDependentUI` must be restructured to one `currentTrack` read.** It currently passes
`state:[self displayState]`, and `displayState` reads `playlistController.currentTrack` itself; a
resolver taking `(state, track)` beside it would be a second read — exactly what the TRAP on
`displayedTrack` (`MainPlayerController.m:392-398`) forbids, and the same shape of bug it was
written for. Take one read and derive both, as `updateUI` and `updateNowPlaying` already do.

`TrackDisplayController.m`:
- `renderState:` — `Parked` joins the `Track`/`Loading` case for alpha, labels and codec line,
  then takes a third time branch beside the `Loading` one at `:232`: elapsed pinned to a real
  `0:00`, right label the track's length once metadata lands, `STR_LABEL_TIME_UNKNOWN` until.
  **That branch owns two values nothing else will write, because `renderPosition:` early-returns
  for `Parked`.** `_lastPosition` must be set to **0**, not left at the `-1` the `Loading` and
  empty branches poison it with: `renderRightTimeLabelWithDisplayPosition:MAX(0, _lastPosition)`
  reads it, so in remaining-time mode `-1` renders `-3:46` for a 3:45 track.
  `_waveformView.progress` must likewise be pinned to 0 here rather than inherited.
- `renderPosition:` (`:292`) — leave the guard as is. `Parked` falls out of the `Track ||
  Loading` test and early-returns, which is exactly what stops a stray tick clobbering the
  resting pin. Update its doc comment.
- `renderTotalDuration:` (`:345`) — admit `Parked`, so the pitch fader keeps the wall-clock
  length honest while parked. Its `duration <= 0` guard already holds the `--:--` until the
  track's metadata duration lands.

**Why a state and not a one-shot pin.** `advanceOrParkAtTrackEnd` (`+PlayerEvents.m:201-237`)
pins the end-of-playlist park by calling `resetPlayheadToStartWithDuration:rate:` *after*
`updateUI`. That works there because the state is `Track` and little follows. A restore park is
long-lived — every metadata delivery, folder-art resolve and appearance flip re-runs `updateUI`
— so the resting values must be **re-derivable from the state**, not pinned once.

## 1.3 The two new methods

`PlaylistController` — split `play:` (`.m:393`), which is three lines ending in `[self play]`:

```objc
- (void)loadURLs:(NSArray<NSURL *> *)urls selectingIndex:(NSUInteger)index {
    [_model replaceAllWithURLs:urls];
    // The replacement already reset the index to 0 and notified, so move it
    // only when the restore names a different row: the index-change observer
    // repaints two rows and re-ranks the metadata neighborhood.
    if (index > 0 && index < _model.count) {
        self.currentIndex = index;
    }
    [self scrollCurrentTrackToVisible];
}
```

**The clamp is load-bearing** — `Playlist.setCurrentIndex:` (`Playlist.m:43-47`) does not
range-check, the same trap iOS documents on `selectTrackAtIndex:`.

`MainPlayerController.restorePlaylistURLs:currentIndex:` then parks. Read the park beside
`performPerTrackRefreshForStartedTrack:` (`+PlayerEvents.m:105-154`) — it makes every direct
call a track start makes, and none of the ones a start *implies*:

| Called | Why |
| --- | --- |
| `_emptyStateSuppressed = NO` | a real track supersedes the launch grace, as `play:` does |
| `metadataCache cancelScan` | before the replacement, same rule `play:` states at `:568` |
| `clearErrorMask` | |
| `metadataCache loadMetadataNow:` | fills title, artist, codec line, art **and `track.duration`** — the parked right-hand label |
| `scheduleDeferredMetadataLoad` | *not* `startPendingMetadataLoad`; the 2s fallback is exactly right here |
| `artworkController trackDidStartPlaying:` | art-memory **ownership**, not playback. Skip it and `_artOwnerTrack` stays nil, so this track's 4–9 MB decoded bitmap is never demoted |
| `prepareForWaveformLoad` + `loadWaveformForTrack:` | see below |
| `fileConverter refreshDestinationStateForTrack:` | Convert menu validation reads that cache |
| `_lastReloadedTrack = track` | the row was just drawn; without the mark `updateUI` rebuilds it and disturbs the indicator's demand balancing |
| `updateUI`, `syncEqualizerActivity` | |

| Deliberately skipped | Why |
| --- | --- |
| `noteNewRecentDocumentURL:` | already in Open Recent; re-noting reorders the menu every launch with nothing opened |
| `prefetchTrack:` | a file open — on a provider, a full download — for a track nobody asked to hear |
| `AppStats playbackStarted` | nothing is playing |
| `resumeUIUpdateTimer` | call `updateUI` directly |
| the Now Playing publish | see 1.4 |
| `_currentTrackDuration = player.duration` | leave 0; the resolver above supplies the length |
| everything in `didBeginLoading:` | there is no open in flight |

**Waveform: load it — but not on a dataless file.** The restored track is by definition the
last thing played, so it's almost always a PINCache disk hit — a stat and a serial read on the
2-wide lookup lane, no decode. On a miss the decode lane is a separate 3-wide utility scheduler
with nothing playing to starve, and on macOS that same pass runs the BPM/key analyzers, so the
header's tempo/key line fills in too. iOS does the same via its pager.

**TRAP: the waveform decode does not go through `AudioFileMaterializationCoordinator` at all.**
There is no waveform *materialization* role — `VibeAudioFileMaterializationRole` is
`{Playback, Prefetch, MetadataPriority, MetadataScan}` — and `VibeWaveformLoadClaim`
(`AudioWaveformCache.mm`) is single-flight ownership of a **decode**, not of a transfer. The
decode opens the file directly: `AVFAudioWaveformLoader.mm:118-131` asks
`url.failsAudioOpenPreflight`, whose first act is a plain `open(O_RDONLY)`
(`NSURL+AudioOpen.m`). On a dataless placeholder that materializes the file synchronously —
outside the transfer lanes, outside `CloudTransferRegistry` (so no row indicator and nothing in
`dump_row_loading` or `dump_cloud_health`), without setting `isForegroundTransferActive` (so it
*races* the t=2s sweep rather than being ordered against it), on an uncancellable `open()`
holding a decode-scheduler slot.

This never bites today because `loadWaveformForTrack:` is only ever reached from
`performPerTrackRefreshForStartedTrack:`, by which point the player has already materialized the
file through the coordinator. **The park would be its first caller on an unmaterialized file.**
So the park probes once and **skips the waveform load when the file is dataless**, leaving it to
the first real play, whose open goes through the coordinator properly. A local file — the
overwhelmingly common case — loads exactly as described above. Verify under `set_fake_cloud`
before shipping.

## 1.4 Now Playing

`Mac/MainWindow/CLAUDE.md`: *"Nothing is published until the first track plays, so Vibe does
not steal Now Playing at launch."* Honor it — but **do not bail before the call**. In
`updateNowPlaying` (`+NowPlaying.m:21`) resolve the *published* track to nil when the state is
`Parked` and call `updateWithTrack:` normally. `NowPlayingController` already implements the
silence rule for a nil track (`_hasPublished`/`_publishedURL`, `NowPlayingController.m:265-278`),
and it deliberately applies `hasNext`/`hasPrevious` command availability **before every early
return** — *"so that command availability tracks the playlist boundaries even when the
now-playing info itself is unchanged, or not yet published"* (`:253-263`). Bailing before the
call skips that, leaving the next/previous remote commands at their `registerCommands` default of
enabled after a one-track restore. Passing nil also does the right thing if a park ever follows a
real publish, which the trap-6 follow-on would introduce.

The *header's* displayed track is unaffected: `displayedTrackForState:` still returns the track
for `Parked`. Only the publish sees nil.

Safe against `check_consistency`, and the four checks that could plausibly fire were all read:
`nowplaying.cleared_without_track` fires only for *published without a displayed track*, never
the reverse; `nowplaying.duration_matches_track` is inside `if (published && displayed)`. The
two cloud checks gated on `player.isStopped && !isLoading` — a condition the park satisfies —
also stay quiet: `cloud.hold_outlives_playback` needs a playback claim the park never takes, and
`cloud.handle_open_stranded` counts only `VibeAudioFileOpenPurpose` opens, all three of which are
the player's.

Consequence to accept: media keys and Control Center do nothing until Play is pressed once.
`nowPlayingControllerPlay:` already routes a stopped player through `playlistController play`,
so it is correct the moment a card exists.

## 1.5 Teardown — at submission, not at settlement

**One line, one site.** `playWillStartHandler` (`MainPlayerController.m:205-216`) fires from
`PlaylistController.play` immediately after the play is submitted; add `clearParkedMark` there.
That single site covers double-click, Return, `next:`/`previous:`, `playPause:`, the Now
Playing Play command and the debug `play_index` — all of which funnel through
`PlaylistController.play`. This is precisely what the handler exists for.

**Submission, not settlement, is the point.** A submitted play reads `isStopped` YES with a nil
player track until `didStartPlaying:`. If the mark survived, the resting `0:00 / 3:45` would
sit over the whole Loading gap of a slow cloud open — the stale-header failure
`playWillStartHandler` was created to fix.

Pressing Play needs nothing else: `playPause:` (`.m:545`) already routes a stopped player to
`[self.playlistController play]`.

## 1.6 Traps

1. **Anything that mints a fresh `AudioTrack` for the current row re-points the mark.**
   `replaceTrackAtIndex:withURL:` mints a *fresh* `AudioTrack` (`Playlist.m:181-185`), so the weak
   `_parkedTrack` stops matching `currentTrack`, the state falls to `Loading`, and the header
   goes to `--:--` with no open in flight. **Two callers reach it**, and both must carry the park:

   - The convert swap. The site is `MainPlayerController+Convert.m`'s `swapConvertedTrack:toURL:`,
     *not* `Playlist.replaceTrackAtIndex:` — that is model-level and must stay ignorant of the
     park. While parked the player is **Stopped**, so `wasPlaying` is NO and `wasLoaded` is NO
     (`isPaused` is NO too), and control reaches `else if (wasCurrent) { [self updateUI]; }` —
     the same branch the end-of-playlist park uses. Re-point there, before the `updateUI`.
   - The restore's own bookmark resolution, when a bookmark resolves to a *different* path
     (§2.6). Same mint, same dissolved mark, and it lands on a track that is current by
     construction if the moved file is the restored cursor.

   Test both explicitly.

   *Pre-existing, adjacent, not this feature's to fix:* in that same `else if (wasCurrent)`
   branch the **end-of-playlist** park already resolves to `Loading` rather than `Track` after a
   swap — the player still holds the finished track object while the playlist holds the fresh one
   — so the header falls to `--:--` there today. Worth a decision while the branch is open.
2. **Any play that bypasses `PlaylistController.play` must clear the mark itself** — today only
   `+Convert`'s `play:atPosition:startPaused:` replay.
3. **Submission identity is untouched** — the park never calls `play:`, so nothing advances
   `_nextSubmittedPlayIdentifier` and no settlement can exist. But every stale guard keys off
   `playlistController.currentTrack`, and a parked track *is* current, so metadata and waveform
   deliveries pass. That is what we want.
4. **Equalizer demand stays balanced by construction** — `equalizerAudioOutputActive` is NO, so
   the indicator draws collapsed dots, never starts its poller, `_levelConsumers` stays 0.
5. **Skips are correctly refused** — both `skipByFileSeconds:` and menu validation gate on
   `!isStopped`.
6. **Waveform click-to-seek is a dead control while parked** — it multiplies by
   `audioPlayer.duration` = 0. Harmless but odd. iOS solves it by opening at the scrubbed
   position *paused*; the mac already has `play:atPosition:startPaused:`. **Scope as a separate
   follow-on**, and it must clear the park mark itself.
7. **The metadata sweep at t=2s is ungated by the foreground rule**, since no Playback claim
   exists. On a cloud folder that is a playlist-wide pass at launch for a playlist the user has
   not touched. Bounded by the existing lanes, but measure it. §1.3's dataless-waveform skip is
   what keeps this from being worse than it sounds: a waveform decode on a placeholder would
   download *outside* those lanes and race the sweep rather than queue behind it.

---

# Part 2 — Persistence

## 2.1 Why not save only on exit

Two independent reasons, the second decisive:

1. `applicationWillTerminate:` does not run on a crash or a Force Quit. "I lost my crate" is the
   exact moment this feature exists to prevent.
2. **`NSSupportsSuddenTermination` is `YES`** (`project.yml:242`, `Vibe/Mac/App/Info.plist:107`),
   so even an *ordinary* quit can be a `SIGKILL` that never runs the callback. This is exactly
   why `AppStats` brackets its listening clock with
   `disableSuddenTermination`/`enableSuddenTermination` (`AppStats.m:87,101`).

So saving is continuous-and-debounced, with the same sudden-termination hold `AppStats` uses:
**take the hold on the dirty edge, release it when the write completes.** That is what makes a
2-second debounce survive a quit. The terminate flush then only shortens the window to zero for
the ordinary path — it is the last line of defence, not the mechanism.

**Be precise about what the hold buys, because it is easy to over-credit.** It forces the
*ordinary* quit down the `applicationWillTerminate:` path instead of letting it be a `SIGKILL`.
It does **nothing** for a crash, a Force Quit or an external `kill -9` — against those the only
protection is the 2-second debounce window itself, and losing at most two seconds of playlist
edits is the accepted cost. Reason 1 above is served by the debounce; reason 2 is served by the
hold. They are not the same mechanism and the verification has to test them separately.

Quit must also stay cheap, which shapes the rest: `flushNow` writes with whatever bookmarks are
already minted and **mints nothing** (see §2.5 for the queue split that makes that safe). A quit
must not block on 500 bookmark creations, and a row that misses its bookmark is kept and merely
unreadable — already the documented behavior.

## 2.2 The store — `LastPlaylistStore`

New files `Vibe/Mac/App/LastPlaylistStore.{h,m}` plus the seam `LastPlaylistRules.h`.

`Vibe/Mac/App/CLAUDE.md`'s ownership test is *"`AppDelegate` creates it, or the OS hands it to
`AppDelegate`; a service used by several features but owned by none lives here."* `AppDelegate`
restores it at launch and flushes at terminate, `MainPlayerController` feeds it, the Settings
pane and debug table read it — exactly `FolderAccessManager`'s and `AppStats`'s situation, in
the directory that already owns sandbox-grant knowledge. `Playlist/Mac/` is the table half and
must stay ignorant of the app shell. Singleton, like both neighbours.

Named `Store` after the live precedent `SearchFolderStore` (iOS: bookmark-backed,
restore-at-launch, persist-on-change — same shape, same word; it persists to `NSUserDefaults`
rather than to a file, so the precedent is the *name and shape*, not the storage) and
deliberately **not** `Coordinator`, which the root vocabulary table reserves for three specific
contracts, none of which this is. `snapshot` is used in its exact sense: main takes an immutable
copy of the paths and cursor and hands it to the writer queue. `_saveGeneration`, never bare
(`make check-vocabulary` rule 1).

**Path.** `URLForDirectory:NSApplicationSupportDirectory …create:YES` — one call, and the
directory question answers itself. Not `URLsForDirectory:inDomains:`, which answers a path that
may not exist in a fresh container and creates nothing. **No `Vibe/` subdirectory**: the
nesting convention exists because unsandboxed apps share `~/Library/Application Support`;
inside the container it is already app-private. Never call it on main — `create:YES` touches
the disk. `make reset-state` already wipes the whole container.

## 2.3 File format — two files, split by write frequency

**This split is the whole 50k story.** The rows change on a handful of user-initiated events;
the cursor changes on every track advance. One file would mean rewriting ~4 MB, and
re-snapshotting 50k tracks, because you pressed Next.

```
…/Application Support/<bundle-id>/
    LastPlaylist.plist        rows + bookmarks — written only when the list changes
    LastPlaylistCursor.plist  ~200 bytes       — written when the cursor moves
```

```objc
// LastPlaylist.plist — a flat string array plus a side table, NOT an array of
// per-row dictionaries: at 50k that shape costs 50k NSDictionary allocations
// on both read and write for two keys. Binary plist serializes a string array
// through an offset table and reads back in one call.
@{
    @"version":   @1,
    @"paths":     @[ @"/Users/…/01.flac", @"/Users/…/02.flac", … ],
    @"bookmarks": @{ @"/Users/…/Desktop/b.mp3": <NSData> },   // uncovered files only
}

// LastPlaylistCursor.plist
@{
    @"version":      @1,
    @"currentIndex": @(42),
    @"currentPath":  @"/Users/…/42.flac",   // wins if it disagrees with the index
    @"rowCount":     @(50000),              // fingerprint against the rows file
    @"lastPath":     @"/Users/…/z.flac",    // fingerprint
}
```

`path`/`bookmark` naming matches `FolderAccessManager`'s own `kEntryPathKey`/`kEntryBookmarkKey`
— it is what the coverage predicates take, and `fileURLWithPath:` is the app's one way back to
a URL everywhere else. `currentPath` alongside the index because a bare index can outlive the
list it was written for, matching iOS's `persistedTrackFileName`.

**Consistency across the two files: ordering plus a fingerprint.** Rows written first, cursor
second, both `NSDataWritingAtomic` (so a mid-write truncation cannot happen). A crash between
them leaves a cursor file describing rows that no longer match, so `rowCount` and `lastPath` are
checked against the loaded array; on mismatch the cursor is discarded and the rows restore at
index 0 rather than throwing the playlist away. A wrong `version` or a non-dictionary root
deletes the file and treats it as absent, rather than partially trusting it. Reader rules live
in `LastPlaylistRules.h` so they are host-lessly testable.

**TRAP: a rows write must ALWAYS write the cursor too, in the same pass.** The fingerprint is
what makes this load-bearing rather than tidy. The rows and the cursor debounce independently
(§2.5), and the cursor is marked dirty only by a cursor move — but a rows change *invalidates the
fingerprint of a cursor file it never touched*. Concretely: playing track 42 of 100, drag 20 more
files in. The rows file is rewritten with 120 rows and a new `lastPath`; the cursor file still
says `{42, rowCount 100, lastPath <old>}`; the fingerprint rejects it; the next launch restores
at index 0. Dropping files onto a playing app would silently lose the cursor. The cursor file is
200 bytes and needs no bookmarks, so there is no reason for a rows write ever to land alone.

**Caps** — both logged when they bite, no silent truncation:
- `kMaxSavedRows = 100000`. A **sanity backstop only** — past it, save nothing rather than a
  misleading prefix. Explicitly *not* a windowed excerpt around the cursor: the requirement is
  that 50k works, and a silently-halved playlist is worse than none.
- `kMaxBookmarks = 500` uncovered files, **minted current-row-first, then playlist order**, so
  if the cap bites, the track the user is on keeps the bookmark that makes it playable. Beyond
  it a path is saved with no bookmark. Each restored bookmark holds a security scope for the
  process lifetime and sandbox extensions are a finite kernel resource. **A 50k playlist came
  from a folder open, so its bookmark count is zero.**

## 2.4 Scaling to 50k+

| Cost | Handling |
| --- | --- |
| **A cursor save** | Reads `currentIndex` and `currentTrack.url.path` and nothing else, then writes ~200 bytes. It must **never call `playlistController.playlist`**, which is `[_tracks copy]` (`Playlist.m:49`) — a 400 KB array copy at 50k. This is the single most important perf rule in the design |
| Redundant cursor writes | `Playlist.setCurrentIndex:` (`.m:43-47`) notifies **unconditionally**, even when the value did not change. The store compares against the last-saved cursor and drops the write |
| Coverage test per file | `canReadInsideDirectory:` (`FolderAccessManager.h:58` — public, any-thread, reads the atomic snapshot, folds in the `~/Music` entitlement) memoized **per parent directory, for one save pass only**. A 50k playlist is usually a handful of folders, so this is a handful of calls, not 50k. The memo cannot outlive the pass: the method's own contract is *"A NO answer can be stale by one grant; `FolderAccessManagerDidChangeNotification` is the signal to reconsider"*, and a cached YES that `removeFoldersAtIndexes:` later invalidates would silently stop minting bookmarks for files that now need one. *(The `path:isCoveredByAnyOf:` class methods are unusable here — they take the granted array, and `activePathSnapshot` is private.)* |
| Bookmark minting | Only uncovered files, capped, and `_bookmarksByPath` caches every blob and is seeded from the file at restore — so a save after an append mints only the new folders' files, and a cursor save mints nothing |
| Snapshot on main | Per **rows** save: `[_tracks copy]`, then a map to `NSArray<NSString *> *paths` — both on main, so no `AudioTrack` ever crosses to `_ioQueue`. That is a 50k-element map, not just the array copy; it is the same order as the open that produced the list, and the debounce caps it at one per 2s, but the table should not pretend it is free. Only the finished path array crosses. Minting and serialization run on the serial utility `_ioQueue` |
| Restore read | Both file reads, the parse and the path→URL mapping all off-main; only the finished `NSArray<NSURL *>` crosses to main |
| Resolving `currentPath` | Check `paths[currentIndex]` first and scan only on a mismatch — never a 50k linear scan in the common case |
| Bookmark resolution | Capped at 500, bounded concurrency (~4, matching `VibeFolderAccessRestoreConcurrencyLimit`), **current row first**, behind its own deadline. The deadline bounds the *waiting*, not the work: a row whose bookmark is still resolving is already present and merely unreadable, and a scope that arrives after the deadline is still started, because it costs nothing and makes the row playable. `unresolvedBookmarks` is therefore a live count, not a settled one |

The irreducible cost is `replaceAllWithURLs:` → `addTracksForURLs:` minting 50k `AudioTrack`s
and filling both indexes (`Playlist.m:85-93`) on the main thread. That is **identical to what
opening a 50k-track folder costs today** — `withURL:` sets three fields and the cache key is
memoized lazily — so it is not new work, but it now sits before first paint at launch and is
worth measuring.

**The restore pays `playlist` twice, though, and that IS new.** `replaceAllWithURLs:` fires
`playlistDidReplaceAllTracks:`, which calls `notifyCurrentIndexDidChange`, which calls
`setNeighborhoodAroundIndex:inTracks:playlistController.playlist` — a `[_tracks copy]`. Then
`loadURLs:selectingIndex:`'s `self.currentIndex = index` fires the index-change observer and does
it again. Two 400 KB copies and two neighborhood computations on main before first paint, from a
method whose own comment calls the index move cheap. Given that this table makes *"never call
`playlist`"* the single most important perf rule, this deserves either a fix (set the index
before the notify, which needs a `Playlist` change) or an explicit measurement — not silence.

*(Related observation, pre-existing and not this feature's to fix: the current
`currentIndexDidChangeHandler` already calls `playlist` on every track advance, so the app
already pays that 400 KB copy per skip.)*

**Deliberate non-optimization:** appends rewrite the whole rows file rather than appending
incrementally. Appends are user-initiated, rare, and the write is off-main; incremental append
would complicate the fingerprint for no real gain.

## 2.5 When saving happens

`Playlist` has one observer slot and `PlaylistController` holds it, so all five mutation kinds —
replace, append, clear, the Convert row swap and the cursor — land on `PlaylistController`'s
four `PlaylistObserver` callbacks (`.m:160-205`). **That is the mac's one playlist-change
point.** Add a block beside the existing `currentIndexDidChangeHandler`:

```objc
// Fires after any change to the rows or the cursor — replacement, append, row
// swap, index move — with rowsChanged NO for a bare cursor move. It is the
// mac's one playlist-change funnel, and exists so that work following the LIST
// rather than the playback state has a single place to hang. The flag is not a
// nicety: a 50k playlist must not be re-snapshotted because the cursor moved.
@property (nonatomic, copy, nullable) void (^playlistDidChangeHandler)(BOOL rowsChanged);
```

`rowsChanged` is `YES` from `playlistDidReplaceAllTracks:`, `didAppendTracksAtIndexes:` and
`didReplaceTrackAtIndex:`; `NO` from `currentIndexDidChangeFromIndex:`. `Playlist/Mac/` stays
store-free — the shell owns the wiring, exactly as it does today for
`currentIndexDidChangeHandler` → `metadataCache`. There is no drag reorder or row delete on
macOS yet; when either arrives it goes through `Playlist`, so through this funnel, for free.

**TRAP: a replacement produces NO cursor edge.** `Playlist.replaceAllWithURLs:` assigns
`_currentIndex = 0` to the *ivar*, not through the setter, so `currentIndexDidChangeFromIndex:`
never fires for it; `playlistDidReplaceAllTracks:` calls `PlaylistController`'s own
`notifyCurrentIndexDidChange` hook instead, which is a different thing. A replace, an append and
a row swap therefore each produce exactly one `playlistDidChangeHandler(YES)` and nothing else.
That is why the rows write carries the cursor with it (§2.3) rather than trusting a separate
cursor edge to follow.

Coalescing: `kSaveDebounce = 2.0` quiet period, plus `kSaveDeadline = 10.0` — **never defer
longer than the deadline**, or a stress run of continuous skips would never persist at all.
Rows and cursor debounce independently, so a burst of skips never re-arms a rows write.

**The sudden-termination holds are counted and must balance.** Two independent debounces mean two
hold/release pairs against one *process-global* counter that `AppStats` also uses
(`AppStats.m:87,101`), so the discipline has to be written down rather than inferred: each dirty
edge takes exactly one `disableSuddenTermination`, and every terminal path releases exactly one —
write completed, write failed, `flushNow`, the setting turned off, and the empty-playlist delete.
A leaked hold leaves the app permanently ineligible for sudden termination; an extra release
corrupts a counter another subsystem depends on.

**Two launch gates, both required:**

- `_launchSettled` — saving is refused until the restore, `skipRestore`, or any open has run.
  Without it the *empty* launch playlist saves over the remembered one before the restore ever
  reads it. Idempotent; `openURLs:appending:` closes it too, so an open that lands while the
  restore's file read is still in flight wins. **A restore that finds nothing closes it as
  well** — the fresh-install path (`startAndDrainQueue` NO, no saved file, `restored: NO`) is the
  one that has to be spelled out, because getting it wrong means the feature saves nothing at all
  until the user has quit and relaunched once.
- `_applyingRestore` — suppresses the save our own restore would otherwise trigger. The
  observer callbacks fire **synchronously** from `replaceAllWithURLs:` (verified,
  `Playlist.m:68-73`), so a plain flag around the call is sufficient.

An **empty** playlist deletes both files rather than writing an empty list.

`applicationWillTerminate:` gains `[LastPlaylistStore flushNow];` beside the existing `AppStats`
flush — the class method, so an off setting costs one BOOL read and instantiates nothing.

**TRAP: nothing `flushNow` waits on may be able to block on a mint.** A bookmark mint can block
for an automounter timeout on an unreachable volume, and a synchronous quit-time hop onto a queue
that can be doing one would hang the quit.

The structural fix, rather than a rule to remember: **`_ioQueue` serializes the writes and nothing
else; minting runs on a second queue** and publishes its results back to `_ioQueue`. Then
`_ioQueue` can never block on a mount, `flushNow` may `dispatch_sync` onto it safely, and the
rows-then-cursor ordering the fingerprint depends on holds for free — including at quit.

The alternative shape — the io queue publishes an immutable bookmark map to main and `flushNow`
writes from main against that copy, minting nothing — was rejected because it has **no
interlock**: at quit, main can write the cursor file while `_ioQueue` writes the rows file from a
different snapshot. Both are atomic so neither file tears, but the write ordering is gone and
last-writer-wins can be the older snapshot. If it is adopted anyway, the interlock has to be
specified, not assumed.

In the overwhelmingly common case the only thing pending at quit is the 200-byte cursor file,
which needs no bookmarks at all.

## 2.6 Restoring

Every entry point is a **class method that reads the setting before touching `sharedInstance`**,
because Part 4's "never instantiated when off" is a stated requirement and a
`[[LastPlaylistStore sharedInstance] …]` at a launch call site breaks it outright. Same for
`flushNow` and for the debug dump's `lastPlaylist` block. `+restoreInto…:completion:` calls back
`NO` synchronously when the setting is off, so the off path is byte-for-byte today's.

```objc
[[FolderAccessManager sharedInstance] restoreGrantedAccessWithCompletion:^{
    // A launch-time open outranks the remembered playlist: the user asked for
    // this file by double-clicking it. Telling the store closes its launch
    // gate, so it starts remembering the OPENED playlist.
    if ([self->_openBurstCoalescer startAndDrainQueue]) {
        [LastPlaylistStore skipRestore];
        return;
    }
    [LastPlaylistStore restoreIntoPlayerController:self.mainPlayerController
                                        completion:^(BOOL restored) {
        if (!restored) {
            [self.mainPlayerController revealEmptyState];
        }
    }];
}];
```

**After the grant restore**, because a remembered row under a granted folder is unreadable until
that folder's scope has started — and most rows will have no bookmark of their own, that being
the whole point of "only mint what isn't covered". That completion is already deadlined at 2s,
so it cannot hang launch. **After the drain decision**, because the drain's answer is what
decides whether a restore is wanted at all.

**The restore's own read needs a deadline too.** `revealEmptyState` runs synchronously inside
that completion today; with the feature on it moves behind two file reads and a parse on
`_ioQueue`, so a stalled container read would leave the window in its launch grace — blank
header, nothing playing — with nothing to end it. Every other launch-blocking wait in this app is
explicitly deadlined for exactly that reason: `restoreGrantedAccessWithCompletion:`,
`awaitRestoredAccessForURLs:`, `kWaveformClaimWaitSeconds`. Give this one the same treatment, and
reveal the empty state when it fires.

**The restore goes through neither the coalescer nor `openURLs:appending:`.** It is not an
open: it grants nothing, must not touch `AppStats.recordOpenedFiles:`, must not mint folder
bookmarks through `noteOpenedURLs:`, and must not disturb the coalescer's quiet period — which
would turn a Finder open 0.2 s later into an **append onto the restored list** instead of a
replacement.

**Races, and why each is already correct:**

- *argv* (`openCommandLineArguments`, dispatched async off main for its `exists` checks): if it
  wins, `startAndDrainQueue` returns YES and the restore is skipped. If it loses, its survivors
  enter through `openBurstURLs:`, which after start drains immediately into a replacing `play:`
  — replacing the restored list, exactly as the existing comment at `AppDelegate.m:146-148`
  promises for the empty state.
- *A late Finder double-click*: same, drains immediately and replaces.
- *An open landing while the restore's file read is still in flight*: `openURLs:appending:` also
  calls `skipRestore`, and the restore's main-thread landing drops itself if the gate is already
  closed. Without this the restore would clobber a playlist the user explicitly asked for.

Landing: read + parse + seed the bookmark cache on `_ioQueue`; then on main, with
`_applyingRestore` set, `restorePlaylistURLs:currentIndex:`; then resolve bookmarks behind it.
**Rows land from their stored paths immediately** and bookmarks only supply the security scope,
so a row whose bookmark hasn't settled is present-and-possibly-unreadable rather than missing.
A stale bookmark is re-minted while its scope is open, as `FolderAccessManager.m:337-352` and
`SearchFolderStore.m:262-283` both do; one that resolves to a *different* path — the file moved
— lands on main as `replaceTrackAtIndex:withURL:`, the model's existing swap point.

That swap has two consequences the resolver owns. It fires `didReplaceTrackAtIndex:`, so it
reports a rows change and rewrites the file with the corrected paths — deliberately **not**
suppressed, since `_applyingRestore` is already cleared by then and the debounce coalesces a
burst of them. And it mints a fresh `AudioTrack`, so if the moved file is the restored cursor it
dissolves the weak `_parkedTrack` exactly as the convert swap does; the park must be re-pointed
here as well (trap 1).

## 2.7 Scope lifetime

**Started at restore, held for the process, never stopped.** `_scopedURLs` retains the exact
`NSURL` instances the starts were called on, and only those whose
`startAccessingSecurityScopedResource` returned YES — the balance discipline of
`ArtworkImageView.m:106-110` and `SearchFolderStore`.

The refcounting in `SearchFolderStore` exists only because an iOS row can be removed while a
grant handle still retains it. The last playlist has no per-row removal and no outstanding
handles, so a flat retain-and-never-stop array is the honest analogue — and it must be written
down as a rule: **nothing else may stop these scopes.** An unbalanced stop over-releases the
sandbox extension and revokes the whole playlist's access mid-session. In particular, turning
the setting **off** deletes the file but does *not* stop the scopes: those tracks are still in
the playlist and still have to play.

**`ArtworkImageView` does not interact, and the reason is worth recording.** It starts a scope
on `self.fileURL` at drag start. For a file whose access comes from our restored bookmark,
`fileURL` is a plain `fileURLWithPath:` URL built by `AudioTrack` — not itself security-scoped
— so that start returns NO, the view records nothing and stops nothing (its own comment already
covers this). The drag still works, because our extension is consumed process-wide.

---

# Part 3 — Setting, strings, UI, debug

## 3.1 The setting

`AppSettings`, **below** the `#if TARGET_OS_OSX` line — the header's preamble says the split is
one block and that which side a property sits on *is* the answer to "does iOS honor this?".
Key `#define SETTING_REOPEN_LAST_PLAYLIST @"Playlist.reopenLast"` (key families are by owner —
`MainWindow.*`, `Transport.*`, `Audio.*` — and this is neither window chrome nor transport).
Plain `boolForKey:`/`setBool:`, not hot-cached. One line `@(NO)` in `registerMacDefaultsInto:`,
which also gives `allSettingsAtDefaults` and `resetToDefaults` the key for free.

**No `SettingsRules.h` normalizer** — those exist for identifier strings and preset ladders
whose stored value can be a spelling no picker produces. A BOOL has no unknown value.

**Live-apply hook: `-[MainPlayerController applyReopenLastPlaylist]`**, public, matching the
`applyEndOfTrackAction` / `applyPitchRange` convention the other panes already use — the pane
talks to the player controller, not to the store. It does three things:

1. **Installs or clears `playlistController.playlistDidChangeHandler`.** This is what makes
   "off" cost nothing (Part 4).
2. **On**: marks the current playlist dirty, so the choice takes effect this session rather than
   at the next change. Through the debounce, not as an immediate synchronous save: on a 50k
   playlist an immediate save is a full rows snapshot plus up to 500 mints, hung off a switch
   click.
3. **Off**: deletes both files. Deliberate — a user turning off "remember my playlist" is
   asking the app to stop remembering, and leaving behind a plist of their file paths plus
   security bookmarks is a privacy surprise, not a convenience. The started security scopes are
   **not** stopped: those tracks are still in the playlist and still have to play.

**TRAP: something must call it once at launch, and it cannot be the restore.** The hook is the
only installer of `playlistDidChangeHandler`, and §2.6's launch-open branch calls `skipRestore`
and returns — so a user who has the setting on and double-clicks a file in Finder gets no
handler, and *that session's playlist is never saved*. Call it from
`MainPlayerController.wireWindowAndViews`, beside `applyAlwaysOnTop`, which is where the other
launch-applied settings already land. Installation is then orthogonal to whether the restore ran.

Because it has a hook, `SettingsAdvancedViewController.resetSettings:` (`.m:163-188`) **must
call it too** — `resetToDefaults` clears the key but not the files. Same shape as the existing
TRAP there about the two window-shape settings no pane shows.

## 3.2 Strings

`VibeStrings.h`, beside `STR_SETTINGS_ALWAYS_ON_TOP` (`:213`):

```objc
#define STR_SETTINGS_STARTUP_SECTION         NSLS(@"settings.general.startup_section", @"Startup", @"…")
#define STR_SETTINGS_REOPEN_PLAYLIST         NSLS(@"settings.general.reopen_playlist", @"Reopen last playlist", @"…")
#define STR_SETTINGS_REOPEN_PLAYLIST_CAPTION NSLS(@"settings.general.reopen_playlist.caption", @"The tracks come back in order. Playback does not start on its own.", @"…")
```

Sentence case, no trailing colon — matching the other switch row. The caption carries the
no-autoplay promise, which is the part a user would otherwise have to discover. Then
`make strings`.

**`make check-translations` is a release gate across all 30 catalog languages**, so all three
keys need translating before a release build. Use the `vibe-strings` skill; real work, not an
afterthought.

## 3.3 Settings UI

`SettingsGeneralViewController.m`: an `NSSwitch *_reopenPlaylistSwitch` from
`switchWithAction:`, in a new **Startup** section placed **first**, above Audio — it is a launch
behavior, not window chrome and not playback. Use the existing
`rowWithTitle:caption:control:` (`SettingsFormViews.h:22`) for the caption. State read in
`refreshFromSettings`; the action writes the setting then calls
`[self.playerController applyReopenLastPlaylist]` — the same two-line shape as
`toggleAlwaysOnTop:` (`.m:118-121`).

The pane grows by one row, so the base's shared-size pass re-maximizes every pane — nothing to
do, `paneContentDidChange` already runs after `refreshFromSettings`, but expect all panes
slightly taller. Re-run `dump_settings_ui` afterwards, per `Mac/Settings/CLAUDE.md`.

---

# Part 4 — Zero impact when the setting is off

The default is off, so this is the path almost every user is on. Audited call by call.

| Surface | Cost when off |
| --- | --- |
| **`VibeResolveTrackDisplayState`** | One extra `currentTrack == parkedTrack` pointer compare against a permanently-nil ivar. `displayState` runs from `updatePlaybackUI`, so at most the UI tick's rate — capped at 60 Hz, and normally the 3 Hz floor. **60 pointer compares per second, worst case.** |
| **`playlistDidChangeHandler`** | **Never installed.** `applyReopenLastPlaylist` installs it only when the setting is on, so the four observer callbacks do a nil-block test and nothing else. No block invocation, no `NSUserDefaults` read, no snapshot — per track advance or otherwise. |
| **`LastPlaylistStore`** | **Never instantiated.** Every entry point is a class method that reads the setting *before* touching `sharedInstance` — `+skipRestore`, `+restoreIntoPlayerController:completion:`, `+flushNow`, and the debug dump's accessor — so on the off path there is no object, no `_ioQueue`, no bookmark cache, no `_scopedURLs`, and no memory held. A `[[LastPlaylistStore sharedInstance] …]` at any launch call site breaks this outright, which is why the shape is a rule and not a preference. |
| **Application Support** | **Never touched — not even created.** The setting check must precede any call to `storeURL`, whose `dispatch_once` does `URLForDirectory:…create:YES`. Get this backwards and every launch with the feature off silently creates a directory. This is a stated requirement, not an implementation detail. |
| **Launch timing** | `+restoreIntoPlayerController:completion:` checks the setting **first** and calls back `NO` **synchronously**, so `revealEmptyState` runs on exactly the same turn it does today. No disk I/O, no deadline, no added latency — the launch path is byte-for-byte what it is now. |
| **`applicationWillTerminate:`** | `flushNow` early-returns on the setting. One BOOL read at quit. |
| **Sudden termination** | The hold is taken only on a dirty edge, which cannot occur — so the app stays eligible for sudden termination exactly as it is today. |
| **`playWillStartHandler`** | Gains `clearParkedMark`, one nil assignment per play. |
| **`+Convert`, `+NowPlaying`, `TrackDisplayController`** | One `state == TrackDisplayStateParked` comparison each on paths that already branch on state. |
| **Debug additions** | `Vibe/Debug/` compiles out of Release entirely. |

**The one unavoidable impact:** the Settings General pane gains a row, and pane sizes are
shared — so every pane, and the Settings window, gets slightly taller whether or not the
setting is on. That is the cost of the feature having UI at all.

**Reviewer's checklist for this property**, since it is easy to regress:

- `grep` every `LastPlaylistStore` reference and confirm each is either a class-method entry
  point that reads the setting first, or inside the store itself. A bare `sharedInstance` outside
  the class is the regression.
- Confirm `storeURL` has no caller that runs before a setting check.
- Launch with the setting off under Instruments and confirm no `LastPlaylistStore` allocation
  and no `Application Support` file operation.
- `dump_state | jq .lastPlaylist` with the setting off must report the store as absent rather
  than instantiating it to answer.

## 3.4 Debug surface

`DebugStateDump.m` — `reopenLastPlaylist` in the `settings` block (`:63-85`), so a test asserts
the *setting* and not just the control; the parked state exposed; and a `lastPlaylist` block
fed by a declaration-only `LastPlaylistStore+Debug` category under `Debug/Mac/Introspection/`
(no `#if DEBUG` in a shipping header — `make check-vocabulary` rule 4, no allowlist):
`fileExists`, `savedRows`, `savedBookmarks`, `savedCurrentIndex`, `dirty`, `savePending`,
`restored`, `restoredRows`, **`unresolvedBookmarks`**, **`scopesHeld`**, `skippedForOpen`. The
last two are the numbers no other signal reveals, and they are what a "moved the folder between
launches" test asserts. The category's *implementation* goes inside `LastPlaylistStore.m` under
`#if DEBUG`, the way `OpenBurstCoalescer.m` carries its own — the rule bans `#if DEBUG` in a
shipping **header**, not in a `.m`.

Four verbs in `DebugCommandTable.m` beside `set_folder_art`:

| Verb | Why it must exist |
| --- | --- |
| `set_reopen_playlist <on\|off>` | writes the setting **and runs the live-apply hook**, as `set_folder_art` does for a pane the injection verbs cannot reach |
| `save_last_playlist` | forces the flush, cancelling the debounce — otherwise every test races 2 seconds |
| `dump_last_playlist` | the store's state plus the first N stored paths and the index |
| `clear_last_playlist` | a first-launch state without `make reset-state` wiping settings, grants and caches too |

**Never log a path** from this store — counts only. (Info and debug are not persisted, but the
habit matters.)

---

# Verification

Unit (`make test`, host-less pure logic — read `Tests/CLAUDE.md` first):
- `Tests/TrackDisplayStateTests.m` — every `VibeResolveTrackDisplayState` call gains the new
  argument. New cases: parked with a nil player track resolves `Parked`; a cleared mark resolves
  `Loading`; error and park cannot both hold; a park mark for a non-current track is ignored.
- `Tests/LastPlaylistRulesTests.m` — schema-version and entry validation, the clamped cursor,
  both caps, and the fingerprint: a cursor whose `rowCount`/`lastPath` disagree with the rows must
  be discarded rather than trusted, and the rows must survive. Factor the plist encode/decode as
  **class methods over arrays** (no singleton, no disk) so a round-trip is testable without a
  container; `VibeTests` already compiles `FolderAccessManager.m` and `Playlist.m`.

Also, not a test but a sweep: `debugIsLoading` is `[self displayState] == TrackDisplayStateLoading`
(`MainPlayerController+DebugPlayerSurface.m:98`), so a sixth state leaves it correct — but read
every `!isLoading` consumer in `DebugConsistency.m` once and confirm each still means what it
says with `Parked` in play. They all currently read as "not mid-open", which the park satisfies.

End-to-end via the **`vibe-debug`** skill (Debug build — the channel compiles out of Release):

```bash
"$V" --debug-cmd set_reopen_playlist on
"$V" --debug-cmd open ~/Music/album && sleep 2
"$V" --debug-cmd play_index 5
"$V" --debug-cmd save_last_playlist
"$V" --debug-cmd quit
# relaunch, then:
"$V" --debug-cmd dump_state | jq '.playlist.count, .playlist.currentIndex, .player.state'
#   → the row count, 5, and "stopped" — the restore must NOT autoplay
"$V" --debug-cmd dump_last_playlist | jq '.savedBookmarks, .unresolvedBookmarks, .scopesHeld'
```

| Check | Verb |
| --- | --- |
| The park renders | `dump_state`: **`ui.currentTime == "0:00"`**, `ui.totalTime` the real length (not `--:--` once metadata lands), title/artist/bpm/key populated |
| Now Playing not stolen | `dump_now_playing` → `hasInfo: 0`. **Run without `--no-audio-hw`**, which suppresses the publish anyway and makes the check vacuous |
| Nothing was submitted | `dump_timing` — no playback open started at launch. The strongest proof |
| No stranded demand | `dump_equalizer` — flat display ticks, no poller, no level consumer |
| Invariants | `check_consistency` — `playlist.current_track_matches_index`, `nowplaying.cleared_without_track`, `equalizer.tap_follows_demand`, plus the two the park newly satisfies the precondition of: `cloud.hold_outlives_playback` and `cloud.handle_open_stranded`, both gated on `player.isStopped && !isLoading` |
| Visual contract | `dump_screenshot` |
| Teardown | `play_pause`, then re-run `dump_state` / `dump_now_playing` — Loading then Playing, times move, `hasInfo: 1` |

Then the cases that silently regress:

1. **Force quit and ordinary quit, separately** — they exercise different mechanisms and the
   single case in the old draft tested only one of them.
   - *Debounce:* `open`, wait 3s (past `kSaveDebounce`), `kill -9`, relaunch, assert the playlist
     came back. This is the debounced write landing, and it never touches the hold.
   - *Debounce window:* `open`, `kill -9` immediately, relaunch, assert the playlist is **absent**.
     Losing up to two seconds of edits to a `SIGKILL` is the accepted cost, and asserting it stops
     a future reader from believing the hold covers this.
   - *Sudden-termination hold:* `open`, then quit normally inside the two-second window, relaunch,
     assert the playlist came back. This is the only case the hold is responsible for.
2. **Loose files** — drag individual files from outside `~/Music` and outside any granted
   folder, relaunch, confirm they restore *readable*. The whole point of the per-file
   bookmarks, and the case that breaks if the coverage test is wrong.
3. **Superseded restore** — launch with an argv path while the setting is on; the argv playlist
   must win, and must still win when the restore's file read is slower than the open.
4. **A fresh `AudioTrack` for the parked row** — both mint paths, since trap 1 has two: convert
   the parked track, and separately restore a playlist whose cursor file has moved so the
   bookmark re-points it. The header must not fall to `--:--` in either.
5. **Moved folder** — move the folder between launches; assert `unresolvedBookmarks` and the
   `replaceTrackAtIndex:` re-point.
6. **Scale** — a 50k-track folder: measure launch-to-first-paint; confirm zero bookmarks minted;
   confirm a skip rewrites **only** `LastPlaylistCursor.plist` and leaves `LastPlaylist.plist`'s
   mtime untouched; confirm a repeated skip to the same index writes nothing at all.
7. **Torn write** — kill between the rows write and the cursor write; the fingerprint must
   reject the cursor and restore the rows at index 0 rather than discarding the playlist.
8. **Zero impact when off** (Part 4) — launch with the setting off and confirm no
   `LastPlaylistStore` allocation, no Application Support directory created, and identical
   launch timing to the current build.
9. **Setting off / factory reset** — both files gone from Application Support.
10. **Cloud** — `set_fake_cloud` + `dump_cloud_health` / `dump_row_loading`: expect the one
    metadata priority record, **no successor prefetch**, and **no transfer at all attributable to
    the waveform**, because the park skips the load on a dataless file (Part 1, §1.3). The
    negative is the whole point of the case: a waveform decode that materialized the file would
    do it outside the lanes and outside `CloudTransferRegistry`, so it would show up in neither
    dump — measure the provider's own transfer count, not the app's records. Then repeat with the
    file already local and assert the waveform *does* load. Belongs in the `vibe-stress` skill's
    cloud scenario suite.

Gates: `make test`, `make check-vocabulary`, `make check-layout`, `make check-strings`,
`make check-translations`, `make analyze CONFIG=Release`.

---

# Files touched

**New** — `Vibe/Mac/App/LastPlaylistStore.{h,m}`, `Vibe/Mac/App/LastPlaylistRules.h`,
`Vibe/Debug/Mac/Introspection/LastPlaylistStore+Debug.h`, `Tests/LastPlaylistRulesTests.m`.

**Modified** — `Vibe/Common/{AppSettings.h/.m, VibeStrings.h}`, `Vibe/Mac/App/AppDelegate.m`,
`Vibe/Playlist/Mac/PlaylistController.{h,m}`,
`Vibe/Mac/MainWindow/{TrackDisplayRules.h, TrackDisplayController.m, MainPlayerController.h/.m,
MainPlayerControllerInternal.h, MainPlayerController+PlayerEvents.m,
MainPlayerController+NowPlaying.m, MainPlayerController+Convert.m}`,
`Vibe/iOS/PlayerScreenRules.h` (preamble only),
`Vibe/Mac/Settings/{SettingsGeneralViewController.m, SettingsAdvancedViewController.m}`,
`Vibe/Debug/Mac/{DebugStateDump.m, DebugCommandTable.m}`, `Tests/TrackDisplayStateTests.m`,
plus `Resources/Localizable.xcstrings` via `make strings`.

**Docs** — `Vibe/Mac/App/CLAUDE.md` (a "Last playlist" section beside "Sandbox grants" and
"Stats": the funnel, the sudden-termination hold, the never-stopped scopes, the launch gates),
`Vibe/Mac/MainWindow/CLAUDE.md` (the parked state), `Vibe/Mac/Settings/CLAUDE.md` (the Startup
group and the reset TRAP), root `CLAUDE.md` (add `LastPlaylistStore` to Singletons; candidate
cross-directory guarantee: *"A restored playlist never plays itself, and a launch-time open
always outranks it."*).

No `project.yml` edit — every directory involved is already a recursive source entry, and
`Mac/App` is macOS-only by path. Just `make project`.

---

# Suggested sequencing

1. **`TrackDisplayStateParked`** + rules tests + the rendering branches. Verifiable on its own,
   with no persistence at all. Includes the `_lastPosition`/progress pinning and the
   one-`currentTrack`-read restructure of `updateRateDependentUI` (§1.2), the `updateWithTrack:nil`
   publish (§1.4), and both halves of trap 1 — they are park mechanics, not storage.
2. **`loadURLs:selectingIndex:` + `restorePlaylistURLs:currentIndex:`** + a debug verb. The
   whole park is drivable and testable before a byte is written to disk.
3. **Settle the dataless-waveform question** (§1.3) before any of Part 2 exists. It changes what
   step 2's park does, and discovering it afterwards means redoing the whole cloud pass.
4. **`LastPlaylistStore`** + rules tests + the setting + the Settings row + the four verbs. The
   rows-write-carries-the-cursor rule (§2.3), the counted sudden-termination holds and the
   `_ioQueue`/mint-queue split (§2.5) all land here.
5. **The launch hook** — including the `applyReopenLastPlaylist` call from
   `wireWindowAndViews`, which is separate from the restore — the two gates, and the end-to-end
   passes.
6. **Follow-on, separately scoped:** scrubbing a parked waveform opens at that position, paused
   (Part 1 trap 6).
