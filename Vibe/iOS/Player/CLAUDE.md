# The now-playing card (iOS)

The scrubber itself is `WaveformUI/iOS/CLAUDE.md`; the shell is `../CLAUDE.md`.

## PlayerViewController

The track pager and the chrome over it. It observes `PlaybackController` and owns no playback state. **Only the settled page commits** (`commitVisiblePage`, `+Pager`); pages appearing switch nothing. Asynchronous results land in `+Delivery`, metadata excepted — that is the model's `PlaybackObserver` event.

**`presented` gates a keep-alive card.** Minimized, the card still lays out and reloads, so `commitVisiblePage` must not run — a playlist replacement settles a scroll nobody made — and neither may the playhead display link. The link reads the exact `sceneActive` the scene delegate supplies, never process-wide notifications.

**The swipe down is arbitrated on axis in `gestureRecognizerShouldBegin:`.** A paging scroll view's pan begins on movement in any direction, so the minimize pan requires the pager's pan to fail, and fails itself on the first horizontal move. **TRAP: the axis test is on TRANSLATION, not velocity** — velocity reads zero whenever the finger pauses, including the moment a slow drag crosses the slop.

**TRAP: the scrub lock's release is matched against the view that took it, not the bound page.** A track ending mid-drag rebinds `_waveformView` to the next page while the finger is down on the outgoing one; filtering the lift on the binding drops it and the pager stays unswipeable. Why the pager must be held still at all is `WaveformUI/iOS/CLAUDE.md`.

`TrackPagerView` declines its pan for touches inside a *loaded* `WaveformScrubberView`; an unloaded scrubber disables its pan and the pager must accept that surface, or the loading strip is a swipe dead zone. **Two fingers are a waveform zoom, never a swipe**: the pager's pan is capped at one touch and requires the scrubber's pinch to fail; the pinch takes the same pager hold a scrub does. The scrubber's own pan stays uncapped (`WaveformUI/iOS/CLAUDE.md`).

**The right time control shows the duration; a tap flips it to minus-prefixed remaining**, held by `PlayerDisplaySettings`. Every render path goes through `VibeRightTimeText`. The mode is one setting, so the handler repaints every visible page. **A settings change arrives from outside the card**: `VibeDisplaySettingsDidChangeNotification` lands on `displaySettingsDidChange`, which reconfigures every visible page, syncs waveform style and repaints times; a pooled cell is configured from scratch on its way back, and `willDisplayCell:` re-applies zoom and style.

**The time labels belong to a scrub while one runs**: `+Delivery` renders `didScrubToProgress:` as the landing time, guarded to whole seconds, and `updatePlaybackUI` bails on `isScrubbing`. The duration falls back to the track's own, so scrubbing a parked track reads correctly.

**The waveform zoom is one value for the whole pager**, stored by `+Delivery`'s `didChangeVisibleFraction:` in `VibeiOSWaveformZoom` and re-applied on every `willDisplayCell:`. What is stored is the user's request, never what a view drew (`WaveformUI/iOS/CLAUDE.md`).

## Output route

`OutputRouteView` rides the page: the middle of portrait's action bar, the top-trailing corner of landscape's codec line; each layout restates its glyph size and width cap as constraint constants. **On the phone's own speaker it draws the AirPlay glyph alone** — the control advertises what tapping it does; only off-device does it name the destination (`Audio/iOS/OutputRouteRules.h` decides). `AVRoutePickerView` is the only way to raise the picker, so the view fills its bounds with one, tints cleared, as an invisible tap surface under our icon and label; **its class is in `gestureRecognizerShouldReceiveTouch:`'s decline list** because what hit-tests inside it is AVKit's view. The controller pushes one route to every visible page.

**The picker's sheet holds the playhead display link, and the hold releases itself.** **TRAP: AVKit does not reliably send the end edge** — on the simulator, never — which would freeze the waveform under correct labels for the life of the process. A generation-stamped deadline releases it, and the scene-active edge settles it sooner. The end edge also re-reads the route, because a destination picked against an inactive session posts no notification. `ui.routePickerUp` in `dump_state` shows the flag; `set_output_route` draws any route kind.

