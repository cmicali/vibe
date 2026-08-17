# iOS app shell (VibeiOS target)

The iPhone and iPad app: a single-folder player where **the current directory is the playlist**. The user picks a folder (or file) in the system document picker; the folder's audio files, filename-sorted, become the playlist. Dropbox and iCloud work through their Files file-providers in the picker — no provider SDKs.

**The shape is Apple Music's.** Two tabs — Playlist and Files — in a capsule with search as a *circle* beside it rather than a third tab inside it, a mini player strip above them, and the now-playing screen as a full-screen card that presents up from the strip and swipes down to go back. Opening files or a folder replaces the playlist, starts playing and presents the card.

**This directory is the app shell and nothing else.** The iOS halves of shared subsystems are documented where they live: `Audio/iOS/`, `WaveformUI/iOS/`, `Util/iOS/` each have their own `CLAUDE.md`.

The target compiles this plus every shared subsystem minus that subsystem's `Mac/` half — see the root `CLAUDE.md` on the directory being the platform boundary. **A new file in a shared directory joins this target automatically** and must be AppKit-free or `TARGET_OS_OSX`-guarded; CI's `build-ios` job is what catches a leak.

On iPad the app is a resizable iPadOS 26 window (all four orientations, no `UIRequiresFullScreen`; minimum 320×480 via `sizeRestrictions` in `VibeiOSSceneDelegate`, the portrait layout's floor). **The portrait/landscape layout switch keys off view aspect**, so window shape — not device orientation — picks the layout.

**Multi-scene is off, deliberately**: there is one `AudioPlayer` per `PlaybackController` and one `PlaybackController` per scene, so a second scene would spawn a second engine. A size transition sets `_windowResizeInFlight`, which holds `commitVisiblePage` — a mid-resize offset rounds to a neighbor page and would otherwise switch tracks.

## The model

**`PlaybackController`** — everything the app plays and nothing that draws it: the engine, the `Playlist`, the metadata cache, the audio session, the `FolderSession`, the Now Playing bridge, the 3 Hz `UIUpdateTimer`, and the display state those resolve to. It is the model half of what the mac's `MainPlayerController` is. The scene delegate owns the one instance; every screen borrows it.

**It broadcasts, where the rest of the app uses a single weak delegate**, and that is the reason the class exists. Three views describe the same playback at once — the library row's playing indicator, the mini strip, and the card — and `Playlist` has exactly one observer slot, so the fan-out had to live somewhere other than a view controller. `PlaybackObserver` is delivered synchronously on main to a weak `NSHashTable`. **Weak is load-bearing**: an observer is a view or view controller, and outlives its registration only by accident.

Two categories, both the mac's split brought over with contracts intact:

- **`+PlayerEvents`** — every `AudioPlayerDelegate` callback. Same two rules as the mac's: **every callback can be stale** and must match the delivered track against the playlist's current one, and **`stop` fires no callback**, so nothing there drives auto-advance.
- **`+NowPlaying`** — the publish and the remote-command routing, landing on the same transport entry points the screens' own controls use. `notifyDidTick` **publishes before it ticks**, so the lock screen can never lag the screens.

`PlaybackControllerInternal.h` is the private surface those categories share.

**A scrub on a parked track seeks; it does not start playback.** Parked, the player holds no file, so its duration is 0 and there is nothing to seek *in* — `seekToProgress:` therefore opens the file **at** the scrubbed position and opens it **paused**, taking the length from metadata. The seek target outranks Loading in the card's two progress paths for the same reason: that open is Loading and seeking at once, and zeroing the waveform there is the snap-back the target exists to prevent. `didStartPlaying:` clears the in-flight flag, since this seek has no `didFinishSeeking:` of its own.

**The playlist-wide metadata sweep waits for the picked track to settle** — the mac's rule brought over: `folderSession:didOpenTracks:` schedules it, `didStartPlaying:` and the error path start it, and a two-second fallback covers an open that never lands. On a file-provider folder each of four workers' reads is a whole download. The other half of the rule is the metadata cache's cloud-lane hold, set here from `didBeginLoading:` and cleared with the download monitor — `Audio/Metadata/CLAUDE.md`.

**The display state is resolved in one place**, `PlayerScreenRules.h` — header-only, Foundation-only and tested from the macOS suite — rather than re-derived from `_parked`, `_trackStartPending`, `_errorText` and the rest at each site. `screenState` gathers the inputs; the card, the mini strip (`VibeMiniPlayerVisible`), the Now Playing publish and the debug dump all read the result. Its mac twin is `TrackDisplayRules.h`; the two enums are deliberately separate, since this screen has no launch grace and parks tracks the mac has no equivalent of.

**Three of the mac's features are off here**, each at one place rather than compiled out: no DJ FX (the engine is created with `enableFX:NO`), no folder art (`AudioTrackArtwork` leaves its resolver handle nil), and no BPM or key analysis (the decode pass's analysis provider is unset). The settings behind all three are macOS-only in `AppSettings`, so there is nothing here to read that could disagree. **The 128px thumbnail is not on that list** — the library rows and the mini strip draw one, so iOS decodes, holds and archives it exactly as the mac does.

