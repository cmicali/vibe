# Main window (macOS)

This directory holds the main window and its controller, `MainPlayerController`, with its categories. It also holds the window's body, the track and artwork display controllers, and the volume control.

**Layout geometry, the Liquid Glass chrome, the art-tint pipeline and the codec line are `LAYOUT.md`. Read it before changing any of those.** `MainPlayerContentView` is the window's body. `MainPlayerContentView.m` keeps the appearance pass, the artist line's edge and the hover reveal. Its `+Construction` category builds the subviews and holds the theme passes that restyle them. The two share `MainPlayerContentViewInternal.h`: the layout block, the ivars and the methods each calls on the other. The volume control inside it is its own view, `VolumeControlView`. This file is behavior: the controller, display states, the playlist edits the shell owns, and the window's resize and drop rules. `Transport/` (bare keys, skips, FX toggles) and `Convert/` (the FLAC swap and its undo) have their own `AGENTS.md`.

## The controller

`MainPlayerController` (`NSWindowController`) is the coordinator. `MainPlayerController.m` keeps the `updateUI` funnel, display-state resolution and the open entry points. Each `MainPlayerController+*.h` preamble states what its category owns:

- `+Playlist`: Close, Save Playlist, the last playlist, and removing and moving rows with their undo.
- `+Transport` (`Transport/`): the skips and the FX toggles. Also shuffle, repeat, On track end and the successor prefetch. Also the pitch fader and its range, the volume slider and the waveform's seek.
- `+PlayerEvents`: every `AudioPlayerDelegate` callback.
- `+Delivery`: the metadata, waveform, tempo and key deliveries. Also the grant, folder-art and thumbnail notifications.
- `+Window`: the content build, the resize, lock and occlusion rules, the window chrome and the waveform theme.
- `+Menus`: menu validation and the View > Theme submenu.
- `+Settings`: the live effects, the shortcut write path and the theme's fonts.
- `+NowPlaying`: the system's Now Playing info and remote commands.
- `+Convert` (`Convert/`): Convert to FLAC's swap and its undo.

**A method a category implements is declared in that category's header.** It is never declared in `MainPlayerController.h` or in `MainPlayerControllerInternal.h` (the shared class extension: outlets, collaborators, the ivars a category touches), or the compiler cannot check either side. `+Debug` is declared under `Vibe/Debug/Mac/Seams/`.

**`+PlayerEvents` and `+Delivery` carry the root doc's staleness guarantee.** Track callbacks can be stale. Waveforms match the current source window. Tempo and key stamp all matching windows in the playlist. Playback callbacks check the current track. The player also guards play settlement by submission identity. The decisions are tested seams: `PlaybackDeliveryRules.h` (track-end advance, seek settlement, the deferred-metadata gate) and `AudioErrorRules.h` (benign and wrong-URL errors).

**TRAP: a device-change callback may arrive after a later switch is queued or bound.** The callback persists the settled device and applies its dependent effects with `updatingOutputModes:NO`. Sending its modes back would overwrite the later device's own preferences. An explicit settings edit uses the same effect mapping with output modes on. The player then asks for the current UID's modes through the controller's read-only `outputModesForDeviceUID` delegate method, which reads only thread-safe settings getters.

## Folder art invalidation

`FolderArtResolver` (`Audio/Metadata/Artwork/FolderArt/`) is the feature. This controller owns invalidation and redraw.

- The `FolderArt` effect calls `refreshFolderArt`, which calls `folderArtSettingDidChange`. **The resolver caches the setting on the cell-draw path, so this effect is the only way a write is ever seen.** It keeps settled answers.
- A grant change (`FolderAccessManagerDidChangeNotification`) is narrower. It is observed here because a grant can change with the Files pane gone. `invalidateDirectoriesSettledWithoutGrant` forgets the no-grant answers and re-arms known cover reads.
- `folderArtDidResolve:` fires for "none" as well as a cover. It coalesces a reload of the visible rows over a short delay. The resolver is serial, so a per-turn gate would coalesce nothing.

