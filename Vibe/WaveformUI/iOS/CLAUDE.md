# The waveform scrubber (iOS only)

`WaveformScrubberView` is the shared renderers on UIKit, DJ-style: **the play position is fixed at the view's horizontal center and the waveform scrolls beneath it.**

The renderer is told the host layer's *virtual* bounds — view width / `visibleFraction` (0.48 at rest, so a bit over 2x the view) — so it draws the whole track zoomed, and **a `UIScrollView` carries it**: that virtual width is the content size and the insets are half a view on each side, so `contentOffset.x == progress·virtualWidth - centerX` and both ends of the track park under the center. UIKit then supplies the drag, the deceleration and the rubber-band give at both ends, so there is no hand-rolled momentum. `decelerationRate` is `Fast` — this is a scrubber, not a document.

## Zoom

`visibleFraction` is a property, driven by a pinch, and **it is the user's request rather than what is drawn.** `effectiveVisibleFraction` — a computed accessor, not second state — clamps it against what this geometry's settled bitmap can hold, and `virtualWidth` reads that one, so the content size, the offset/progress mapping, the buckets and the bake are all clamped without any of them knowing about the clamp.

**The floor is derived, not a constant** (`WaveformUI/WaveformZoomMath.h`): the deepest zoom whose bake fits both the GPU texture ceiling and a per-bake byte budget, which works out to about 10% of the track on iPhone portrait and 15–17% on wider or shorter layouts. The budget is what makes the worst case *chosen* — the texture ceiling alone would allow 35MB a bake, and three pager cells hold one each.

The split exists because that floor moves under the value: a rotation to a shorter, wider layout raises it, and clamping the stored value there would shallow the user's zoom permanently, persisted copy included. Keeping the request intact means the picture shallows while the layout demands it and comes straight back. **Persist the request, never the effective one** — the key is `VibeiOSWaveformZoom`, written by the pager (`Vibe/iOS/CLAUDE.md`), because one zoom is shared across every page.

**A live pinch frame stretches the baked bitmap; it does not re-render.** `applyVirtualGeometry` — the scroll geometry, factored out of `layoutSubviews` so the zoom can call it too — resizes `_bakedHost` and `_bakedUnplayed` and lets resize gravity do the scaling, so a frame costs three property writes instead of a 4,096-rect mask rebuild over a multi-screen layer. The picture goes slightly soft until the re-bake on release, which is invisible against a moving one. **Only during a pinch**: every other resize keeps the teardown-and-redraw, so rotation is unchanged.

The fraction is written **live** rather than accumulated into a transform and committed, which is why there is no second scale factor anywhere — the scroll view's content size and end stops stay honest on every frame. `UIScrollView`'s own `zoomScale` was the obvious alternative and is the wrong shape: it scales both axes and anchors on the pinch centroid, where this design's guarantee is the playhead at center.

**TRAP: park the content offset unconditionally on every pinch frame.** `syncContentOffsetToProgress` declines while `isScrubbing`, and the pinch's own fingers keep the scroll's pan reporting `isTracking` — the same reason `resetWaveformContentState` parks unconditionally. Without it the playhead drifts off center as the zoom changes.

**TRAP: `installEnvelopeImage:` must drop an existing baked host first.** Every bake used to be preceded by a teardown, so it could assume nil; the stretch path deliberately leaves one standing.

### Pinch and scrub are one continuous gesture

A finger already scrubbing must be able to start a zoom, and lifting back to one finger must return to scrubbing — without the hand leaving the glass. Three things make that work, and each of them is a trap in the obvious direction:

**TRAP: the pinch needs `shouldRecognizeSimultaneouslyWithGestureRecognizer:` or it cannot start during a scrub at all.** By the time a second finger lands the scroll's pan has recognized, and UIKit gives one gesture to one recognizer — so the pinch is simply refused and the second finger does nothing.

**TRAP: `UIScrollView`'s pan cannot carry a gesture across a change in touch count.** It ends the instant a finger is added or lifted, and an ended recognizer is never handed touches that were already down — so it cannot come back for the finger still on the glass. `UIPinchGestureRecognizer` does the opposite: it stays in `Changed` with one touch left. Measured on device, lifting the second finger killed the pan and left 148 frames of one-touch pinch with nothing driving the position.

**So from the pinch's first frame, the pinch owns the gesture to its end.** `trackZoomGestureScrub:` moves the track from the pinch's own centroid, and only when exactly **one** touch remains — with two, that centroid is the zoom's anchor, so the position holds still while zooming. It re-anchors on any touch-count change, or the 2→1 jump in the centroid lands as one enormous scrub. Capping the pan at `maximumNumberOfTouches = 1` looks like the way to stop a second finger scrubbing and only makes it die sooner; the cap is deliberately absent.

**TRAP: the dying pan must not be allowed to finish anything.** Its `endScrub` arrives mid-gesture, and left alone it commits a seek to wherever the finger was when the second one lifted and hands the pager back under a live drag. `endScrub` declines outright while `_isPinching`; the seek, the haptics and the pager hold are all settled by `endZoomGesture` when the hand actually leaves.

`isScrubbing` therefore includes a live pinch — without it the 3 Hz tick and the display link write playback's position over the finger's once the pan is gone.

**Everything that scrolls is a sublayer of the scroll's layer, and everything that does not is a sublayer of the view's** — the loading indicator and the empty placeholder must not move with the content.

The played/unplayed gradient boundary is the only playhead marker (no line), and it stays pinned at center **by construction** rather than by synchronization: the played clip spans content x `0..progress·virtualWidth`, the same space the scroll translates.

