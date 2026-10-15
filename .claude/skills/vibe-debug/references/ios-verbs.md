# iOS channel and touch-driver verbs

The `debug-ios.sh` verbs iOS adds or answers differently, the `drive-ios.sh` gestures, per-session simulators and the build lock, and iPad. The shared verbs in `references/mac-verbs.md` (`play_index`, `check_consistency`, `dump_stats`, `dump_metadata_progress`, the cloud and loading verbs, `work_tally`) answer here too. `SKILL.md`'s "iOS: the simulator loop" carries the rules and traps.

## The channel

Same file protocol and one-JSON-object contract as the mac's, with **no CLI client**. The simulator app's container tmp is a plain host directory, so `debug-ios.sh` writes the command file and reads the reply. Exit codes match the mac client (0 ok, 1 no response, 2 command error). Action replies can lag pipeline work, so follow with `dump_state`. App side: `Vibe/Debug/iOS/DebugiOSEntry.m`, `DebugiOSVerbs.m` and `DebugDropboxVerbs.m` over `Vibe/Debug/Channel/DebugChannel.m`.

`dump_state.playlist.structureGeneration` advances on a replacement, including a reopen of the same folder. `playlist.folder` names the landed folder. Wait for both and the intended row before measuring playback progress after `open`.

```bash
S=.claude/skills/vibe-debug/scripts/debug-ios.sh
"$S" dump_state          # {player, currentTrack, playlist, ui, fx, settings, widget: {placed}}. player.buffering is a stream's hold; player.bufferingRecord {holds, releases, stalls, heldSeconds} counts since launch, so diff it. ui carries waveformProgress, waveformOverscroll (points past an end, + past the start, - past the end), waveformScrollGeom ([offset, min, max, contentWidth]), waveformBaked, waveformLoading, openSlow, bufferingShown (Buffering… and its spinner, 0.5 s into a hold: on the codec line while it has text, else the artist line), isScrubbing, parked, sceneActive, routePickerUp, playerPresentation ("minimized"|"full"), miniPlayerShown, selectedTab, libraryEmpty, pasteRowShown, pasteRowResolving and linkSheet. settings.widgetWaveformStyle null means Match app
"$S" dump_equalizer      # references/equalizer-counters.md; set_equalizer_mode likewise
"$S" dump_audio_path     # the render chain as on the mac, minus the device stage
"$S" dump_now_playing    # {hasInfo, title, artist, duration, elapsed, rate, hasArtwork}: the mac verb minus playbackState
"$S" dump_view_tree      # {windows: [{class, frame, keyWindow, rootViewController, contentView: {…, subviews}}]}: label text included
"$S" dump_art            # {currentIndex, window, held, waveformTarget, pages: [{index, title, metadata, art, needsLoad, loading, inWindow, cellUp, waveformProgress, waveformFilled, waveformComplete}]}: the pager's art window. The only way to tell "not decoded yet" from "no art", since both draw the placeholder. A page with art:false may have no usable artwork. Compare its metadata, loading state and cache window before diagnosing a missed prefetch
"$S" dump_screenshot     # {ok, path, pointWidth, pointHeight, scale}: in-process render into the container; the host reads the path directly. Blurs only approximate; `simctl io screenshot` is the ground truth
"$S" play_pause          # compact {ok, state, index, count, position, parked, playerPresentation}; next, previous and seek answer the same
"$S" seek 90             # seconds, through the scrubber's didSeek path, so the seek-in-flight guard behaves as a real release
"$S" set_pause_at_track_end on  # {ok, pauseAtTrackEnd}: writes Settings > Playback > On track end and applies it at once. dump_state.settings carries it beside crossfadeMilliseconds
"$S" open <path>         # a file inside the container (seed via launch-ios.sh), through FolderSession's open-in-place path. Replaces the playlist, plays and expands the card
"$S" append <path>       # the same, added to the end through FolderSession.addURLs:. Nothing plays; files already listed are skipped; an add onto an empty playlist becomes an open
# TRAP: both take a path inside the container, which is not security-scoped, and the data container's UUID changes on every install. Re-resolve it (simctl get_app_container … data) before each call
"$S" expand_player       # the card without a gesture; also minimize_player
"$S" check_waveform_preparation refresh  # refresh|transition|artwork|interaction|color: live regressions for neighbor preparation; {ok, measured checks}
"$S" set_waveform_zoom 0.12  # the DJ zoom (0-1 = fraction of the track visible) through the released-pinch callback. {waveformZoomRequested, waveformZoomEffective} differ when the layout cannot draw the depth asked
"$S" set_waveform_style wiggle_centered  # {ok, waveformStyle}: the persisted identifier, never the display name; an unknown one lists the valid set. Wiggle is `wiggle_centered` whether Centered is on or off; Centered reads back as settings.waveformCentered
"$S" set_fx_pad 0.8 0.5  # the FX pad's position through the model (x: reverb, then delay past 0.5; y: the low cut's cutoff), or `set_fx_pad off`. Replies {ok, fx}. dump_state.fx is the FX intent per stage (intent, enabled, active, gateTarget), delayTapBPM and unitRenders. ui.fxPadShown follows settings.audioFXEnabled; ui.fxPadEngaged is a finger on a pad
"$S" set_output_route airplay "Living Room"  # draws the route indicator as any kind (none|speaker|receiver|wired|bluetooth|airplay|carplay|other), model untouched. A page reconfigure or real route event overwrites it, so set it just before the check
"$S" select_tab playlist # or favorites, files, search
"$S" dump_favorites      # {favorites: [{name, location, path}]}: the starred folders as drawn; nothing is resolved
"$S" tap_favorite_star   # toggles the open folder in and out of favorites; the add is asynchronous (SKILL.md). Errors with no folder open
"$S" open_favorite 0     # index into dump_favorites.favorites, through the row's didSelectRow:. Needs select_tab favorites first, since the provider is lazy
"$S" append_favorite 0   # the same row added instead of opened. Same caveat
"$S" search zebra        # {ok, query, materiallyVisible, filesWalkRunning, sections:[{header, rows:[{text, secondaryText}]}]}: replies once the table settles. The only way to query, since nothing synthesizes keystrokes into the field. Needs select_tab search first
"$S" open_search_hit 0   # index into search.sections[1].rows (Local): plays that file alone with the card up
"$S" dump_dropbox        # {linked, fake, accountID, accountName, accountPath, playlistTracks:[{dropboxPath, placeholder, stream}]} (Loading/iOS/Dropbox/AGENTS.md). A real sign-in is Dropbox's own web sheet, which only a human can fill
"$S" set_fake_dropbox <directory>|off [<transfer-seconds>]   # a host directory answers as the Dropbox account over the client's HTTP boundary (VibeFakeDropbox.h), linked at once. Downloads are paced in 64 KB pieces over transfer-seconds; closed ranges answer at once. Installing again swaps the tree and clears faults and log without rebuilding the client's sessions (VibeFakeDropbox.m's TRAP). To open a folder no listing has made, mkdir it under accountPath and `open` it
"$S" fake_dropbox_fault <kind> [file=<basename>] [after=<bytes>] [seconds=<s>] [rate=<bytes/s>]   # {ok, faults}. Kinds: stall (until `fake_dropbox_fault resume`), drop, rev-change, throttle, expired-token, tail-fail, slow-tail, slow-tags, rate, latency; `clear` drops them all. VibeFakeDropbox.h has each kind's effect
"$S" dump_fake_dropbox   # {fake, requests, downloads:{whole, resume, ranged, tail}, faults, transfers, log:[{seq, t, file, kind, range, rev, status, delivered, outcome}]}: the last 200 download requests. delivered is what the fake handed the URL loading system, so a resend's Range can start below a drop
"$S" open_url https://fake.vibe.test/song.mp3   # {ok, file, placeholder} or {ok: false, linkError, code, status}: the Files tab's Open URL road. Replies when the resolve settles; poll dump_state and dump_row_loading
"$S" open_url_sheet show|type <text>|paste <text>|open|cancel   # drives Open URL's sheet on the add sheet's browser while it is up, else the Files tab's (select_tab files first). dump_state.ui.linkSheet is {shown, text, resolving, openEnabled}. A failure leaves an error alert that only a tap or a relaunch clears
"$S" paste_link <text>   # what a tap on the paste row does once the clipboard is read, without the clipboard. ui.pasteRowShown and pasteRowResolving report the row
"$S" set_clipboard <text>|clear   # writes the clipboard from inside the app, which never raises the Allow Paste prompt. TRAP: `xcrun simctl pbcopy` writes nothing on the iOS 27 simulator. To see the prompt, another process must own the clipboard. The prompt blocks the touch driver until a relaunch
"$S" set_fake_http <host directory>|off [<transfer-seconds>]   # a common verb (references/mac-verbs.md); build/streaming-fixtures serves as is
"$S" dump_layout_anchors # {navigationBar, firstRow, tabBar, strip, contentOffsetY, adjustedContentInset, tabsSafeAreaInsets, topSafeAreaInsets, tabsHidden, backdropScale, cardOffset}: where the selected tab's live chrome sits. Under a moving card every anchor must hold still (iOS/AGENTS.md's backdrop TRAP)
"$S" sample_layout_anchors <seconds>   # records the anchors every frame; read the series with dump_layout_samples. scripts/check-layout-stability.sh wraps both around a gesture
"$S" sample_frame_rate <seconds>   # then dump_frame_rate: {averageHz, frames, hitches, worstIntervalMs, maximumHz}. The simulator caps at 60. On a phone, launch with --frame-rate-probe and the report lands in the log every five seconds
"$S" dump_search         # {roots, folders}: the search scope before FileSearchIndex prunes nested and duplicate roots, so a folder can appear twice. Starred folders join once the search screen has been visited
"$S" add_search_folder <dir>  # {ok, added, roots, folders}: widens the scope as Settings would; remove_search_folder <index>. added:false means a root already covers it
"$S" set_fake_cloud 4 100     # references/test-audio.md
"$S" set_slow_volume stall    # references/mac-verbs.md
"$S" clear_caches        # blocks until both PINCaches are empty; waits its own 20 s window
```