Neither may wipe everything (`Audio/Metadata/Artwork/FolderArt/AGENTS.md`).

## The UI tick

`UIUpdateTimer` (`Vibe/Util/`) drives `updatePlaybackUI` only while playback wants updates and the window is not occluded. `windowDidChangeOcclusionState:` pushes the gate and refreshes once on reveal. The full `updateUI` runs on transport events and metadata deliveries. Its header work is one phase, `renderTrackPresentationForState:track:displayTrack:`, against one display-state decision. Rate and position updates stay separate, so they reload no artwork or rows. A same-track refresh reloads no row (`_lastReloadedTrack`). The gutter's three states reconcile on their own edges (`Playlist/Mac/AGENTS.md`).

**The tick rate follows the playhead's on-screen speed.** `syncUITimerRate` feeds the waveform's `devicePixelWidth`, the duration and the varispeed rate to `VibeUIUpdateHzForPlayhead` (`Util/UIUpdateMath.h`, tested). **Every mover of an input must call the sync**: track start, transport events, fader ticks (`updateRateDependentUI`), `windowDidResize:` (live-drag frames included) and the cap setting. `check_consistency`'s `ui.update_rate_follows_inputs` catches a mover that forgot.

**A start, resume or seek also aims one update just past the time label's next change** (`scheduleUpdateAtNextDisplayedSecond`). The rate is untouched. At 3 Hz the tick can land a third of a second late, and a stuck 0:00 reads as playback not starting.

Listening statistics follow `audioPlayer:didChangeOutputAudioActive:`, as the equalizer does. An outgoing fade counts. Silent Loading time does not.

## Track end, close and save

**Where a track end goes is the playlist's `trackEndSuccessor`, which is nil under On track end = Pause** (root `AGENTS.md`). `pushTransportModesToPlaylist` pushes Pause with repeat and shuffle. Every prefetch parks `trackEndSuccessor`, and `advanceOrParkAtTrackEnd` calls `advanceAtTrackEnd`.

**Shuffle (⌥⌘S) and Repeat (⌘R, Off → All → One) are Playback-menu items, the mac's only controls for them.** Repeat's item is titled by its mode. Each writes its setting and requests `EndOfTrack`. That effect pushes both modes into the playlist and Now Playing, re-parks the successor and refreshes Next. Launch pushes them before the restore, so a shuffled restore starts its order on the saved row. While on, each shows as a glyph on the codec line (`LAYOUT.md`).

**File > Close (⌘W, `closeFile:`) is nil-targeted.** The key window's target owns the action and the shared item's title. The player retitles it Close File or Close All Files and enables it for a nonempty playlist. Settings, About and the Open URL panel restore the singular and close themselves. The player's action runs `unloadPlaybackClearingPlaylist:YES`. That invalidates the open coordinator, calls `AudioPlayer.stop` (no delegate event), clears the playlist, cancels the deferred metadata load, and drops the scan loader with `cancelScan`. **A cancelled loader still holds every queued track strongly.**

**File > Save Playlist… (⌘S) needs the player window key and a nonempty playlist.** Its sheet attaches here, and ⌘S over Settings must not raise one behind it. `writePlaylistToURL:error:` is the one write path. It snapshots at OK, writes paths relative to the chosen folder, writes atomically, and notes the file in Open Recent. The `save_playlist` debug verb shares it.

## The last playlist

`AppSettings.reopenLastPlaylist` (off by default) mirrors the playlist to `Application Support/<bundle id>/LastPlaylist.m3u` at quit and reopens it at launch. `PlaylistFile+Session` owns the save and restore (`Playlist/Mac/AGENTS.md`).

