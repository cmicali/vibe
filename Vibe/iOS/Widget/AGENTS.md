# The widget's app side

The Home Screen and Lock Screen widget runs in its own process, the `VibeWidget` extension (`VibeWidget/AGENTS.md`). The publisher and the snapshot it writes are vibe-libs' `system/Widget` and `system/WidgetState`, whose `AGENTS.md` files hold the snapshot's layout, the writing order, and the waveform bake. This directory holds what stays Vibe's: the app group's name, WidgetKit's calls, and the buttons' intents.

| File | Role |
| --- | --- |
| `VibeWidgetIntents.swift` | The widget's buttons, and `VibeWidgetActions`, what they ask of the app. **Compiled into both targets.** |
| `VibeWidgetGroup.h` | Vibe's app group and read signal, as C string macros so Swift can read them. **Compiled into both targets.** |
| `VibeWidgetReloader.swift` | WidgetKit's reload and placed query, which have no Objective-C API. `PlaybackController` hands them to the publisher as blocks. Keep it small. |

`project.yml` names the shared files one by one. The rest of the directory reaches for app classes and must never join the extension. The app takes `VibeLibsWidget`, and the extension takes `VibeLibsWidgetState` alone.

## What Vibe hands the publisher

`PlaybackController` owns one `WidgetPublisher` and feeds it from the Now Playing publish (`PlaybackController+NowPlaying.m`).

- **Each track is a `VibeWidgetTrack`.** `AudioTrack` adopts it in a category with no code (`PlaybackControllerInternal.h`). The publisher reads `displayTitle`, `displayArtist`, and `cachedArt` on every tick, and each is a cached read.
- **The envelope is offered once it is complete, and only for the current track** (`noteCompleteWaveform:forTrack:`). The card's pages also decode their neighbors, and a neighbor's offer would replace the current track's.
- **The app group and the read signal** come from `VibeWidgetGroup.h`. The app sets them at launch (`VibeiOSAppDelegate`), before any scene makes the publisher, whose init asserts them. The extension sets them when its widget bundle is made.
- **WidgetKit's two calls** are `VibeWidgetReloader`'s, wrapped in blocks.
- **The strip's look.** `PlaybackController.pushWidgetWaveformSettings` pushes the style, Centered, and the playhead line at launch and on every `VibeDisplaySettingsDidChangeNotification`. Both pushes resolve the look through `WaveformTheme+Settings`, so the card and the widget follow one rule. The theme, the custom colors, Centered and Playhead line are the widget's copies of the card's settings, read with `widget:YES` (`Common/AGENTS.md`). Under Match app every one of them reads as the card's.
- **The buttons act through one protocol object.** Vibe's `VibeWidgetActions` is `VibeWidgetSceneActions`, which `VibeiOSSceneDelegate.installWidgetActions` installs at launch. Each call goes to the connected scene.

## The buttons

The transport and seek intents are `AudioPlaybackIntent`s. The system performs them in the app's process, launching it in the background if needed. A plain `AppIntent` would run in the extension, where it can do nothing.

The playlist button's intent, `VibeShowPlaylistIntent`, is a plain `AppIntent` whose `supportedModes` is `.foreground`. The system opens the app and performs it there. It lowers the card and shows the Playlist tab's list (`PlaybackShellHost.showPlaylist`), even over Search. A launch already lands there. So with no connected scene it does nothing. It also does nothing while a sheet or alert is up, so the app only comes forward.

- **TRAP: the bodies act only through the installed `VibeWidgetActions`.** The extension installs none, so they are no-ops there. If a transport button does nothing, first check that the app installs its actions before an intent can run. Then check that its intent is still an `AudioPlaybackIntent`. If the playlist button only opens the app, check that its intent is still `.foreground`.
- **TRAP: a tap can be the app's launch.** `VibeWidgetTransport.perform` continues in the foreground when no scene has connected. It then always waits for the launch restore to settle (`widgetWhenRestored:`, which is `performWhenLaunchOpenSettled` in Vibe). A local restore usually wins that race, so skipping the wait seems to work. A cloud folder loses it, and the tap lands on an empty playlist.
- **TRAP: intent titles are literals**, because the metadata processor reads them statically. Each key and English default must match its `STR_WIDGET_INTENT_*` entry in `VibeStrings.h`.
- The seek intent maps a zone to the zone's centre. It drops a tap whose `trackKey` is not the displayed track's, which `WidgetPublisher.trackKeyForTrack:` spells through vibe-libs' `VibeWidgetTrackKey`.
