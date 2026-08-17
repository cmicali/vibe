# The waveform view (macOS only)

`AudioWaveformView` is a CALayer-based `NSView` that delegates drawing to the shared renderer strategies one directory up. **It is a pure rendering surface**: `MainPlayerController` owns the `AudioWaveformCache`, symmetrically with `metadataCache`, requests loads and forwards deliveries to the view through `TrackDisplayController`'s pass-throughs — `prepareForWaveformLoad` to reset, then `showWaveform:`.

`AudioWaveformView+Loading` holds the two non-waveform states, and `AudioWaveformViewInternal.h` is the private surface they share.

## The three states

- **Waveform** — the renderer's layer tree.
- **Loading** — `showLoadingIndicator`, while a slow file open is pending. The control itself is the shared `WaveformLoadingIndicator`.
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

The view gates on having a waveform at all, which is how the empty, loading and parked states opt out, and the state transitions that clear the waveform also clear the highlight. Click-to-seek is unaffected.

## The convert sweep

`convertSweepFraction` keeps the front and dips only the span since the last set, so bars behind the front are never re-zeroed mid-recovery. It gates on having a waveform, like hover, and resets in `prepareForWaveformLoad` and the empty and loading states. A value at or below the front just moves the front — that is the post-conversion reset. The mechanism is shared; see `WaveformUI/CLAUDE.md`.
