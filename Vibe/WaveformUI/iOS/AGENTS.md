# The waveform scrubber (iOS only)

`WaveformScrubberView` is the shared renderers on UIKit, DJ-style: **the play position is fixed at the view's horizontal center and the waveform scrolls beneath it.**

The renderer is told the host layer's *virtual* bounds — view width / `visibleFraction` (0.48 at rest, so a bit over 2x the view) — so it draws the whole track zoomed, and **a `UIScrollView` carries it**: that virtual width is the content size and the insets are half a view on each side, so `contentOffset.x == progress·virtualWidth - centerX` and both ends of the track park under the center. UIKit then supplies the drag, the deceleration and the rubber-band give at both ends, so there is no hand-rolled momentum. `decelerationRate` is `Fast` — this is a scrubber, not a document.

## Zoom

`visibleFraction` is a property, driven by a pinch, and **it is the user's request rather than what is drawn.** `effectiveVisibleFraction` — a computed accessor, not second state — clamps it against what this geometry's settled bitmap can hold, and `virtualWidth` reads that one, so the content size, the offset/progress mapping, the buckets and the bake are all clamped without any of them knowing about the clamp.

**The floor is derived, not a constant** (`WaveformUI/WaveformZoomMath.h`): the deepest zoom whose bake fits both the GPU texture ceiling and a per-bake byte budget, which works out to about 10% of the track on iPhone portrait and 15–17% on wider or shorter layouts. The budget is what makes the worst case *chosen* — the texture ceiling alone would allow 35MB a bake, and three pager cells hold one each.

The split exists because that floor moves under the value: a rotation to a shorter, wider layout raises it, and clamping the stored value there would shallow the user's zoom permanently, persisted copy included. Keeping the request intact means the picture shallows while the layout demands it and comes straight back. **Persist the request, never the effective one** — the key is `VibeiOSWaveformZoom`, written by the pager (`Vibe/iOS/Player/AGENTS.md`), because one zoom is shared across every page.

**A pinch frame stretches the bitmap; it does not re-render.** `applyVirtualGeometry` — the scroll geometry, factored out of `layoutSubviews` so the zoom can call it too — re-places the bitmap at the new virtual bounds (`placeBakedLayer:`) and lets resize gravity do the scaling, so a frame costs three property writes. The picture goes slightly soft until the re-bake on release, which is invisible against a moving one. Every other resize — a rotation, a split-screen change — stretches the same way and re-bakes at once.

**Wiggle and Wiggle MC keep the same loops throughout a zoom.** The scrubber supplies `samplingWidth` as the viewport width divided by the default zoom fraction; these two styles use it for their loop count while drawing across the zoomed virtual width. A pinch therefore stretches the existing samples, and release restores stroke sharpness without replacing the loops with a different count and energy envelope. An actual viewport resize can change the count; the finer bar styles continue sampling at their drawn width.

The fraction is written **live** rather than accumulated into a transform and committed, which is why there is no second scale factor anywhere — the scroll view's content size and end stops stay honest on every frame. `UIScrollView`'s own `zoomScale` was the obvious alternative and is the wrong shape: it scales both axes and anchors on the pinch centroid, where this design's guarantee is the playhead at center.

**TRAP: park the content offset unconditionally on every pinch frame.** `syncContentOffsetToProgress` declines while `isScrubbing`, and the pinch's own fingers keep the scroll's pan reporting `isTracking` — the same reason `resetWaveformContentState` parks unconditionally. Without it the playhead drifts off center as the zoom changes.

**TRAP: `installEnvelopeImage:` must drop the standing bitmap first.** Every install but the first replaces one; without the removal the old layer stays in the scroll's tree for the life of the view. The one a completing bake fades over goes when its fade ends, and the next install or a reset drops it if that never comes.

### Pinch and scrub are one continuous gesture

A finger already scrubbing must be able to start a zoom, and lifting back to one finger must return to scrubbing — without the hand leaving the glass. Three things make that work, and each of them is a trap in the obvious direction:

**TRAP: the pinch needs `shouldRecognizeSimultaneouslyWithGestureRecognizer:` or it cannot start during a scrub at all.** By the time a second finger lands the scroll's pan has recognized, and UIKit gives one gesture to one recognizer — so the pinch is simply refused and the second finger does nothing.