## FolderSession

The picked location's owner: picker presentation, the security scope, the bookmark that restores the folder on relaunch (default `bookmarkData`; iOS has no `WithSecurityScope` option and does not need it), and the listing via `NSURLUtil audioFilesInDirectory:`.

**The security scope is held for the whole session** — the player, TagLib and the waveform loader read under it at arbitrary times — and released only after a successor is in hand.

**Adoption happens on the session's own serial queue, never main**: bookmark resolution and the listing are both file-provider IPC that can run seconds on a cloud folder. Delegate deliveries land on main, in submission order.

A single-file pick is a one-track playlist: **iOS grants no sibling access from a file grant.** A relaunch restore **parks** the remembered track — header, waveform, metadata loaded, nothing playing, card left minimized — and the scene delegate runs exactly one of restore-or-adopt at launch, so a cold "Open in Vibe" never pays for a restore it immediately replaces.

Persistence is `FolderSession`'s own `NSUserDefaults` keys (`VibeiOSFolderBookmark`, `VibeiOSLastTrackFileName`), deliberately not the shared `AppSettings`.

## The shell

### RootViewController

The scene's root and the app's shape: a `UITabBarController` child, the mini player in its `bottomAccessory`, and the card above both. It owns expand and minimize, and is the only thing that knows whether the card is up.

**The tabs are `UITab`s, not view controllers**, which is what buys the Apple Music shape: `UISearchTab` draws the search circle *outside* the capsule, and its `automaticallyActivatesSearch` is what makes tapping it collapse the whole bar behind a search field and restore the previous tab on cancel. Each tab builds its view controller through a lazy provider, so a tab never visited costs nothing — which matters most for Files. The search tab's identifier is UIKit's rather than ours, so `selectedTabIdentifier` matches it by kind and the other two by the identifiers we minted.

**A container, not a `UITabBarController` subclass.** The card has to sit above the tab bar controller's whole view so the screen behind it can scale back, and a subclass cannot transform its own view without dragging the card along with it.

**The card is built once and never torn down.** Minimizing translates it off the bottom; it is not presented and not dismissed. Its pager, art window and waveform snapshots have to survive a minimize, or every expand would pay a re-read and re-decode of art already in memory. Its art is deliberately not pruned on minimize either — the byte budget already bounds retention, and pruning would cost a placeholder flash on the way back up.

**TRAP: the card moves by TRANSFORM and never by frame.** Its pages carry `WaveformScrubberView`s, and a scrubber tears down its baked envelope bitmap and re-bakes it 0.6s later on any bounds change — over a layer tree twice the view's width. Animating the card's frame would pay that on every expand, on every page. `dump_state`'s `ui.waveformBaked` is how to check it stayed baked.

