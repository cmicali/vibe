# Playlist table (macOS only)

The `NSTableView` half of `Vibe/Playlist/`: `PlaylistController`, `PlaylistTableView`, `PlaylistRowView`, `PlaylistTextCell`, `PlaylistCoverImageView`, `PlaylistDropZoneView`. The shared model and the CUE/M3U readers are one directory up. The iOS list is `Vibe/iOS/LibraryViewController`, which shares only `EqualizerIndicatorView`.

## Structure vs content

`PlaylistTableView` owns everything **structural**: columns, row metrics, the enclosing scroll view (`scrollViewWithFrame:`, placed by `MainPlayerContentView`), the code-built cell views for track number and equalizer, artwork thumbnail, title and artist, and duration, and all their text styling. Cells are built in `makeCellViewWithIdentifier:` and recycled through the table's normal reuse queue.

`PlaylistController` is the `NSTableViewDataSource` and delegate and decides only cell **content**, through `cellViewForColumn:` and the formatting helpers.

An evicted embedded thumbnail returns the placeholder without decoding in the cell callback. Its bounded background recovery posts the exact metadata object; `PlaylistController` reloads only matching visible rows' artwork column when it arrives.

**TRAP: cell content is set as an *attributed* string, and an attributed string's own paragraph style overrides the cell's `lineBreakMode`.** Its default wraps, so every column's attributes must carry a truncating paragraph style of their own, or a long title wraps to a clipped second line instead of truncating. `PlaylistTextCell` sets `usesSingleLineMode`, which is what actually centers a cell's text vertically.

## Row appearance

Row backgrounds belong to `PlaylistRowView`, not to AppKit. **`drawSelectionInRect:` does not call super**, which replaces the system `selectedContentBackgroundColor` accent-blue fill with a neutral white or black wash at about 9%. The playing row draws the same wash from `drawBackgroundInRect:`, and skips it when the row is also selected, which already drew it.

`rowViewForRow:` sets `playingRow`, and `refreshRowViewPlayingStates` re-stamps it across the visible rows on every `currentIndex` change, because `reloadDataForRowIndexes:` rebuilds cell views but keeps row views.

**The playing row's bars follow the audio, from the same analyzer iOS uses.** `PlaylistController` hands every row the `levelSource` it was given — `MainPlayerController`, which owns the player and the window gate — and the indicator drives itself from there; see `Audio/Levels/CLAUDE.md` for the producer and `Controls/CLAUDE.md` for the renderer. On this platform the tap sits on the FX segment's output, so its snapshots include the dry signal and active reverb/delay returns. The shared audio documentation also records why a wet-only tail after every source stops has no reliable liveness edge.

The renderer and analyzer share one fail-closed activity decision. `MainPlayerController.syncEqualizerActivity` supplies actual output activity and material window visibility. `PlaylistController` adds the playing row's real intersection with both the scroll clip and window content, refreshing it on clip movement and resize. That intersection naturally covers a scrolled-away row and the compact window height that clips the playlist; it does not infer either from the UI update timer or the user's size intent.

Only an active row owns a 20–30 Hz snapshot/staleness poller. A new sequence retargets only materially changed retained layers; explicit scalar Core Animation animations provide display-cadence motion without a 60 Hz app callback, draw, path rebuild, layout or waveform invalidation. Starting the poller declares one `equalizerLevelsWanted:` consumer; stopping destroys the poller, releases that consumer, and leaves the player's tap absent at zero. A visible audio stop may finish one compositor-only release to dots; pixel or ownership loss cancels it immediately. Window occlusion, minimization, clipping, pause, stop and a Loading request with no audible outgoing fade therefore stop both the poller and the lower-rate FFT. An outgoing fade remains active until it is actually silent.

The macOS indicator is always white and never inherits artwork color. `PlaylistTableView` owns that styling when it constructs the cell, while iOS keeps the shared control's appearance-derived default. Its 16-point frame is centered across the whole visible gutter from the row edge to the artwork, including AppKit's leading full-width-table padding and excluding the artwork's four-point bleed. The frame derives that padding from the first column rect rather than assuming its size. The indicator and neutral row wash are the whole "playing" marking.

**The number gutter has three states, in precedence: loading, playing, number** — `configureNumberCell:row:track:isCurrentRow:`, the one place all three are set, unconditionally on every configure so a reused cell cannot carry a previous row's state. Loading is `CloudTransferRegistry.isTransferringURL:` — a provider transfer really running for the row's file, at most the lane capacity's worth of rows at once — drawn by the shared `LoadingIndicatorView` in the equalizer's slot, white like the bars. Loading outranks playing deliberately: while the open is in flight there is no output audio, so the equalizer would be a row of collapsed dots. On a registry change the controller reconfigures the **visible number cells in place** (`viewAtColumn:row:makeIfNecessary:NO`) — never `reloadData` and never row reloads, which would rebuild the playing row's `EqualizerIndicatorView` and disturb its demand balancing.

## Wiring and the context menu

`setTableView:`, called from `MainPlayerController.windowDidLoad`, wires the delegate, dataSource and double-click and installs the row context menu: Show in Finder, a separator, then Copy Name and Copy File, carrying the same SF Symbols their counterparts have elsewhere.

