# Playlist row removal (macOS) — DONE

Implemented 2026-08-25, from the plan below. The plan is kept as the record of the reasoning; the
code and the directory docs are the authority on what shipped. The implementation diverged in
these places:

- **The row menu's clicked-track capture is in `menuNeedsUpdate:`, not `menuWillOpen:`, and is not
  cleared when the menu closes.** AppKit validates the items between those two callbacks, so a
  capture made in `menuWillOpen:` would be stale for the validator, and the chosen item's action
  can run after `menuDidClose:`, so clearing there would leave the removal with nothing to act on.
  The reference is weak and every open overwrites it, so an uncleared capture retains nothing.
- **The shell funnel takes only the exact track** (`removePlaylistTrack:`) and resolves its live row
  once, rather than passing and immediately rechecking an index/identity pair.
- **The debug key injector gained a `repeat` token** as well as `forward_delete`, because nothing
  else can synthesize `isARepeat` and the plan's "repeat removes only one row" acceptance is not
  otherwise testable.
- **The iOS observer boundary is a no-op**, rather than broadcasting a speculative structural
  event to four screens. iOS exposes no removal path, and view reconciliation belongs with the
  transport-safe coordinator a future removal feature would first have to add.

Not verified end to end: **clicking the row context menu's item**. `click_menu` searches the menu
bar only, and a real context menu blocks the debug channel until dismissed, so that one path was
checked by construction and by opening the menu, not by driving the click.

This plan is written to be executed phase by phase by an implementation agent. Read the root
`CLAUDE.md`, `Vibe/Playlist/CLAUDE.md`, `Vibe/Playlist/Mac/CLAUDE.md`,
`Vibe/Mac/MainWindow/CLAUDE.md`, `Vibe/Mac/Menu/CLAUDE.md` and `Tests/CLAUDE.md` first.
Strings require the `vibe-strings` skill; live verification requires the `vibe-debug` skill.

Drag reordering is deliberately not part of this plan. It is specified separately in
`docs/future/playlist-drag-reordering.md`, after the model and observer groundwork here.

## The feature

Remove one row from the macOS playlist without touching its audio file:

- **Edit > Remove from Playlist** acts on the selected row.
- Backspace and Forward Delete perform the same action while the playlist is visible.
- The playlist row context menu gets **Remove from Playlist**, acting on the clicked row.
- The table remains single-selection. Multi-row removal, Select All over the playlist and group
  drag are not part of this slice.
- Removing a non-current row never interrupts playback.
- Removing the current row selects and loads a deterministic adjacent row; it never leaves the
  player sounding an object the playlist no longer contains.
- Removing a row never deletes, trashes, renames or moves the source file.

The symbol is `minus.circle`, not `trash`: this is an edit to the in-memory playlist, not to the
filesystem.

## No Clear Playlist command

There is no new **Clear Playlist** item.

File > Close already changes its title to **Close All Files** when several tracks are loaded, and
`MainPlayerController.closeFile:` owns the complete teardown: stop/supersede playback, stop the
download monitor, drop the prefetched successor, cancel the waveform load and deferred metadata
work, clear the playlist and error mask, stop the UI timer, and render the empty state. A model-only
`Playlist.clear` deliberately does none of that because its caller owns the player.

A second whole-list command would therefore be either:

- an alias for Close All Files, adding UI with no behavior; or
- a second teardown path, liable to omit a future piece of playback state.

Keep **Close File / Close All Files** and `⌘W` as the sole whole-list action. Do not add a clear
item to Edit or either context menu, and do not rename Close All Files: it unloads the deck as well
as emptying the visible rows, which “clear playlist” understates.

## Behavior contract

### Which row an action names

The keyboard and Edit-menu action read `PlaylistTableView.selectedRow` and its exact `AudioTrack`
at action time. For the row context action, capture `clickedRow` and that exact object as the menu
opens, then resolve the object through `getIndexForTrack:` when the item is chosen. Existing Show
in Finder and Copy actions may keep their current clicked-row behavior, but a structural edit must
not remove an unrelated row that a playlist replacement put at the same number while the menu was
open. A departed or replaced object resolves to `-1` and the action no-ops; if another edit merely
shifted it, removal follows the originally clicked object to its live row.

