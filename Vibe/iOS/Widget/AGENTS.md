# The widget's app side

The Home Screen and Lock Screen widget runs in its own process, the `VibeWidget` extension (`VibeWidget/AGENTS.md`). This directory owns the shared state, publishing, reload requests and button intents. The playback and player controllers feed the publisher.

| File | Role |
| --- | --- |
| `WidgetPublisher` | The only writer of the shared app group. `PlaybackController` owns one and feeds it from the Now Playing publish (`PlaybackController+NowPlaying.m`). Main thread only. |
| `VibeWidgetState` | The snapshot the app writes and the widget reads. **Compiled into both targets**, so it is Foundation only. |
| `VibeWidgetIntents.swift` | The widget's buttons. **Compiled into both targets.** The app owns the bodies. |
| `VibeWidgetReloader.swift` | WidgetKit's reload and placed query, which have no Objective-C API. Keep it small. |

`project.yml` names the two shared files one by one. The rest of the directory reaches for app classes and must never join the extension.

## The snapshot

`VibeWidgetState` is what was true at `positionDate`. The widget advances the playhead itself, so ordinary playback publishes nothing. A publish happens on a track change, a play or pause, a duration or title change, or a seek. The seek test is the lock screen's (`VibeNowPlayingPositionIsDirty`) with a 2 s tolerance.

The state is a plist in the app group container, with up to three images beside it: the artwork JPEG and the played and unplayed waveform PNGs. **The images are named by `trackKey`**, the track's `pathKey` plus a cue row's window. A publish that lands between the extension's reads can then leave an image missing, but never pair one track's title with another's cover. The key also rides in every seek button, so a tap on a stale render cannot seek a different track.

`kStateVersion` is bumped when a field's meaning changes. An unknown version draws the empty state until the next publish. The Swift names on `loadState`, `positionAtDate:` and `progressAtDate:` are pinned, because a rename breaks the extension in a build the app never runs.

## Writing

- **Writes are gated on `widgetPlaced`. The bookkeeping is not.** The publisher keeps `_published` current either way, so a widget that appears mid-track gets the current snapshot at once (`republish`).
- **Two sources decide `widgetPlaced`, each right about one direction.** WidgetKit's configurations, asked at launch and on every return to the foreground, turn it off. The extension posts `kVibeWidgetReadNotification` on every read, which turns it on the instant a widget renders. The query fails open.
- **TRAP: artwork lands before the plist.** The waveform bake can follow later. The widget reads the plist first. The sweep of old images runs last and spares the outgoing track's, which a plist just read may still name.
- **TRAP: `cachedArt` is nil until the art decodes**, so a track change usually writes nil and deletes the file. `_artworkOnDisk` re-fires the write on the first tick with decoded art.
- One serial queue orders file writes and reload requests. Requests are throttled to four a second. The first of a quiet period is queued at once. A burst schedules one trailing request. WidgetKit decides when to refresh.
- Artwork is bounded to 576 px and never cropped. The widget crops where it draws.

## The waveform bake

The app bakes the current track's envelope twice, once in each half of the palette, at the medium widget's aspect. The widget reveals the played image up to the playhead, so nothing re-renders per entry. The style is `widgetWaveformStyle`, or the app's style when it is nil. `widgetWaveformCentered` sets the alignment. The theme is always dark, because the widget's background is.

A waveform is baked only for the published track, so a page swiped past cannot overwrite the strip. A bake runs only when its signature changes: the resolved style, alignment, palette and waveform object. **TRAP: the Custom theme's colour wells post continuously while dragged.** The signature compare and the cancel of a queued bake keep a drag from queuing dozens.

## The buttons

The intents are `AudioPlaybackIntent`s. The system performs them in the app's process, launching it in the background if needed. A plain `AppIntent` would run in the extension, where it can do nothing.

- **TRAP: the bodies are behind `VIBE_APP`**, because the extension cannot link an app class. They are no-ops there. If a button does nothing, first check that its intent is still an `AudioPlaybackIntent`.
- **TRAP: a tap can be the app's launch.** `VibeWidgetTransport.perform` continues in the foreground when no scene has connected. It then always waits for the launch restore to settle (`performWhenLaunchOpenSettled`). A local restore usually wins that race, so skipping the wait seems to work. A cloud folder loses it, and the tap lands on an empty playlist.
- **TRAP: intent titles are literals**, because the metadata processor reads them statically. Each key and English default must match its `STR_WIDGET_INTENT_*` entry in `VibeStrings.h`.
- The seek intent maps a zone to the zone's centre. It drops a tap whose `trackKey` is not the displayed track's.