Those three act on the **clicked** row, and read `clickedRow` at action time rather than capturing it when the menu opened, since the playlist can be replaced while the menu is up. The window-body menu's items and the Convert menu's act on the *current* track and stay with `MainPlayerController`. **Convert to FLAC is deliberately not a row action** — it converts the current track only.

Below them, after a separator, sits **Remove from Playlist** (`minus.circle`, not `trash`: this edits the in-memory list and leaves the file on disk). It is the one row command that changes **structure**, and that changes how it names its row twice over.

- **It captures the clicked `AudioTrack` as the menu opens**, in `menuNeedsUpdate:`. Validation resolves that object through `getIndexForTrack:`, while the action forwards only the object and the shell resolves its live row once. The content commands can afford to re-read `clickedRow`, because acting on the wrong row merely copies the wrong name; a structural edit that fell through onto whatever a playlist replacement put at that number would remove an unrelated track. A departed object resolves to `-1` and the action no-ops; an object merely shifted by another edit is followed to its live row. **The capture is in `menuNeedsUpdate:`, not `menuWillOpen:`, because AppKit validates the items in between** — the validator has to see a fresh capture. It is weak and is deliberately *not* cleared when the menu closes: the chosen item's action can run after that callback, which would leave the removal with nothing to act on. Every open overwrites it, and a weak reference holds nothing open in the meantime.
- **It does not perform the removal.** The controller raises `removeTrackRequestHandler` with the exact object, and the shell decides the playback consequences — removing the *current* row is a transport operation, and this directory owns no player, download monitor, waveform, metadata sweep or empty-state teardown. `removeTrackAtIndex:` here is the pass-through the shell calls once it has decided; nothing a user gesture reaches may call it directly.

## Keyboard

The up and down arrows are `NSTableView`'s own `moveUp:`/`moveDown:`; nothing here implements them. Return is their counterpart, `playSelectedTrack`, which takes the same two steps `doubleClick:` does. Both read the selection **at action time**, like the context menu's clicked row, because the playlist can be replaced between the press and here.

Backspace and Forward Delete are the other pair, and they remove the selected row rather than playing it — again read at action time, and again nothing here implements them.

None of them works while the playlist is collapsed. That gate is not here — the table has no say in the window's height — but in `TransportKeyMonitor` (`Mac/MainWindow/CLAUDE.md`), which swallows all six keys, and in the menu validation of Play Selected Track and Remove from Playlist, which share one gate: the player window key, the pane showing, *and* a selection.

## Scrolling and swaps

`play:` replaces the list; `append:` extends it without touching playback or `currentIndex`. Every track change calls `scrollCurrentTrackToVisible`, a no-op while the row is already visible. Nothing else scrolls the table.

`replaceTrackAtIndex:withURL:` and `indexesOfTracksWithURL:` forward to the model and are where the convert swap lands — see `Vibe/Playlist/CLAUDE.md` for why the model keeps a URL index, and `Mac/MainWindow/CLAUDE.md` for why the swap mints a fresh `AudioTrack`.

`currentIndexDidChangeHandler` is this shell's one current-index funnel, and is what sends a playlist position to the metadata cache's cloud-lane ranking (`Audio/Metadata/CLAUDE.md`).

`playStartPaused:` is `play`'s parked twin, for the shell's removal funnel: it submits the current track at its start with nothing rendering until playPause, through the same funnel, so `playWillStartHandler` fires after submission exactly as an ordinary start's does. Keeping it here rather than letting the shell reach `AudioPlayer` directly is what preserves the one-play-funnel rule — the header is repainted at submission, which is all a slow open would otherwise show.

## Removal: the precise table update

The model's removal event is one edit, so the table reconciles it once, in the observer method and nowhere else:

1. `removeRowsAtIndexes:withAnimation:` with **no animation** — a deletion shifts every row below it, and sliding thousands of them is motion and work nobody asked for, the same reason the append inserts without one. The model has already shrunk, so `numberOfRows` agrees.
2. Selection moves to the row that closed the gap, or to the new last row when the removed one was at the end. **Presentation only** — it must never call `playSelectedTrack`, and the playing row stays a separate concept from the selection.
3. `refreshRowViewPlayingStates` re-stamps the visible rows from the final cursor: a row removal keeps row views, exactly as a cell reload does.
4. All visible **number cells** are reconfigured in place (`reconfigureVisibleNumberCells`, shared with the cloud-transfer refresh), so their numbers, loading bars, equalizer ownership and current equalizer visibility agree. The full visible pass includes the promoted row when the removed current row was last and costs at most one screenful. Never `reloadData` and never row reloads, which would rebuild the playing row's `EqualizerIndicatorView` and disturb its demand balancing.

**`currentIndexDidChangeHandler` is deliberately NOT invoked** as a second edge for the same edit. The shell's removal funnel refreshes the metadata neighborhood and the transport once, from the final state, right after the synchronous mutation returns; raising the ordinary cursor callback as well would make one structural edit reconcile twice and obscure the ordering.

The insert event — the undo of a removal — mirrors the same reconciliation: `insertRowsAtIndexes:` with no animation, re-stamped row views, reconfigured number cells, no cursor callback. It differs in one deliberate way: the restored row is selected **and scrolled to visible**, because an undo whose row is off screen would otherwise read as a no-op. `insertTrack:atIndex:` is the same pass-through contract as `removeTrackAtIndex:` — only the shell's undo funnel calls it.