- `saveLastPlaylist` writes absolute paths and never touches Open Recent. The current row goes in the `VibeLastPlaylistCurrentIndex` defaults key. It is state, not a preference, so a reset leaves it. The mirror is deleted when the setting is off or the playlist is empty. Turning the setting off deletes it at once (`applyReopenLastPlaylist`).
- `restoreLastPlaylist` lands **parked**, through `loadTracks:selectingIndex:startPaused:YES`. Every row comes back, readable or not, and a cue row keeps its window and names. The mirror is read through `PlaylistFile.rowsInM3UData:`, not the open funnel. Nothing is stat'd, not even a cue row's sheet, and no grant panel is raised.
- When the restore finds nothing, `loadWelcomeTrack` parks the bundled `vibe-theme.mp3` on the first launch only. `AppDelegate` sets `AppSettings.welcomeTrackLoaded` at that launch, even when an open pre-empts the track. Only Factory reset clears it.

`AppDelegate` calls these only after grants restore, and only when no launch-time open drained (`Mac/App/AGENTS.md`). Every quit must reach `applicationWillTerminate:` for the write, so the app does not opt into sudden termination.

## Removing playlist rows

`removePlaylistRows:` is the one funnel. Remove from Playlist enters it through `removePlaylistTracks:`, which adds Remove's undo, and Move to Trash adds its own. The Edit menu and the two delete keys act on the whole selection (`PlaylistController.selectedTracks`). The row context menu arrives through `removeTracksRequestHandler`. Remove takes exact `AudioTrack`s and resolves each live row once, so a shifted object is followed and a departed one drops out.

**`Playlist.removeTracksAtIndexes:` touches no audio, so the playback consequences are decided here** (root `AGENTS.md`). **The funnel never touches a file, and registers no undo.** The method's comments carry each step. In short: Remove sends a removal of every row to `closeFile:` instead. In the funnel, emptying the list is an edit followed by Close's teardown with the list kept (`unloadPlaybackClearingPlaylist:NO`). **TRAP: never empty it with a clear.** A clear bumps `structureGeneration` and retires every older undo registration. The playback intent is read through `AudioPlayer.getPlaybackIntent:forTrack:` before the model changes. One model call sends one event. A surviving current track's audio is left alone. A removed current row is replaced through the play funnel, so its old settlement dies on `submittedPlayIsCurrent:`. Nothing synthesizes a delegate callback or treats a removal as a track end.

**A removal is undoable as the list edit it is.** The funnel registers `reinsertPlaylistTracks:atIndexes:generation:` under the item's action name. Undo restores the exact objects to their rows, selected and revealed. It asks for their metadata again through `loadMetadataNow:`, since the removal abandoned their scan work. It never replays a removed current row.

- **The registration is stamped with `PlaylistController.structureGeneration`.** It forwards the model's own generation, which every replace or clear bumps before announcing. A restore whose playlist was replaced does nothing, its redo does nothing, and the dead pair falls off both stacks.
- `levelsOfUndo` is capped, so dead registrations cannot hold tracks without bound.
- Remove routes a removal of every row to `closeFile:` before registering, so Close stays un-undoable.
- **Every re-park of the successor goes through `prefetchSuccessor`, which does nothing while the player is Stopped.** That covers a removal, a restore, an append (`reconcileAfterPlaylistStructureEdit`), a Pause, repeat or shuffle change (`applyEndOfTrackAction`) and a conversion. A Stopped player advances nothing. So a stopped or errored player must not open or download a successor.

## Move to Trash

Edit > Move to Trash (⌘⌫) and the row menu's item move each target row's file to the Trash. Every row of each file goes, found by URL, on the first trash and on every redo. So one cue row takes all of its image's rows, and a duplicate row goes with its file. A cue sheet beside the image stays. The bundled welcome track and an Open URL link's file are not trashable, because the app owns them.

**The rows go at once and the files follow.** The rows leave through the funnel, so the player lets go of a removed current file before it moves. The files move on the converter's dispose queue (`AudioFileConverter.trashItemAtURL:completion:`), coordinated and off main. A file that fails to move raises an alert naming it. Its row is already gone, and Undo brings it back. A trash that removes every row empties the list as an edit, so its undo restores every row and keeps the older history. Rows put back into an emptied list park on the cursor's row, as a removal parks.

