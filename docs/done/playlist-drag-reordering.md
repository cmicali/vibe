# Done: Playlist drag reordering, multi-select and group delete (macOS)

Written 2026-08-23 as a single-row plan; implemented 2026-08-26 on top of
`docs/done/playlist-row-removal.md`, at the user's request **with multi-select added** — group
drag, group delete, and a selection-aware row context menu — which this plan had scoped out.
The body below is the plan as written; where it and the code disagree, the code and the
directory `CLAUDE.md`s are the authority. The deliberate divergences:

- **Every structural model op is batch-shaped, and the single-row APIs are gone.** The plan's
  `moveTrackAtIndex:toIndex:` was never built; `moveTracksAtIndexes:toIndex:` is the one move op
  and a single row is the one-index case. Row removal's `removeTrackAtIndex:` /
  `insertTrack:atIndex:` and their observer events were likewise **replaced** by
  `removeTracksAtIndexes:` / `insertTracks:atIndexes:` (the undo pair generalized with them:
  `reinsertPlaylistTracks:atIndexes:generation:`), so one code path serves both arities.
- **The move event carries only sources and destination.** `previousCurrentIndex` had no
  consumer — `refreshRowViewPlayingStates` re-stamps from final state — and was dropped.
- **`PlaylistDragRules.h` grew a second pure function**, `VibePlaylistMoveSequenceEnumerate`:
  the evolving-coordinate `moveRowAtIndex:toIndex:` sequence for a group drop is exactly the
  kind of off-by-one arithmetic the seam exists to test. The slot-`count` clamp special case
  disappeared into the general `slot − |sources below slot|` formula.
- **The visual reconciliation reuses removal's whole-visible-band pass** rather than the plan's
  `min(source, destination)` band; `reconfigureVisibleNumberCells` was already the shared helper
  and is bounded by one screenful anyway.
- **A group drag proceeds with its survivors.** Retained dragged objects that no longer resolve
  (replacement, convert swap, removal mid-drag) drop out per track; the drag dies only when none
  survive. All-or-nothing would let one background conversion silently kill a ten-row drag.
- **Multi-select fallout the plan scoped out**: `allowsMultipleSelection` is on, which enables
  Edit > Select All through the table's existing validator; Return plays the topmost selected
  row (`selectedRow` pins that deterministically); the delete pair and Edit > Remove act on the
  whole selection through the renamed `removeSelectedPlaylistTracks:` /
  `removePlaylistTracks:` funnel; Select All + Delete routes to `closeFile:` like the one-row
  playlist did; the context menu follows the platform rule (click in selection → selection,
  outside → that row) with a weak-pointer-array capture; `TrackCommands` takes track arrays.
- **The prefetch re-park in `playlistOrderDidChangeHandler` is gated on a not-Stopped player**,
  matching the gate removal grew after this plan was written.
- **Moves are undoable**, reversing this plan's no-undo non-goal at the user's request. The
  model op generalized to set-to-set (`moveTracksAtIndexes:toIndexes:`), making it its own
  inverse with the sets swapped; `playlistOrderDidChangeHandler` carries the sets and is the
  one undo-registration point, firing for drag, undo and redo alike, so `NSUndoManager`'s
  unwind routing chains redo with no second bookkeeping path. The action name is the new
  `menu.edit.reorder` string, translated into every catalog language.
- Accessibility: the VoiceOver verification the plan requires has **not** been run, and the
  conditional Move Up/Move Down custom actions were not added — both remain open follow-ups.

Live verification requires the `vibe-debug` skill; pointer drags are manual.

## The feature

Drag one row within the visible macOS playlist to change its position:

- The standard table insertion line shows where the row will land.
- No grip or extra column is added: dragging anywhere on a row after AppKit's normal threshold
  starts the move, while an ordinary click still only selects.
- The row's existing `AudioTrack` object moves; metadata, artwork, analyzed BPM/key and async
  identity move with it.
- Reordering the current row, or moving another row across it, does not restart playback or move
  the playhead. The playing marker follows the current object to its new row.
- Next, Previous, track-end advance and gapless prefetch follow the new visible order immediately.
- The moved row remains selected and is scrolled into view at the drop.
- The source audio file is never moved, renamed, copied or rewritten.

The table stays single-selection. This plan does not add group drag, multi-selection, external-file
insertion at an exact row, persistent saved playlists or a general sorting system.