`check_waveform_preparation` preconditions. Run each on a freshly opened folder after `file_cache` has primed its waveforms. Refresh and color need nothing else. Interaction needs an expanded, paused card whose page shows its baked waveform. Transition and artwork need an expanded, paused local playlist of two or more with a prepared neighbor that has no live cell. Run transition on a fresh launch too, since cells already in the reuse pool hide a miss. Artwork also needs colored art on that neighbor and the `album_art` waveform theme.

The `search` reply reports the matching rows. `dump_view_tree` also exposes the drawn table.

TRAP: **`dump_view_tree` frames are each view's frame in its superview, with no scroll offset.** Summing them from the root puts a table's rows tens of points too high. Aim taps from `xcrun simctl io "$UDID" screenshot` instead: points = screenshot px × (device point height ÷ image height).

## What the simulator cannot show

Interruptions (calls, Siri), route changes, background audio past lock and the lock-screen card need a real device. The route picker opens on a tap (`ui.routePickerUp`), but the simulator offers no second route, so only `set_output_route` shows the other renderings. Report these as unverified rather than driving a phone.

## Feeding audio

```bash
UDID=$(.claude/skills/vibe-debug/scripts/sim-udid.sh)
DATA=$(xcrun simctl get_app_container "$UDID" com.commonwealthrecordings.Vibe data)
xcrun simctl openurl "$UDID" "file://$DATA/Documents/Music/tone-long.wav"   # open-in-place a seeded file
xcrun simctl io "$UDID" screenshot shot.png                                   # device pixels (3x), top-left origin
```