**Move to Trash is undoable, with its own registration.** Undo restores each file from its Trash location first. Only then does it put the rows back, through `restorePlaylistTracks:`, the step it shares with Remove's undo. So no prefetch or play reaches a file still in the Trash. Redo removes the rows and trashes the files again. Each direction registers the opposite at once, while `NSUndoManager`'s stack direction is still active. The two directions share one dictionary from each file to its place in the Trash. Each direction rewrites it, so a file one direction could not move is skipped by the next. A file the Trash moved without saying where is never touched again, because its path no longer proves where it is.

- **The playlist holds still while Move to Trash moves files.** The shell sets `PlaylistController.structureEditsHeld`, and `fileMoveInFlight` reads it with the converter's own flag. Undo, Redo, Remove, Move to Trash, the row menu's removals and a reorder drop all wait. An undo's rows are absent until their files land, so any edit in between would shift the rows every older registration names.
- A replaced playlist takes no rows back, but the files still come back.

## Reordering playlist rows

The drag is `Playlist/Mac/AGENTS.md`'s. **`playlistOrderDidChangeHandler` is a reorder's whole follow-up.** It registers the inverse, re-parks through `prefetchSuccessor`, refreshes the metadata neighborhood once, and calls `updateUI`. **A move never enters a play funnel.** The current object survives at its new row, so a Loading row keeps its pending play and a paused row stays paused.

**The handler is the ONE undo registration point.** The model operation is its own inverse with the two index sets swapped. The handler registers `movePlaylistTracksFromIndexes:toIndexes:generation:` under `STR_MENU_EDIT_REORDER`. It fires for every completed move, whether a drag, an undo or a redo, so `NSUndoManager` chains undo and redo with no second path. The bare row sets stay exact because of LIFO plus the generation. Every undoable edit between a move and its undo has been unwound. No un-undoable edit shifts rows without replacing the list: appends extend it, the convert swap keeps its row, and Close and every replacement bump `structureGeneration`. A stale restore performs no move and registers nothing.

## Display states and time labels

**All header rendering resolves through one `TrackDisplayState`.** Five states describe the playback: track, loading, empty, launch-grace and error. `displayState` decides them (`TrackDisplayRules.h`, tested). Now Playing, the delay's tempo and the play button read it. **The header draws `headerState`**: the display state, or Notice while one is held (`headerStateForState:`). `TrackDisplayController` draws it, holds no player or playlist state, and keeps only what it last drew.

- **Loading**: the incoming tags and `--:--`. The waveform's loading line starts at `didBeginLoading:`. A provider's dataless verdict fires it at once. Other opens use the 250ms fallback (`Audio/AGENTS.md`).
- **Empty**: midline placeholder, `--:--` and the drop hint, at half strength. The launch grace suppresses it until `revealEmptyStateNamingPlaylist:`, so a launch-time open never flashes it. An open that found nothing playable keeps the playlist. When it named a playlist, the placeholder says "Could not open listed files" over the playlist's file name until the next load or Close.
- **Error**: inline, with no modal and no auto-skip. `_erroredTrack` and `_errorStatus` mask the errored track. They are written only through `setErrorMaskForTrack:status:` and `clearErrorMask`. The track stays for a retry, and late deliveries are ignored while it is masked. The display state masks only a Stopped track. A track the player parked Paused with an error (a lost device, a device another app took, a refused resume) gets the same mark. `TrackDisplayController` then shows its status in place of the file info line until a resume or a new play clears it.
- **Notice**: a link that failed to open shows in the Error look for 4 s (`showNotice:naming:`). Its short status goes on the artist line, over the link's name. It is a header state only, so a playing track plays on under it. While a notice shows, `TrackDisplayController` drops the track's strip and playhead writes, the waveform stays off, the times stay `--:--`, and the BPM line names no track. The delay's tempo still follows the playing track. The artwork is not covered. The notice ends after 4 s, at a newer open request or at Close. `_noticeGeneration` pairs it with its timer. The end runs `restoreCoveredHeader`, as the end of the drop shimmer does. `dump_state` reports it as `ui.headerState` `notice`, with `ui.notice` its status.