**The off-track space is empty, deliberately.** It used to carry two hairline segments continuing the waveform's midline past the content's ends, colored to match it and glued to its edges so they rode the scroll and the bounce for free. They read as a stray line across the card near the start of a track — which is most of what the eye catches — so they are gone, along with the renderer's `baselineAlphaForPlayed:` that existed only to color them. The empty state's placeholder and the loading track are a different element and still draw (`WaveformMidline.h`).

The renderer tree hangs off a `geometryFlipped` sublayer giving the shared math the mac's y-up space. **Do not "fix" coordinates in shared renderer code for iOS.**

Style is hard-wired to the app default (`SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT`) until a style picker exists.

## The settled fast path

The live renderer tree is only the *morph* surface: per-frame scrolling against its full-width shape mask means a full offscreen re-composite of the multi-screen layer. So once a load's morph settles, the scrubber bakes the envelope into one bitmap (`DetailedAudioWaveformRenderer`'s envelope-image API) and swaps in two image layers — unplayed full-width, played stacked on top and cropped by `contentsRect` — making a scroll or scrub frame pure texture translation.

Any reset, delivery, or geometry/trait change tears the fast path down and re-bakes after settle. `showWaveform:animated:NO` takes `settleMorphImmediately` and bakes on the next turn of the main queue instead of 0.6s after the last delivery; `prepareForWaveformLoad`'s collapse to the midline takes the same path, since here every reset is a recycled pager cell being emptied off-screen. Otherwise a page arriving mid-swipe spends the whole swipe on the live tree at 60 Hz, rebuilding a 4,096-rect mask path per frame — which is what the pager's own scroll hold exists to keep off the frame budget (`Vibe/iOS/CLAUDE.md`).

`dump_state`'s `ui.waveformBaked` is how to check it stayed baked.

## Scrubbing

A drag moves the content 1:1 under the fixed center (no hover highlight); a tap nudges to the tapped point within the visible window, which also preserves tap-to-start on a parked track. `isScrubbing` is the scroll's own `isDragging || isDecelerating || isTracking`, so it spans the whole content motion — coast and bounce included — and keeps the progress writers from fighting it. A tap mid-coast stops the scroll first, or the deceleration would settle later and commit a second seek over the tap's.

**The time labels show where the scrub will land, not what is playing.** The playhead is pinned at center and never moves, so the labels are the only reading of a scrub's target; `didScrubToProgress:` delivers it per frame of scroll and the shell renders it (`Vibe/iOS/CLAUDE.md`). For its duration the scrub owns the whole readout — `updatePlaybackUI` bails on `isScrubbing`, the same as `scrollTick:` one tier down.

**TRAP: `endScrub` is the ONLY place a scrub seeks.** Committing earlier — on reaching an end mid-gesture — reads as correct and is not: a seek to 1.0 lands the player on the track's end, which finishes it and auto-advances, so pushing against the end skipped to the next track with the finger still down. `UIScrollView` also reports `isDecelerating` *during* a drag, so there is no "still moving" test that separates a coast from a finger.

**TRAP: a `UIScrollView` owns its pan's delegate and raises on assignment**, so the "no waveform, nothing to scrub" gate rides `scrollEnabled` (set from `setWaveform:`) rather than `gestureRecognizerShouldBegin:`. It has to exist at all because the pager makes its own pan require the scrubber's to fail: a pan that always begins satisfies that requirement forever and turns an empty strip into a dead zone where the page will not swipe. A disabled scroll's pan counts as failed, which is exactly what that wants.

**TRAP: that failure requirement is not enough on its own, and the gap only opens at an end.** When the scrubber's scroll sits *exactly* at a content edge, UIKit's nested-scroll arbitration stops its pan from beginning at all so an ancestor scroll view can have the gesture — so the requirement is satisfied, the pager inherits the drag, and pushing against an end turns the page instead of bouncing (or, on a one-track playlist, does nothing). Arriving at an edge mid-drag is fine, because the pan has already begun; only *starting* parked at an end fails, which is why it survives casual testing. `VibeTrackPagerView` (`Vibe/iOS/PlayerViewController.m`) closes it by declining its own pan for touches that hit-test into a `WaveformScrubberView`. Both halves are needed: `scrollEnabled` decides whether the scrubber *wants* the drag, the pager's override stops it being taken away.

**TRAP: the pager has to be held STILL for the length of a scrub, not merely out-gestured.** UIKit chains an inner scroll view's overscroll into an enclosing one, and that chaining is decided from geometry rather than from which recognizer won — so while the pager could still scroll the way the finger is going, the scrubber *clamps* at its end instead of bouncing, even though the pager already declined the gesture and never moves. It presents as an end that bounces on the last page and hard-stops on every other. `didChangeScrubbing:` (the delegate's second method) exists solely for this: the shell sets `_pagesView.scrollEnabled = NO` for the duration. **It must be released on every path out, including a track change mid-scrub**, or the pager stays locked and the app stops swiping.

**TRAP: on reset, park the content offset unconditionally.** Cancelling the scroll does not clear `isDragging` until the touch is delivered, so the progress write can skip its park and leave a recycled cell scrolled to the previous track's position.

**TRAP: clamp before the cast in `progressBucket`, not after.** `setProgress:` stores what the timer writers hand it, which can land a hair outside the unit range at track end, and converting a negative or overlarge double to `NSUInteger` is undefined rather than merely wrong.
