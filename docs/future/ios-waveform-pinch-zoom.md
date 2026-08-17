# Future: pinch to zoom the iOS waveform horizontally

Written 2026-08-16, planned but not implemented. Nothing in the repo has changed for it yet. The file:line anchors below are against branch `ios-app` at `1a492d3`. Re-check every anchor before acting.

## Context

`WaveformScrubberView` (`Vibe/WaveformUI/iOS/`) draws the track zoomed and scrolls it under a playhead pinned at the view's horizontal center. The zoom level is one constant, `kWaveformVisibleFraction = 0.4` (`WaveformScrubberView.mm:24`), whose own comment already names this change: *"the one knob the whole scrubber's scale hangs off — a preference or a pinch gesture would drive this and nothing else."* Today the user cannot change it; a pinch should, from the whole track down to a DJ-style close-up.

## Scope this was planned at

Two decisions, already taken:

- **iOS only.** The macOS `AudioWaveformView` has no scroll or zoom model at all — the full track across the view width, with x mapping to the track linearly for click-to-seek, the hover highlight and the convert sweep. Pinch there is a separate and much larger change.
- **Whole-track rendering is kept**, with zoom depth clamped so the settled envelope bitmap stays within budget. Rendering only a *window* of the track — which removes the depth ceiling entirely — is the documented extension point below, not this change.

**Ordering: the edge elasticity comes first.** Rubber-banding the scrub past the track's ends is a separate change, planned to land before this one. It touches the same file — `scrubToProgress:`, `momentumTick:` and `applyScrollAndProgress` — so this plan assumes it is already in and builds on top of it rather than beside it.

## The constraint that shapes the design

The scrubber's fast path bakes the **entire track** into one bitmap at `viewWidth / visibleFraction` (`bakeEnvelopeForGeneration:`, `WaveformScrubberView.mm:401`), and up to three pager cells hold one at a time. Zooming in grows that image linearly, against two ceilings:

- the GPU texture ceiling already handled by `kMaxBakeImagePixels` (16384px — past it a `CALayer`'s contents render **blank**, which is why that constant exists), and
- memory: iPhone portrait is ~6MB per cell today; unclamped zoom reaches tens of MB per cell, times three live cells.

So the zoom range's floor is **derived from geometry**, not a constant, and works out to roughly 8–17% of the track visible at maximum zoom depending on device and orientation — from today's 40%, out to 100%.

## Design

### 1. The zoom knob becomes a property, and it is the *requested* zoom

`kWaveformVisibleFraction` → `WaveformScrubberView.visibleFraction`, default 0.4.

**Stored and effective are two different numbers, and the stored one is the user's request.** `visibleFraction` holds what the user asked for, clamped only to the absolute design range `[kVibeWaveformMinimumZoomFraction, 1.0]`. What the view actually draws at is `effectiveVisibleFraction`, a *computed* accessor — not second state — that additionally clamps the request against the current geometry's floor (§2). `virtualWidth` reads the effective one; everything downstream (`virtualBounds`, the host translation, `progressBucket`, `tickBucket`, momentum, the bake) already derives from `virtualWidth` and needs no change.

The split exists because the geometry floor moves under the value: a rotation to a shorter, wider layout raises the floor, and clamping the *stored* value there would shallow the user's zoom permanently — including the persisted one, which one rotation would then ruin for every future launch. Keeping the request intact means the picture shallows while the layout demands it and comes straight back when the layout does. The two agree in ordinary use, because the pinch is itself clamped against the effective floor (§3); they diverge only when geometry changes underneath a committed value, which is exactly the case this handles.

The setter tears the bake down, resizes `_rendererHost.bounds`, redraws **settled** (`drawWaveformSettled` — a zoom is a pure geometry change, and `WaveformMorphEngine.updateTargetForSize:` already treats an unchanged identity+count as a resize and just rebuilds, so no morph should run), and schedules a bake.

A geometry change needs no new plumbing: `layoutSubviews` already compares `_rendererHost.bounds.size` against `virtualBounds` and tears the bake down on a mismatch, and since `virtualWidth` reads the *effective* fraction, a rotation that moves the floor moves that size and is caught by the existing test.

### 2. The clamp is pure math, in its own header

New `Vibe/WaveformUI/WaveformZoomMath.h` — header-only `static inline`, Foundation + CoreGraphics only, in the shared directory (so it compiles into both targets; only iOS calls it), following the `*Math.h` convention in the root `CLAUDE.md`:

- `VibeWaveformMinimumVisibleFraction(viewWidthPt, heightPt, scale)` — the deepest zoom whose bake fits **both** ceilings: `min(kMaxBakeImagePixels, byteBudget / (4 · heightPx))`. Budget as a new constant (~32MB/cell; at that size iPhone portrait lands right at the texture ceiling).
- `VibeWaveformClampVisibleFraction(requested, minimum)` — clamped to `[minimum, 1.0]`. 1.0 is the zoom-out stop: the whole track spans exactly the view width.
- `kVibeWaveformMinimumZoomFraction` — the absolute floor the *stored* request is held to, independent of any geometry (a hair under the deepest any layout could allow, ~0.01). It exists so a corrupt or hand-written defaults value cannot store something absurd, and so the request stays a sane number to persist.

`kMaxBakeImagePixels` moves here from the .mm so the bake and the clamp read one number. Unit-tested in `Tests/` (add the test file to the `VibeTests` source list in `project.yml`; the header itself needs no source entry). The round trip is worth a test of its own: a request below a given geometry's floor clamps for drawing but survives unchanged in the stored value.

### 3. The pinch itself

A `UIPinchGestureRecognizer` on the scrubber, beside the existing pan and tap.

- **The anchor is free.** The design guarantee `position.x + progress·virtualWidth == centerX` means zoom is inherently anchored at the playhead. No anchor math, and it is the right DJ behavior.
- **Live frames are a transform, not a re-render.** Re-rendering per pinch frame means rebuilding a 4,096-rect mask path over a multi-screen layer at 60Hz — exactly what the bake exists to avoid. Instead hold a `_pinchScale` and fold it into the one place geometry is applied, `applyScrollAndProgress`: `effectiveVirtualWidth = virtualWidth · _pinchScale`, host gets `CATransform3DMakeScale(_pinchScale, 1, 1)`. The played clip (`_bakedPlayed.bounds` / `contentsRect`) lives in the host's own space and scales with it for free; only the host position and the two baseline segments need the effective width. A live pinch is then pure texture scaling, on the baked and live-tree paths alike.
- **Commit on `Ended`/`Cancelled`**: `visibleFraction = startFraction / totalScale`, transform back to identity, bake re-lands. `_pinchScale` is clamped live against the **effective** range so the gesture stops where the picture does — a hard stop; rubber-banding the *zoom* limits is out of scope. Because the gesture was already held there, the committed request never sits below the current floor: request and effective agree on every value the user actually pinches to, and diverge only when a later rotation moves the floor.
- `Began` cancels any in-flight pan (the `enabled = NO; enabled = YES` idiom already in `resetWaveformContentState`) and any momentum, so a pan-into-pinch cannot commit a stray seek.

### 4. One zoom across all pages, persisted

The pager carries a scrubber per cell, so the zoom has to be shared or a swipe would change it.

- Extend `WaveformScrubberViewDelegate` with `waveformScrubberView:didChangeVisibleFraction:`, beside the existing `didSeek:`. Implemented in `PlayerViewController+Delivery.m`, which already holds that conformance.
- `PlayerViewController` stores the value (new ivar in `PlayerViewControllerInternal.h`), applies it to every visible cell's scrubber on change, and sets it on each cell in `collectionView:willDisplayCell:` (`PlayerViewController+Pager.m:111`, the same one-time block that wires the delegate) so a recycled or newly displayed page comes up at the current zoom.
- **Persistence**: a new `NSUserDefaults` key owned by the iOS side (`VibeiOSWaveformZoom`), *not* `AppSettings` — the platform split there is one `#if TARGET_OS_OSX` block with no iOS-only side, and iOS already keeps its own keys (`FolderSession`'s `VibeiOSFolderBookmark` / `VibeiOSLastTrackFileName`). **The persisted value is the request, never the effective one** (§1), so a launch in one orientation cannot shallow the zoom a later launch in the other would have allowed. A missing or unreadable key reads as the 0.4 default; a present one is clamped to the absolute range on read, and the geometry floor is applied by the view, not baked into what is stored.

### 5. Gesture arbitration

- `_panRecognizer.maximumNumberOfTouches = 1` on the scrubber's own pan, so a second finger does not scrub.
- `_pagesView.panGestureRecognizer.maximumNumberOfTouches = 1` in `+Pager`, so a two-finger pinch cannot start a page swipe.
- Extend the existing loop at `PlayerViewController+Pager.m:115` — which today makes the pager pan require the scrubber's *pan* to fail — to include the pinch.
- `PlayerViewController.gestureRecognizer:shouldReceiveTouch:` (`PlayerViewController.m:239`) already returns NO for any touch inside a `WaveformScrubberView`, so the screen tap and the minimize pan stay out of the way with no change.

## Files

| File | Change |
| --- | --- |
| `Vibe/WaveformUI/WaveformZoomMath.h` | **new** — min-fraction and clamp math, `kMaxBakeImagePixels` |
| `Vibe/WaveformUI/iOS/WaveformScrubberView.h` | `visibleFraction`, the new delegate callback |
| `Vibe/WaveformUI/iOS/WaveformScrubberView.mm` | the bulk: property, pinch, transform path |
| `Vibe/iOS/PlayerViewControllerInternal.h` | the shared-zoom ivar |
| `Vibe/iOS/PlayerViewController+Delivery.m` | `didChangeVisibleFraction:`, persistence write |
| `Vibe/iOS/PlayerViewController+Pager.m` | apply zoom per cell; the two `maximumNumberOfTouches`; pinch in the fail loop |
| `Vibe/iOS/PlayerViewController.m` | restore the persisted zoom at setup |
| `Vibe/Debug/iOS/PlayerViewController+Debug.m` | `waveformZoomRequested` **and** `waveformZoomEffective` in the chrome dump — both, since telling them apart is the only way to check the split from outside |
| `Vibe/Debug/iOS/RootViewController+Debug.{h,m}` | pass-through for the new verb |
| `Vibe/Debug/iOS/DebugCommands.m` | `set_waveform_zoom <fraction>` verb |
| `Tests/WaveformZoomMathTests.m` + `project.yml` | unit tests for the header |
| `Tests/iOSDriver/VibeiOSDriverTests.m`, the skill's `drive-ios.sh` | a `pinch <identifier> <scale> <velocity>` verb |

The driver's pinch needs an element to center on — XCUITest has no coordinate-based multi-touch, only `XCUIElement.pinchWithScale:velocity:` — so the scrubber gets an `accessibilityIdentifier`. That alone puts it in the XCUI element tree; it does **not** need `isAccessibilityElement`, so there is no VoiceOver behavior change and no new localized string.

No new user-facing strings, so no `make strings` run. No `AppSettings` change.

## Docs to update

- `Vibe/WaveformUI/CLAUDE.md` — the iOS scrubber paragraph: zoom is a property not a constant, why the range floor is geometry-derived, and why the live pinch is a transform rather than a re-render.
- `Vibe/iOS/CLAUDE.md` — the zoom's persistence key beside `FolderSession`'s, and the pager's gesture arbitration line.
- `.claude/skills/vibe-debug/SKILL.md` — the new debug verb and the driver's `pinch`.

## Verification

1. `make build-ios CONFIG=Debug` (what CI's `build-ios` job runs) and `make test` for the new math tests. `make analyze` and `make check-layout` before finishing.
2. Launch in the simulator (`vibe-debug` skill's iOS loop), open a folder, expand the card.
3. `debug-ios.sh set_waveform_zoom 0.1` / `1.0` / `0.4` + `dump_screenshot` at each: bars stay sharp, the playhead stays exactly centered, the baselines fill the off-track space, and `dump_state` shows `ui.waveformBaked: true` once each settles — a `false` there means the bake bailed and every frame is running the live tree.
4. Confirm the clamp: request a fraction below the floor, and check `waveformZoomEffective` is the floor while `waveformZoomRequested` keeps what was asked for — and that the waveform is not blank. The blank-texture failure mode is silent otherwise.
5. Swipe pages at a non-default zoom — every page comes up at the same zoom and `waveformBaked` stays true; relaunch and confirm the zoom restored.
6. Rotate (`drive-ios.sh rotate left`) at deep zoom: no blank waveform, the picture re-clamps to the new floor, and the current track index survives the transition. **Rotate back and the original depth returns** — that is the request-vs-effective split (§1) working; a value that stays shallow means the clamped number got stored. Then relaunch in each orientation and confirm the persisted zoom is the deep one either way.
7. **Gestures** (`drive-ios.sh`, the one thing only real touches test): `pinch` on the waveform zooms and the pager does not move; a one-finger `drag` on the waveform still scrubs 1:1 and does not page; a drag on the artwork still pages; the edge elasticity from the prior change still behaves at both ends, at several zoom levels.
8. Memory: at maximum zoom with three pages live, check the app's footprint is in the expected tens of MB, not hundreds.

## Deliberately out of scope

- macOS pinch/zoom.
- **Windowed rendering** — render only the visible span instead of the whole track. That is what removes the zoom-depth ceiling entirely, and it would give *more* detail when zoomed in: the data holds 8,192 chunks (`NUM_CHUNKS`, `AudioWaveform.mm:8`) against the 4,096 bars the x4 style draws, and `getChunkAtIndex(index, size)` already resamples to an arbitrary bucket count, so a sub-range is `size = count / windowFraction`, `index = windowStart · size + i`. The costs are a sample-range input on the shared renderers (macOS passes the full range), a morph identity that includes the range, and a re-bake as the playhead travels — with a fast scrub throw outrunning the re-bake and falling back to the live tree. The clamp above is the natural seam for it: cap the host width, and windowing is what happens past the cap.
- Tiling the bake into two images to double the texture ceiling.
- Rubber-banding the zoom limits.
- A double-tap-to-reset-zoom gesture, which would collide with tap-to-seek.
