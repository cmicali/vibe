# The waveform view (macOS only)

`AudioWaveformView` is a CALayer-based `NSView` that delegates drawing to the shared renderer strategies one directory up. **It is a pure rendering surface**: `MainPlayerController` owns the `AudioWaveformCache`, symmetrically with `metadataCache`, requests loads and forwards deliveries to the view through `TrackDisplayController`'s pass-throughs — `prepareForWaveformLoad` to reset, then `showWaveform:`.

`AudioWaveformView+Loading` holds the two non-waveform states, and `AudioWaveformViewInternal.h` is the private surface they share.

## The three states

- **Waveform** — the renderer's layer tree.
- **Loading** — `showLoadingIndicator`, once a file open crosses the player's 0.5s slow-open threshold. The control itself is the shared `WaveformLoadingIndicator`. Fast local and prefetched opens settle without showing it; until the threshold, the outgoing waveform may remain under the incoming track's title.
- **Empty** — `showEmptyPlaceholder`, a static midline for the no-track state, which is that same control at rest.

Loading and empty are mutually exclusive, and `prepareForWaveformLoad` clears both.

## Progress

`setProgress:` repaints only on **device-pixel crossings**, using the view's `devicePixelWidth`. That self-gating is what makes the window's scaled UI tick rate affordable — see `Mac/MainWindow/CLAUDE.md` on `VibeUIUpdateHzForPlayhead`. `devicePixelWidth` is also an input to that rule, so a resize resyncs it.

## Hover scrubbing

While the cursor is over a loaded waveform, the waveform's own column under the cursor is lit to full brightness. Nothing is drawn on top of it, and there is no tooltip.

The view only routes the cursor's x to the renderer, through `setHoverHighlightX:`, where a negative value clears the highlight — **because the two renderer families need opposite mechanisms**:

- The **Detailed** family adds a flat full-alpha column layer inside `_waveformContainer`, so the shared bar mask clips it to the envelope for free. It is a couple of points wide, since one bar is sub-point at 1024 bars or more.
- **Sonic Cirrus**, whose bars are discrete layers with gaps, snaps to a bar index and recolors that bar's two layers instead — a fixed-width column there could land in a gap and light nothing.

Sonic Cirrus must restore the bar's *resting* played or unplayed color when the hover moves off, and **re-apply the highlight after `updateProgress:` repaints a range covering it**. Otherwise the playhead crossing the hovered bar, or a full repaint after `updateColors:`, erases it. Renderers keep the x so a resize can re-place the highlight.

The view gates both hover and click-to-seek on having a waveform at all, which
is how the empty, loading and parked states opt out. Every presentation reset
also clears a press in flight, so a mouse-up cannot seek after the track
changed underneath it.

## Drag behavior

`AppSettings.waveformDragBehavior` decides what a drag starting on the
waveform does; the view reads it once per mouse-down into the gesture's state,
so a settings write cannot change a drag's meaning mid-flight.

- **`drag_window`** (the default): the window moves —
  `mouseDownCanMoveWindow` answers YES — and only a stationary click seeks.
  `mouseUp:` bails when either the window's origin or the view-local point
  moved past a ~4pt hysteresis since mouse-down: the origin check catches the
  server-side background drag, where the local point barely moves because the
  window traveled with the cursor, and the local check covers delivery where
  it doesn't. (Pre-setting behavior seeked on that release — dropped, not
  preserved.)
- **`seek`**: the window stays put and the drag scrubs. Past the hysteresis
  the tracked column renders through the hover machinery
  (`setHoverHighlightX:`, clamped to the bounds), real progress keeps painting
  underneath, and the audio is seeked once on release to the clamped
  fraction — bypassing the stationary path's containment test, since the drag
  may legitimately end outside the view.

With no waveform `mouseDownCanMoveWindow` answers YES in every mode, so the
empty and loading states always drag the window. A drag in flight is
presentation state: `resetWaveformContentState` clears it with the press, so
a track change mid-drag makes the release a no-op.

## The convert sweep

`convertSweepFraction` keeps the front and dips only the span since the last set, so bars behind the front are never re-zeroed mid-recovery. It gates on having a waveform, like hover, and resets in `prepareForWaveformLoad` and the empty and loading states. A value at or below the front just moves the front — that is the post-conversion reset. The mechanism is shared; see `WaveformUI/CLAUDE.md`.
