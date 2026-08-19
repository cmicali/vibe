# Main window (macOS)

**Layout geometry, the Liquid Glass chrome, the art-tint/accent pipeline and the codec line's rendering are in `APPEARANCE.md`, in this directory — read it before changing any of those.** This file covers behavior: the controller, transport, the convert swap and its undo, display states, and the window's resize and drop rules.

## Bootstrap

`MainWindow` configures itself in `init`: borderless, frame autosave, drag-and-drop registration. `MainPlayerContentView`, a plain transparent `NSView`, holds the hierarchy and exposes subviews as readonly properties; the glass backdrop and pitch panel are `contentView` **siblings** installed by the controller. `MainPlayerController` adopts the hierarchy as outlets in `buildContentInWindow:` (called from `init`) and **invokes `windowDidLoad` by hand — AppKit only fires it on the nib path.**

## The controller

`MainPlayerController` (`NSWindowController`) is the central coordinator. Its public header exposes only collaborators, actions and `NSMenuDelegate`. What is left in `MainPlayerController.m` is the coordination: the `updateUI` funnel, display-state resolution, the open and playlist entry points, and the settings live-apply hooks. Everything else is a category:

| Category | Owns |
| --- | --- |
| `+Window` | Building content into the window, the two sibling frames, resize/occlusion/restoration rules, and the actions that change the window's shape or appearance. `NSWindowDelegate` and `NSWindowRestoration` declared here. |
| `+PlayerEvents` | Every `AudioPlayerDelegate` callback. |
| `+Delivery` | Where asynchronous results land: metadata, waveform snapshots, detected BPM and key, and the waveform's scrub seek. |
| `+Menus` | Menu validation and the waveform-style submenu. |
| `+NowPlaying` | The `updateNowPlaying` publish and `NowPlayingControllerDelegate` routing. |
| `+Transport` | Relative-seek skips and DJ effect toggles. |
| `+Convert` | The Convert to FLAC funnel, the playlist swap and the undo round trip, with `VibeFLACConversionRecord`. |
| `+Debug` | The debug channel's extra surface — declared in `Vibe/Debug/Mac/Introspection/`, never here. |

**Two rules govern `+PlayerEvents` and are stated at its top: every callback can be stale**, so it must match the delivered track against the playlist's current one, and **`stop` fires no callback**, so nothing there drives auto-advance. `+Delivery` is one file precisely because all of it implements the same cross-directory staleness guarantee.

**`MainPlayerControllerInternal.h` is the one private surface all of them share** — the class extension with the outlets, collaborator handles, the ivars a category touches, and the internal methods. A method a category *implements* is declared in **that category's header**, never in `MainPlayerController.h` or the internal header, or the compiler cannot check either side.

## Folder art invalidation

The feature lives in `Audio/Metadata/FolderArtResolver`, but this controller owns its invalidation and its redraws.

`refreshFolderArt` (public) runs when Settings > Files changes the album-art setting and calls the resolver's `folderArtSettingDidChange`. **The setting is cached in the resolver, on the hot cell-draw path, so this call is what makes the write observable at all** — not merely a redraw. It deliberately keeps the settled answers.

A **grant** change is answered separately in `grantedFoldersDidChange:`, with the resolver's narrow `invalidateDirectoriesSettledWithoutGrant`. It forgets no-grant discovery answers and re-arms known cover reads, which recheck active access before touching the file. The controller observes `FolderAccessManagerDidChangeNotification` itself, because a grant can change after a drop, open, or Settings edit with the Files pane no longer visible.

`folderArtDidResolve:` observes the resolver's notification — which fires for "this folder has none" as well as for a cover — and coalesces the redraw over a short delay, reloading the *visible* rows alone. The delay is the point: the resolver is serial, so a per-run-loop-turn gate would coalesce nothing. These two observers are why the class has a `dealloc`.

See `Audio/Metadata/CLAUDE.md` for why neither invalidation may be a full wipe.

## Transport keys

`TransportKeyMonitor` handles the bare keys: Space, B, N, P, Tab; A/S/D skip forward, Z/X/C skip back; and the dual-mode effect keys Q, W, E, R, T (R = 1/8-note delay taps, T = 1/16). **A tap toggles, a hold is momentary**: the effect flips at keyDown, and keyUp reverts to the pre-press state when the press ran past the ~0.35s tap threshold — **keyUp is what decides tap vs hold**, which is why the menu items' key equivalents are display and fallback only.