## Behavior contract

### Drag source and destination

Only `PlaylistTableView` may originate this drag, and only the same table/controller may accept
it. Use a private pasteboard type for an internal reorder; do not put a file URL on the pasteboard,
because the window's existing external-file drop path interprets file URLs as Add/Replace opens.

At drag start, retain the exact `AudioTrack` object. At every validation and at the drop, resolve
its current row through `getIndexForTrack:`. If an open replaced the playlist, Convert minted a
fresh row object, or removal took the row while the drag session was active, lookup returns `-1`
and the drop is rejected. Do not trust a row number captured at mouse-down.

Mint a unique token for each drag session, write that token under the private pasteboard type and
retain the same token beside the track. Validation and acceptance require the same table source,
type and token. Mere presence of Vibe's private type is not proof that a stale or fabricated
pasteboard belongs to the active session. Clear both token and retained track when the session
ends or is cancelled.

Accept only `NSTableViewDropAbove` positions:

- proposed insertion rows range from 0 through `count`;
- when the source row is before the proposed insertion row, subtract one after removal to obtain
  the final row index;
- otherwise the proposed insertion row is already the final index;
- clamp only the legal edge representation (`count` to final `count - 1`); malformed positions
  are rejected, not guessed;
- a final index equal to the source index is a no-op and sends no model event.

The model API takes a **final row index**, not an AppKit insertion index. State that in the header
so the downward-move off-by-one is solved once at the view boundary. Put this conversion in the
pure `PlaylistDragRules.h` seam and unit-test it; do not bury it in an AppKit delegate method.

Drag validation and insertion-line updates stay O(1): token comparison, identity lookup and slot
arithmetic only. Do not rebuild either playlist index or reload table data while the mouse moves.
An accepted, non-no-op drop performs exactly one O(n) model index rebuild.

### Playback and cursor

The current track is preserved by object identity:

- dragging the current row sets `currentIndex` to its destination;
- moving another row from before current to after it shifts `currentIndex` down;
- moving another row from after current to before it shifts `currentIndex` up;
- a move that stays entirely on one side of current leaves the numerical cursor unchanged.

No move calls `AudioPlayer.play`, `play:atPosition:startPaused:`, `stop`, `finishCurrentTrack`,
pause or resume. Loading/playing/paused/stopped/error intent and playhead position remain exactly as
they were.

Every successful move re-submits `successorPrefetchTrack`, even when the likely successor appears
unchanged. A user gesture is rare, and unconditional reconciliation is safer than duplicating
successor identity logic in the table. `prefetchTrack:` is the gapless arm point: it must unqueue
an old linear neighbor before a track-end splice can promote it.

The current-index metadata neighborhood is also recomputed once after every move, even when the
current numerical index did not change: its next two and previous one rows may all be different.

### Visual result

Use `NSTableView.moveRowAtIndex:toIndex:` after the model has moved. Do not call `reloadData`:

- the moved row's cells already describe the same `AudioTrack` object;
- a full reload destroys and recreates the playing equalizer unnecessarily;
- selection and scroll position are easier to preserve with the precise operation.

After the move:

1. select the final row;
2. re-stamp visible playing-row flags from the model's new `currentIndex`;
3. reconfigure visible number-column cells throughout `min(source, destination)` through
   `max(source, destination)` so their displayed row numbers and loading/equalizer states agree;
4. reconcile the current equalizer's material visibility;
5. scroll the final row into view only if needed.

Dragging is unavailable while the playlist is collapsed because the table is not a material
surface there. The window-wide Add/Replace drop wells remain unchanged.

### Accessibility

Before shipping, verify with VoiceOver whether AppKit exposes the row move as an accessible drag.
If it does not, add `NSAccessibilityCustomAction`s named **Move Up** and **Move Down** to the
selected row/table, routed through the exact same model move funnel. Do not create a second reorder
implementation. The actions disable at their respective playlist boundaries and must be declared
through `VibeStrings.h` using the `vibe-strings` skill.

This plan deliberately adds no general keyboard shortcut: bare Up/Down already move selection,
modified variants are not established Vibe transport vocabulary, and an invisible shortcut is not
the primary affordance the request calls for.

## How dragging works today

There is no internal playlist drag source or destination. `PlaylistTableView` builds four fixed,
headerless columns and explicitly disables column reordering; it is single-selection and delegates
content to `PlaylistController`.