**TRAP: `shouldAutomaticallyForwardAppearanceMethods` is per-parent, not per-child.** Only one child is on screen at a time, so this controller says when each appears — but turning forwarding off for the card turns it off for the tabs too, which is why both are forwarded by hand.

### MiniPlayerView

The accessory's content: artwork (the 128px thumbnail, never the card's full-size decode), title over artist, play/pause and next. Metrics are Apple Music's: **the tap targets stay large and the glyphs are small** (`kGlyphPointSize`, 19), because sizing the button instead of the symbol made ours read as buttons rather than as a transport. Next is `forward.end.fill`, the glyph the mac draws — one transport vocabulary across both apps.

**TRAP: the row needs a designated give, and the simulator will never tell you.** The strip is pinned to the edges of UIKit's accessory container, and on device that container reports a width of **zero** on at least one pass — where the rest of the row is required and needs 160pt (12 + art + 10 + 6 + two 40pt controls + 8). UIKit then breaks whichever constraint it likes and logs the whole conflict on every launch. The art's leading inset is therefore `UILayoutPriorityRequired - 1`: below required, that pass just slides the left block off and costs nothing, and at any real width the 12pt is honored exactly. Any new required constraint spanning this row reopens it.

**TRAP: the strip is 48pt and that is not negotiable.** `UITabAccessory` frames its content view at a fixed system height — an `intrinsicContentSize` is ignored, and so is an explicit height constraint, *without logging a conflict*, because UIKit never asks Auto Layout to size it. A taller strip means giving up the accessory, and with it the Liquid Glass, the collapse-inline behavior and the automatic safe-area inset for the tab children.

**There is deliberately no playhead bar**, for the same reason: one fits in 48pt only by taking a slice off the top and pushing the artwork and labels into what is left. Apple Music draws none either, and nothing in the shell reads the position tick as a result.

`traitCollection.tabAccessoryEnvironment` — set by UIKit on everything inside a `bottomAccessory` — is what tells it the tab bar has collapsed it inline, where the artist line is dropped.

### FilesViewController

The Files tab: `UIDocumentBrowserViewController`, the system's own browser over every Files provider. A picked file goes through `PlaybackController.openExternalURL:openInPlace:` — the same road the picker takes.

**This tab opens FOLDERS too, and that is why the playlist screen needs no Open button.** `UTTypeFolder` leads its content types, so navigating into a folder puts an **Open** button in the browser's own top right that hands that directory back through the same delegate — and `openExternalURL:openInPlace:YES` funnels into `FolderSession.adoptURL:`, exactly where the document picker's own delegate lands. The subtree grant, the directory-as-playlist listing and the persisted folder bookmark are therefore bit for bit what the picker produces. Only the empty state still presents a picker, for the first run.

It is the browser rather than an embedded `UIDocumentPickerViewController` because the picker is a modal presentation and unsupported as a child, and it takes **no navigation controller**: the browser brings its own bar and hierarchy, and wrapping it stacks two.

**TRAP: it needs `additionalSafeAreaInsets` for the mini strip, and it is the only tab that does.** UIKit insets tab children for the tab bar but **not** for the `bottomAccessory`, and the browser places its own Recents/Shared/Browse bar against its safe area — so with the strip up that bar ends up half underneath it. A scroll view never shows this, because it just receives extra content inset; a view controller that positions its own chrome does. `RootViewController.applyFilesBottomInset` **measures the live accessory** rather than assuming 48pt, so a system height change cannot silently reopen the overlap.

### LibraryViewController

The Playlist tab, and the home screen. The mac playlist table's four columns re-proportioned to Apple Music's list: number — replaced on the playing row by `EqualizerIndicatorView`, the very same bars the mac table draws, which is why that class is in the shared `Vibe/Controls/` — artwork, **title over artist on two lines**, and the duration out on the right.