The five effect-state setters in `+Transport` are the single funnel for menus, bare-key taps and holds, and debug commands; each calls `updateFXIndicators`, **which re-reads the live `AudioFX` flags rather than trusting the caller's intent.** The codec line doubles as the FX indicator; its rendering is in `APPEARANCE.md`.

## The UI tick

A `UIUpdateTimer` (`Vibe/Util/`) drives `updatePlaybackUI`, only while playback wants updates and the window is unoccluded; `windowDidChangeOcclusionState:` pushes the gate and refreshes once on reveal, since Control Center keeps counting on its own. The full `updateUI` runs on transport events and metadata deliveries. An asynchronously recovered thumbnail takes that same path only when its exact metadata object is still displayed, which refreshes the header and republishes Now Playing without letting an old track's decode overwrite either. Its header work has one named phase, `renderTrackPresentationForState:track:displayTrack:`: base state first, then tempo/key and FX, then artwork, all against the same display-state decision. Rate-only and position updates stay separate so they do not reload artwork or playlist rows.

**Its rate is scaled to the playhead's on-screen speed rather than fixed.** `syncUITimerRate` feeds the waveform's `devicePixelWidth`, the cached duration and the varispeed rate to `VibeUIUpdateHzForPlayhead` (`Util/UIUpdateMath.h`, tested), which asks for the Hz that steps the playhead ~2 device pixels, floored at 3 and capped by `AppSettings.uiUpdateHzCap` (Settings > Advanced: 3, 30 default, or 60). An ordinary song computes under the floor and costs what it always did; a five-second sample takes the whole cap.

The inputs move at a track start and any transport event, a fader tick (`updateRateDependentUI`), a resize (`windowDidResize:`, live-drag frames included) and the cap itself — **and each of those must call the sync.** The higher rate is affordable only because the expensive paths self-gate: `AudioWaveformView.setProgress:` repaints on device-pixel crossings using that same `devicePixelWidth`, and the time labels are change-guarded at one second.

Read the chosen rate back with `dump_state`'s `ui.uiUpdateHz`; `check_consistency` pairs it with the rule re-applied to the live inputs (`ui.update_rate_follows_inputs`), which catches a path that moves an input without resyncing.

## Skipping and closing

Skip actions seek **by bars when the tempo is known** — tagged BPM beats analyzed, the same precedence as the BPM label. The three sizes are `AppSettings.skipBaseBars` (4, 8 or 16, default 8), twice it and four times it. Bars are fixed spans of file time, so the jump stays on the musical grid at any pitch. Without a tempo: 10/30/60 seconds in the pitch-adjusted wall-clock seconds the labels show. The arithmetic is `TransportMath.h`, tested.

A forward skip past the end calls `AudioPlayer.finishCurrentTrack`, which fires `didFinishPlaying:`, so the usual auto-advance / end-of-playlist path handles it — no bespoke branch.

**Whether a track end advances at all is Settings > Playback > On track end** (`AppSettings.pauseAtTrackEnd`), and `successorPrefetchTrack` is the single place it is enforced. Every prefetch site asks it for the playlist's next track, and under Pause it answers nil — so nothing is parked, the player cannot arm its gapless splice, and a track end can only reach `didFinishPlaying:`, which then takes the same park as the end of the playlist. A pane write must call `applyEndOfTrackAction`, or a mid-track switch to Pause leaves an armed splice that advances anyway.

Skips need a player that is not Stopped, gated in both `skipByFileSeconds:` (bare keys bypass validation) and menu validation: **after the playlist ends the finished file stays open, so `duration` alone still looks seekable while no node exists.**

File > Close (⌘W, `closeFile:`) is nil-targeted, so the key window's `closeFile:` target owns both the action and the shared menu item's title. The player retitles it "Close File" / "Close All Files" and enables it only for a nonempty playlist; Settings and About restore the singular title and close only themselves. The player's action calls `AudioPlayer.stop` (which fires no delegate event), then clears the playlist, cancels the deferred metadata load, and drops the scan loader with `cancelScan` — a cancelled loader still strongly holds every queued track, thumbnails included.

## Convert to FLAC: the swap

The conversion engine is `Audio/Mac/Convert/`; this is what happens when it finishes. **The FLAC takes the row its source occupied**, so the action reads as the file changing format in place.