Right-click removal acts on the clicked row even when a different row was selected. After any
successful removal, the table selects the surviving row that slid into the removed position, or
the new last row when the removed row was at the end. The playing row remains a separate concept
from selection, as it is today.

### Removing a row that is not current

Playback, playhead position, paused/loading intent, header and waveform remain untouched.

- A row before the current row makes `currentIndex` decrease by one so it continues to name the
  exact same `AudioTrack` object.
- A row after the current row leaves `currentIndex` unchanged.
- If the removed row was the prefetched successor, or removing it changes which row is next, the
  shell immediately re-parks the new successor through `successorPrefetchTrack`.
- Next/Previous enablement, Now Playing command availability, row numbering and the metadata
  neighborhood are refreshed in the same main-thread turn.

### Removing the current row

Vibe's player-event guards compare the delivered `AudioTrack` with the playlist's current object.
Allowing removed audio to keep sounding “off-list” would make correct player callbacks look stale,
break the playing-row guarantee, and leave auto-advance with no authoritative successor. The
current row therefore changes as one coordinated transport operation:

| Before removal | Surviving row chosen | Landing intent |
| --- | --- | --- |
| A successor exists | The successor that slides into the same row | Playing when the removed track had playing intent; otherwise paused |
| Current row was last, earlier rows survive | The new last row | Paused, even if the removed last row was playing; removal must not replay backward |
| It was the only row | None | Call `closeFile:`; ordinary empty-state teardown |

For a successor, `AudioPlayer.playingIntentAfterPendingCommands` resolves the intent after every
transport command already submitted to the player queue. This includes a pause whose fade has
started but not completed, without mirroring transport state in the controller. `outputAudioActive`
answers whether pixels/FFT should run and is not a transport intent. Paused, Loading-paused,
Stopped and error states all land the replacement parked.

The replacement starts at file position 0. A playing successor goes through ordinary `play:` so
the configured track-change crossfade applies. A parked replacement uses
`play:atPosition:startPaused:YES`, but it must still go through a `PlaylistController` play helper
that invokes `playWillStartHandler` after submission. That hook is what immediately repaints the
header during a slow open and keeps every play entry point on one path.

Before every parked replacement, fold the listening clock and stop the UI timer. Both operations
are idempotent, and must happen before the new submission suppresses any pending stop or pause
callback from the departed track. A slow parked open therefore produces no app-side UI wakeups.

### Async work and other features

- **Player settlements:** submitting the replacement mints a newer play identity, so an old open's
  settlement is dropped by `AudioPlayer.submittedPlayIsCurrent:`. The shell's current-track guard
  supplies the second fence.
- **Metadata:** rebuild the model's identity map before the observer fires. A late delivery for a
  surviving track resolves its new row; a removed track resolves to `-1` and draws nowhere.
- **Duplicate URLs:** URL lookup still reaches every surviving occurrence. Separate rows holding
  the same URL remain separate `AudioTrack` identities.
- **Waveform/BPM/key:** current-track removal takes the ordinary play/delivery path. Object-specific
  presentation from the departed row must fail the current-track guard. File-level analysis for a
  surviving duplicate URL may still be accepted legitimately; duplicate rows describe the same
  audio file. Non-current removal does not restart the current waveform.
- **Metadata sweep:** do not cancel and restart the whole playlist scan for one removed row. Its
  immutable input may finish harmless work for that departed object, whose delivery resolves no
  row; restarting a large scan would discard more useful work than it saves. Re-rank the live
  neighborhood immediately.
- **Gapless:** re-submit `successorPrefetchTrack` after every removal. If a boundary wins the race,
  the existing `didAutoAdvanceFromTrack:toTrack:` next-row identity check must fall back to the
  playlist's real successor.