The number and duration take the **artist line's text style**, not a fixed size, so the three secondary columns scale together under Dynamic Type instead of agreeing only at the default size.

An empty playlist gets `UIContentUnavailableConfiguration` with the same Open action, saying something different when the last pick found no audio. **Selecting a row plays it and stays here** — expanding the card is the strip's job, not a side effect of picking a track.

The folder name goes on `navigationItem.title`, **not `self.title`**: the latter is also the tab bar item's title, and the open folder's name is not what the tab is called.

The bar carries **the gear and nothing else**. There is deliberately no Open button beside it: the Files tab opens folders as well as files (above), so one there would be a third door to the same room. The empty state keeps its own Open action, which is the first run, where there is no Files tab visit to have made yet.

### SettingsViewController

Behind the gear, **pushed onto this tab's navigation stack rather than presented** — everything on it is something the mini strip or the card behind it draws, and both stay up. A grouped list of three: the waveform style (one row per registered renderer, sorted by localized display name, checkmark on the resolved style — never the raw stored one, or an identifier nothing draws would still be ticked), the time display, and the file-info switch.

**It writes settings and posts; it never reaches for the screens that draw them.** The card is the only thing that has to react and it is elsewhere in the app, so `VibeDisplaySettingsDidChangeNotification` carries it — see the card's `displaySettingsDidChange`. This is the one place a notification is right where the mac would use a direct live-apply hook (`Common/CLAUDE.md`): the settings screen and the card have no owner in common below `RootViewController`.

**`PlayerDisplaySettings`** is the store behind two of the three: `VibeiOSShowRemainingTime` and `VibeiOSShowFileInfo`, iOS-owned keys beside `FolderSession`'s and the waveform zoom's. Deliberately *not* `AppSettings`' equivalents — those sit inside its macOS-only block because they are read on every playback tick and ride the hot cache that block exists for, and iOS reads these a few times a second. File info defaults to **on**, which is the mac's default, so the absence of the key is tested rather than registered. The waveform style is the exception and is a shared `AppSettings` property: both platforms draw waveforms and both now offer the picker.

### SearchViewController

Behind the search circle: a `UISearchController` over the open folder's tracks, matching title, artist and filename. It installs the field on its own `navigationItem`, and `UISearchTab` hoists that field into the collapsed tab bar — so there is **one** search controller, not one per bar. The empty query lists everything, so it doubles as a browse list. It re-*filters* rather than reloading on a playlist change, because its rows are indexes into a playlist that has just been replaced. It deliberately does not focus the field on appear.

### PlayerViewController — the card

The track pager and the chrome over it. It observes `PlaybackController` and owns no playback state.

- **`+Pager`** — the collection view's data source and layout, size-transition re-paging, per-page waveform bookkeeping, and `commitVisiblePage`. **Playback does not switch as pages appear; only the settled page commits.**
- **`+Delivery`** — where the pager's asynchronous results land: waveform snapshots, and the scrubber's seek. Metadata is not here; it is the model's delivery and arrives as a `PlaybackObserver` event.

`PlayerViewControllerInternal.h` is the surface those categories share.

**`presented` is the gate that makes a keep-alive card safe.** Minimized, the card is still laid out and still reloads, so two things must not run: `commitVisiblePage` — a playlist replacement settles a scroll nobody performed, and committing it would change track under a user looking at the library — and the playhead's display link, which would animate a waveform nobody can see.

**The swipe down is arbitrated on axis, in `gestureRecognizerShouldBegin:`.** A horizontally-paging scroll view's pan begins on movement in *any* direction, so the minimize pan has to beat it to the touch: the pager's pan requires it to fail, and it fails on the first move of a horizontal drag.

**TRAP: the axis test is on TRANSLATION, not velocity.** Velocity is sampled over the last few touch events and reads zero whenever the finger pauses — including the moment a slow deliberate drag crosses the recognizer's slop, which is exactly when this is asked. Translation is monotonic and always past the slop by then.

