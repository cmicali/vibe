# Main window

## Layout

Layout is programmatic: no nibs, absolute frames and autoresizing masks. Every number lives in one named layout block at the top of `MainPlayerContentView.m`. Frames are authored at the design size, `kMainWindowContentWidth` by `kMainWindowDesignHeight`, with edge-reaching values derived from the width, and each subview's mask says how it stretches from there to the user's window size.

One frame is the exception, because what it has to clear is content rather than geometry. The artist line ends where the codec line's *text* begins, and that text is right-aligned inside a label whose column is sized for its worst case, a long codec string behind three FX symbols. Reserving the whole column would cost the artist line a third of its width at the design size and nearly all of it in a narrow window, so `layoutArtistLineClearOfCodecLine` re-caps it against what the codec line actually renders. Both inputs move: the geometry on every resize, which the view hooks through `resizeSubviewsWithOldSize:` so that a live drag is covered too, and the text on every codec and FX change, which `TrackDisplayController` hooks from its compose. The frame in the layout block is the worst-case reservation, and so is also the fallback. The two header lines need different clearances because they sit at different heights: the artist line is level with the codec line, while the title only has to clear the shorter BPM line beneath it, which its shrink-to-fit width already does.

One overhang is deliberate and named. The header glass panel bleeds `kHeaderPanelRightBleed` past the window's right edge so that the window shape clips its right-side corner arcs off-screen. The glass rounds all corners uniformly, and without the bleed the header's right edge shows visible curves instead of running square to the edge.

`MainWindow` configures itself in `init`: borderless, frame autosave, drag-and-drop registration. The view hierarchy lives in `MainPlayerContentView`, a plain transparent `NSView` that exposes its subviews as readonly properties, since the window's glass backdrop provides all the background. The backdrop and the pitch panel are the two exceptions; the controller installs them as `contentView` siblings. `MainPlayerController` adopts the hierarchy as its outlets in `buildContentInWindow:`, called from `init`, and invokes `windowDidLoad` by hand because AppKit only fires it on the nib path. Playlist cell views are built in `PlaylistTableView`'s `makeCellViewWithIdentifier:` and recycled through the table's normal reuse queue.

## Chrome: three layers of Liquid Glass

Window chrome uses macOS 26's `NSGlassEffectView` in three layers, each with a different job.

**1. The backdrop.** `buildContentInWindow:` installs a window-spanning glass backdrop behind everything, in the very transparent **Clear** style, pitch panel included.

**2. The header panel and its tint.** The header and waveform area gets its own **Regular**-style glass panel in `MainPlayerContentView`. Regular is the `NSGlassEffectView` default, so there is no explicit `.style` to grep for. Over it sits `headerTintView`, a passthrough layer view washed with the current track's dominant art color. `NSImage+Util`'s `dominantColor` computes that color from a hue histogram weighted by saturation times brightness, falling back to the average gray for monochrome art, and `ArtworkDisplayController` applies it. That class also owns the art view, the dock icon and deferred art loads.

The wash's clamps are **perceptual, not HSB** (`NSColor+OKLCH`). The unplayed waveform must stay distinguishable from the wash over any artwork, and HSB brightness is hue-blind — a yellow and a blue at the same brightness are worlds apart to the eye — so an HSB cap let bright-hued art wash the waveform out. Lightness is capped low in dark mode (OKLCH L at most 0.30, over a light waveform) and high in light mode (at least 0.87, over a dark one), and chroma moderately in both. An out-of-gamut result gives up chroma, never lightness or hue. The same resolution emits the playlist's accent through `accentColorDidChangeHandler`, from the same source color, in a text-legible band.

TRAP: `refreshHeaderTint` must resolve light or dark from the **window**, not from `headerTintView`. Its appearance-change caller is the *content view's* `viewDidChangeEffectiveAppearance`, and AppKit updates the tree top-down, one callback per view, so a subview there still reports the outgoing appearance. Reading it left the wash and accent a full appearance behind on every live light-dark toggle — a dark-band wash under the light appearance, exactly the contrast failure the clamps prevent.