## The touch driver

`drive-ios.sh` runs gestures through the resident `VibeiOSDriver` XCUITest (`Tests/iOSDriver/`) over the same file protocol. It is the only touch path on iOS. Its header lists every gesture and its arguments.

- **Latency** is about 0.7 s per gesture. `start` takes about 10 s once the driver is built. XCTest reads only an app it launched or activated, so the driver activates the app on its first gesture and on `attach`. `launch-ios.sh` sends `attach` after every relaunch while a driver is up. TRAP: after a relaunch by anything else, send `drive-ios.sh attach`. Otherwise a gesture retries snapshots for 60 s and then relaunches the app itself, playlist gone and without the silencing flags.
- **TRAP: `drive-ios.sh start` launches nothing.** It installs the built app when it differs, which kills a running one, and returns with no app up. Follow it with `launch-ios.sh`. State set after that (a selected tab, a fake Dropbox, a pushed screen) survives the first gesture.
- One session per device: `start` kills only this device's previous driver.
- `pinch scale velocity` finds the scrubber by accessibility identifier, since XCUITest has no coordinate multi-touch. It needs the card expanded.
- `type "key"` drives the keyboard. The keyboard sits in its own window, so a tap aimed at a key hits the app behind it.
- `springboard tap|press|drag|type|tap_label|tree …` targets the Home screen and widget gallery. Start with `VIBE_SIGN_SIM=1` for widget work.
- The runner disables XCTest's per-event quiescence waits, which never settle under Vibe's display link. That reaches XCTest internals and degrades to slow-but-working if an Xcode update renames them (`Tests/iOSDriver/VibeiOSDriverTests.m`).

