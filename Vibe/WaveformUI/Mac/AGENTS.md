# The waveform view (macOS only)

`WaveformView` is a CALayer-based `NSView` that draws through the shared renderers in `../Renderers/`. **It is a pure rendering surface.** `MainPlayerController` owns the `AudioWaveformCache` and requests loads. It forwards deliveries through `TrackDisplayController`'s pass-throughs: `prepareForWaveformLoad` to reset, then `showWaveform:`.

`WaveformView+Loading` holds the two states with no waveform. `WaveformViewInternal.h` is the private surface they share.

## The three states

- **Waveform**: the renderer's layer tree.
- **Loading**: `showLoadingIndicator`, the shared `LoadingIndicator` in its waveform style (`Controls/AGENTS.md`). It shows at once for a File Provider placeholder classified as dataless. Other opens wait for the player's half-second slow-open delay (`kWaitIndicatorDelaySeconds`, in `AudioPlayer`'s `submitOpenOnQueueForTrack:openRequestId:`). Until then the outgoing waveform may stay under the incoming title.
- **Empty**: `showEmptyPlaceholder`, a static midline for the no-track state. It is the same control at rest.

Loading and empty are mutually exclusive, and `prepareForWaveformLoad` clears both.

**TRAP: feed every delivery directly into the running morph, completion included.** Holding the first leaves an empty strip after a skip as the outgoing bars collapse. Settling partials breaks the continuous ease. A window no one can see settles each delivery at once, since every eased frame is a full raster on main. The morph eases from the displayed bars at 60 Hz, so a newer snapshot bends the motion rather than snapping it. The loader already limits partial snapshots to about 10 Hz, so the view adds no pacing of its own. Normalize's completing raise uses the same morph.

## Progress

`setProgress:` repaints only on **device-pixel crossings**, using `devicePixelWidth`. That self-gating is what makes the window's scaled UI tick rate affordable (`VibeUIUpdateHzForPlayhead`, `Mac/MainWindow/AGENTS.md`). `devicePixelWidth` is also an input to that rate, so a resize resyncs it.

**Under a theme's playhead line the renderer is told 1, and the line carries the position** (`playedProgress`, `layoutPlayheadLine`, the rule in `../AGENTS.md`). The line is one layer of the view's own, above whatever tree the renderer built. It moves on the same pixel crossings and is clamped inside the bounds, so it shows at both ends of the track. It is hidden with nothing loaded.

## Hover and click

While the cursor is over a loaded waveform, the waveform marks the column under it. Nothing is drawn on top, and there is no tooltip. The view only passes the cursor's x to `setHoverHighlightX:`, where a negative value clears it. **Each renderer family marks it its own way:**

- **Detailed** adds a flat full-alpha column inside `_waveformContainer`, so the shared mask clips it to the envelope. It is a couple of points wide, since the columns are finer than a point.
- **Wiggle** uses the same masked column, spanning a whole loop.
- **Sonic Cirrus** has discrete bars with gaps, so it snaps to a bar index and recolors that bar's two layers. A fixed-width column could land in a gap.
- **Progress** grows the pill while hovered, and a hairline column inside it tracks the x.

**Over the unplayed side the column is lit in the theme's `hoverColor`. Over the played side it shows the unplayed side.** A lit column barely differs from Mono's translucent played color. It does not differ at all from Album Art's opaque one. Detailed, Bars, Cupertino, Wiggle and Progress hide the lit column there and cut a hole in the played layer (`VibePlaceHoverColumn`). Sonic Cirrus paints the bar in its unplayed colors. Under a playhead line the whole waveform is played. There the column always shows the unplayed side. `updateProgress:` re-places the column, because the playhead can cross a still cursor. 3-Band and Spectrum light the column on both sides. Their played side is the bands, not the theme's played color.

**Sonic Cirrus paints every bar through `colorForBar:top:`, and that method knows the hovered bar.** A repaint that skipped it would erase the highlight when the playhead crosses the hovered bar, or after `updateColors:`. Renderers keep the x so a resize can re-place the highlight.

**Hover and click-to-seek are gated on having a waveform.** That is how the empty, loading and parked states opt out. Every presentation reset (`resetWaveformContentState`) also clears a press or drag in flight, so a mouse-up cannot seek after the track changed.

## Pushed settings

**The view reads no store.** `MainPlayerController.applyWaveformSettings` pushes everything it draws from: the theme's bar density, bar width and Centered, Normalize and gain, `dragSeeks`, and last the style. The style's set is the one draw, so the bars ease to a new level mapping under a slider drag. Launch and the WaveformStyle, WaveformLevels and WaveformDrag effects all run it. The theme is resolved through `themeProvider`, a block the shell installs once (`../AGENTS.md`). A view with none draws Mono.

## Drag behavior

`dragSeeks` decides what a drag that starts on the waveform does. The shell pushes it from `AppSettings.waveformDragBehavior`. The view stashes it once per mouse-down, so a push cannot change a drag mid-flight.

**TRAP: `mouseDownCanMoveWindow` is a constant NO.** AppKit caches the answer in the window's movable region when the view joins the window. An answer derived from the setting or the loaded state goes stale, and seek mode then scrubbed while the window moved. Moving the window is per gesture, through `performWindowDragWithEvent:`.

- **Off** (`drag_window`, the default): a stationary click seeks. A drag past the 4pt hysteresis (`kWaveformDragHysteresis`) disarms the press and hands the gesture to `performWindowDragWithEvent:`. `mouseUp:` also bails when the window origin or the cursor moved, for a release that still arrives after the handoff.
- **On** (`seek`): the window stays put and the drag scrubs. Past the hysteresis the column under the cursor shows through `setHoverHighlightX:`, clamped to the bounds, while real progress keeps painting. The audio seeks once on release, to the clamped fraction. The release skips the containment test, since the drag may end outside the view.

With no waveform, or outside the renderer's seek hit band, `mouseDown:` hands the event to `performWindowDragWithEvent:` at once in every mode. So the empty and loading states and the view's margins always drag the window.

A locked window (`Mac/MainWindow/AGENTS.md`) declines every handoff. Under `drag_window` a drag past the hysteresis then does nothing, since the press is already disarmed. A stationary click still seeks.

## The convert sweep

`convertSweepFraction` keeps the front and dips only the span since the last set, so bars behind the front are never re-zeroed while they recover. A value at or below the front only moves the front, which is the post-conversion reset. It is gated on having a waveform and resets with every presentation reset. The mechanism is `../Renderers/AGENTS.md`'s.