The wash is deliberately not the glass's own `tintColor`. AppKit silently discards a glass view's tint whenever the window is not key, and offers no public override. The design instead keeps the window as close to key-state-independent as public API allows: the app-controlled pieces, the header tint wash and the playlist frost via `NSVisualEffectStateActive`, never dim, while the glass views' own subtle inactive dimming is accepted. There is no public opt-out — `isKeyWindow` overrides do not affect it, and only the private `resignKeyAppearance` does, verified by pixel-diffing active and inactive captures. Private API is off-limits, because this app ships in the App Store. Tint changes fade over `kVibeArtCrossfadeDuration`, shared with the art crossfade in `CrossfadingImageView`.

**3. The playlist frost.** The playlist sits on a behind-window `NSVisualEffectView` frost, `UnderWindowBackground` in both appearances — the light `WindowBackground` material is effectively opaque paint — with a brightening white wash in light mode only. Row text is not readable over Clear glass.

TRAP: an `NSGlassEffectView` inside `MainPlayerContentView` must not be height-flexible. This frost band showed why: as an `NSGlassEffectView` with `NSViewHeightSizable`, its SwiftUI hosting internals fought the stretch from the design height and the window silently refused to expand past it. That is why the frost is an `NSVisualEffectView` — a choice that also keeps it from ever dimming, through `NSVisualEffectStateActive`. The trap is the design-size-to-window-size autoresizing stretch, not height-flexibility itself: the window-spanning glass backdrop is a `contentView` sibling created full-bleed at the window's live bounds, is `NSViewHeightSizable`, and has height-resized cleanly since before the window was freely resizable. Width-flexibility is fine, and both glass views are `NSViewWidthSizable` and drag-resize cleanly.

All corner rounding shares `kMainWindowCornerRadius` (Constants.h, 20pt, the macOS 27 standardized window radius): the contentView layer mask, both glass views, the header tint layer and the pitch panel's right-edge path.

## The controller

`MainPlayerController`, an `NSWindowController`, is the central coordinator. It implements `AudioPlayerDelegate`, `AudioWaveformViewDelegate`, `AudioWaveformCacheDelegate`, `AudioTrackMetadataCacheDelegate` and `FileDropDelegate`, all in the class extension. The public header exposes only collaborators, actions and `NSMenuDelegate`, which is public so `MainMenuBuilder` can wire the controller as the waveform-style submenu's delegate.

Several pieces are split into categories:

- `MainPlayerController+Menus` — menu validation and the delegate-built waveform-style submenu. `NSMenuItemValidation` conformance is declared on the category.
- `MainPlayerController+NowPlaying` — the `updateNowPlaying` publish and `NowPlayingControllerDelegate` command routing, following the same conformance-on-category pattern.
- `MainPlayerController+Transport` — the relative-seek skips and the DJ effect toggles, declared in the category header rather than the main one, since they touch only public collaborators.
- `MainPlayerController+Debug.h` — the debug command channel's extra surface.

`TransportKeyMonitor` handles the bare keys: Space, B, N, P and Tab; A, S and D to skip forward and Z, X and C to skip back; and the dual-mode effect keys Q, W, E, R and T for low kill, low-kill boost, reverb and delay, where R gives 1/8-note taps and T gives 1/16. A tap toggles the effect and a hold is momentary: the effect flips at keyDown, and keyUp reverts to the pre-press state when the press ran longer than the tap threshold of about 0.35 seconds. The controller owns the monitor, which watches both keyDown and keyUp, and keyUp is what decides tap against hold.

A 3 Hz timer, `UIUpdateTimer` in `Util/`, drives the playback-position UI through `updatePlaybackUI`. It runs only while playback wants updates and the window is unoccluded; `windowDidChangeOcclusionState:` pushes the visibility gate and refreshes once on reveal, since Control Center keeps counting on its own. The full `updateUI` runs on transport events and metadata deliveries. Metadata loading for a dropped playlist waits until playback starts, with a two-second fallback, so the first track plays immediately on a large folder drop.

