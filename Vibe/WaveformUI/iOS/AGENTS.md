# The waveform scrubber (iOS only)

`WaveformScrubberView` is the shared renderers on UIKit, DJ-style. **The play position is fixed at the view's horizontal center, and the waveform scrolls beneath it.**

The renderer draws the whole track across a *virtual* width: the view width divided by `visibleFraction` (0.48 at rest). **A `UIScrollView` carries it.** The virtual width is the content size, and the insets are half a view on each side. So `contentOffset.x == progress·virtualWidth - centerX`, and both ends of the track park under the center. UIKit supplies the drag, the deceleration and the rubber-band at both ends. `decelerationRate` is `Fast`.

The view is split like the mac's. `WaveformScrubberView.mm` is the core: the scroll, the zoom, the renderer and theme, the window it draws, progress, accessibility, `cancelInteraction`, `resetWaveformContentState`, layout, and showing a waveform. `+Loading.mm` is the loading indicator. `+Gestures.mm` is the touch scrub, the tap and the pinch. `WaveformScrubberViewInternal.h` is the private surface they share. It holds the ivars and the cross-file methods. It is ObjC++ only, because it imports `WaveformRenderer.h`.

## Zoom

**`visibleFraction` is the user's request, not what is drawn.** A pinch drives it. `effectiveVisibleFraction` is a computed accessor that clamps it to the deepest zoom the waveform can draw. `virtualWidth` reads the effective value, so the content size, the offset mapping and the buckets are all clamped without knowing it.

**The floor is derived, not a constant** (`WaveformUI/WaveformZoomMath.h`). Each style answers its own (`minimumFramesPerPointForWaveform:`, `Renderers/AGENTS.md`). A style that reads the summary alone stops at two bins a point, since finer the summary has nothing more to draw. The bar styles stop sooner, where their bars stop growing in number. The floor is also no wider than float geometry keeps sharp. So it moves with the track, the style and the view's width. Clamping the stored value there would shallow the user's zoom for good on one short track. **Persist the request, never the effective value.** The pager stores one zoom for every page in `VibeiOSWaveformZoom` (`Vibe/iOS/Player/AGENTS.md`).

**A pinch frame draws again.** The step styles read fixed columns at zoom steps (`Renderers/AGENTS.md`), so a frame inside a step only resamples them, and every frame stays sharp. A pinch frame draws no margin, since the next frame draws again. The gesture's end draws the margins back.

**A complete waveform zooms past its bins on the stream's own frames** in the Detailed types, down to eight points a frame (`kVibeWaveformMinimumDetailFramesPerPoint`). The width cap stops a 4:40 song near 12 frames a point, and a loop reaches its samples, drawn as the line through them. A draw that finds detail blocks missing leaves them in the waveform's detail. After the draw the view takes them and asks its delegate for them, one request at a time (`needsDetailBlocks:`). The pager reads them through its cache, for the page bound to playback only, and the view refills as they land. Until then the bins draw. A block that cannot be read is asked for again only by a later draw that lacks it, so a file gone from disk cannot loop. A neighbor page is refused, and asks again when it next draws as the current page. A streaming waveform keeps the bins' floor.


The fraction is written live, so the content size and end stops are honest on every frame. `UIScrollView`'s own `zoomScale` is the wrong shape. It scales both axes and anchors on the pinch centroid, but the playhead must stay at center.

**TRAP: park the content offset unconditionally on every pinch frame** (`parkContentOffsetAtProgress`). `syncContentOffsetToProgress` declines while `isScrubbing`, and the pinch's own fingers keep the scroll's pan reporting `isTracking`. Without the park, the playhead drifts off center as the zoom changes.

### Pinch and scrub are one continuous gesture

A finger already scrubbing must be able to start a zoom. Lifting back to one finger must return to scrubbing without the hand leaving the glass. Four traps make that work.

**TRAP: the pinch needs `shouldRecognizeSimultaneouslyWithGestureRecognizer:`, or it cannot start during a scrub.** By the time a second finger lands, the scroll's pan has recognized. By default one gesture belongs to one recognizer, so the pinch is refused.

**TRAP: `UIScrollView`'s pan cannot carry a gesture across a change in touch count.** It ends the instant a finger is added or lifted. An ended recognizer is never handed touches that were already down. `UIPinchGestureRecognizer` stays in `Changed` with one touch left. **So from its first frame the pinch owns the gesture to its end.** `trackZoomGestureScrub:` moves the track from the pinch's centroid only when exactly one touch remains. With two, the centroid is the zoom's anchor. It re-anchors on any touch-count change, or the 2-to-1 centroid jump lands as one huge scrub. The pan has no `maximumNumberOfTouches` cap on purpose, because a cap only makes it die sooner.