**TRAP: `UIScrollView`'s pan cannot carry a gesture across a change in touch count.** It ends the instant a finger is added or lifted, and an ended recognizer is never handed touches that were already down — so it cannot come back for the finger still on the glass. `UIPinchGestureRecognizer` does the opposite: it stays in `Changed` with one touch left.

**So from the pinch's first frame, the pinch owns the gesture to its end.** `trackZoomGestureScrub:` moves the track from the pinch's own centroid, and only when exactly **one** touch remains — with two, that centroid is the zoom's anchor, so the position holds still while zooming. It re-anchors on any touch-count change, or the 2→1 jump in the centroid lands as one enormous scrub. Capping the pan at `maximumNumberOfTouches = 1` looks like the way to stop a second finger scrubbing and only makes it die sooner; the cap is deliberately absent.

**TRAP: the dying pan must not be allowed to finish anything.** Its `endScrub` arrives mid-gesture, and left alone it commits a seek to wherever the finger was when the second one lifted and hands the pager back under a live drag. `endScrub` declines outright while `_isPinching`; the seek, the haptics and the pager hold are all settled by `endZoomGesture` when the hand actually leaves. Nor may its coast outlive the pinch: `endZoomGesture` stops it before clearing `_isPinching`, or `scrollViewDidScroll:` reads a position out of the coast that no seek follows.

`isScrubbing` therefore includes a pinch that is scrubbing — without it the 3 Hz tick and the display link write playback's position over the finger's once the pan is gone.

**TRAP: a pure zoom is not a scrub, and must neither freeze the position nor seek.** Two fingers landing start the scroll's pan too, so `_seekPending` is set by nearly every pinch; counting the whole pinch as a scrub froze the picture while the audio played on, and the lift then seeked back to the frozen spot — an audible skip by the length of the pinch. So a pinch scrubs only once it has a seek to commit: `beginZoomGesture` drops a pan scrub that moved less than `kZoomScrubSlop` from where it began (`_scrubStartProgress`), `scrollViewWillBeginDragging:` ignores a pan starting under a live pinch, and the one-finger phase needs the same slop before it scrubs, because the finger left behind as a pinch lifts always wobbles. Until then `isScrubbing` is NO and playback keeps writing the position under the zoom.

**Everything that scrolls is a sublayer of the scroll's layer, and everything that does not is a sublayer of the view's** — the loading indicator must not move with the content.

The played/unplayed gradient boundary is the playhead marker, and it stays pinned at center **by construction** rather than by synchronization: the played clip spans content x `0..progress·virtualWidth`, the same space the scroll translates.

**The playhead line replaces that boundary, and costs a frame nothing.** With a `playheadColor` on the resolved theme (`../AGENTS.md`) the played side spans the whole track (`playedProgress`), live tree and bake alike, and the line is one layer of the view's own at its center — a sublayer of `self.layer`, not the scroll's, since the play position is the center and it is the content that moves. So no progress write or zoom frame touches it, and it holds still through a bounce while the track's end pulls away from it. The choice is in `themeSignature`, so `syncWaveformTheme` applies a flip of the switch as it does a palette change.

**The off-track space is empty, deliberately.** Hairline segments continuing the waveform's midline past the content's ends read as a stray line across the card near the start of a track, which is most of what the eye catches.

**The loading track obeys the same rule**, and `loadingTrackBounds` is where: it spans the part of the view the *content* occupies — `[centerX - progress·virtualWidth, centerX + (1-progress)·virtualWidth]` clipped to the view — rather than the view's width, so a track at its start draws it from the center to the right edge and nothing to the left. A page swiped onto a neighbor is at progress 0, so drawn full-width it would put half of itself in that empty space on every swipe. It follows the playhead as well as the geometry, because `showLoadingIndicator` always runs against progress 0 — `resetWaveformContentState` puts it there — and the shell's next tick restores the real position under it.

**TRAP: keep the "did the span actually move" test in `syncLoadingTrackToProgress`.** It is the one relayout that can land mid-download, and a duration-0 relayout snaps an easing fill to its target; while the provider materializes the file progress is parked, so the test declines.