## Skipping and closing

The skip actions — skip, more and most — seek by 8, 16 or 32 bars when the track's tempo is known, with tagged BPM beating analyzed BPM, the same precedence as the BPM label. Bars are fixed spans of file time, so the jump stays on the musical grid at any pitch. Without a tempo they fall back to 10, 30 or 60 seconds in the pitch-adjusted wall-clock seconds the labels show.

A forward skip past the end calls `AudioPlayer.finishCurrentTrack`, which fires `didFinishPlaying:` so the usual auto-advance and end-of-playlist stop path handles it. The controller needs no next-against-stop branch of its own.

Skips need a player that is not Stopped, gated both in `skipByFileSeconds:`, because the bare keys bypass validation, and in menu validation. After the playlist ends the finished file stays open, so `duration` alone still looks seekable while no node exists.

File > Close (⌘W, `closeFile:`, retitled "Close File" or "Close All Files" in validation) calls `AudioPlayer.stop`, which fires no delegate event. It then clears the playlist, cancels the deferred metadata load, drops the metadata scan loader with `cancelAll` — a cancelled loader still strongly holds every track it queued, thumbnails included, and after a Close nothing would ever replace it — and returns to the empty state.

## The codec line and FX indicators

The codec line doubles as the FX indicator. The SF Symbols of whichever performance effects are latched are drawn inline at the head of the same right-aligned run, so they stay glued to the codec text, whose left edge moves with the track's string. Low kill shows the filled dial while its boost is on, since the boost modifies that filter rather than being an effect of its own; reverb gets one symbol; each active delay gets one, matching the FX menu's.

Two adjustments are optical rather than derivable from any metric. The symbols are drawn at bold weight, because the default stroke is a hairline at this size. The two dial glyphs get a size multiplier of their own: they spend much of their bounding box on the tick marks ringing a small central dial, so at the row's shared box height they read visibly smaller than the solid-stroke symbols beside them.

The symbols render a step brighter than the codec text, at full `secondaryLabelColor`, matching the time labels. That is why both corner labels now carry their dimming in the text color — `tertiaryLabelColor` in `cornerTextAttributes` — at full field alpha, rather than the field-wide 0.5 alpha they used before. A field alpha would dim the symbols along with the text, and the codec and BPM lines are one visual pair that must keep the same treatment. The symbols are template images, so the tint follows the label through appearance changes with no second color to keep in sync.

The line has two independent inputs, the codec text and the FX state, and `TrackDisplayController` composes it from the last of each, because FX are deck state that outlives any track: they persist across track changes and into the empty state. Every path that can change an effect refreshes the line. The five state setters in `MainPlayerController+Transport` are the single funnel for the menu items, the bare keys' taps and momentary holds, and the debug commands, and each calls `updateFXIndicators`, which re-reads the live `AudioFX` flags rather than trusting the caller's intent. `AudioFX` enforces its own coupling: clearing `lowKillEnabled` also clears `lowKillBoostActive`.

## Time labels and display states

The right-hand time label shows either the total duration or, by default, the minus-prefixed remaining time counting down with the 3 Hz tick. Clicking it toggles the mode, persisted in `AppSettings.showRemainingTime`. Both readings are wall-clock — file time over the varispeed rate — like the elapsed label, and every write goes through `renderRightTimeLabelWithDisplayPosition:duration:rate:` so the two modes cannot drift. The tick skips the label when the duration cache is 0, or the end-of-playlist park's full-length resting value would be clobbered with `-0:00`.

In the empty state, with no track, the waveform shows a static midline placeholder, both time labels read `--:--` and a "Drop a file or press ⌘O" hint appears, all at half strength. At launch the `revealEmptyState` grace suppresses it to a blank header, so a launch-time open never flashes it.

Play errors render inline in the same empty-state style, with no modal and no auto-skip. `displayedTrack` masks the errored track through the `_erroredTrack` and `_errorStatus` pair, written only via `setErrorMaskForTrack:status:` and `clearErrorMask`, and the error text sits on the artist line over the track's title. The track stays in the playlist for a retry, and late metadata and art deliveries for it are ignored while it is masked.

