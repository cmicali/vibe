# Playlist

## Row appearance

Row backgrounds belong to `PlaylistRowView`, not to AppKit. `drawSelectionInRect:` does not call super, which replaces the system `selectedContentBackgroundColor` accent-blue fill with a neutral white or black wash at about 9%. The playing row draws the same wash. `rowViewForRow:` sets `playingRow`, and `refreshRowViewPlayingStates` re-stamps it across the visible rows on every `currentIndex` change, because `reloadDataForRowIndexes:` rebuilds cell views but keeps row views.

The artwork-derived accent appears only in the playing row's equalizer indicator, as `EqualizerIndicatorView.barColor`. It is deliberately never a full-width saturated fill, and deliberately not on the title text, which keeps its normal label color like every other row. The indicator and the neutral wash are the whole "playing" marking. The color arrives from `ArtworkDisplayController`'s `accentColorDidChangeHandler` — the same dominant-color resolution as the header wash, clamped into an OKLCH band that stays legible over the playlist frost — through `PlaylistController.accentColor`, which reloads the playing row on change.

## Structure and content

`PlaylistController` owns the track list as the `NSTableViewDataSource` and delegate. `PlaylistTableView`, in the same directory, owns everything structural about the table: columns, row metrics, the enclosing scroll view (`scrollViewWithFrame:`, placed by `MainPlayerContentView`), the code-built cell views for track number and equalizer, artwork thumbnail, title and artist, and duration, and all their text styling. The controller therefore decides only cell *content*, through `cellViewForColumn:` and the formatting helpers.

TRAP: cell content is set as an **attributed** string, and an attributed string's own paragraph style overrides the cell's `lineBreakMode`. Its default wraps, so every column's attributes must carry a truncating paragraph style of their own. Without one a long title took two lines in a 28pt row: the first rode high and the second was clipped away, which read as the row's text losing its vertical centering against the duration beside it. `PlaylistTextCell` sets `usesSingleLineMode`, which is what actually centers a cell's text vertically and is the belt to that braces.

Attaching the table with `setTableView:`, from `MainPlayerController.windowDidLoad`, wires the delegate, dataSource and double-click, and installs the row context menu — "Show in Finder", a separator, then Copy File and Copy Name, carrying the same SF Symbols their counterparts have elsewhere. All three act on the *clicked* row, and the actions and their shared validation live in `PlaylistController`, reading `clickedRow` at action time rather than capturing it when the menu opened, since the playlist can be replaced while the menu is up. The window-body menu's items and the Convert menu's act on the *current* track and stay with `MainPlayerController`. Convert to FLAC is deliberately **not** a row action — it converts the current track only — so the playlist's part in it is just the rows the swap lands on.

`replaceTrackAtIndex:withURL:` is where that swap lands, and `indexesOfTracksWithURL:` is how it reaches every affected row at once: the same file can sit in the playlist twice, and a duplicate row left pointing at the converted-away source would break the moment Delete Original trashes it. See `Main Window/CLAUDE.md` for why the swap mints a fresh `AudioTrack` rather than reassigning a `url`.

`play:` replaces the list. `append:` extends it without touching playback or `currentIndex`; rows never move otherwise, so the track-to-row map only ever grows. Every track change calls `scrollCurrentTrackToVisible`, a no-op while the row is already visible. Nothing else scrolls the table, which is why auto-advance used to lose the playhead off screen.

## Launch Services bursts

`AppDelegate` handles Launch Services opens as a *burst*. The first batch plays immediately, because a double-clicked file must not wait out a coalescing delay, and later batches within a 0.3-second quiet period are appended through `MainPlayerController.addURLs:`. A multi-file open that Launch Services splits across events therefore still lands as one playlist, without restarting the first track. The ⌘O panel and Open Recent bypass the burst and always replace.
