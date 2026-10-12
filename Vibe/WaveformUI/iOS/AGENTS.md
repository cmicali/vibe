# The waveform scrubber (iOS only)

`WaveformScrubberView` is the shared renderers on UIKit, DJ-style. **The play position is fixed at the view's horizontal center, and the waveform scrolls beneath it.**

The renderer draws the whole track across a *virtual* width: the view width divided by `visibleFraction` (0.48 at rest). **A `UIScrollView` carries it.** The virtual width is the content size, and the insets are half a view on each side. So `contentOffset.x == progress·virtualWidth - centerX`, and both ends of the track park under the center. UIKit supplies the drag, the deceleration and the rubber-band at both ends. `decelerationRate` is `Fast`.

## Zoom

**`visibleFraction` is the user's request, not what is drawn.** A pinch drives it. `effectiveVisibleFraction` is a computed accessor that clamps it to what this geometry's bitmap can hold. `virtualWidth` reads the effective value, so the content size, the offset mapping, the buckets and the bake are all clamped without knowing it.

**The floor is derived, not a constant** (`WaveformUI/WaveformZoomMath.h`). It is the deepest zoom whose bake fits both the GPU texture ceiling and a per-bake byte budget. The budget bounds the worst case across the pager's cells and the bake store. A rotation to a shorter, wider layout raises the floor. Clamping the stored value there would shallow the user's zoom for good. **Persist the request, never the effective value.** The pager stores one zoom for every page in `VibeiOSWaveformZoom` (`Vibe/iOS/Player/AGENTS.md`).

**A pinch frame stretches the bitmap. It does not re-render.** `applyVirtualGeometry` re-places the bitmap at the new virtual bounds (`placeBakedLayer:`), and resize gravity does the scaling. The picture goes slightly soft until the re-bake on release. Every other resize, such as a rotation, stretches the same way and re-bakes at once. A stored bake of another zoom is installed stretched and then re-baked once.

**Wiggle keeps the same loops through a zoom.** The scrubber sets `samplingWidth` to the viewport width divided by the default zoom fraction. Wiggle uses it for its loop count while drawing across the zoomed width. A real viewport resize can still change the count. The finer bar styles sample at their drawn width.

The fraction is written live, so the content size and end stops are honest on every frame. `UIScrollView`'s own `zoomScale` is the wrong shape. It scales both axes and anchors on the pinch centroid, but the playhead must stay at center.

**TRAP: park the content offset unconditionally on every pinch frame** (`parkContentOffsetAtProgress`). `syncContentOffsetToProgress` declines while `isScrubbing`, and the pinch's own fingers keep the scroll's pan reporting `isTracking`. Without the park, the playhead drifts off center as the zoom changes.

### Pinch and scrub are one continuous gesture

A finger already scrubbing must be able to start a zoom. Lifting back to one finger must return to scrubbing without the hand leaving the glass. Four traps make that work.

**TRAP: the pinch needs `shouldRecognizeSimultaneouslyWithGestureRecognizer:`, or it cannot start during a scrub.** By the time a second finger lands, the scroll's pan has recognized. By default one gesture belongs to one recognizer, so the pinch is refused.

**TRAP: `UIScrollView`'s pan cannot carry a gesture across a change in touch count.** It ends the instant a finger is added or lifted. An ended recognizer is never handed touches that were already down. `UIPinchGestureRecognizer` stays in `Changed` with one touch left. **So from its first frame the pinch owns the gesture to its end.** `trackZoomGestureScrub:` moves the track from the pinch's centroid only when exactly one touch remains. With two, the centroid is the zoom's anchor. It re-anchors on any touch-count change, or the 2-to-1 centroid jump lands as one huge scrub. The pan has no `maximumNumberOfTouches` cap on purpose, because a cap only makes it die sooner.

**TRAP: the dying pan must not finish anything.** Its `endScrub` arrives mid-gesture. Left alone, it would seek to where the finger was when the second one lifted and release the pager under a live drag. `endScrub` declines while `_isPinching`. `endZoomGesture` settles the seek, the haptics and the pager hold when the hand leaves. It also stops the pan's coast before clearing `_isPinching`. Otherwise `scrollViewDidScroll:` reads a position out of the coast that no seek follows.

