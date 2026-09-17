# Playlist table (macOS only)

The `NSTableView` half of `Vibe/Playlist/`: `PlaylistController` (data source and delegate — cell *content*, the model observer, the drag session, the row menu), `PlaylistTableView` (everything *structural* — columns, row metrics, the scroll view, the code-built cells and their styling), `PlaylistRowView` (row backgrounds), `PlaylistTextCell`, `PlaylistCoverImageView`, and `PlaylistDropZoneView` (the pane's Add/Replace wells — presentation and hit-testing only; the window is the dragging destination). Model, cursor and index rules are `../CLAUDE.md`'s; the shell's removal and reorder follow-ups are `Mac/MainWindow/CLAUDE.md`'s.

## Cells

**Structure in `PlaylistTableView`, content in `PlaylistController`.** Nothing outside the table file defines a column, a cell layout or a font; the controller fills cells through `cellViewForColumn:` and the `+*CellString` helpers. The column identifiers key the column set, the prototypes and the reuse queue, so a literal misspelled on either side renders an empty cell.

**TRAP: cell content is an *attributed* string, and its own paragraph style overrides the cell's `lineBreakMode` — the default wraps.** Every column's attributes must carry a truncating paragraph style of their own, or a long title wraps into a clipped second line. `PlaylistTextCell` sets truncation and `usesSingleLineMode` as well, and its `drawingRectForBounds:` is what centers the line vertically — unconditional because the cell is never editable, so no field editor is misplaced.

**Cell attributes are cached and invalidated by the `PlaylistAppearance` effect** (`+invalidateCellAttributes` + `reloadData`), never cached forever: `ensureCellAttributes` reads the theme's per-column colors (`resolvedPlaylistColorForBase:`, `Common/Mac/Theme/CLAUDE.md`) and the playlist font slot.

**An evicted thumbnail returns the placeholder without decoding in the cell callback.** Recovery posts the exact metadata object; `thumbnailDidLoad:` reloads the art column of only the visible rows holding that object.

## Row appearance

**Row backgrounds are `PlaylistRowView`'s, not AppKit's.** `drawSelectionInRect:` calls no super, replacing the accent-blue fill with the theme's selected-row color; `drawBackgroundInRect:` draws the playing-row color and skips a selected row, which already drew — two washes read as a brighter row. Both are read per draw; the record lookup is cheap. Text styling never varies with the playing state: the equalizer and the wash are the whole marking.

**`rowViewForRow:` stamps `playingRow`, and `refreshRowViewPlayingStates` re-stamps the visible rows on every `currentIndex` change and every structural edit**, because cell reloads, row removals, inserts and moves all rebuild or shift cell views while keeping row views.

## The number gutter

**Three states, in precedence: loading, playing, number — set unconditionally by `configureNumberCell:row:track:isCurrentRow:` on every configure**, so a reused cell cannot carry a previous row's state; `levelSource` is reassigned every time so a reused view releases its old source before declaring demand. Loading is `CloudTransferRegistry.isTransferringURL:` (root `CLAUDE.md`'s loading-bar guarantee), drawn by `LoadingIndicatorView` in the equalizer's slot. Loading outranks playing: during the open there is no output audio, so the equalizer would be collapsed dots.

**A registry change or a structural edit reconfigures the visible number cells in place (`reconfigureVisibleNumberCells`, `viewAtColumn:row:makeIfNecessary:NO`) — never `reloadData` and never a row reload**, which would rebuild the playing row's `EqualizerIndicatorView` out from under its demand balancing.

**The indicator and the loading pill are always white** — set by `PlaylistTableView` at construction; this gutter never inherits artwork color, while iOS keeps the control's default. Both are centered across the visible gutter from the row edge to the artwork's bleed, deriving AppKit's leading full-width padding from the first column rect rather than assuming it.

**The gutter is a themed column (`AppTheme.showPlaylistNumberColumn`, beside the art and duration switches in `applyThemedColumnVisibility`), and hiding it hides all three states** — the playing row keeps its wash, and the hidden column has no cells, so the indicator detaches and its level demand drops to zero by the ordinary attachment rule. Every gutter lookup already tolerates a missing cell. The art column then leads the row and inherits that leading padding, so `cellViewForColumn:` re-derives the cover's leading bleed on every fetch — a reused cell outlives a toggle.