External Finder drops are owned by `MainWindow`, which accepts file URLs only when
`draggingSource` is nil and forwards the location to `PlaylistDropZoneView`'s Add/Replace wells.
That rejection is useful: an internal row drag must be consumed by the table and never fall through
as a file open.

The shared `Playlist` model currently says rows never move. `_trackIndexes` and `_indexesByURL`
therefore store row positions without any shift-repair path, and `currentIndex` is positional. The
row-removal plan introduces the auditable one-pass index rebuild and a coherent structural observer
event; this feature extends both rather than creating drag-only storage in the AppKit layer.

## Phase 1 — Shared model move

Files: `Vibe/Playlist/Playlist.{h,m}`, `Vibe/Playlist/CLAUDE.md`, `Tests/PlaylistTests.m` and
`Vibe/iOS/PlaybackController.m`.

### 1a. Public operation

Add:

```objc
// Moves one existing row to its final index. The exact AudioTrack object and
// current-track identity survive. Returns NO for invalid or no-op moves.
- (BOOL)moveTrackAtIndex:(NSUInteger)sourceIndex
                 toIndex:(NSUInteger)destinationIndex;
```

The implementation:

1. Reject an out-of-range source/destination or equal indexes with no event.
2. Capture `previousCurrentIndex` and the exact current `AudioTrack`.
3. Remove the source object and insert that same object at the final destination.
4. Run the row-removal plan's `rebuildIndexes` once.
5. Resolve the captured current object through the rebuilt identity map and assign
   `_currentIndex` directly.
6. Fire one structural move observer event after the entire model is coherent.

Proposed event shape:

```objc
- (void)playlist:(Playlist *)playlist
        didMoveTrack:(AudioTrack *)track
           fromIndex:(NSUInteger)sourceIndex
             toIndex:(NSUInteger)destinationIndex
 previousCurrentIndex:(NSUInteger)previousCurrentIndex;
```

Do not also fire `currentIndexDidChangeFromIndex:`. As with removal, one structural action has one
observer edge; the shell derives table and cursor work from its payload and final model state.

### 1b. Unit tests

Add deterministic model cases for:

- first-to-last, last-to-first, upward and downward middle moves;
- invalid and same-row moves: return NO and no event;
- exact final-index semantics at the model boundary;
- moved `AudioTrack` identity and installed metadata preserved;
- current object follows when it moves;
- current object follows when another row crosses it in either direction;
- moves wholly before or after current;
- every survivor's identity lookup reports its new row;
- duplicate URLs still report every occurrence while their separate object lookups distinguish
  rows;
- `trackForURL:` reports the first occurrence in the new order;
- exact observer payload and synchronous ordering.

**Acceptance:** `make test`, `make check-layout`, `make check-vocabulary`, and
`make build-ios CONFIG=Debug`.

### 1c. Shared-target fallout

Implement the new required `PlaylistObserver` move selector in iOS `PlaybackController` as a no-op.
No iOS drag UI is added, so do not add a speculative `PlaybackObserver` event or view refreshes just
to keep the shared target compiling. Unlike removal, a move is transport-safe at the model boundary
because the exact current `AudioTrack` object survives, but a future iOS caller must still go through
`PlaybackController` and add the screen reconciliation its actual feature needs; a view may never
mutate the private playlist directly.

## Phase 2 — AppKit drag source and destination

Files: `Vibe/Playlist/Mac/PlaylistController.{h,m}`,
`Vibe/Playlist/Mac/PlaylistTableView.{h,m}`, `Vibe/Playlist/Mac/PlaylistDragRules.h`,
`Vibe/Playlist/Mac/CLAUDE.md` and `Tests/PlaylistDragRulesTests.m`.

### 2a. Tested insertion-slot rule

Add an AppKit-free `PlaylistDragRules.h` helper that takes source row, proposed insertion slot and
pre-move count, and either rejects the input or returns the model's final destination. Cover:

- every legal insertion slot from 0 through `count`;
- upward and downward moves, including the required subtraction for a source before its slot;
- first/last edges, a one-row playlist, same-row/no-op results and malformed positions;
- a count or row at the integer boundary without underflow.

The helper returns a decision and the destination; it performs no mutation and imports no AppKit.
Its host-less tests own the downward off-by-one that model tests cannot see. Import the platform
header as `../Vibe/Playlist/Mac/PlaylistDragRules.h`, matching the existing iOS-rules tests; the
VibeTests target does not search `Vibe/Playlist/Mac`, and this header-only seam needs no new source
entry or `project.yml` change.

