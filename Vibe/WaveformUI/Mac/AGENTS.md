# The waveform view (macOS only)

`AudioWaveformView` is a CALayer-based `NSView` that delegates drawing to the shared renderer strategies in `../Renderers/`. **It is a pure rendering surface**: `MainPlayerController` owns the `AudioWaveformCache`, symmetrically with `metadataCache`, requests loads and forwards deliveries to the view through `TrackDisplayController`'s pass-throughs — `prepareForWaveformLoad` to reset, then `showWaveform:`.

`AudioWaveformView+Loading` holds the two non-waveform states, and `AudioWaveformViewInternal.h` is the private surface they share.

## The three states

- **Waveform** — the renderer's layer tree.
- **Loading** — `showLoadingIndicator`, once a file open crosses the player's 0.5s slow-open threshold. The control itself is the shared `LoadingIndicator` in its waveform style (`Controls/AGENTS.md`). Fast local and prefetched opens settle without showing it; until the threshold, the outgoing waveform may remain under the incoming track's title. A dataless file's open is slow from the start, so it shows at once (`AudioPlayer`'s `submitOpenOnQueueForTrack:`).
- **Empty** — `showEmptyPlaceholder`, a static midline for the no-track state, which is that same control at rest.

Loading and empty are mutually exclusive, and `prepareForWaveformLoad` clears both.

**Every delivery retargets the renderer's running morph immediately**, including completion. The shared `WaveformMorphEngine` eases from the currently displayed bars at 60 Hz, so a newer snapshot bends the ongoing motion rather than snapping it to the previous target. The loader already limits partial snapshots to about 10 Hz; the view adds no display interval, bitmap reveal or forced settle. Normalize's completing raise uses the same morph.

**TRAP: feed every delivery directly into the running morph.** Holding the first leaves an empty strip after a skip as the outgoing bars collapse; settling partials breaks the continuous ease. This is the Mac presentation path; the iOS scrubber keeps its own pacing and bitmap reveal.

## Progress

`setProgress:` repaints only on **device-pixel crossings**, using the view's `devicePixelWidth`. That self-gating is what makes the window's scaled UI tick rate affordable — see `Mac/MainWindow/AGENTS.md` on `VibeUIUpdateHzForPlayhead`. `devicePixelWidth` is also an input to that rule, so a resize resyncs it.

**Under a theme's playhead line the renderer is told 1 and the line carries the position** (`playedProgress`, `layoutPlayheadLine`; the rule is `../AGENTS.md`'s). The line is one layer of the view's own, above the renderer's tree whatever style built it last, moved on the same pixel crossings and clamped inside the bounds so it shows at both ends of the track. It is hidden with nothing loaded, as hover and seek are off.

## Hover scrubbing

While the cursor is over a loaded waveform, the waveform's own column under the cursor is lit to full brightness. Nothing is drawn on top of it, and there is no tooltip.

The view only routes the cursor's x to the renderer, through `setHoverHighlightX:`, where a negative value clears the highlight — **because the two renderer families need opposite mechanisms**:

- The **Detailed** family adds a flat full-alpha column layer inside `_waveformContainer`, so the shared bar mask clips it to the envelope for free. It is a couple of points wide, since one bar is sub-point at 1024 bars or more.
- **Wiggle** uses the same masked column but span a complete loop, including its curved ends, so the highlight does not flicker into dots between the vertical strokes. Played progress and seeks stay continuous.
- **Sonic Cirrus**, whose bars are discrete layers with gaps, snaps to a bar index and recolors that bar's two layers instead — a fixed-width column there could land in a gap and light nothing.
- **Cupertino Basic** has no bars to light: the pill grows while hovered — Apple Music's own affordance — and a hairline column inside the capsule tracks the x.

Sonic Cirrus must restore the bar's *resting* played or unplayed color when the hover moves off, and **re-apply the highlight after `updateProgress:` repaints a range covering it**. Otherwise the playhead crossing the hovered bar, or a full repaint after `updateColors:`, erases it. Renderers keep the x so a resize can re-place the highlight.

The view gates both hover and click-to-seek on having a waveform at all, which
is how the empty, loading and parked states opt out. Every presentation reset
also clears a press in flight, so a mouse-up cannot seek after the track
changed underneath it.

## Drag behavior

`AppSettings.waveformDragBehavior` decides what a drag starting on the
waveform does; the view reads it once per mouse-down into the gesture's state,
so a settings write cannot change a drag's meaning mid-flight.

**TRAP: `mouseDownCanMoveWindow` is a constant NO.** AppKit caches the answer
in the window's movable region when the view joins the window, so one derived
from the setting or the loaded state goes stale — seek mode then scrubbed
while the window moved. Moving the window is per gesture, via
`performWindowDragWithEvent:`.

- **`drag_window`** (the default): a stationary click seeks; a drag past the
  ~4pt hysteresis disarms the press and hands the rest of the gesture to
  `performWindowDragWithEvent:`, so the window moves from there. `mouseUp:`
  keeps the origin-and-local-motion bail as a backstop for a release that
  still arrives after the handoff.
- **`seek`**: the window stays put and the drag scrubs. Past the hysteresis
  the tracked column renders through the hover machinery
  (`setHoverHighlightX:`, clamped to the bounds), real progress keeps painting
  underneath, and the audio is seeked once on release to the clamped
  fraction — bypassing the stationary path's containment test, since the drag
  may legitimately end outside the view.

With no waveform, and below or above the renderer's seek hit band, `mouseDown:`
hands the event to `performWindowDragWithEvent:` immediately in every mode, so
the empty and loading states and the view's margins always drag the window. A
drag in flight is presentation state: `resetWaveformContentState` clears it
with the press, so a track change mid-drag makes the release a no-op.

A locked window (`Mac/MainWindow/AGENTS.md`) declines every handoff, so under
`drag_window` a drag past the hysteresis does nothing by design: the press is
already disarmed, so it neither seeks nor moves. A stationary click still seeks.

## The convert sweep

`convertSweepFraction` keeps the front and dips only the span since the last set, so bars behind the front are never re-zeroed mid-recovery. It gates on having a waveform, like hover, and resets in `prepareForWaveformLoad` and the empty and loading states. A value at or below the front just moves the front — that is the post-conversion reset. The mechanism is shared; see `WaveformUI/Renderers/AGENTS.md`.