**TRAP: the scrub lock's release is matched against the view that took it, not against the bound page.** Playback runs on through a scrub — the seek only commits on lift — so a track ending mid-drag rebinds `_waveformView` to the next page while the finger is still down on the outgoing one. Filtering the lift on the binding drops it, and **the pager stays unswipeable**. See `WaveformUI/iOS/CLAUDE.md` for why the pager must be held still at all.

`VibeTrackPagerView`, in `PlayerViewController.m`, declines its own pan for touches that hit-test into a `WaveformScrubberView` — the other half of the same problem, and likewise documented in `WaveformUI/iOS/CLAUDE.md`.

**A two-finger touch on this screen is a waveform zoom, never a page swipe.** The *pager's* pan is capped at `maximumNumberOfTouches = 1` and additionally requires the scrubber's *pinch* to fail alongside its pan, which covers the drag that begins with one finger and becomes a pinch. The pinch takes the same pager hold a scrub does (`didChangeScrubbing:`), so nothing pages for its duration. **The scrubber's own pan is deliberately left uncapped** — capping it breaks the pinch-back-to-scrub handoff, and `WaveformUI/iOS/CLAUDE.md` carries why.

**The right time label shows the total duration, and a tap flips it to the minus-prefixed remaining** — the mac's behavior and its default, held by `PlayerDisplaySettings` (below). Every render path — the tick, a page at rest, a scrub — goes through `VibeRightTimeText` so they cannot disagree, and `VibeTimeLabel` is a class of its own only so the card's tap-anywhere-to-pause can decline it, exactly as `VibeTransportRowView` is. The tap is wired per cell but the mode is one setting, so the handler repaints **every visible page**, not the tapped one.