**TRAP: a pure zoom is not a scrub. It must neither freeze the position nor seek.** Two fingers landing start the scroll's pan too, so nearly every pinch sets `_seekPending`. Counting the whole pinch as a scrub froze the picture while the audio played on. The lift then seeked back to the frozen spot, an audible skip. So a pinch scrubs only once it has a seek to commit. `beginZoomGesture` drops a pan scrub that moved less than `kZoomScrubSlop` from `_scrubStartProgress`. `scrollViewWillBeginDragging:` ignores a pan that starts under a live pinch. The one-finger phase needs the same slop before it scrubs, because the finger left behind always wobbles. Until then `isScrubbing` is NO, and playback keeps writing the position.

## Layers and the playhead

**Everything that scrolls is a sublayer of the scroll's layer. Everything that does not is a sublayer of the view's.** The loading indicator must not move with the content.

The played and unplayed boundary is the playhead marker. It stays at center **by construction**. The played clip spans content x `0..progress·virtualWidth`, the same space the scroll translates.

**The playhead line replaces that boundary at no per-frame cost.** With a `playheadColor` on the resolved theme (`../AGENTS.md`), the played side spans the whole track (`playedProgress`), live tree and bake alike. The line is one layer of the view's own at its center. So no progress write or zoom frame touches it, and it holds still through a bounce. The choice is part of `themeSignature`, so `syncWaveformTheme` applies a flip of the switch.

**The off-track space is empty on purpose.** A hairline continuing the midline past the content's ends reads as a stray line across the card near the start of a track.

**The loading track obeys the same rule.** `loadingTrackBounds` spans only the part of the view the content occupies, clipped to the view. A page swiped onto is at progress 0, so drawn full-width it would put half of itself in the empty space. Showing the indicator on an empty view resets its progress to 0, and the shell's next tick restores the real position.

**TRAP: keep the "did the span actually move" test in `syncLoadingTrackToProgress`.** It is the one relayout that can land mid-download. A duration-0 relayout snaps an easing fill to its target. While the provider materializes the file, progress is parked, so the test declines.

The renderer tree hangs off a `geometryFlipped` sublayer that gives the shared math the mac's y-up space. **Do not "fix" coordinates in shared renderer code for iOS.**

## Loading and interaction state

**`cancelInteraction` ends a drag or pinch without seeking or discarding pixels.** A cursor change calls it for held scrubbers, and cell reuse calls it through the content reset. It drops the pending seek before disabling the recognizers, since cancellation can send their end callbacks. A pinch still active afterward is ended through `endZoomGesture`, so the final bake and the shared zoom update still happen.

**Showing a loading indicator keeps an existing waveform.** Cell reuse clears the previous track explicitly. Starting playback on a prepared page must keep its pixels. A positive transfer update creates the indicator if needed. The shell's `playbackLoading` keeps the shimmer through a slow open, including one with no transfer. Settlement or a cursor change clears it.

**Outside a pending playback open, the first bitmap ends the shimmer but not the fill.** A disk-cached waveform can land while the provider is still downloading the audio. Then the fill over the drawn waveform is the only sign of the download. That is `endSweepKeepingFill`, whose answer says whether anything is left to keep. This scrubber is its only caller.

## Style and theme

The style comes from `AppSettings.waveformStyle` through the registry's fallback chain, as on the mac. The settings screen writes it (`Vibe/iOS/Settings/AGENTS.md`). `syncWaveformStyle` is the live swap. It rebuilds only when the resolved style differs from the current renderer's, since the pager calls it on every cell and on each `willDisplayCell:`. The outgoing style's bitmap stays up until the new one lands.

Normalize and Gain are mac settings (`AppSettings+Mac.h`). This scrubber sets `normalizesLevels` on at renderer creation and never reads a level setting.

**`syncWaveformTheme` compares against `themeSignature`, which is an instance method.** `album_art` draws from `artworkThemeColor`, which is **per view, because each page is a different track**. `TrackPageCell` sets it as it installs the page's art, so the color rides the artwork install path (root `AGENTS.md`). The setter re-resolves through `syncWaveformTheme` itself, and an unchanged signature costs nothing. **The color is in the signature only under `album_art`.** Left out there, a swipe onto a track with different art would compare equal and keep the previous palette. Under every other theme it is left out on purpose, so late art re-bakes nothing.

