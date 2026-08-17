# The waveform scrubber (iOS only)

`WaveformScrubberView` is the shared renderers on UIKit, DJ-style: **the play position is fixed at the view's horizontal center and the waveform scrolls beneath it.**

The renderer is told the host layer's *virtual* bounds — view width / `kWaveformVisibleFraction` (0.48, so a bit over 2x the view) — so it draws the whole track zoomed, and **a `UIScrollView` carries it**: that virtual width is the content size and the insets are half a view on each side, so `contentOffset.x == progress·virtualWidth - centerX` and both ends of the track park under the center. UIKit then supplies the drag, the deceleration and the rubber-band give at both ends, so there is no hand-rolled momentum. `decelerationRate` is `Fast` — this is a scrubber, not a document.

**Everything that scrolls is a sublayer of the scroll's layer, and everything that does not is a sublayer of the view's** — the loading indicator and the empty placeholder must not move with the content.

The played/unplayed gradient boundary is the only playhead marker (no line), and it stays pinned at center **by construction** rather than by synchronization: the played clip spans content x `0..progress·virtualWidth`, the same space the scroll translates. The two hairline baseline segments covering the off-track space are likewise fixed-size and glued to the content's edges — they ride the scroll and the bounce for free — and are colored via `DetailedAudioWaveformRenderer.baselineAlphaForPlayed:` so they continue the waveform's own silence hairline seamlessly. `kBaselineOverhangWidths` keeps them reaching the view's edge at full bounce.

The renderer tree hangs off a `geometryFlipped` sublayer giving the shared math the mac's y-up space. **Do not "fix" coordinates in shared renderer code for iOS.**

Style is hard-wired to the app default (`SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT`) until a style picker exists.

## The settled fast path

The live renderer tree is only the *morph* surface: per-frame scrolling against its full-width shape mask means a full offscreen re-composite of the multi-screen layer. So once a load's morph settles, the scrubber bakes the envelope into one bitmap (`DetailedAudioWaveformRenderer`'s envelope-image API) and swaps in two image layers — unplayed full-width, played stacked on top and cropped by `contentsRect` — making a scroll or scrub frame pure texture translation.

Any reset, delivery, or geometry/trait change tears the fast path down and re-bakes after settle. `showWaveform:animated:NO` takes `settleMorphImmediately` and bakes on the next turn of the main queue instead of 0.6s after the last delivery; `prepareForWaveformLoad`'s collapse to the midline takes the same path, since here every reset is a recycled pager cell being emptied off-screen. Otherwise a page arriving mid-swipe spends the whole swipe on the live tree at 60 Hz, rebuilding a 4,096-rect mask path per frame — which is what the pager's own scroll hold exists to keep off the frame budget (`Vibe/iOS/CLAUDE.md`).

`dump_state`'s `ui.waveformBaked` is how to check it stayed baked.

## Scrubbing

A drag moves the content 1:1 under the fixed center (no hover highlight); a tap nudges to the tapped point within the visible window, which also preserves tap-to-start on a parked track. `isScrubbing` is the scroll's own `isDragging || isDecelerating || isTracking`, so it spans the whole content motion — coast and bounce included — and keeps the progress writers from fighting it. A tap mid-coast stops the scroll first, or the deceleration would settle later and commit a second seek over the tap's.

**TRAP: `endScrub` is the ONLY place a scrub seeks.** Committing earlier — on reaching an end mid-gesture — reads as correct and is not: a seek to 1.0 lands the player on the track's end, which finishes it and auto-advances, so pushing against the end skipped to the next track with the finger still down. `UIScrollView` also reports `isDecelerating` *during* a drag, so there is no "still moving" test that separates a coast from a finger.

**TRAP: a `UIScrollView` owns its pan's delegate and raises on assignment**, so the "no waveform, nothing to scrub" gate rides `scrollEnabled` (set from `setWaveform:`) rather than `gestureRecognizerShouldBegin:`. It has to exist at all because the pager makes its own pan require the scrubber's to fail: a pan that always begins satisfies that requirement forever and turns an empty strip into a dead zone where the page will not swipe. A disabled scroll's pan counts as failed, which is exactly what that wants.

**TRAP: that failure requirement is not enough on its own, and the gap only opens at an end.** When the scrubber's scroll sits *exactly* at a content edge, UIKit's nested-scroll arbitration stops its pan from beginning at all so an ancestor scroll view can have the gesture — so the requirement is satisfied, the pager inherits the drag, and pushing against an end turns the page instead of bouncing (or, on a one-track playlist, does nothing). Arriving at an edge mid-drag is fine, because the pan has already begun; only *starting* parked at an end fails, which is why it survives casual testing. `VibeTrackPagerView` (`Vibe/iOS/PlayerViewController.m`) closes it by declining its own pan for touches that hit-test into a `WaveformScrubberView`. Both halves are needed: `scrollEnabled` decides whether the scrubber *wants* the drag, the pager's override stops it being taken away.

**TRAP: the pager has to be held STILL for the length of a scrub, not merely out-gestured.** UIKit chains an inner scroll view's overscroll into an enclosing one, and that chaining is decided from geometry rather than from which recognizer won — so while the pager could still scroll the way the finger is going, the scrubber *clamps* at its end instead of bouncing, even though the pager already declined the gesture and never moves. It presents as an end that bounces on the last page and hard-stops on every other. `didChangeScrubbing:` (the delegate's second method) exists solely for this: the shell sets `_pagesView.scrollEnabled = NO` for the duration. **It must be released on every path out, including a track change mid-scrub**, or the pager stays locked and the app stops swiping.

**TRAP: on reset, park the content offset unconditionally.** Cancelling the scroll does not clear `isDragging` until the touch is delivered, so the progress write can skip its park and leave a recycled cell scrolled to the previous track's position.

**TRAP: clamp before the cast in `progressBucket`, not after.** `setProgress:` stores what the timer writers hand it, which can land a hair outside the unit range at track end, and converting a negative or overlarge double to `NSUInteger` is undefined rather than merely wrong.