**A settings change arrives from outside the card**, since the screen that makes it sits on the Playlist tab with this one minimized behind it: `VibeDisplaySettingsDidChangeNotification` lands on `displaySettingsDidChange`, which re-configures every visible page (the header's codec line), syncs each page's waveform style, and repaints the times. It re-reads all three rather than being told which moved. A cell in the reuse pool needs none of it — it is configured from scratch on its way back on screen, and `willDisplayCell:` re-applies the zoom and the style there.

**The time labels belong to a scrub while one is running.** `didScrubToProgress:` arrives per frame of scroll and `+Delivery` renders it as the time the release will land on, guarded to whole seconds so a drag does not format strings at display rate; `updatePlaybackUI` bails outright on `isScrubbing` rather than fighting it. The duration falls back to the track's own, as the seek path does, so scrubbing a *parked* track — which is how one gets opened at a position — reads correctly too.

**The waveform zoom is one value for the whole pager**, since every cell carries its own scrubber and a swipe must not change it. `+Delivery`'s `didChangeVisibleFraction:` stores it, fans it out to the visible cells, and persists it to `VibeiOSWaveformZoom` — an iOS-owned key beside `FolderSession`'s, for the same reason; `+Pager` re-applies it on every `willDisplayCell:`, since a recycled cell keeps whatever depth it was last shown at. **What is stored is the user's request, never what a view drew**: see `WaveformUI/iOS/CLAUDE.md` for why a launch in the shallower orientation would otherwise ruin it permanently.

### TrackPageCell

One full-screen page: blurred art plus the mac-style header, and the transport row — previous, play/pause, next — which rides the page rather than the chrome above it. Two constraint sets swapped on the cell's own aspect in `layoutSubviews` — portrait is the Apple Music-style centered card, landscape is the mac main window transplanted. Its geometry constants are private to the cell.

**The transport is always up**; only the empty state fades it (`chromeAlpha`). It used to hide while playing, on the theory that a screen tap was the pause control — the tap still is, everywhere off the waveform and the transport row, but it is no longer the only one. **Next is dimmed at the end of the playlist**, decided off the PAGE's own index rather than the playing one so the last page arrives already dimmed.

Two traps sit under that one dimmed button, and both are load-bearing:

- **The disabled look is drawn, not delegated.** A system-type button dims its own template image for the disabled state, so an alpha on top compounds — the glyph measured 52/255 over the card's backdrop instead of the half it asks for. `setGlyph:onButton:pointSize:` therefore installs a pre-tinted `AlwaysOriginal` image for `UIControlStateDisabled`, which opts out of the tinting the adjustment rides on and carries the alpha itself.
- **Hit-testing does NOT hand back a disabled button.** The touch falls through to whatever is behind it, which here is the card's tap-anywhere-to-pause — so tapping next at the end of the playlist *paused playback*. The fix is `VibeTransportRowView`, a class of its own for the row's container, declined as a whole in `gestureRecognizerShouldReceiveTouch:` alongside `UIControl` and `WaveformScrubberView`. A `UIControl` check alone cannot cover it.

**Portrait is four bands, and only one of them moves.** A fixed strip under the safe top holds the grabber pill the card's chrome draws; the **art band** takes everything left over, which makes it the band the screen's height lands in, with the card centered in it at 80% — the remaining 20% is its padding; the **label band** is fixed; and the waveform and transport hang off the *safe bottom*, the time row off the waveform.

**So the waveform sits at the same y on every page, and that is a layout guarantee, not a coincidence.** The label band's height is the worst case its labels can need — a two-line title, one line each for artist and codec — **except that the codec line can leave the band entirely**, when the setting is off or a track has no readout yet: it gives up its line *and* the gap above it, so the band tightens by the whole row instead of holding its height as slack. That is one setting across every page, so the guarantee holds; what moves is the art above it. Within the band, a two-line title, a missing artist or a shrunk-to-fit one cannot move its edges, and nothing above the waveform can reach it anyway. All three labels shrink to fit their width rather than truncate. **The labels ride centered in the band**, one gap for both seams, rather than each sitting in a reserved box: a one-line title in a two-line box put its slack on screen as a gap under the title. The two single-line labels do keep their line reserved, so a track with no artist lays out like one that has it. The art card is what gives at accessibility text sizes.

**TRAP: the art card's shadow path is restated from the card's OWN layout pass** (`VibeArtCardView`), not the cell's. The constraints that size it belong to the contentView, so the header metrics landing — or Dynamic Type, or anything else that moves the label band — resizes the card without the cell's `layoutSubviews` running again. Set from there, the shadow keeps the card's previous, larger size: a wide dark halo around the art that vanishes the moment a swipe recycles the cell, which is exactly what makes it look like a rendering glitch rather than a layout one.

**The time row is pulled UP into the waveform view's bottom** (`kCellTimeWaveformOverlap`). The scrubber centers its envelope in its bounds and reserves headroom above and below it, so measuring the gap from the view's frame leaves the times looking stranded; the edge the eye measures against is the drawn waveform. It hangs off the waveform rather than sitting between waveform and transport, so tightening it cannot push the waveform down. Landscape keeps a plain gap: its strip is a third shorter and its transport rides the time row's centerline, so the same pull-up would put a glyph over the envelope.

**A page shows full-size art and nothing standing in for it** — the vinyl placeholder until it arrives, never the 128px thumbnail, which is fine under the blur but visibly soft in the art card and only buys a swap to sharp a moment later.

Making it arrive first is the **art window**, in `+Pager`: the current page and its immediate neighbors decode ahead and keep their art (`_artHeldPages`) up to a byte budget, so a swipe either way lands on art already in memory — **but a page with a live cell is never released**, since its image view pins the bitmap anyway and the discard would free nothing while leaving the page one reconfigure from dropping to the placeholder in view. `renderHeaderForTrack:` moves the window; a metadata delivery re-runs it, because until a track's metadata lands its art dispatch is a message to nil. **The commit path deliberately discards nothing**: the departing track is usually the page right beside the arriving one, and releasing it per commit made every swipe back re-read and re-decode the file.

**The blurred backdrop is a baked image, not a `UIVisualEffectView`** — see `Util/iOS/CLAUDE.md`.

### PageWaveformCoordinator

The pager's waveform bookkeeping between `AudioWaveformCache` and the cells: the cache runs one load at a time, and this owns which page it targets along with that page's URL, the latest snapshot per page for re-hydrating reloaded cells, and the complete set. Foundation-only and tested.

**Waveform deliveries carry the URL they were loaded for**, so a decode that outlives its retarget is dropped on the value rather than on the cancel having been observed in time — the app-wide staleness guarantee, and the reason `requestIndex:track:` records `_targetURL` beside `_targetIndex`. A page the pipeline already targets is left alone, since re-requesting on every cell reload would keep killing the decode. The snapshot window prunes to a radius around the current page. BPM/key deliveries pass through untouched.

**The scroll hold (`held`) is the pager's frame budget.** A swipe is the one moment the main thread has nothing to spare, and both halves of this object were spending it: a delivery repaints a scrubber, which tears its baked envelope down and restarts a 60 Hz full-view path rebuild — and a decode delivers about ten times a second, so the bake never re-landed — while a request cancels the ONE load the cache runs, so a swipe across N pages cancelled N decodes and finished none. Held, deliveries are recorded but not forwarded and requests are dropped; `+Pager` sets it on `scrollViewWillBeginDragging:` and clears it in both settle paths, **before** `commitVisiblePage`, so the page the drag landed on is what asks for a load. The cost is deliberate: a page pulled into view mid-drag shows the snapshot it has, or the loading line, rather than starting a decode nobody has settled on. The same flag pauses the playhead's display link (`updateScrollLinkState`).

## Building and verifying

```bash
make build-ios CONFIG=Debug     # exactly what CI's build-ios job runs
```

Use the **`vibe-debug` skill**'s "iOS: the simulator loop" section to launch, feed, screenshot and log the app. `launch-ios.sh` boots/installs/relaunches with audio silent by default (the mac's `--no-audio-hw --silent` flags work verbatim; the engine is shared), seeds audio into the container, and the log streams from the host.