### 2b. Private drag representation

Define one private pasteboard type, scoped to the playlist controller. The pasteboard payload only
contains the live session's unique token; the authoritative row payload stays in the controller as
the retained `AudioTrack` object.

Implement the relevant `NSTableViewDataSource`/dragging hooks:

- vend a pasteboard writer for a valid row and retain its track;
- advertise move, never copy, for local drags;
- validate only the same table, the private type, the matching session token and a still-indexed
  retained track;
- register the table for the private type when it is attached; do not register file URLs;
- set the drop operation to Above;
- convert proposed insertion row through `PlaylistDragRules.h`;
- return `NSDragOperationNone` for a helper-reported no-op, so dropping beside the source does not
  pretend to perform a move;
- clear the token and retained track on completion/cancel so a finished drag cannot be reused.

If the implementation needs a staleness counter, name it for the protected thing, such as
`playlistDragGeneration`; do not introduce a bare counter. Identity lookup is sufficient for the
known replacement/convert/removal races, so prefer it unless testing finds a missing edge.

### 2c. Mutation ownership

`PlaylistController` may perform the pure model move because a move never changes playback intent.
After the model observer has applied the table update, fire one synchronous
`playlistOrderDidChangeHandler` block owned by `MainPlayerController`. The owner uses that edge to:

- re-submit `successorPrefetchTrack`;
- refresh Next/Previous and Now Playing command availability;
- recompute the metadata neighborhood directly, exactly once; do not misuse
  `currentIndexDidChangeHandler` as a second structural reconciliation edge;
- update UI without reloading the current track's waveform or artwork.

Do not let AppKit mutate a private array directly. Every move, including a future accessibility
action, goes through `Playlist.moveTrackAtIndex:toIndex:` and its observer.

### 2d. Precise row presentation

Handle the move observer with `moveRowAtIndex:toIndex:` and the visual reconciliation in the
Behavior contract. A move across the playing row must not briefly leave two rows marked playing or
two active equalizer consumers. Restamp and reconcile in the same main-thread callback before
returning to the run loop.

**Acceptance:** manually pointer-drag every direction, including one-row and boundary no-ops. The
insertion line, final order, selection, row numbers and playing marker agree without a full-table
flash. On a 50,000-row playlist, hover/validation remains smooth and an accepted drop causes one
index rebuild and one precise table move, never a reload. Use a debug-only counter or signpost if
code inspection cannot prove the rebuild count, and remove temporary instrumentation before the
change lands; do not add production logging.

## Phase 3 — Playback, prefetch and race reconciliation

Files: `Vibe/Mac/MainWindow/MainPlayerController.m`,
`Vibe/Mac/MainWindow/MainPlayerController+PlayerEvents.m` only if a verified race requires a
change, and `Vibe/Mac/MainWindow/CLAUDE.md`.

Wire `playlistOrderDidChangeHandler` beside `playWillStartHandler` and
`currentIndexDidChangeHandler`. Its production behavior is deliberately small:

```objc
[self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
[self.metadataCache setNeighborhoodAroundIndex:self.playlistController.currentIndex
                                       inTracks:self.playlistController];
[self updateUI];
```

If the playlist observer already invokes the neighborhood handler, do not invoke it a second time;
the requirement is one final-state recomputation, not this exact spelling.

The move never calls a play funnel. That distinction is load-bearing:

- a current-row move must not mint a play submission, crossfade, reset position, add an Open Recent
  entry, reload waveform/art or restart listening stats;
- a Loading current row remains the exact pending play object, so its later settlement still
  passes the current-track guard at the object's new index;
- a paused/stopped/error current row keeps the same display/player relationship.

No new gapless fallback is expected. `prefetchTrack:` already unqueues a parked wrong successor,
and `didAutoAdvanceFromTrack:toTrack:` already compares the promoted object with the playlist's
actual next row. Verify both before deciding code is needed.

The metadata sweep is not restarted. Pending records may retain their original broad ordering, but
the live three-row neighborhood is the user-visible priority and is re-ranked immediately; parsed
results resolve moved tracks through the rebuilt identity map.

**Acceptance:** while a long tone plays, move the current row and rows across it in both directions;
the playhead increases monotonically, player/current identity stays equal and the next natural
advance follows the new visible neighbor.

