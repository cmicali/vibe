# Future: Shuffle mode

Written 2026-08-20, planned but not implemented. Nothing in the repo has changed for it yet. The file:line anchors below are against branch `ios-app` at `a19c5c5` **with its uncommitted working tree**. Re-check every anchor before acting.

This plan is written to be executed phase by phase by an implementation agent. Each phase compiles, passes `make test`, and is verifiable on its own. Read the root `CLAUDE.md` (especially the successor-prefetch and settlement guarantees), `Vibe/Playlist/CLAUDE.md`, `Vibe/Playlist/Mac/CLAUDE.md`, `Vibe/iOS/CLAUDE.md`, `Vibe/Mac/Settings/CLAUDE.md` and `Tests/CLAUDE.md` first; strings need the `vibe-strings` skill, verification the `vibe-debug` skill.

## The feature

A shuffle play mode: with it on, advancing plays every track in the playlist exactly once, in a random order, before the end is reached — the way iTunes/Music, Spotify and every DJ player implement shuffle, as a **shuffled permutation walked by a cursor**, not a per-advance random pick (which repeats some tracks and starves others).

Behavior spec, matching convention:

- Turning it on shuffles the whole playlist into a hidden play order with the current track first. The visible playlist order never changes — only what "next" means.
- **Next** walks forward through that order; **Previous** walks back through the tracks actually played, in reverse (the permutation *is* the history, so this falls out free).
- The end of the play order behaves exactly like the end of the playlist today: park, don't restart. (Auto-reshuffle-and-continue is a repeat mode; the app has no repeat mode, and this plan deliberately doesn't add one.)
- Manually picking a row (double-click on mac, row tap on iOS) plays that track and shuffle continues from it; the picked track is spliced into the cursor position so nothing else repeats.
- Tracks appended while shuffling are inserted at random positions in the *unplayed* remainder.
- Turning it off resumes linear order from the current track.
- The mode persists across launches (the order itself does not — a fresh launch reshuffles).

**Naming, decided here**: the feature is **shuffle** — code and screen both. It is the term `MPRemoteCommandCenter` and the whole MediaPlayer API use (`changeShuffleModeCommand`), the term every other player puts in front of the user, and one word per pattern is the vocabulary rule. "Random" is not a synonym for it anywhere in the code, the strings or this plan.

## How advance works today (anchors verified at `a19c5c5`)

- `Playlist` (shared, tested) owns `currentIndex` and the advance API, and its boundary predicates are *documented* as "the single source of truth for whether there is a track after or before the current one" (`Playlist.h:74-77`). `hasNextTrack` is `_currentIndex + 1 < _tracks.count`; `next`/`previous` move `currentIndex` through its setter (`Playlist.m:127-149`), which fires the one observer.
- Both shells funnel through it: mac `PlaylistController.next/previous` advance the model then `play` (`PlaylistController.m:390-405`), with `advanceToNextTrackWithoutPlaying` as the gapless splice's bookkeeping half (`:408-413`); iOS `PlaybackController.next/previous` call `[_playlist next/previous]` then `playCurrentTrack` (`PlaybackController.m:374-387`).
- Track end funnels through `didFinishPlaying:` → `advanceOrParkAtTrackEnd`, which reads `hasNextTrack` *before* advancing (`MainPlayerController+PlayerEvents.m:196-215`).
- **The one linear-order leak**: the mac's `successorPrefetchTrack` computes the gapless arm point as `trackAtIndex:currentIndex + 1` directly (`MainPlayerController.m:735-740`) instead of asking the model. Per the root `CLAUDE.md` guarantee, that parked handle is what a gapless splice advances into — so under shuffle it *must* answer the shuffled successor, or track ends splice into the linear neighbor while the UI expects the shuffled one.
- Menu validation gates Next/Previous on the same predicates (`MainPlayerController+Menus.m:54-57`); the Playback menu holds the transport items (`MainMenuBuilder.m:227-260`).
- `changeShuffleModeCommand` is currently in Now Playing's deliberately-disabled set (`System/NowPlayingController.m:225`).
- `PlaylistTests.m` exists — the model is pure logic, host-less.

## Phase 1 — Shuffle in the `Playlist` model

The order lives **inside `Playlist`**, not in a controller: the boundary predicates are the declared single source of truth, both shells already funnel every advance through them, and the model is the one shared, tested home. Files: `Vibe/Playlist/Playlist.{h,m}` (shared — Foundation only, as now).

### State

```objc
@property (nonatomic) BOOL shuffleEnabled;
// Injectable for tests; defaults to arc4random_uniform. Never Date/seed-based.
@property (nonatomic, copy) uint32_t (^randomBelow)(uint32_t upperBound);
```

