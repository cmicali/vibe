# Playlist table (macOS only)

The macOS half of `Vibe/Playlist/`:

- `PlaylistController` is the data source and delegate: cell *content*, the model observer, the drag session and the row menu.
- `PlaylistTableView` is everything *structural*: columns, row metrics, the scroll view, and the code-built cells and their styling.
- `PlaylistRowView` draws row backgrounds. `PlaylistTextCell` and `PlaylistCoverImageView` are cell parts.
- `PlaylistDropZoneView` draws the pane's Add and Replace wells and hit-tests them. The window is the dragging destination.
- `PlaylistFile+Session` is the last-playlist store. It saves and restores the mirror and owns the `VibeLastPlaylistCurrentIndex` defaults key. Only `MainPlayerController` calls it (`Mac/MainWindow/AGENTS.md`, The last playlist). It is here, not in the shell, so `PlaylistFileSessionTests` keeps testing it.

Model, cursor and index rules are `../AGENTS.md`'s. The shell's removal and reorder follow-ups are `Mac/MainWindow/AGENTS.md`'s.

## Cells

**Structure lives in `PlaylistTableView`, content in `PlaylistController`.** Nothing outside the table file defines a column, a cell layout or a font. The controller fills cells through `cellViewForColumn:` and the `+*CellString` helpers. The column identifiers key the column set, the prototypes and the reuse queue, so a misspelled literal renders an empty cell.

**TRAP: the vertical scroller is `PlaylistScroller`, which sets no cursor.** A borderless window resizes only from a 3pt strip inside its edge. A stock scroller's arrow cursor rect borders that strip on the right. Leaving a cursor rect clears whatever cursor override is up, so a move into the strip could drop the resize cursor.

**TRAP: every column's attributes must carry a truncating paragraph style.** Cell content is an attributed string, and its paragraph style beats the cell's `lineBreakMode`. The default wraps a long title into a clipped second line, and `PlaylistTextCell`'s own truncation is not enough.

**Cell attributes are cached until the `PlaylistAppearance` effect invalidates them** (`+invalidateCellAttributes`, then `reloadData`). `ensureCellAttributes` reads the theme's per-column colors (`resolvedPlaylistColorForBase:`, `Common/Mac/Theme/AGENTS.md`) and the playlist font.

**An evicted thumbnail shows the placeholder, and the cell callback never decodes.** Recovery posts the exact metadata object. `thumbnailDidLoad:` then reloads the art column of only the visible rows holding that object.

## Row appearance

**`PlaylistRowView` draws the row backgrounds, not AppKit.** `drawSelectionInRect:` calls no super and fills with the theme's selected-row color. `drawBackgroundInRect:` draws the playing-row color and skips a selected row, since two washes read as a brighter row. Text styling never varies with the playing state. The equalizer and the wash are the whole marking.

**`rowViewForRow:` stamps `playingRow`. `refreshRowViewPlayingStates` re-stamps the visible rows on every `currentIndex` change and every structural edit.** Cell reloads, removals, inserts and moves all rebuild or shift cell views while keeping row views.

## The number gutter

**The gutter has three states. In precedence they are loading, playing and number.** `configureNumberCell:row:track:isCurrentRow:` sets all three on every configure, so a reused cell cannot carry another row's state. It also reassigns `levelSource` every time, so a reused view releases its old source before declaring demand. Loading is `CloudTransferRegistry`'s `isTransferringURL:` (root `AGENTS.md`), drawn by `LoadingIndicatorView` in the equalizer's slot. It stays visible until the transfer ends, including during streamed playback.

**A registry change or a structural edit reconfigures the visible number cells in place** (`reconfigureVisibleNumberCells`, with `makeIfNecessary:NO`). Never use `reloadData` or a row reload here. Either rebuilds the playing row's `EqualizerIndicatorView` out from under its demand balancing.

**The indicator and the loading pill are always white in this gutter.** `PlaylistTableView` sets that at construction. Both are centered from the row edge to the artwork's bleed. The table derives AppKit's leading padding from the first column rect rather than assuming it.