## Material visibility: the equalizer's macOS fold

**The playing row's indicator is active only for modeled output audio *and* material visibility, and this directory owns the row half of the visibility fold** (root `CLAUDE.md`). `MainPlayerController` supplies `equalizerAudioOutputActive` and `equalizerSurfaceVisible` (window occlusion); the controller ANDs the surface gate with `isCurrentEqualizerRowVisible` — the row's real intersection with the scroll clip *and* the window's content — and re-runs it on every clip bounds change (`NSViewBoundsDidChangeNotification`) and on every write of either input, since the surface boolean can stay true while a resize clips the row away. A scrolled-away row and the compact window height are covered by that geometry; nothing infers them from the UI tick or the user's size intent. Every row gets the `levelSource` the shell handed the controller; the poll, demand and release contracts are `Controls/CLAUDE.md`'s and `Audio/Levels/CLAUDE.md`'s.

## Wiring, the row menu and the keyboard

**`setTableView:` (from `MainPlayerController.windowDidLoad`) wires delegate, data source, double-click, the drag masks and the row menu**: Show in Finder, then Copy Name and Copy File, then Remove from Playlist (`minus.circle`, not `trash` — the files stay on disk). Convert to FLAC is deliberately not a row action; it and the window-body menu act on the *current* track from `MainPlayerController`.

**A click inside the selection acts on the whole selection, outside it on that row alone (`clickedTargetTracks`).** The three content commands read it at action time, since the playlist can be replaced while the menu is up and their worst case is copying the wrong name. Removal is structural and captures instead:

- **`menuNeedsUpdate:` captures the target `AudioTrack`s as weak pointers — not `menuWillOpen:`, because AppKit validates the items in between** and the validator needs a fresh capture. **The capture is deliberately not cleared on close**: the chosen action can run after `menuDidClose:`. Every open overwrites it. Validation and the action resolve the objects through `rowsForTracks:` — departed objects drop out, shifted ones are followed, and the action no-ops only when none survive — so a replacement while the menu is up cannot remove strangers.
- **The controller never removes.** The action raises `removeTracksRequestHandler` with the exact objects. `removeTracksAtIndexes:` and `insertTracks:atIndexes:` are pass-throughs only the shell's removal funnel and its undo may call (root `CLAUDE.md`), and `moveTracksAtIndexes:toIndexes:` exists for the shell's reorder undo alone — the drag lands through `acceptDrop`.

**The keyboard is AppKit's.** Arrows, shift and ⌘ selection and Edit > Select All are `NSTableView`'s own, enabled by `allowsMultipleSelection`; nothing here implements them. **TRAP: `validateMenuItem:` has no super to call** — it is a protocol method none of `NSTableView`, `NSView` or `NSResponder` implements, so everything but `selectAll:` is answered by `validateUserInterfaceItem:`, which `NSTableView` does implement; a second nil-targeted action the table answers to (`print:`, `deselectAll:`) would otherwise throw on validation whenever the table has focus. Return is `playSelectedTrack` — `doubleClick:`'s two steps on the **topmost** selected row (`selectedRow`; `NSTableView.selectedRow` is the last-clicked one). Backspace and Forward Delete remove the whole selection (`selectedTracks`). All three read the selection at action time. None works while the playlist is collapsed — that gate is `TransportKeyMonitor`'s (`Mac/MainWindow/Transport/CLAUDE.md`) and the menu validation's, not the table's.

## Replacement, append and play

**`loadURLs:selectingIndex:` replaces the list and lands the cursor, opening nothing**; the shell follows with `play` or `playStartPaused:`, so an open and the launch restore share one path. `append:` inserts rows without animation and touches neither playback nor `currentIndex`. A replacement `deselectAll`s before `reloadData`, which would otherwise keep a stale selection by row index. `scrollCurrentTrackToVisible` runs on every track change and is the only scroller.