Internal: `NSMutableArray<NSNumber *> *_playOrder` (a permutation of row indexes 0..count-1) and `NSUInteger _playOrderCursor`. Invariant to keep true everywhere: **entries before the cursor are played, the cursor entry is the current row, entries after it are unplayed** — every rule below is an application of it.

### Rules

- **`setShuffleEnabled:YES`** — Fisher-Yates over all row indexes (using `randomBelow`), then swap the current row's entry to position 0, cursor = 0. **`NO`** — discard order and cursor; linear predicates take over from `currentIndex` unchanged.
- **`hasNextTrack`** under shuffle: `_playOrderCursor + 1 < _playOrder.count`; **`hasPreviousTrack`**: `_playOrderCursor > 0`. Linear bodies unchanged otherwise.
- **`next`/`previous`** under shuffle: move the cursor, then set `currentIndex` to the row at the cursor — through an internal index write that *skips* the manual-pick re-anchor below but still fires `currentIndexDidChangeFromIndex:` (the observers must not care which mode moved it). `advanceToNextTrackWithoutPlaying` rides `next` and needs no change beyond that.
- **Successor peek** — new public accessor, the model-side answer the mac prefetch will use:

  ```objc
  // The track next would advance to — shuffled successor or linear neighbor —
  // or nil at the boundary. The gapless arm point must ask this, never
  // trackAtIndex:currentIndex + 1.
  - (nullable AudioTrack *)nextTrackPeek;
  ```

- **Manual pick** (`setCurrentIndex:` from outside `next`/`previous`) under shuffle: find the picked row's entry in `_playOrder`, swap it with the entry at `cursor + 1`, advance the cursor to it. If the picked row was already played (its position ≤ cursor), the same swap replays it and retires the slot it left — nothing else repeats. A pick of the current row changes nothing (the setter already re-fires the observer for that case, `Playlist.h:47-49`).
- **`replaceAllWithURLs:` / `clear`** — regenerate (or drop) the order; `replaceAll` resets `currentIndex` to 0 as today and the new permutation puts row 0 first. Opening a folder therefore still starts on the first row; shuffle governs what comes *next*, which is the conventional behavior.
- **`appendURLs:`** — insert each new row index at a `randomBelow`-chosen position in `(cursor, end]`. Played history is untouched.
- **`replaceTrackAtIndex:withURL:`** (the convert swap) — **no change needed**: the order stores row indexes, not tracks, and the swap moves no rows. State this in a comment on `_playOrder`.

### Tests (`Tests/PlaylistTests.m`, deterministic via an injected `randomBelow`)

Every track visited exactly once walking `next` to the boundary; the boundary parks (`hasNextTrack` NO); `previous` retraces the exact visited sequence; enabling puts the current row first; manual pick of an unplayed row continues with no repeats; manual pick of a played row replays it and still exhausts the remainder; append lands every new row in the unplayed span; toggle off resumes linear from `currentIndex`; convert swap mid-shuffle changes nothing; `nextTrackPeek` always equals the row `next` then lands on (the invariant Phase 2 leans on).

**Acceptance**: `make test`, `make check-layout`, `make build-ios` (shared file, both targets).

## Phase 2 — macOS integration

### 2a. The setting

`Vibe/Common/AppSettings.h`, **above** the platform split (both platforms shuffle): `- (BOOL)shuffleEnabled; - (void)setShuffleEnabled:(BOOL)enabled;`, key `Settings.shuffleEnabled`, default NO registered in the shared `registerDefaults` dictionary (`AppSettings.m:131-138`). BOOL — no normalize rule needed. The key string is permanent once shipped (`Common/CLAUDE.md` trap).

### 2b. The one-place apply hook, and the re-park trap

`MainPlayerController` (pattern: `applyEndOfTrackAction`, `MainPlayerController.m:742-748`):

```objc
- (void)applyShuffle {
    self.playlistController.shuffleEnabled = AppSettings.sharedInstance.shuffleEnabled;  // add the pass-through to PlaylistController
    // TRAP: the parked successor is the gapless arm point (root CLAUDE.md).
    // Without this re-park a track end splices into the *linear* neighbor
    // that was armed before the toggle. Same edge as applyEndOfTrackAction.
    [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
}
```

Called at launch (after the playlist restores) and by every writer of the setting. **Every future write of `shuffleEnabled` must go through it** — say so in the property comment in `AppSettings.h`, as `pauseAtTrackEnd`'s does.

### 2c. Close the linear-order leak