**The gutter is an optional column** (`showPlaylistNumberColumn`, applied in `applyColumnVisibility`). Hiding it hides all three states. The playing row keeps its wash. With no cell, the indicator detaches and its level demand drops to zero by the ordinary rule. The art column then leads the row and inherits the leading padding. So `cellViewForColumn:` re-derives the cover's leading bleed on every fetch, because a reused cell outlives a toggle.

## Material visibility: the equalizer's macOS fold

**The playing row's indicator is active only for modeled output audio and material visibility. This directory owns the row half of the visibility fold** (root `AGENTS.md`). `MainPlayerController` supplies `equalizerAudioOutputActive` and `equalizerSurfaceVisible` (window occlusion). The controller ANDs the surface gate with `isCurrentEqualizerRowVisible`, the row's real intersection with the scroll clip and the window's content. It re-runs that check on every clip bounds change and on every write of either input. The surface boolean can stay true while a resize clips the row away. A scrolled-away row and the compact window height are both covered by that geometry. The poll, demand and release contracts are `Controls/AGENTS.md`'s and `Audio/Levels/AGENTS.md`'s.

## Wiring, the row menu and the keyboard

**`setTableView:` wires the delegate, data source, double-click, drag masks and the row menu.** The row menu is Show in Finder, then Copy Name and Copy File, then Remove from Playlist. Remove uses `minus.circle`, not `trash`, because the files stay on disk. Convert to FLAC is not a row action. It acts on the *current* track from `MainPlayerController`.

**A click inside the selection acts on the whole selection. A click outside it acts on that row alone** (`clickedTargetTracks`). The three content commands read their targets at action time. Removal is structural and captures them instead:

- **`menuNeedsUpdate:` captures the target `AudioTrack`s as weak pointers.** It is not `menuWillOpen:`, because AppKit validates the items in between. The capture is not cleared on close, because the action can run after `menuDidClose:`. Every open overwrites it. Validation and the action resolve the objects through `rowsForTracks:`, so a replacement while the menu is up cannot remove strangers.
- **The controller never removes.** The action raises `removeTracksRequestHandler` with the exact objects. Only the shell's removal funnel and its undo may call `removeTracksAtIndexes:` and `insertTracks:atIndexes:`. `moveTracksAtIndexes:toIndexes:` is for the shell's reorder undo alone. A drag lands through `acceptDrop`.

**The keyboard is AppKit's.** Arrows, shift and ⌘ selection and Select All come from `NSTableView` with `allowsMultipleSelection`. Return is `playSelectedTrack` on the **topmost** selected row (`selectedRow`, since `NSTableView.selectedRow` is the last-clicked one). Backspace and Forward Delete remove the whole selection (`selectedTracks`). None works while the playlist is collapsed. That gate belongs to `TransportKeyMonitor` (`Mac/MainWindow/Transport/AGENTS.md`) and the menu validation.

**TRAP: `PlaylistTableView`'s `validateMenuItem:` has no super to call.** None of `NSTableView`, `NSView` or `NSResponder` implements it, so calling super throws for any other nil-targeted action the table answers (`print:`, `deselectAll:`). Everything but `selectAll:` goes to `validateUserInterfaceItem:`, which `NSTableView` does implement.

## Replacement, append and play

**`loadTracks:selectingIndex:` replaces the list and lands the cursor. It opens nothing.** The shell follows with `play` or `playStartPaused:`, so an open and the launch restore share one path. A replacement calls `deselectAll` before `reloadData`, which would otherwise keep a stale selection by row index. `append:` inserts rows without animation and touches neither playback nor `currentIndex`.

**Every start goes through `playStartPaused:`.** So `playWillStartHandler` fires after submission for a parked start as for an ordinary one. No caller reaches `AudioPlayer` directly.

**`currentIndexDidChangeHandler` is the one current-index funnel. A structural edit does not raise it.** The shell's removal and reorder funnels refresh once from the final state, and a second edge would reconcile one edit twice.