`didConvertTrack:toURL:error:` resolves the source's row **at completion time**, because a re-drop during the encode replaces the playlist — then there is nothing to swap and the FLAC stays on disk. Four outcomes: row gone → nothing; row current and loaded → replay; row current but stopped → `updateUI`; row elsewhere → re-arm the prefetch when it is `currentIndex + 1`, since the parked handle is path-keyed and still points at the source (through `successorPrefetchTrack`, which names that same row and is nil under On track end = Pause).

The replay uses `AudioPlayer.play:atPosition:startPaused:`. **The playlist entry is swapped first**, so `didStartPlaying:`'s identity guard passes and the whole per-track refresh — waveform, codec label, artwork, Now Playing, Open Recent, prefetch — comes free with the ordinary play path.

**`PlaylistController.replaceTrackAtIndex:withURL:` mints a *fresh* `AudioTrack`**: `AudioTrack` memoizes its cache key with no invalidation, so a track still carrying the WAV's key would file the FLAC's waveform and metadata under the WAV's entries. Duration and detected BPM carry across by hand — same audio, and re-deriving would blank the row until the new decode lands.

**Disposing of the source is the last step, and the ordering is the point**: swap first, then `trashSourceIfEnabled:convertedTo:` — the swap is what stops the row and the player from pointing at the file about to be deleted. The source URL is read *before* the swap, and the trash runs whether or not a row was found: the encode succeeded either way. Its completion is where the conversion becomes undoable — the controller builds a `VibeFLACConversionRecord` (source URL, output URL, where the Trash put the source, nil when Delete Original was off) and registers "Convert to FLAC" with the window's `NSUndoManager`.

Progress is the waveform's brush-through sweep: `progressHandler` forwards the fraction to `trackDisplay.setConvertSweepFraction:` **only while the converting track is `displayedTrack`**, so a background conversion draws nothing and a track change stops the sweep at the next report.

## Undo: the conversion round trip

Edit > Undo/Redo are thin forwards to the window's `NSUndoManager`; `+Menus` validates and retitles from the manager. **One conversion undo/redo transaction may be in flight at a time**: the controller disables both items and rejects every action entry point until the async restore/trash chain settles, so rapid commands cannot interleave file moves against the same mutable record.

`undoConversion:` restores the trashed original, returns its rows through the same `swapConvertedTrack:toURL:` — a playing FLAC replays as the original at the same playhead — then trashes the FLAC: **restore first** because the swap replays from the restored file, **FLAC last** for the same reason the conversion trashes last. `redoConversion:` mirrors it: the FLAC comes back **from the Trash, never a re-encode**, and the original is re-trashed only if the conversion had trashed it (`sourceWasTrashed` — a Delete Original toggle flipped in between changes nothing). The record mutates in place as moves land, so either direction proceeds sensibly after the other half-failed.

**TRAP: each direction registers its inverse synchronously inside the invocation, before any file move runs and before the in-flight bail-out.** Only while the manager `isUndoing` does a registration land on the redo stack (mirrored for redo), and the moves outlive the invocation — registering from a completion would push the inverse onto the *undo* stack as a fresh action. And `NSUndoManager` has already popped the action by the time the body runs, so bailing out before registering would drop the conversion off **both** stacks and make it permanently un-undoable. So an inverse exists even when the moves then fail, and both directions re-check reality — the row via `trackForURL:`, the files via the record — rather than trusting the moves landed. A failed restore logs, beeps and reveals the stranded Trash item; Finder's Put Back is the recovery.

## Time labels and display states

The right time label shows total duration (default) or minus-prefixed remaining time counting down; clicking toggles the mode, persisted in `AppSettings.showRemainingTime`. Both are wall-clock — file time over the varispeed rate — like the elapsed label, and **every write goes through `renderRightTimeLabelWithDisplayPosition:duration:rate:` so the modes cannot drift.** The tick skips the label when the duration cache is 0, or the end-of-playlist park's full-length resting value would be clobbered with `-0:00`.

**All header rendering resolves through one five-state `TrackDisplayState`** — track, loading, empty, launch-grace, error — resolved in one place (`displayState`, using `TrackDisplayRules.h`, tested) and shared by `updateUI`, `updatePlaybackUI` and the Now Playing publish, so the branches cannot drift. `TrackDisplayController` draws it and holds no player or playlist state: pure decide-vs-draw.

