# Playlist table (macOS only)

The `NSTableView` half of `Vibe/Playlist/`: `PlaylistController`, `PlaylistTableView`, `PlaylistRowView`, `PlaylistTextCell`, `PlaylistCoverImageView`, `PlaylistDropZoneView`. The shared model and the CUE/M3U readers are one directory up. The iOS list is `Vibe/iOS/LibraryViewController`, which shares only `EqualizerIndicatorView`.

## Structure vs content

`PlaylistTableView` owns everything **structural**: columns, row metrics, the enclosing scroll view (`scrollViewWithFrame:`, placed by `MainPlayerContentView`), the code-built cell views for track number and equalizer, artwork thumbnail, title and artist, and duration, and all their text styling. Cells are built in `makeCellViewWithIdentifier:` and recycled through the table's normal reuse queue.

`PlaylistController` is the `NSTableViewDataSource` and delegate and decides only cell **content**, through `cellViewForColumn:` and the formatting helpers.

**TRAP: cell content is set as an *attributed* string, and an attributed string's own paragraph style overrides the cell's `lineBreakMode`.** Its default wraps, so every column's attributes must carry a truncating paragraph style of their own, or a long title wraps to a clipped second line instead of truncating. `PlaylistTextCell` sets `usesSingleLineMode`, which is what actually centers a cell's text vertically.

## Row appearance

Row backgrounds belong to `PlaylistRowView`, not to AppKit. **`drawSelectionInRect:` does not call super**, which replaces the system `selectedContentBackgroundColor` accent-blue fill with a neutral white or black wash at about 9%. The playing row draws the same wash from `drawBackgroundInRect:`, and skips it when the row is also selected, which already drew it.

`rowViewForRow:` sets `playingRow`, and `refreshRowViewPlayingStates` re-stamps it across the visible rows on every `currentIndex` change, because `reloadDataForRowIndexes:` rebuilds cell views but keeps row views.

The artwork-derived accent appears **only** in the playing row's `EqualizerIndicatorView.barColor` — deliberately never a full-width saturated fill, and never on the title text, which keeps its normal label color like every other row. The indicator and the neutral wash are the whole "playing" marking. The color arrives from `ArtworkDisplayController`'s `accentColorDidChangeHandler` — the same dominant-color resolution as the header wash, clamped into a legible OKLCH band — through `PlaylistController.accentColor`, which reloads the playing row on change.

## Wiring and the context menu

`setTableView:`, called from `MainPlayerController.windowDidLoad`, wires the delegate, dataSource and double-click and installs the row context menu: Show in Finder, a separator, then Copy Name and Copy File, carrying the same SF Symbols their counterparts have elsewhere.

All three act on the **clicked** row, and read `clickedRow` at action time rather than capturing it when the menu opened, since the playlist can be replaced while the menu is up. The window-body menu's items and the Convert menu's act on the *current* track and stay with `MainPlayerController`. **Convert to FLAC is deliberately not a row action** — it converts the current track only.

## Scrolling and swaps

`play:` replaces the list; `append:` extends it without touching playback or `currentIndex`. Every track change calls `scrollCurrentTrackToVisible`, a no-op while the row is already visible. Nothing else scrolls the table.

`replaceTrackAtIndex:withURL:` and `indexesOfTracksWithURL:` forward to the model and are where the convert swap lands — see `Vibe/Playlist/CLAUDE.md` for why the model keeps a URL index, and `Mac/MainWindow/CLAUDE.md` for why the swap mints a fresh `AudioTrack`.

`currentIndexDidChangeHandler` is this shell's one current-index funnel, and is what sends a playlist position to the metadata cache's cloud-lane ranking (`Audio/Metadata/CLAUDE.md`).