**TRAP: the dying pan must not finish anything.** Its `endScrub` arrives mid-gesture. Left alone, it would seek to where the finger was when the second one lifted and release the pager under a live drag. `endScrub` declines while `_isPinching`. `endZoomGesture` settles the seek, the haptics and the pager hold when the hand leaves. It also stops the pan's coast before clearing `_isPinching`. Otherwise `scrollViewDidScroll:` reads a position out of the coast that no seek follows.

**TRAP: a pure zoom is not a scrub. It must neither freeze the position nor seek.** Two fingers landing start the scroll's pan too, so nearly every pinch sets `_seekPending`. Counting the whole pinch as a scrub froze the picture while the audio played on. The lift then seeked back to the frozen spot, an audible skip. So a pinch scrubs only once it has a seek to commit. `beginZoomGesture` drops a pan scrub that moved less than `kZoomScrubSlop` from `_scrubStartProgress`. `scrollViewWillBeginDragging:` ignores a pan that starts under a live pinch. The one-finger phase needs the same slop before it scrubs, because the finger left behind always wobbles. Until then `isScrubbing` is NO, and playback keeps writing the position.

## Layers and the playhead

**Everything that scrolls is a sublayer of the scroll's layer. Everything that does not is a sublayer of the view's.** The loading indicator must not move with the content. The renderer's tree is in the scroll's layer, at virtual size.

The played and unplayed boundary is the playhead marker. It stays at center **by construction**. The played clip spans content x `0..progress·virtualWidth`, the same space the scroll translates.

**The playhead line replaces that boundary at no per-frame cost.** With a `playheadColor` on the resolved theme (`../AGENTS.md`), the played side spans the whole track (`playedProgress`). The line is one layer of the view's own at its center. So no progress write or zoom frame touches it, and it holds still through a bounce. The choice is part of `themeSignature`, so `syncWaveformTheme` applies a flip of the switch.

**The off-track space is empty on purpose.** A hairline continuing the midline past the content's ends reads as a stray line across the card near the start of a track.

**The loading track obeys the same rule.** `loadingTrackBounds` spans only the part of the view the content occupies, clipped to the view. A page swiped onto is at progress 0, so drawn full-width it would put half of itself in the empty space. Showing the indicator on an empty view resets its progress to 0, and the shell's next tick restores the real position.

**TRAP: keep the "did the span actually move" test in `syncLoadingTrackToProgress`.** It is the one relayout that can land mid-download. A duration-0 relayout snaps an easing fill to its target. While the provider materializes the file, progress is parked, so the test declines.

The renderer tree hangs off a `geometryFlipped` sublayer that gives the shared math the mac's y-up space. **Do not "fix" coordinates in shared renderer code for iOS.**

## Loading and interaction state

**`cancelInteraction` ends a drag or pinch without seeking or discarding pixels.** A cursor change calls it for held scrubbers, and cell reuse calls it through the content reset. It drops the pending seek before disabling the recognizers, since cancellation can send their end callbacks. A pinch still active afterward is ended through `endZoomGesture`, so the shared zoom update still happens.

**Showing a loading indicator keeps an existing waveform.** Cell reuse clears the previous track explicitly. Starting playback on a prepared page must keep its pixels. A positive transfer update creates the indicator if needed. The shell's `playbackLoading` keeps the shimmer through a slow open, including one with no transfer. Settlement or a cursor change clears it.

**Outside a pending playback open, the first waveform shown ends the shimmer but not the fill.** A disk-cached waveform can land while the provider is still downloading the audio. Then the fill over the drawn waveform is the only sign of the download. That is `endSweepKeepingFill`, whose answer says whether anything is left to keep. This scrubber is its only caller.

## Style and theme

The style comes from `AppSettings.waveformStyle` through the registry's fallback chain, as on the mac. The settings screen writes it (`Vibe/iOS/Settings/AGENTS.md`). `syncWaveformStyle` is the live swap. It rebuilds only when the resolved style differs from the current renderer's, since the pager calls it on every cell and on each `willDisplayCell:`. The new style lands settled, in the same turn.

Normalize and Gain are mac settings (`AppSettings+Mac.h`). This scrubber sets `normalizesLevels` on at renderer creation and never reads a level setting.

**`syncWaveformTheme` compares against `themeSignature`, which is an instance method.** `album_art` draws from `artworkThemeColor`, which is **per view, because each page is a different track**. `TrackPageCell` sets it as it installs the page's art, so the color rides the artwork install path (root `AGENTS.md`). The setter re-resolves through `syncWaveformTheme` itself, and an unchanged signature costs nothing. **The color is in the signature only under `album_art`.** Left out there, a swipe onto a track with different art would compare equal and keep the previous palette. Under every other theme it is left out on purpose, so late art recolors nothing.

## The live renderer