## TrackPageCell

One full-screen page: blurred art (a baked image, `Util/iOS/CLAUDE.md`), header, transport row. Two constraint sets swapped on the cell's own aspect in `layoutSubviews`: portrait is the centered card, landscape the mac window transplanted. Geometry constants are private to the cell.

**The transport is always up**; only the empty state fades it, with the action bar and route control (`chromeAlpha`). A tap anywhere else pauses. **Next dims at the end of the playlist, from the PAGE's index**, so the last page arrives dimmed. Two traps under that button:

- **TRAP: the disabled look is drawn, not delegated.** A system button dims its own template image, so an alpha on top compounds. `setGlyph:onButton:pointSize:` installs a pre-tinted `AlwaysOriginal` image for the disabled state.
- **TRAP: hit-testing does not hand back a disabled button**; the touch falls through to the card's pause. `TrackPageTransportView` and `TrackPageActionBarView` are classes of their own so the row and the bar decline as a whole in `gestureRecognizerShouldReceiveTouch:`, beside `UIControl` and `WaveformScrubberView`.

**Portrait is four bands and only the art band moves**: grabber strip, art band (the leftover height, art centered in it), fixed label band, and the action bar, transport and waveform off the safe bottom with the time row off the waveform. **The art is capped twice**: a width fraction (the binding cap on tall screens) and the band (short screens).

**The waveform sits at the same y on every page — a layout guarantee.** The label band's height is its worst case: two-line title, one line each for artist and codec. The one exception is the codec line leaving the band with its gap when the setting is off or a track has no readout yet; that is one setting across every page, so the guarantee holds and the art moves instead. Labels shrink to fit, never truncate, and ride centered in the band with the single-line labels' lines reserved, so a missing artist lays out like a present one. The art card gives at accessibility sizes.

**TRAP: the art card's shadow path is restated from the card's OWN layout pass** (`TrackPageArtCardView`). Its size is set by the contentView's constraints, so a label-band change resizes it without the cell's `layoutSubviews` running; set from the cell, the shadow keeps the previous size until a swipe recycles the cell. Landscape anchors the header to the top safe area too.

**The time row is pulled up into the waveform view's bottom** (`kCellTimeWaveformOverlap`): the scrubber reserves headroom around the envelope, and the eye measures from the drawn waveform. It hangs off the waveform so tightening it cannot push the waveform down. Landscape keeps a plain gap, since its transport rides the time row's centerline.

**A page shows full-size art or the vinyl placeholder, never the 128px thumbnail.** The **art window** in `+Pager` decodes the current page and its neighbors ahead and holds their art (`_artHeldPages`) to a byte budget — **but never releases a page with a live cell**, whose image view pins the bitmap anyway. `renderHeaderForTrack:` moves the window, and a metadata delivery re-runs it: before metadata lands, the art dispatch is a message to nil. **The commit path discards nothing**, since the departing page is usually the arriving one's neighbor.

## PageWaveformCoordinator

Waveform bookkeeping between `AudioWaveformCache`, which runs one load at a time, and the cells.

**Deliveries carry the URL they were loaded for**, and a stale one is dropped on the value — the app-wide staleness guarantee; `requestIndex:track:` records `_targetURL` beside `_targetIndex`. A page already targeted is left alone, since re-requesting per reload would keep killing the decode. A matching terminal failure clears the target and lets the next request retry; the snapshot window prunes to a radius around the current page. BPM/key are not forwarded — analysis is macOS-only.

**The scroll hold (`held`) is the pager's frame budget.** A delivery repaints a scrubber, which tears down its bake, and a request cancels the cache's one load — so a swipe across N pages cancelled N decodes and finished none. Held, deliveries are recorded but not forwarded and requests are dropped. `+Pager` holds for a user swipe, a visible programmatic page animation and a size transition (a minimized page move snaps without one), and clears the swipe hold **before** `commitVisiblePage` so the settled page's request gets through. **Every programmatic retarget renews a generation-stamped deadline**, since UIKit may never deliver its end callback; the deadline releases the hold and reissues the current page's request. The same hold pauses the playhead display link (`updateScrollLinkState`).