**The debug command channel exists on iOS** (debug builds only): `debug-ios.sh <verb>` writes a command file into the simulator app's container tmp — a plain host directory, so no CLI client is needed — and the app's directory watcher answers with one JSON object, the same file protocol as the mac. The transport (`Vibe/Debug/DebugChannel.m`) is shared with the mac verbatim, and so is most of the verb set, written once in `Vibe/Debug/DebugCommonVerbs.m` against the `VibeDebugPlayerSurface` protocol.

**`RootViewController` is what adopts that protocol**, because it is the one object that can see the whole app: `RootViewController+Debug` composes the model's handles (`PlaybackController+Debug`) with the card's chrome and art window (`PlayerViewController+Debug`) and adds the shell's own state — which tab, whether the strip is up, whether the card is. What is left in `Vibe/Debug/iOS/DebugCommands.m` is only what needs UIKit, plus `expand_player`, `minimize_player` and `select_tab`, which exist because the channel cannot synthesize a touch. **All three debug categories live in `Vibe/Debug/iOS/`** — the shipping tree carries no declaration for a tool that does not ship, and `make check-vocabulary` enforces it.

The channel cannot inject touches (no public API synthesizes `UITouch`es in-process); **gestures go through the touch driver** — `drive-ios.sh` and the resident `VibeiOSDriver` XCUITest in `Tests/iOSDriver/`. Real-pixel screenshots stay `simctl io booted screenshot`; the channel's `dump_screenshot` is the in-process render.

**Interruptions, route changes, background audio past lock and the lock-screen card need a real device** — the simulator exercises none of them faithfully.