## Phase 4 — Debug visibility and final verification

Add debug surface only where the existing state is insufficient to prove behavior. Useful facts:

- ordered playlist paths and current index already appear in state;
- gapless armed state already appears;
- add selected row and, if needed, the active drag row only to the macOS debug dictionary, never to
  the shipping public surface.

The debug channel cannot synthesize a genuine `NSDraggingSession`; its `drag` verb posts pointer
events and the file-drop verbs call a delegate directly. Therefore pointer drag, insertion-line,
cancel and VoiceOver behavior below are manual checks. Use `dump_state`, `check_consistency` and
screenshots after each manual drop as oracles; do not claim the debug command performed the drag.

After reading `vibe-debug` and generating its standard test audio:

1. Load `A, B, C, D`; drag every row upward and downward, including first/last and no-op insertion
   positions. Compare the visible order with `dump_state` after every drop.
2. Play `B` and drag it to first and last. Current object and header remain B, position keeps
   increasing, and the equalizer follows its row.
3. While B plays, move A/C/D across it without moving B. The numerical current index adjusts but
   audio does not restart.
4. Pause B, reorder, resume and confirm it continues from the same position. Repeat while B is in
   a fake-cloud Loading state and after an error.
5. Use an M3U ordered `A, B, A`; move either A independently and confirm identity-based delivery
   and selection follow the intended occurrence.
6. Arm a gapless successor, drag a different row into the next position near the boundary and
   confirm the newly adjacent row advances. Repeat by moving the old successor away, and with On
   track end = Pause.
7. Move a row while metadata/art is landing and while that row is converting. Delivery and the
   conversion swap resolve the row's new index.
8. Begin a drag, replace the playlist before dropping, and confirm the stale drag is rejected with
   no mutation.
9. Exercise VoiceOver. If AppKit exposes no usable reorder, verify the Move Up/Move Down custom
   actions and their boundary enablement.
10. Run `check_consistency` after every structural case and `dump_health` after Loading/gapless
    races.
11. Load a local M3U with 50,000 rows and let background work settle, then drag near the beginning,
    middle and end. Confirm validation does no O(n) work while hovering and each accepted drop
    performs exactly one index rebuild. Record the measurement with the implementation review.

Final gates:

```bash
make test
make build CONFIG=Debug
make build-ios CONFIG=Debug
make analyze CONFIG=Release
make check-layout
make check-vocabulary
make check-strings        # when accessibility action names were needed
make check-translations   # same condition
```

## Interaction with other future plans

### Row removal

`docs/done/playlist-row-removal.md` has landed. Reuse its `rebuildIndexes`, one-event
structural observer discipline, precise row reconciliation and cross-target implementations. Do
not add a second drag-owned index or notify the shells through replace-all.

### Reopen last playlist

`docs/future/reopen-last-playlist.md` proposes
`PlaylistController.playlistDidChangeHandler(rowsChanged)`. A successful move calls it exactly once
with `rowsChanged = YES`, after the final row order and cursor are coherent, so the visible order is
the order restored at the next launch. No-op/rejected drags call it zero times.

### Shuffle

`docs/future/shuffle-mode.md` currently proposes `_playOrder` as row indexes and says row replacement
is safe because it moves no row. Drag reordering invalidates that assumption. If shuffle lands
first, one of these must be decided and tested before this feature ships:

1. hold `AudioTrack` identities in the hidden play order, resolving visible indexes only for
   presentation; or
2. rebase every stored row index after a visible move while preserving the played-history cursor
   and no-repeat guarantee.

The first is easier to compose with both removal and reorder. In either design,
`successorPrefetchTrack` must ask shuffle's successor peek rather than `currentIndex + 1`; this
feature's unconditional re-park then picks the correct shuffled object. Do not assume visible
adjacency while shuffle is active.

## Explicit non-goals

- No row removal in this file; it is the prerequisite plan, and it has shipped.
- No multi-selection or group drag.
- No external file insertion at a chosen row.
- No file movement, copying, renaming or Trash operation.
- No undo/redo for a move in this slice.
- No Move Up/Move Down visible menu unless accessibility verification proves a custom action is
  insufficient.
- No sortable columns, automatic sorting, shuffle, repeat or saved-playlist editor.
- No iOS drag-reorder UI.
- No new preference, persistent mode, background worker or ongoing playback cost.