`successorPrefetchTrack` (`MainPlayerController.m:735-740`) keeps its `pauseAtTrackEnd` gate (that guarantee outranks shuffle) and replaces `trackAtIndex:currentIndex + 1` with the model peek, through a `PlaylistController` pass-through:

```objc
return [self.playlistController nextTrackPeek];
```

Audit the other prefetch call sites (`MainPlayerController.m:544`, `+PlayerEvents.m:129`, `+Convert.m:162`) — all already funnel through `successorPrefetchTrack`, which is the guarantee working as designed; none may bypass it.

`advanceOrParkAtTrackEnd` needs **no change**: it reads `hasNextTrack` and calls `next:`, both of which Phase 1 made shuffle-aware.

### 2d. Menu

Playback menu, after the Next item (`MainMenuBuilder.m:231`): a checkmarked toggle, symbol `shuffle`, no key equivalent (the bare transport keys belong to `TransportKeyMonitor`; don't grow that set), identifier `menu_shuffle`. Action on `MainPlayerController`:

```objc
- (IBAction)toggleShuffle:(id)sender {
    AppSettings.sharedInstance.shuffleEnabled = !AppSettings.sharedInstance.shuffleEnabled;
    [self applyShuffle];
}
```

Validation in `validateMenuItem:` (`+Menus.m:20`): always enabled, state = the setting. String: new `menu.playback.shuffle` — **"Shuffle"** — in `VibeStrings.h` via the `vibe-strings` skill, then `make strings` + translations.

No Settings-pane row: this is transport state like play/pause, not configuration — it lives in the menu (and later the remote command), not in Settings > Playback.

**Acceptance**: `make test`, `make check-strings`, `make check-translations`; then with the `vibe-debug` skill: `click_menu` the toggle, `dump_state` shows the setting; load a folder, walk Next to the end and confirm every row's play indicator is visited once (the debug channel's state dump names the current track — script the walk and collect the sequence); toggle shuffle mid-track and confirm the *next* track end lands on a shuffled successor (gapless re-park proof); Previous retraces; a double-clicked row continues shuffling with no repeat.

## Phase 3 — iOS integration

- `PlaybackController` gets the same pass-through: apply `AppSettings.sharedInstance.shuffleEnabled` to its `Playlist` at init and expose `- (void)toggleShuffle` writing the setting and the model together (no gapless prefetch exists on iOS — verify while there: if the iOS player parks any successor handle, route it through `nextTrackPeek` the same way). `next`/`previous`/`selectTrackAtIndex:` already funnel through the model (`PlaybackController.m:374-395`) and inherit Phase 1.
- UI: a shuffle button on the now-playing card's control row (`Vibe/iOS/CLAUDE.md` owns the card's layout conventions — follow them; tinted when active, like the system players). The library rows and mini player need nothing: the visible order never changes.
- The card's page-swipe navigation (`PlayerViewController+Pager.m`) previews neighbors — check what it uses for "next page": if it asks `trackAtIndex:currentIndex ± 1` anywhere, it must ask the model's peek instead, or the swiped-to page won't match the track that plays. This is the iOS twin of the mac's prefetch leak; grep for `currentIndex + 1` under `Vibe/iOS/` and fix every hit through the model.

**Acceptance**: `make build-ios`; simulator loop (`launch-ios.sh`, `drive-ios.sh`): toggle shuffle, swipe and tap through tracks, confirm the no-repeat walk and that a page swipe lands on the same track advance would have chosen.

## Phase 4 (optional, separate decision) — Now Playing shuffle command

`changeShuffleModeCommand` is in the deliberately-disabled set (`NowPlayingController.m:218-233`). Enabling it puts a shuffle toggle in Control Center / CarPlay and routes the system's shuffle state to `applyShuffle`. **TRAP (same as the CarPlay doc's skip-command note): `MPRemoteCommandCenter` is process-global and the system may re-layout the compact transport when new commands appear** — verify on a real device that enabling it costs nothing on the lock screen before shipping. Keep this phase out of the initial landing; the feature is complete without it.

## Phase 5 — Final verification

- The Phase 2 scripted walk on a 50+ track folder: collect the played sequence, assert it is a permutation (no repeat, no omission), assert park at the end.
- Toggle off mid-walk → next advance is `currentIndex + 1` in visible order.
- Append mid-walk (drop onto the Add well) → appended tracks all play before the end, none twice.
- Convert a track mid-shuffle (the row swap) → order undisturbed, swapped row still plays once.
- `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make check-strings`, `make check-translations`, `make build-ios`.
- A `vibe-stress` torture run with shuffle on (the suite hammers skips against the metadata scan; shuffle changes which row a skip lands on, which is exactly the delivery-race surface those oracles watch).