## The bitmap is the only picture

**What the scrubber shows is always one bitmap of the whole track.** It is two image layers: unplayed full-width, and played on top cropped by `contentsRect`. So scrolling, scrubbing, paging and zooming are texture translation. The renderer only samples. Its layers live in a host that is never shown.

**TRAP: never show the renderer's live tree here.** It is a multi-screen layer under a mask of thousands of rects. The render server scan-converts it on the CPU on every frame it moves, and a scrub over it ran at 30 Hz or less on a phone.

The Detailed family and 3-Band bake through the envelope-image API (`AudioWaveformRenderer.h`), with samples read on main and pixels drawn off it. Every other style draws whole through `WaveformRendererRegistry`'s `newImageForCodableWaveform:`, once all played and once all unplayed.

**TRAP: `installEnvelopeImage:` must drop the standing bitmap first.** Without the removal, the old layer stays in the scroll's tree for the life of the view. **TRAP: crop the played side inside the install's transaction.** That transaction is top-level and commits at once. Left to the next pass, the new played layer showed at zero width for a frame, and the played side blinked at every swap.

**Fresh deliveries take `showWaveform:`, and the view picks the entrance from its own state.** The pager hydrates a complete cached snapshot with `animated:NO`.

**Every complete bake goes into a small content-keyed store.** The key is the waveform's identity, the bake height, scale, appearance, style and theme signature. The baked width is stored beside the pixels. It holds three entries of a played and an unplayed bitmap, NSCache-evicted. `showWaveform:animated:NO` installs a hit synchronously, so a page arriving with pixels baked shows them on the turn it appears. The key carries the view's own geometry, so a cell must be laid out before it looks up its bitmap. Bitmaps are shared, never layers or gestures. An entry holds its waveform, so the address in its key cannot be reused while it lives.

For an ordinary load:

- **The first bitmap onto an empty view grows from the midline** (`kArrivalGrowDuration`), **once, at its final heights when it can.** A partial waits `kFirstPartialDelay` for its load to complete, and most loads do, so they enter once. Until then the loading indicator stays up, or the strip is empty.
- **A streaming load swaps partial bitmaps at a steady pace** (`kLoadBakeMinInterval`, trailing, so the newest shape wins). A swap per delivery read as flicker. **Each swap grows only the newly decoded stretch up from the midline** (`kChunkGrowDuration`, `revealDecodedFrom:to:tailPlayed:…`). The edge is the first unfilled chunk (`AudioWaveform`'s `getDecodedFraction`). The picture is made of segments (`newSegmentFrom:to:`). Each segment is a stretch of the track drawn as the played image up to the playhead over the unplayed one. A reveal uses three: before the stretch, the stretch, and the undecoded rest. So no mask is involved, and the stretch grows the same on either side of the playhead.
- **TRAP: every stretch outside the new one stays drawn.** Cropping one layer at the old edge hid the undecoded midline, and it blinked at every swap. Growing only the unplayed side popped a stretch the playhead had passed.
- **TRAP: everything past the old edge comes from the previous picture**, where it is all midline. A drawn bar is wider than a chunk and straddles the decoded edge. Cut from the new picture, the edge bar's sliver stood at full height while the stretch grew. Padding the stretch past its edges instead regrew bars already shown.
- **TRAP: under the growing stretch, the previous picture shows only for the first half of the grow.** Smooth outlines like 3-Band's draw nothing near a hairline, so without it the midline had a gap. Left for the whole grow, its midline showed through the translucent stretch.
- **The complete bitmap grows from the partial's heights to its own** (`kCompletionGrowDuration`) while its last stretch grows in. Normalize raises its reference only for the whole track (`Renderers/AGENTS.md`), so a plain swap made the bars jump. With Gain at 0, the raise is one vertical scale (`normalizationGainForWaveform:`), and the bitmap starts squashed by it.
- **TRAP: never fade one picture over another.** The waveforms are translucent, so a crossfade drew the pair brighter than either and then dimmed in one frame.
- **Everything else swaps in place.** A re-bake after a resize, zoom, theme, style or scale change keeps the old bitmap up, stretched if the size moved, until the new one lands. Only a reset (a track change, a recycled page) removes it.

One bake runs at a time per view. A finished bake installs unless a change of meaning bumped `_bakeEpoch` meanwhile. A newer streaming delivery does not discard it. A page handed the complete waveform it already shows does nothing.

**TRAP: the scroll offset is written without a `CATransaction`.** On the display link's tick there is no implicit transaction yet. An explicit one is top-level and commits the whole tree, layout included, a second time in the frame. `setContentOffsetX:` opts out of an enclosing animation block instead. Each segment's played layer carries null actions, so the progress write needs no transaction either.

The debug channel's `dump_state` reports `ui.waveformBaked`, which is whether a bitmap is up.

## Scrubbing

A drag moves the content 1:1 under the fixed center, with no hover highlight. A tap nudges to the tapped point within the visible window, which also keeps tap-to-start on a parked track. `isScrubbing` is the scroll's `isDragging || isDecelerating || isTracking`, or under a pinch whether it has a seek to commit. So it spans the whole content motion, coast and bounce included, and keeps the progress writers off. A tap mid-coast stops the scroll and sends the scrub-end callback itself. Cancelling deceleration does not guarantee `scrollViewDidEndDecelerating:`, and without the callback the pager stays disabled.

**The time labels show where the scrub will land, not what is playing.** The playhead never moves, so the labels are the only reading of a scrub's target. `didScrubToProgress:` delivers it per frame, and the shell renders it (`Vibe/iOS/Player/AGENTS.md`). The shell's `updatePlaybackUI` and `scrollTick:` bail while `isScrubbing`.

**TRAP: a scrub seeks only when its gesture ends**, in `endScrub`, or in `endZoomGesture` for a pinch-carried scrub. A seek to 1.0 mid-gesture finishes the track and auto-advances with the finger still down. `UIScrollView` also reports `isDecelerating` during a drag, so no "still moving" test separates a coast from a finger.

**TRAP: a `UIScrollView` owns its pan's delegate and raises on assignment.** So the "no waveform, nothing to scrub" gate rides `scrollEnabled`, set from `setWaveform:`, not `gestureRecognizerShouldBegin:`. The gate is needed because the pager requires the scrubber's pan to fail. A pan that always begins never fails, which turns an empty strip into a dead zone where the page will not swipe. A disabled scroll's pan counts as failed.

**TRAP: that failure requirement is not enough at a content edge.** When the scroll sits *exactly* at an edge, UIKit's nested-scroll arbitration stops its pan from beginning so an ancestor can have the gesture. The pager then inherits the drag, and pushing against an end turns the page instead of bouncing. Arriving at an edge mid-drag is fine. Only *starting* parked at an end fails. `TrackPagerView` (`Vibe/iOS/Player/PlayerViewController.m`) closes the gap by declining its own pan for touches that hit-test into a loaded `WaveformScrubberView`. Both halves are needed. `scrollEnabled` says whether the scrubber wants the drag, and the pager's override stops it being taken away.

**TRAP: the pager must be held still for the length of a scrub, not merely out-gestured.** UIKit chains an inner scroll view's overscroll into an enclosing one, decided from geometry rather than from which recognizer won. So while the pager could still scroll the way the finger goes, the scrubber clamps at its end instead of bouncing. `didChangeScrubbing:` exists for this. The shell holds the pager for the scrub's duration (`Vibe/iOS/Player/AGENTS.md`). **It must be released on every path out, including a track change mid-scrub**, or the pager stays locked.

**TRAP: on reset, park the content offset unconditionally.** Cancelling the scroll does not clear `isDragging` until the touch is delivered. The progress write can then skip its park and leave a recycled cell at the previous track's position.

**TRAP: clamp before the cast in `progressBucket`.** `setProgress:` stores what the timer writers hand it, which can land a hair outside the unit range at track end. Converting a negative or overlarge double to `NSUInteger` is undefined.