**The scrubber shows the renderer's own tree**, as the mac view does. Its pictures are layer contents (`Renderers/AGENTS.md`, Pictures), so scrolling moves textures and the render server scan-converts nothing. A track change discards the renderer, so the next waveform grows out of the midline rather than morphing from the last track's.

**The renderer draws only a window around what the view shows** (`drawRendererWindowForcing:`, the renderer's `renderRect`). It is the visible stretch and half a view either side. A scroll redraws once the visible stretch leaves the window. That redraw leads the scroll: it reaches a whole view ahead and a quarter behind. So playback redraws after a whole view of travel, not half of one, and draws 2.25 views for each view it travels rather than 4. A 3-Band or Spectrum redraw copies the stretch it already drew and draws only the rest (`Renderers/AGENTS.md`, Pictures). A resize, a zoom and a new waveform redraw at once. A step style draws the same pixels for the same content wherever its window lands, so a redraw cannot be seen. The content can be far wider than any texture, and it is never drawn whole.

**TRAP: no explicit `CATransaction` on the progress or window path.** On the display link's tick an explicit transaction is top-level and commits the whole tree a second time. `applyPlayedClip` and the window's redraw disable actions on the implicit transaction instead, which nests the renderers' own transactions inside it.

**Each delivery eases in through the morph engine, as on the mac.** The first grows from the midline. A streaming load's newly decoded stretch rises, since undecoded bins read as silence. The complete waveform eases to Normalize's heights. A page hydrated with `animated:NO` lands settled, so a swipe onto a cached page shows it at once. A page handed the complete waveform it already shows does nothing.

The debug channel's `dump_state` reports `ui.waveformShown`, which is whether a waveform is drawn.

## Scrubbing

A drag moves the content 1:1 under the fixed center, with no hover highlight. A tap nudges to the tapped point within the visible window, which also keeps tap-to-start on a parked track. `isScrubbing` is the scroll's `isDragging || isDecelerating || isTracking`, or under a pinch whether it has a seek to commit. So it spans the whole content motion, coast and bounce included, and keeps the progress writers off. A tap mid-coast stops the scroll and sends the scrub-end callback itself. Cancelling deceleration does not guarantee `scrollViewDidEndDecelerating:`, and without the callback the pager stays disabled.

**The time labels show where the scrub will land, not what is playing.** The playhead never moves, so the labels are the only reading of a scrub's target. `didScrubToProgress:` delivers it per frame, and the shell renders it (`Vibe/iOS/Player/AGENTS.md`). The shell's `updatePlaybackUI` and `scrollTick:` bail while `isScrubbing`.

**TRAP: a scrub seeks only when its gesture ends**, in `endScrub`, or in `endZoomGesture` for a pinch-carried scrub. A seek to 1.0 mid-gesture finishes the track and auto-advances with the finger still down. `UIScrollView` also reports `isDecelerating` during a drag, so no "still moving" test separates a coast from a finger.

**TRAP: a `UIScrollView` owns its pan's delegate and raises on assignment.** So the "no waveform, nothing to scrub" gate rides `scrollEnabled`, set from `setWaveform:`, not `gestureRecognizerShouldBegin:`. The gate is needed because the pager requires the scrubber's pan to fail. A pan that always begins never fails, which turns an empty strip into a dead zone where the page will not swipe. A disabled scroll's pan counts as failed.

**TRAP: that failure requirement is not enough at a content edge.** When the scroll sits *exactly* at an edge, UIKit's nested-scroll arbitration stops its pan from beginning so an ancestor can have the gesture. The pager then inherits the drag, and pushing against an end turns the page instead of bouncing. Arriving at an edge mid-drag is fine. Only *starting* parked at an end fails. `TrackPagerView` (`Vibe/iOS/Player/PlayerViewController.m`) closes the gap by declining its own pan for touches that hit-test into a loaded `WaveformScrubberView`. Both halves are needed. `scrollEnabled` says whether the scrubber wants the drag, and the pager's override stops it being taken away.

**TRAP: the pager must be held still for the length of a scrub, not merely out-gestured.** UIKit chains an inner scroll view's overscroll into an enclosing one, decided from geometry rather than from which recognizer won. So while the pager could still scroll the way the finger goes, the scrubber clamps at its end instead of bouncing. `didChangeScrubbing:` exists for this. The shell holds the pager for the scrub's duration (`Vibe/iOS/Player/AGENTS.md`). **It must be released on every path out, including a track change mid-scrub**, or the pager stays locked.

**TRAP: on reset, park the content offset unconditionally.** Cancelling the scroll does not clear `isDragging` until the touch is delivered. The progress write can then skip its park and leave a recycled cell at the previous track's position.

**TRAP: clamp before the cast in `progressBucket`.** `setProgress:` stores what the timer writers hand it, which can land a hair outside the unit range at track end. Converting a negative or overlarge double to `NSUInteger` is undefined.