`scrollCurrentTrackToVisible` runs on every track change and replacement. It scrolls minimally, and not at all for a visible row. Under shuffle it centers the row instead, clamped at the list's ends, since the next row is usually far off.

## Structural edits: precise row operations, never `reloadData`

**The observer reconciles each remove, insert and move once, with no animation.** It uses `removeRowsAtIndexes:`, `insertRowsAtIndexes:`, or the rules header's `moveRowAtIndex:toIndex:` sequence inside `beginUpdates` and `endUpdates`. Row views survive, so the wash and the equalizer travel with their rows.

**TRAP: `moveRowAtIndex:toIndex:` has no animation argument and slides by default, so it runs inside a zero-duration `NSAnimationContext` group.** A sliding row from off screen lands as a blank slot. A row still sliding when `endUpdates`' cleanup runs is retained by the table for good. The group closes the slot and most of the retention. Rapid back-to-back reorders or undos can still strand a few row views. That is an AppKit bug with no public-API cure.

Every edit ends with `refreshRowViewPlayingStates` and then `reconfigureVisibleNumberCells`, before returning to the run loop. So no frame shows two playing rows.

**Selection after an edit is presentation only and never plays.** A removal selects the row that closed the topmost gap, or the new last row. An insert (a removal's undo) and a move select the landed rows and scroll the first into view. An undo whose rows are off screen would otherwise read as a no-op.

**`playlistOrderDidChangeHandler` fires from the move observer, last, with the two sets.** It does not fire from the drop site, so every initiator, the undo stack included, gets the shell's one follow-up (`Mac/MainWindow/AGENTS.md`).

## Dragging rows: reorder inside, files outside

**One drag has two destinations, chosen by the operation mask.** Each row's `NSPasteboardItem` carries the private reorder type, with the session token as payload. The first dragged row of each file also carries its file URL, so a drop outside copies each file once. The mask is `NSDragOperationMove` locally and `NSDragOperationCopy` elsewhere. So inside the table a drag reorders, and onto the Finder or another app it copies the files.

**The private type plus the live token is the whole proof that a drop is this table's reorder** (`draggingInfoIsLiveReorderSession:`). A file URL alone is what an external drag carries too. The table registers only the private type, so an external file drag still falls to the window's wells. `MainWindow` refuses any in-app source, so a row dragged around the window never reads as an open.

**A remote placeholder is never dragged out** (`TrackCommands`' `handsOutURL:`). No other app could read its bytes. Its item carries only the reorder type, so its row still reorders. Copy Files skips it by the same answer.

**`willBeginAtPoint:` starts the security scope on each dragged URL, and `endedAtPoint:` balances it.** `endedAtPoint:` runs on drop and cancel alike. A receiver outside the app reads the files long after the session. Only URLs whose start answered YES are recorded, because an unbalanced stop over-releases the sandbox extension. A URL covered by a folder grant answers NO and drags fine.

**A row number captured at mouse-down is never trusted.** The payload is the exact `AudioTrack`s, re-resolved through `rowsForTracks:` at every validation and at the drop. A replaced playlist resolves to nothing and rejects the drag. A row converted away drops out alone. One qualification (`reorderDestinationForInfo:`) serves both the insertion line and the accept, so the line never promises a move the drop refuses.

**`PlaylistDragRules.h` is the one conversion from an AppKit insertion slot to model final positions**, tested in `Tests/Playlist/PlaylistDragRulesTests.m`. `VibePlaylistDropDestinationForSlot` solves the downward off-by-one. It answers nil for a no-op slot, so no insertion line is drawn there. A no-op is a contiguous block dropped onto or beside itself, or every row at once. `VibePlaylistMoveSequenceEnumerate` emits single-row moves in **evolving coordinates**: apply one before computing the next.

## Track commands

**`TrackCommands`**: reveal in Finder, copy the files, and copy the names, over an array of tracks. Copying the files skips a remote placeholder, whose bytes no other app could read (`handsOutURL:`, tested in `FolderWalkTests`). Menu validation reads no file, so Copy File stays enabled over a placeholder. When nothing is left to copy, it beeps. The playlist's drag out asks `handsOutURL:` too.