**`playStartPaused:` is `play`'s parked twin and every start goes through it**, so `playWillStartHandler` fires after submission for a parked start exactly as for an ordinary one — the header is repainted at submission, which is all a slow open would otherwise show. No caller reaches `AudioPlayer` directly.

**`currentIndexDidChangeHandler` is the one current-index funnel** (the metadata cache's cloud-lane ranking rides it), and **a structural edit deliberately does not raise it** — the shell's removal and reorder funnels refresh the neighborhood and the transport once from the final state, and a second edge would reconcile one edit twice.

`replaceTracksMatchingTrack:withURL:` and `indexesOfTracksWithURL:` forward to the model for the convert swap (`../CLAUDE.md`, `Mac/MainWindow/Convert/CLAUDE.md`).

## Structural edits: precise row operations, never `reloadData`

**The observer reconciles each of remove, insert and move once — `removeRowsAtIndexes:`, `insertRowsAtIndexes:`, or the rules header's evolving `moveRowAtIndex:toIndex:` sequence inside `beginUpdates`/`endUpdates` — with no animation**: thousands of rows sliding is motion nobody asked for, and row views survive so the wash and the equalizer travel with their rows. Every edit then runs the same tail before returning to the run loop, so no frame shows two playing rows: `refreshRowViewPlayingStates`, then `reconfigureVisibleNumberCells`.

**Selection after an edit is presentation only and never calls `playSelectedTrack`.** Removal selects the row that closed the topmost gap, or the new last row. Insert (the undo of a removal) and move select the landed rows **and scroll the first to visible** — an undo whose rows are off screen reads as a no-op, and a drag begun outside the selection would otherwise leave it behind.

**`playlistOrderDidChangeHandler` fires from the move observer, last, with the two sets** — not from the drop site — so every initiator, the undo stack included, gets the shell's one follow-up for free (`Mac/MainWindow/CLAUDE.md`).

## Dragging rows: reorder inside, files outside

**One drag, two destinations, decided by the operation mask, not the payload.** Each row's `NSPasteboardItem` carries the private reorder type (payload: the per-session token) and the file URL. `NSDragOperationMove` for local, `NSDragOperationCopy` elsewhere: inside the table a reorder, onto the Finder or another app a copy of the files, one per selected row.

**The private type plus the live token is the whole proof a drop is this table's reorder** (`draggingInfoIsLiveReorderSession:`: same source, the type, a matching token) — a file URL alone is what an external file drag carries too. The table registers only the private type, so an external file drag still falls to the window's wells, and `MainWindow` refuses any in-app source, so a row dragged around the window never reads as an open.

**`willBeginAtPoint:` starts the security scope on each dragged URL and `endedAtPoint:` — always called, drop or cancel — balances it**, since a receiver outside the app reads the files long after the session. Only URLs whose start answered YES are recorded: an unbalanced stop over-releases the sandbox extension, and a URL covered by a folder grant answers NO and drags fine. Token, tracks and scopes all clear at session end.

**A row number captured at mouse-down is never trusted.** The payload is the retained array of exact `AudioTrack`s, re-resolved through `rowsForTracks:` at every validation and at the drop: a replaced playlist resolves all to nothing and rejects the drag; a row converted away drops out alone and its companions still move. One qualification (`reorderDestinationForInfo:`) serves both the insertion line and the accept, so the line never promises a move the drop refuses. Hover is O(1) in playlist size; an accepted drop is one O(n) model rebuild.

**The slot arithmetic is `PlaylistDragRules.h`, tested host-lessly (`Tests/PlaylistDragRulesTests.m`), and it is the one conversion from an AppKit insertion slot to model final positions.** `VibePlaylistDropDestinationForSlot` solves the downward off-by-one once and answers nil for a no-op slot — a contiguous block dropped onto or beside itself, every row at once — so no insertion line is drawn for one; a non-contiguous set is never a no-op. `VibePlaylistMoveSequenceEnumerate` emits the single-row moves in **evolving coordinates** — apply one before computing the next; a scatter (the undo) is its gather's pairs reversed and swapped. The model op is set-to-set and its own inverse with the sets swapped (`../CLAUDE.md`).