**The first bitmap landing ends the sweep but not the fill** (not the data arriving, or the strip would sit empty until it lands) — a disk-cached waveform can land while the provider is still materializing the audio, so the fill riding over the drawn waveform is the only remaining sign of the download. That is `endSweepKeepingFill`, whose answer tells the caller whether anything is left to keep. This scrubber is its only caller; the mac view only ever hides the indicator whole.

The renderer tree hangs off a `geometryFlipped` sublayer giving the shared math the mac's y-up space. **Do not "fix" coordinates in shared renderer code for iOS.**

Style comes from `AppSettings.waveformStyle` through the registry's fallback chain, exactly as the mac view's does; the settings screen (`Vibe/iOS/Settings/AGENTS.md`) writes it. `syncWaveformStyle` is the live swap — it compares against the style the current renderer was built from and rebuilds only on a difference, since the pager fans it out over every cell and re-applies it on each `willDisplayCell:`. A rebuild drops the renderer (which removes its own layers) and re-bakes at once; the outgoing style's bitmap stays up until the new one lands.

The level mapping is not a third sync: Normalize and Gain are macOS settings (`AppSettings+Mac.h`), and this scrubber pins `normalizesLevels` on at renderer creation and never reads a level setting.


Theme is the same shape, with one difference: `syncWaveformTheme` compares against a signature, and **that signature is an INSTANCE method** where the style's is app-wide. All four themes are offered here, and `album_art` draws its palette from `artworkThemeColor` — which is **per view, because each page of the pager is a different track**. `TrackPageCell` sets it as it installs the page's art, so the color rides the artwork install path and cannot belong to another track however a delivery raced (the root `AGENTS.md`'s waveform-theme guarantee). Setting it re-resolves through `syncWaveformTheme` itself, so a caller that has just handed a page its art has nothing else to call, and the signature compare makes a repeated set with the same color free. **Leave the color out of the signature and a swipe onto a track with different art compares equal and keeps the previous track's palette.**

## The bitmap is the only picture

**What the scrubber shows is always one bitmap of the whole track** — two image layers, unplayed full-width and played on top cropped by `contentsRect` — so a frame of scrolling, scrubbing, paging or zooming is texture translation. The renderer is only the bitmap's sampler: its layers live in a host that is never shown. **TRAP: never show the renderer's live tree here.** It is a multi-screen layer under a mask of thousands of rects, which the render server scan-converts on the CPU on every frame it moves; on a phone a scrub over it ran at 30 Hz or less, and a page swiped while one eased cost the render server most of a core. The Detailed family and 3-Band bake through the renderers' envelope-image API (`AudioWaveformRenderer.h`, samples on main, pixels off it); every other style draws whole through `WaveformRendererRegistry newImageForCodableWaveform:`, the widget's road, once all played and once all unplayed.

**Every delivery takes one road, `showWaveform:`, and the view picks the entrance from its own state** (`installEnvelopeImage:`), so a track looks the same whether it was cached, local, streaming or swiped onto:

- **The first bitmap onto an empty view grows from the midline** (`kArrivalGrowDuration`, the layer anchored at its vertical center), **once, at its final heights when it can**: a partial waits `kFirstPartialDelay` for its load to complete, and most loads do, so they enter without a crossfade after them. Before it lands the loading indicator stays up if one is, or the strip is empty — the wait plus one bake, about 0.1 s on a phone for a cached waveform.
- **A streaming load swaps its partial bitmaps at a steady pace** (`kLoadBakeMinInterval`, trailing, so the newest shape wins), whatever the decode's own: it delivers about ten times a second, and a swap per delivery read as flicker. What has not decoded draws as the silence hairline, under the shimmer and fill as before.
- **The complete bitmap crossfades over a partial one** (`kCompletionFadeDuration`, the old one kept as `_bakedOutgoing` until the fade ends): Normalize raises its reference only for the whole track (`Renderers/AGENTS.md`), so a plain swap made the bars jump taller as a load finished.
- **Everything else swaps in place**: a re-bake after a resize, a zoom, a theme, a style or a scale change keeps the old bitmap up — stretched if the size moved — until the new one lands. Only a reset (a track change, a recycled page) removes it.

One bake runs at a time per view. A finished one installs unless a change of meaning bumped `_bakeEpoch` meanwhile; a newer streaming delivery does not discard it. A page handed the complete waveform it already shows does nothing.

**The scroll offset is written without a `CATransaction`.** On the display link's tick there is no implicit transaction yet, so an explicit one is top-level and committed the whole tree, layout included, a second time in the frame on every progress step; `setContentOffsetX:` opts out of an enclosing animation block instead, and `_bakedPlayed` carries null actions, so the progress write needs no transaction either.

`dump_state`'s `ui.waveformBaked` is whether a bitmap is up.

## Scrubbing

A drag moves the content 1:1 under the fixed center (no hover highlight); a tap nudges to the tapped point within the visible window, which also preserves tap-to-start on a parked track. `isScrubbing` is the scroll's own `isDragging || isDecelerating || isTracking`, or under a pinch whether it has a seek to commit, so it spans the whole content motion — coast and bounce included — and keeps the progress writers from fighting it. A tap mid-coast stops the scroll first and explicitly sends the matching scrub-end callback: cancelling deceleration does not guarantee `scrollViewDidEndDecelerating:`, and without that callback the pager stays disabled after the tap.

**The time labels show where the scrub will land, not what is playing.** The playhead is pinned at center and never moves, so the labels are the only reading of a scrub's target; `didScrubToProgress:` delivers it per frame of scroll and the shell renders it (`Vibe/iOS/Player/AGENTS.md`). For its duration the scrub owns the whole readout — `updatePlaybackUI` bails on `isScrubbing`, the same as `scrollTick:` one tier down.

**TRAP: a scrub seeks only when its gesture ends — `endScrub`, or `endZoomGesture` for a pinch-carried scrub.** Committing earlier — on reaching an end mid-gesture — reads as correct and is not: a seek to 1.0 finishes the track and auto-advances with the finger still down. `UIScrollView` also reports `isDecelerating` *during* a drag, so there is no "still moving" test that separates a coast from a finger.

**TRAP: a `UIScrollView` owns its pan's delegate and raises on assignment**, so the "no waveform, nothing to scrub" gate rides `scrollEnabled` (set from `setWaveform:`) rather than `gestureRecognizerShouldBegin:`. It has to exist at all because the pager makes its own pan require the scrubber's to fail: a pan that always begins satisfies that requirement forever and turns an empty strip into a dead zone where the page will not swipe. A disabled scroll's pan counts as failed, which is exactly what that wants.

**TRAP: that failure requirement is not enough on its own, and the gap only opens at an end.** When the scrubber's scroll sits *exactly* at a content edge, UIKit's nested-scroll arbitration stops its pan from beginning at all so an ancestor scroll view can have the gesture — so the requirement is satisfied, the pager inherits the drag, and pushing against an end turns the page instead of bouncing (or, on a one-track playlist, does nothing). Arriving at an edge mid-drag is fine, because the pan has already begun; only *starting* parked at an end fails, which is why it survives casual testing. `TrackPagerView` (`Vibe/iOS/Player/PlayerViewController.m`) closes it by declining its own pan for touches that hit-test into a loaded `WaveformScrubberView`. Both halves are needed: `scrollEnabled` decides whether the scrubber *wants* the drag, the pager's override stops it being taken away, and an unloaded scrubber must let the pager begin.

**TRAP: the pager has to be held STILL for the length of a scrub, not merely out-gestured.** UIKit chains an inner scroll view's overscroll into an enclosing one, and that chaining is decided from geometry rather than from which recognizer won — so while the pager could still scroll the way the finger is going, the scrubber *clamps* at its end instead of bouncing, even though the pager already declined the gesture and never moves. It presents as an end that bounces on the last page and hard-stops on every other. `didChangeScrubbing:` (the delegate's second method) exists solely for this: the shell sets `_pagesView.scrollEnabled = NO` for the duration. **It must be released on every path out, including a track change mid-scrub**, or the pager stays locked and the app stops swiping.

**TRAP: on reset, park the content offset unconditionally.** Cancelling the scroll does not clear `isDragging` until the touch is delivered, so the progress write can skip its park and leave a recycled cell scrolled to the previous track's position.

**TRAP: clamp before the cast in `progressBucket`, not after.** `setProgress:` stores what the timer writers hand it, which can land a hair outside the unit range at track end, and converting a negative or overlarge double to `NSUInteger` is undefined rather than merely wrong.