**Every write of the right time label goes through `renderRightTimeLabelWithDisplayPosition:duration:rate:`.** It delegates the rate, the remaining-time subtraction, the clamping and the whole-second string cache to `Formatters.durationStringForFileDuration:rate:elapsedDisplayTime:remaining:`. Both labels are wall-clock: file time over the varispeed rate. The label shows duration or minus-prefixed remaining, toggled by a click and stored in `AppSettings.showRemainingTime`. `VibeTrackTimeMayUpdate` keeps the placeholder states intact. The tick skips the label while the cached duration is 0, or the end-of-playlist park would read `-0:00`. `AppSettings.showTimeLabels` hides both labels and their click target. Updates still carry the position, so revealing them is immediate.

**Now Playing** publishes the same wall-clock position and duration (`NowPlaying/AGENTS.md`). Its artwork reads without blocking: `cachedArt`, else the 128px `cachedThumbnail`, refreshed when the full art resolves.

## The window

Undo and Redo forward from the window to its controller, so menu routing through the responder chain keeps the file-move gate (`fileMoveInFlight`).

**The height has a second floor, which is a band.** A playlist pane under `kPlaylistPaneMinHeight` is a sliver, so no height between `kMainWindowSmallHeight` and `kMainWindowMinLargeHeight` is a resting height. `restingHeightForDraggedHeight:` sends a drag to the nearer end, and `loadSettings` clamps a restored frame out of the band. The rule reaches drags through `windowWillResize:toSize:`, **gated on `inLiveResize`**, so the app's own animated resizes are not snapped mid-flight. All three programmatic resizes use one fixed `animationResizeTime:` (`kWindowResizeAnimationDuration`) rather than AppKit's distance-scaled default.

**The pitch-panel toggle is the one resize the two `contentView` siblings must not follow.** The reveal is the right edge sweeping past a panel that stays still. So `togglePitchPanel:` swaps in fixed masks for the animation and restores the resizable ones after.

**The position lock is `movable = NO` and nothing else.** `applyWindowLock` sets it from `AppSettings.windowPositionLocked`, and `MainWindow` never reads the setting. The window stays resizable, and the app's own resizes still set the frame. `frameKeptOnScreen:` skips its slide, so a growth against the right screen edge may extend past it. `movable` alone stops the background drag and nothing more, hence two traps in `MainWindow.m`:

- **From macOS 26 `performWindowDragWithEvent:` ignores `isMovable`.** The window's override drops the call while locked, which covers the waveform's handoffs.
- **The system never moves a non-movable window when displays change.** `keepLockedWindowOnScreen` centers a locked window on the primary screen when no screen shows it any more. The rescue is one-way.

**TRAP: a Finder drag delivers file-reference URLs** (`file:///.file/id=…`). Their `.path` re-resolves to wherever the file *is*. Everything downstream treats a track's URL as fixed: cache keys hash it, and the convert undo record restores to it. Unpinned, a converted source's URL follows the file into the Trash, and the undo restore becomes a move onto itself. **Testing with `open` never shows it.** `performDragOperation:` pins every file to `fileURLWithPath:`, and `didConvertTrack:` pins the undo record's source again.

**The window takes files and web links** (`kVibeDropType*`, `LinkDropRules.h`). `draggingEntered:` decides once per drag, through `VibeDropURLsOfItems`, and draws the wells only for a drag it takes. A drag holding no file and no http or https link is refused. A link goes on as it came. The drop resolves the empty-state wells into append or replace **synchronously**, since the dragging session is gone by the time the expansion lands. `openDroppedItems:appending:` is the drop's whole road, shared with the debug channel's `file_drag_drop`. It ends in `AppDelegate.openDroppedURLs:appending:`, the one open funnel (`Mac/App/AGENTS.md`). The window's `cancelOperation:` is Escape's. It cancels the opens still resolving their links, and passes Escape on when there are none.