- **Loading**: the incoming track's tags and `--:--` for both times resolve as the play is initiated. The waveform's loading line begins only when the player's 0.5s slow-open threshold fires `didBeginLoading:`, so a fast local or prefetched play never flashes it; until then the outgoing waveform may remain under the incoming title.
- **Empty**: static midline waveform placeholder, both time labels `--:--`, a "Drop a file or press ⌘O" hint, all at half strength. At launch the `revealEmptyState` grace suppresses it to a blank header, so a launch-time open never flashes it.
- **Error**: rendered inline in the same style — no modal, no auto-skip. `displayedTrack` masks the errored track through the `_erroredTrack`/`_errorStatus` pair, written only via `setErrorMaskForTrack:status:` and `clearErrorMask`; the error text sits on the artist line over the title. The track stays in the playlist for a retry, and late metadata and art deliveries are ignored while masked.

## Now Playing

`NowPlayingController` is `Vibe/System/` and shared with iOS; on this platform the main window is its only driver. `updateNowPlaying` runs from the `updateUI` funnel plus the seek and pitch-change paths. Command handlers marshal delegate delivery to the main queue before routing to the same `playPause:`, `next:`, `previous:` and seek entry points the buttons use.

Position and duration are **wall-clock, pitch-adjusted** (file time ÷ varispeed rate), matching the app's own labels, so Control Center tracks the pitch fader; the MediaPlayer rate is 1.0 while playing, 0 paused. **Nothing is published until the first track plays**, so Vibe does not steal Now Playing at launch.

Artwork reads non-blocking: `cachedArt` returns only already-decoded art, falling back to the 128px `cachedThumbnail`, and refreshes when the full art resolves. The pre-scale and the `--no-audio-hw` trap are `Vibe/System/CLAUDE.md`.

## The window

Freely resizable in both axes: the frame belongs to the user and autosave keeps it. The window enforces only the floor — `kMainWindowMinContentWidth` plus the pitch panel's slice when showing, and `kMainWindowSmallHeight` — and applies the app's own size changes: the playlist toggle's height, `kPitchPanelWidth` either way, the View > Size presets.

**The height has a second floor that is a *band*.** A playlist pane shorter than `kPlaylistPaneMinHeight` (100) is a sliver — worst in the empty state, where the drop well runs out of room and hides at its visibility floor, leaving a blank strip. So nothing rests between `kMainWindowSmallHeight` (150) and `kMainWindowMinLargeHeight`: `restingHeightForDraggedHeight:` sends a drag through the band to the nearer end, and `loadSettings` clamps a restored frame out of it. `minSize` still floors at the collapsed height, which the toggle and restore target exactly. The rule reaches drags through `windowWillResize:toSize:`, **gated on `inLiveResize`** so the app's own animated resizes are not snapped mid-flight; every height the app sets is a fixed point of the rule anyway.

All three programmatic resizes animate at one fixed `animationResizeTime:` (`kWindowResizeAnimationDuration`) rather than AppKit's distance-scaled default, which drags on big jumps.

**The pitch-panel toggle is the one place the two `contentView` siblings must not follow the resize** — the reveal is the window's right edge sweeping past a stationary panel. `togglePitchPanel:` swaps in fixed masks for the animation and restores the resizable ones (body width-sizable, panel right-anchored) afterwards.

**TRAP: a Finder drag delivers file-reference URLs** (`file:///.file/id=…`), whose `.path` re-resolves to wherever the file currently *is*, while everything downstream treats a track's URL as a fixed path — cache keys hash it, and the convert-undo record restores to it. Unpinned, a dragged-in source that a conversion trashed has its URL silently follow the file into the Trash, and the undo restore becomes a move onto itself that reports success. **Invisible when testing with `open`, which delivers plain path URLs.** Every drop is pinned to `fileURLWithPath:` in `performDragOperation:`, and `didConvertTrack:` pins the undo record's source URL again.

A drop resolves the empty-state wells into an append-or-replace decision **synchronously** — the wells are geometry, and the dragging session is gone by the time the expansion lands — then hands the URLs to `AppDelegate.openDroppedURLs:appending:`, the app's one open funnel. See `Mac/App/CLAUDE.md` for the burst and supersession rules.

A folder's recursive walk filters unsupported entries before retaining and sorting them, then sorts by full path with `localizedStandardCompare:` — Finder's numeric ordering, subfolders grouped. **`NSDirectoryEnumerator` hands back APFS hash order, which played an album shuffled.** An explicit multi-file drop keeps its pasteboard order, which is the user's own.