## Staleness: `sim-install.sh`

`sim-install.sh` is the one home of "the installed app matches the built one". `launch-ios.sh` and `drive-ios.sh start` both call it, and it installs only when the bundles differ. It hashes each file’s path and contents in both bundles. It does not compare mtimes. `drive-ios.sh status` reports `appStale` as the backstop, since a driver session outlives any number of rebuilds.

## Per-session simulators and the build lock

`sim-udid.sh` names the device `Vibe-<dir>-<hash>` from the checkout path plus `CLAUDE_CODE_SESSION_ID`. Without `CLAUDE_CODE_SESSION_ID`, callers in one checkout share a device. An explicit `VIBE_SIM_UDID` or `VIBE_SIM_NAME` can isolate them. Driver files live in `build/ios-driver/<UDID>`. Devices from ended sessions are deleted on every `sim-udid.sh` call once shut down and untouched for 12 hours. `VIBE_SIM_UDID` pins a device. `VIBE_SIM_NAME` renames it.

Same-checkout sessions share `build/DerivedData`, `Vibe.xcodeproj` and the built `.app`, so builds and installs serialize through `scripts/build/build-lock.sh`. `drive-ios.sh start` holds the lock across `xcodegen generate`, the build and the install. A stuck lock is `build/.build-lock`. It names its holder's pid and is broken automatically once that process is gone. A waiting caller says so once on stderr.

## iPad

The target is device family `1,2`, and the app is a resizable iPadOS window. Wider than tall shows the landscape layout, taller than wide the portrait one, and a window under 600 pt tall the card's compact layouts (`Vibe/iOS/Player/AGENTS.md`). `sim-udid.sh` models iPhones only, so `xcrun simctl create` an iPad and export `VIBE_SIM_UDID`. `drive-ios.sh rotate left|right|portrait` flips orientation. Assert from `dump_screenshot`'s `pointWidth` and `pointHeight`, and check the current track survived. Windowed mode is enabled per device in Settings → Multitasking & Gestures. The iOS Simulator control tool's `touch_path` drags the resize corner (hold about 0.6 s first) in portrait device points even when rotated. TRAP: in a rotated, windowed scene `drive-ios.sh tap` reports ok and lands nowhere. Tap with the control tool, aimed from its screenshot.

## Streaming scenarios

`scripts/dropbox-streaming.sh [-o <out-dir>] [-j <simulators>] [scenario ...]` drives Dropbox streaming end to end over the fake. Its header lists every scenario, its needs and its outputs. Run it after `launch-ios.sh`. Each scenario opens a fresh fixture folder from `build/streaming-fixtures`, writes every poll to `<out-dir>/<scenario>.jsonl` and the numbers and failed checks to `summary.json`, and exits nonzero on any failed check. A failed setup command fails its scenario as `setup: <command> -> <reply>`. The default run spreads the scenarios over three simulators (`-j 1` for this one alone; `VIBE_STREAMING_KEEP=1` leaves the extra ones up) and takes about two and a half minutes. It replaces the playlist and leaves `set_audio_loading` at its defaults.