All header rendering resolves through one five-state `TrackDisplayState` — track, loading, empty, launch-grace and error. `displayState` resolves it in one place, and `updateUI`, `updatePlaybackUI` and the Now Playing publish share the result, so the branches cannot drift. `TrackDisplayController` draws the rendering itself: the header labels, with the title shrinking to fit, the codec and BPM corner, the drop hint, and the waveform view's progress, shimmer and placeholder states. The split is pure decide-against-draw — the controller resolves what to show and hands it over, and the display controller holds no player or playlist state.

## Now Playing

`NowPlayingController` bridges the player to the system Now Playing UI — Control Center, the hardware media keys and AirPods or Bluetooth transport — through MediaPlayer's `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`. The controller owns it and calls `updateNowPlaying` from the `updateUI` funnel, and from the seek and pitch-change paths, to publish title, artist, artwork, duration, elapsed time, rate and state. Command handlers route back through `NowPlayingControllerDelegate` to the same `playPause:`, `next:`, `previous:` and seek entry points the on-screen buttons use.

Position and duration are reported in wall-clock, pitch-adjusted time — file time divided by the varispeed `playbackRate` — matching the app's own current and total time labels, so the Control Center readout tracks the pitch fader. The MediaPlayer rate is then 1.0 while playing, since wall-clock elapsed time advances at real time, and 0 while paused. The system is told nothing until the first track plays, so Vibe does not steal Now Playing from other apps at launch. Artwork is read non-blocking, since `albumArt` returns only already-decoded art or nil, and refreshed when art resolves. To inspect it in a debug build, run `Vibe --debug-cmd dump_now_playing`.

## The window

`MainWindow` is a custom `NSWindow` that accepts file drag-and-drop through `NSDraggingDestination` and supports the small-large layout toggle. It is freely resizable in both axes: the frame belongs to the user and the autosave keeps it. The window enforces only the floor — `kMainWindowMinContentWidth`, plus the pitch panel's slice when showing, and `kMainWindowSmallHeight` — and applies the size changes the app makes itself: the playlist toggle's height, the pitch panel's `kPitchPanelWidth` either way, and the View > Size width presets.

The height has a second floor above the first, and it is a *band* rather than a limit. A playlist pane shorter than `kPlaylistPaneMinHeight` is a sliver rather than a playlist, and the empty state shows it worst: the drop well runs out of room for the two lines of text inside it, then hides itself entirely at `PlaylistDropZoneView`'s own visibility floor, leaving a blank strip. So nothing rests between `kMainWindowSmallHeight` and `kMainWindowMinLargeHeight`. `restingHeightForDraggedHeight:` sends a drag through that band to whichever end it is nearer, which reads as the playlist snapping shut and springing back open under the cursor, and `loadSettings` clamps a restored frame out of it. `minSize` still floors at the collapsed height, because the toggle and the restore both target that exactly. The rule reaches the drag through `windowWillResize:toSize:` on the controller, gated on `inLiveResize` so that the app's own animated resizes are not snapped mid-flight — every height the app sets is a fixed point of the rule regardless.

All three animate at one fixed `animationResizeTime:`, `kWindowResizeAnimationDuration`, rather than AppKit's distance-scaled default, which made the playlist's 250pt jump drag and would have put a Large-to-Small preset near a second.

The pitch-panel toggle is the one place where the two `contentView` siblings must not follow the resize, because the reveal is the window's right edge sweeping past a stationary panel. `togglePitchPanel:` swaps in fixed masks for the animation and restores the resizable ones — body width-sizable, panel right-anchored — afterwards.

Dropped folders expand on a serial queue (`NSURLUtil`), so overlapping drops complete in submission order. A folder's recursive walk is sorted by full path with `localizedStandardCompare:`, which gives Finder's numeric ordering and keeps subfolders grouped; `NSDirectoryEnumerator` hands back APFS hash order, which played an album shuffled. An explicit multi-file drop keeps its pasteboard order, which is the user's own.