- **Conversion:** removing a converting row does not change or cancel the already accepted job.
  Conversion may finish; its completion finds no row and leaves the converted file on disk, the
  same result as a playlist replacement racing the encode. If that job snapshotted **Delete
  Original**, it may still trash the source after a successful encode; that is the earlier
  conversion command's consequence, not a file operation initiated by removal. A surviving
  converted row still resolves through the rebuilt identity map.
- **Cloud rows:** removing a current Loading row supersedes its open. A removed background row may
  finish already-admitted metadata materialization, but no loading indicator or delivery can be
  attached to a row that no longer exists.

## How the playlist works today

`Playlist` owns `_tracks`, `currentIndex`, an identity-to-row map and a URL-to-rows index. It can
replace all rows, append, clear, advance/retreat and replace one row for Convert to FLAC. Its
documentation explicitly relies on rows never otherwise moving, so both indexes record positions
incrementally and never repair shifted entries.

`PlaylistController` is the model's one observer on macOS. It maps model events onto precise table
updates, owns row selection/click semantics and exposes the model to `MainPlayerController`.
`PlaybackController` takes the same single observer slot on iOS and broadcasts to its several
views.

`MainPlayerController` is the only suitable owner of removal consequences. `PlaylistController`
has an `AudioPlayer` reference so it can run the ordinary play funnel, but it does not own the
download monitor, waveform, metadata scan, stats, error mask, Now Playing publish or empty-state
teardown.

The Edit menu explicitly targets `MainPlayerController` today, except for the nil-targeted Select
All item. Keep that convention. The Remove item targets the player controller and its validator
requires the player window to be key, the playlist pane visible and a valid selected row; a Delete
key pressed in Settings or About must never edit the hidden player.

## Phase 1 — Shared model mutation

Files: `Vibe/Playlist/Playlist.{h,m}`, `Vibe/Playlist/CLAUDE.md`, `Tests/PlaylistTests.m`,
`Vibe/iOS/PlaybackController.{h,m}`, `Vibe/iOS/LibraryViewController.m`,
`Vibe/iOS/SearchViewController.m`, `Vibe/iOS/PlayerViewController.m` and
`Vibe/iOS/RootViewController.m`.

### 1a. One rebuild for the two indexes

Extract a private `rebuildIndexes` that empties and repopulates `_trackIndexes` and
`_indexesByURL` from `_tracks` in one pass. Use it after row removal and, later, drag reordering.
Keep the existing incremental append and row-replacement updates unless using the rebuild there
materially simplifies the implementation; those paths are already correct and hot playlists can
be very large.

An O(n) rebuild is acceptable here: `NSMutableArray` removal is already O(n), the action is an
explicit user gesture, and the hot async-delivery lookups remain O(1). Recreating `AudioTrack`s
from URLs is not acceptable: it would throw away installed metadata/artwork and defeat identity
checks.

### 1b. Public mutation and observer event

Add a model operation with an unambiguous invalid case:

```objc
// Removes and returns the exact row object, or nil when index is out of range.
// The surviving current track keeps its identity; when current is removed,
// the same final row or the preceding last row becomes current.
// The calling shell owns the corresponding audio-player transition.
- (nullable AudioTrack *)removeTrackAtIndex:(NSUInteger)index;
```

Add one synchronous structural observer delivery carrying the removed index:

```objc
- (void)playlist:(Playlist *)playlist didRemoveTrackAtIndex:(NSUInteger)index;
```

Set `_tracks`, both indexes and `_currentIndex` to their final coherent state before calling the
observer. Do not also send `currentIndexDidChangeFromIndex:`: two callbacks for one structural
edit make the table reconcile against the same action twice and obscure event ordering. The
removed index is all the table reconciliation consumes; the shell already knows the exact
requested object and whether it was current before it invokes the mutation.

An invalid index returns nil, changes nothing and sends no event. Empty removal resets
`_currentIndex` to 0.

### 1c. Shared-target fallout

Implement the new required `PlaylistObserver` method in both observer owners:

- macOS `PlaylistController` performs the precise table update described in Phase 2;
- iOS `PlaybackController` implements the required selector as an explicit no-op. The iOS app
  exposes no remove UI and adds no caller in this feature, so speculative metadata and view
  reconciliation would have no safe production path to serve.

Any future iOS remove UI must first add a player coordinator: `PlaybackController` would otherwise
keep playing the departed object. Add the matching view reconciliation with that feature; it may
not call the model method directly.

### 1d. Unit tests

Add pure model cases for:

- invalid index and empty model: no mutation, no observer event;
- remove before and after current: same current object, correct numerical index;
- remove current with a successor, current at the end, and sole row;
- first, middle and final ordinary rows;
- removed identity returns `-1`, every survivor resolves to its shifted row;
- duplicate URL sets lose exactly the removed occurrence and `trackForURL:` still returns the
  first surviving row;
- observer index payload, final state and exact synchronous event order;
- a metadata-bearing `AudioTrack` remains the exact same object after another row is removed.

**Acceptance:** `make test`, `make check-layout`, `make check-vocabulary`, and
`make build-ios CONFIG=Debug`.

## Phase 2 — macOS table and selection

Files: `Vibe/Playlist/Mac/PlaylistController.{h,m}`,
`Vibe/Playlist/Mac/PlaylistTableView.{h,m}`, `Vibe/Playlist/Mac/CLAUDE.md`.

### 2a. Controller surface

Add:

- a range-checked selected-row accessor for the shell action;
- a range-checked clicked-row removal action for the context menu;
- a synchronous request block from the playlist controller to its shell owner, carrying the exact
  `AudioTrack` identity, never a track guessed from its URL;
- a public pass-through that performs `Playlist.removeTrackAtIndex:` only when the shell has
  decided the playback consequences;
- a play helper that accepts `startPaused` and always fires `playWillStartHandler` after
  submission, preserving the existing “one play funnel” rule.

The request block keeps the app-shell work out of `Playlist/Mac/`. The selected-row action captures
its identity at invocation; the context action captures it when the menu opens. `MainPlayerController`
wires the block beside the existing play and current-index handlers and resolves the exact object to
its live row once; a departed object no-ops and a shifted one is followed.

### 2b. Precise table update

On the model's removal event:

1. Remove the row with `removeRowsAtIndexes:withAnimation:` and no animation. A deletion commonly
   shifts thousands of rows; animating them is motion and work nobody requested.
2. Select the row that closed the gap, or the new final row.
3. Re-stamp visible `PlaylistRowView.playingRow` values from the model's final current index.
4. Reconfigure all visible number-column cells in place so their row numbers, loading bars,
   equalizer ownership and current equalizer visibility agree. This includes the promoted current
   row when the removed row was last and costs at most one screenful. Do not `reloadData` and do
   not rebuild every column.
5. Do not invoke `currentIndexDidChangeHandler` as a second edge for the same structural edit. The
   shell removal funnel performs the final-state metadata-neighborhood and transport refresh once
   after the synchronous mutation; duplicating that work through the ordinary cursor callback
   obscures the one-mutation/one-reconciliation ordering.

The selection update is presentation only; it must not call `playSelectedTrack`.

### 2c. Context menu

Append a separator and **Remove from Playlist** after Copy File in the row context menu. Give it a
playlist-owned identifier distinct from the main Edit item, target `PlaylistController`, and
validate by resolving the menu-open capture to a live row. The existing clicked-row actions keep
their current validation; Remove additionally proves identity because it mutates structure.

**Acceptance:** remove first/middle/last non-current rows with the player stopped and with another
row playing; selection, row numbers, playing wash and equalizer remain coherent without a full
table flash.

## Phase 3 — shell playback coordination

Files: `Vibe/Mac/MainWindow/MainPlayerController.{h,m}` and its internal surface. Keep the work in
the central controller unless it makes that file materially less readable; if a
`MainPlayerController+PlaylistEditing` category is introduced, add it to the category table in
`Vibe/Mac/MainWindow/CLAUDE.md` and declare its implementation methods in its own header.

One private `removePlaylistTrack:` is the funnel for Edit, keyboard and context requests:

1. Resolve the exact `AudioTrack` through `getIndexForTrack:` once; no-op if it has departed.
2. If the playlist has one row, call `closeFile:` and return without first mutating the model.
3. Capture whether the requested row is current and whether a forward successor exists. Only for
   that successor case, resolve the ordered intent through
   `AudioPlayer.playingIntentAfterPendingCommands` before mutating.
4. Perform the model removal through `PlaylistController`.
5. Recompute the metadata neighborhood from the final rows exactly once; do not route this through
   `currentIndexDidChangeHandler` as a second structural notification.
6. If the current identity survived, leave audio alone, re-park `successorPrefetchTrack`, and run
   the lightweight UI/Now Playing refresh.
7. If current was removed, derive one landing intent: a successor preserves the captured intent;
   the previous row chosen after removing the last track always parks.
8. Before a parked landing, fold the listening clock and stop the UI timer synchronously, then
   submit through the common play helper.
9. Ensure the branch's final state has passed `successorPrefetchTrack` to `prefetchTrack:` once.
   Reuse that reconciliation when the ordinary play funnel already owns it; do not double-submit.

Every post-removal prefetch goes through `successorPrefetchTrack`; no new caller computes
`currentIndex + 1` on its own. Settings > Playback > On track end therefore continues to outrank
prefetch exactly as it does today.

The current-row replacement must clear an existing error mask and tear down a download monitor
belonging to the removed open through the same submission/start paths an ordinary track change
uses. Do not synthesize player delegate callbacks, and do not treat removal as a track end.

**Acceptance:** current-row removal in Playing, Paused, Loading-playing, Loading-paused, Stopped,
error, first/middle/last and sole-row states. A surviving current row never restarts; a replacement
settles with playlist/player identity equal.

## Phase 4 — menu, keyboard, strings and observability

### 4a. Edit menu

Files: `Vibe/Mac/Menu/MainMenuBuilder.m`, `Vibe/Mac/MainWindow/MenuValidationRules.h`,
`Vibe/Mac/MainWindow/MainPlayerController+Menus.m`, `Vibe/Mac/Menu/CLAUDE.md`,
`Vibe/Common/VibeStrings.h` and `Tests/MenuValidationRulesTests.m`.

Add **Remove from Playlist** after Copy Name/Copy File, separated from both the Copy pair and Select
All. Give it:

- action `removeSelectedPlaylistTrack:` on `MainPlayerController`;
- identifier `menu_edit_remove_from_playlist`, so `VibeEditMenuCleaner` retains it;
- symbol `minus.circle`;
- bare Backspace as its displayed/fallback key equivalent.

The separator before Remove is `menu_edit_separator_remove`; keep
`menu_edit_separator_select` after it. Both identifiers deliberately retain the
`menu_edit_*` prefix, because `VibeEditMenuCleaner` removes unidentified separators along with
unidentified items.

Keep the explicit player target convention. Validation requires all of: the player window is key,
the playlist is shown, and `PlaylistController` has a valid selection. Add the identifier to the
Edit validation domain and its unit-test inventory. This prevents a Delete press in an auxiliary
window from editing an invisible playlist.

### 4b. Keyboard

Files: `Vibe/Mac/MainWindow/TransportKeyMonitor.{h,m}`,
`Vibe/Mac/MainWindow/CLAUDE.md`, `Vibe/Debug/Mac/DebugInput.m` and
`.claude/skills/vibe-debug/SKILL.md`.

`TransportKeyMonitor` handles both `NSDeleteCharacter` and `NSDeleteFunctionKey` as playlist keys.
Like Return and the arrows, they are swallowed while the playlist is collapsed. With the pane
visible they call the same main-controller action as the menu. Ignore repeat key-down events for
removal, and preserve the existing modifier/text-editor gates.

The menu advertises Backspace only; Forward Delete is a supported physical-key twin, not a second
menu shortcut. The debug key injector currently maps only `delete`/Backspace. Add a distinct
`forward_delete` name to its key-code and character maps, update its unknown-key usage, and
document it in `vibe-debug`. Do not claim the existing `key delete` command covered both code
paths.

