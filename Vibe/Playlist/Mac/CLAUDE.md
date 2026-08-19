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

## Wiring and the context menu

`setTableView:`, called from `MainPlayerController.windowDidLoad`, wires the delegate, dataSource and double-click and installs the row context menu: Show in Finder, a separator, then Copy Name and Copy File, carrying the same SF Symbols their counterparts have elsewhere.

All three act on the **clicked** row, and read `clickedRow` at action time rather than capturing it when the menu opened, since the playlist can be replaced while the menu is up. The window-body menu's items and the Convert menu's act on the *current* track and stay with `MainPlayerController`. **Convert to FLAC is deliberately not a row action** — it converts the current track only.

## Keyboard

The up and down arrows are `NSTableView`'s own `moveUp:`/`moveDown:`; nothing here implements them. Return is their counterpart, `playSelectedTrack`, which takes the same two steps `doubleClick:` does. Both read the selection **at action time**, like the context menu's clicked row, because the playlist can be replaced between the press and here.

Neither works while the playlist is collapsed. That gate is not here — the table has no say in the window's height — but in `TransportKeyMonitor` (`Mac/MainWindow/CLAUDE.md`), which swallows all four keys, and in the Playback menu's validation of Play Selected Track, which needs the pane showing *and* `hasSelectedTrack`.

## Scrolling and swaps

`play:` replaces the list; `append:` extends it without touching playback or `currentIndex`. Every track change calls `scrollCurrentTrackToVisible`, a no-op while the row is already visible. Nothing else scrolls the table.

`replaceTrackAtIndex:withURL:` and `indexesOfTracksWithURL:` forward to the model and are where the convert swap lands — see `Vibe/Playlist/CLAUDE.md` for why the model keeps a URL index, and `Mac/MainWindow/CLAUDE.md` for why the swap mints a fresh `AudioTrack`.

`currentIndexDidChangeHandler` is this shell's one current-index funnel, and is what sends a playlist position to the metadata cache's cloud-lane ranking (`Audio/Metadata/CLAUDE.md`).