### 4c. Strings and debug state

Declare one shared string in `Vibe/Common/VibeStrings.h`, with a translator comment that says the
file remains on disk. Update `STR_MENU_EDIT`'s description so its inventory includes Remove from
Playlist. Run the `vibe-strings` extraction path; never edit catalog extraction state by hand.

Add `playlist.selectedRow` to the macOS debug state if the live scenarios cannot otherwise prove
selection followed the removal. Do not add a production setting or persisted state.

**Acceptance:** `dump_menu` shows correct title, symbol, shortcut, enablement and identifier;
Backspace and Forward Delete each remove one row; repeat removes only one; Settings/About do
nothing; collapsed playlist does nothing; context removal targets the clicked row rather than an
older selection.

## Phase 5 — final verification

After reading the `vibe-debug` skill and generating its standard test audio:

1. Load four distinct short tones. Remove a non-current row before and after the current one while
   playing; position continues increasing and current-track identity does not change.
2. Remove the current middle row while playing; its successor becomes current and starts through
   the ordinary crossfade. Repeat paused and confirm the successor lands parked.
3. Remove the current last row while playing; the previous row becomes current and parked. Remove
   the sole row and confirm the same empty state and teardown as `⌘W`.
4. Start a slow/fake-cloud open, remove that current row before settlement, and verify the old
   settlement cannot repaint or stop the replacement.
5. Load an M3U containing `A, B, A`; remove each duplicate occurrence independently and verify URL
   lookup/deliveries reach only survivors.
6. Arm gapless playback, remove the parked successor near the boundary and confirm the new
   adjacent track advances. Repeat with On track end = Pause and confirm no advance.
7. Remove a row while metadata/art deliveries are landing, and a row while conversion is in
   flight. No removed row reappears; conversion output remains on disk when its source row is gone.
8. Run `check_consistency` after every structural scenario and `dump_health` after the slow/cloud
   cases.

Final gates:

```bash
make test
make build CONFIG=Debug
make build-ios CONFIG=Debug
make analyze CONFIG=Release
make check-layout
make check-vocabulary
make check-strings
make check-translations
```

## Interaction with other future plans

### Reopen last playlist

`docs/future/reopen-last-playlist.md` proposes
`PlaylistController.playlistDidChangeHandler(rowsChanged)`. Removal must call it exactly once with
`rowsChanged = YES`, after the model and cursor are coherent, so a removed row does not return at
the next launch. If that plan lands first, revise its statement that there is no per-row removal;
its process-held restored scopes may remain held for the session, but persistence must snapshot the
new rows immediately through its debounce.

### Shuffle

`docs/future/shuffle-mode.md` currently proposes a hidden permutation of row indexes. If shuffle
lands first, row removal must remove/rebase the departed index in that play order without repeating
or starving survivors, and current-row replacement must use shuffle's successor rather than the
linear row that slid into place. Prefer revising the shuffle plan to hold `AudioTrack` identities,
or add tested index-rebasing rules, before composing the features. Do not implement the linear
rules in this document blindly over a shipped shuffle mode.

### Drag reordering

`docs/future/playlist-drag-reordering.md` reuses `rebuildIndexes`, the structural-observer shape,
precise table updates, prefetch re-parking and the cross-feature rules above. Removal is useful on
its own and should land first; drag reordering remains a separate user-visible change and review.

## Explicit non-goals

- No Clear Playlist alias; use File > Close All Files.
- No file deletion or Trash integration.
- No multi-selection or batch removal.
- No undo/redo for playlist edits in this slice. (Added the day after, in the audit follow-up:
  `Playlist.insertTrack:atIndex:` as the removal's inverse and the shell's generation-stamped
  reinsert funnel — see `Mac/MainWindow/CLAUDE.md`.)
- No drag reordering here.
- No sortable columns, shuffle, repeat, saved playlist editor or library database.
- No iOS removal UI.
- No new preference, mode, background worker or ongoing playback cost.
