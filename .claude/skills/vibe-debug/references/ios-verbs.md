# iOS channel and touch-driver verbs

Every `debug-ios.sh` verb with its reply schema, the `drive-ios.sh` gesture verbs and their costs, the iPad path, and how per-session simulators and the build lock work. Read when driving the simulator beyond `dump_state`; `SKILL.md`'s "iOS: the simulator loop" carries the rules and traps.

## The channel

Same file protocol and one-JSON-object contract as the mac's, with **no CLI client**: the simulator app's container tmp is a plain host directory, so `debug-ios.sh` writes the command file and reads the reply, and the app's tmp watcher answers. Exit codes match the mac client (0 ok, 1 no response, 2 command error). Replies to action verbs are read synchronously and can lag pipeline work — follow with `dump_state`. App side: `Vibe/Debug/iOS/DebugCommands.m` over `Vibe/Debug/DebugChannel.m`; the cross-platform verbs live once in `Vibe/Debug/DebugCommonVerbs.m`.

```bash
S=.claude/skills/vibe-debug/scripts/debug-ios.sh
"$S" dump_state          # {player, currentTrack, playlist, ui, settings} — ui includes waveformProgress, waveformOverscroll (points past an end: + past the start, - past the end; the only way to assert the scrubber's rubber band), waveformScrollGeom ([offset, min, max, contentWidth] — tells "resting at an end" from "pinned and refusing to give"), waveformBaked, isScrubbing, parked, foreground, routePickerUp, and the shell: playerPresentation ("minimized"|"full"), miniPlayerShown, selectedTab, libraryEmpty
"$S" dump_equalizer      # references/equalizer-counters.md; set_equalizer_mode likewise
"$S" dump_now_playing    # {hasInfo, title, artist, duration, elapsed, rate, hasArtwork} — the mac verb minus playbackState
"$S" dump_view_tree      # {windows: [{class, frame, keyWindow, rootViewController, contentView: {…, subviews}}]} — UILabel text and button labels included
"$S" dump_art            # {currentIndex, window, held, pages: [{index, title, metadata, art, needsLoad, loading, inWindow, cellUp}]} — the pager's art window. The ONLY way to tell "not decoded yet" from "no art": both draw the vinyl placeholder. held past the budget, or a page landing with art:false, is the prefetch failing to keep up
"$S" dump_screenshot     # {ok, path, pointWidth, pointHeight, scale} — in-process render into the container; the HOST reads the path directly, no TCC. UIVisualEffectView blurs only approximate; `simctl io screenshot` is the ground truth
"$S" play_pause          # compact {ok, state, index, count, position, parked}; also next, previous
"$S" seek 90             # seconds, through the scrubber's didSeek path, so the seek-in-flight guard behaves as a real release
"$S" set_pause_at_track_end on  # a common verb: {ok, pauseAtTrackEnd} — writes Settings > Playback > On track end and applies it at once (re-parks or drops the prefetched successor). Read back in dump_state.settings, beside crossfadeMilliseconds (the stored choice; player.crossfadeMilliseconds is what the player holds)
"$S" open <path>         # a file INSIDE the container (seed via launch-ios.sh); the FolderSession open-in-place path. Replaces the playlist, plays, AND expands the card
"$S" append <path>       # a common verb: the same file or directory ADDED to the end of the playlist instead of replacing it, through FolderSession.addURLs:. Nothing plays, the tab and the card stay put, and files already in the playlist are skipped. An Add onto an empty playlist is promoted to an open
# TRAP: BOTH of these take a path INSIDE the container, which is not security-scoped — the scope round trip goes unexercised — and the data container's UUID ROTATES on every install, so a path cached from an earlier run fails their existence check. Re-resolve it (simctl get_app_container … data) before each call
"$S" expand_player       # the card without a gesture; also minimize_player. The shell presents it only on an open, so this is the other way in
"$S" set_waveform_zoom 0.12  # the DJ zoom, 0-1 = fraction of the track visible, through the delegate callback a released pinch takes, so it fans out across pages and persists. Replies {waveformZoomRequested, waveformZoomEffective}; they DIFFER when the layout cannot draw the depth asked — the only way to check the clamp
"$S" set_output_route airplay "Living Room"  # draws the card's route indicator as any kind (none|speaker|receiver|wired|bluetooth|airplay|carplay|other), model untouched — the simulator reports the built-in speaker and nothing else. A page reconfigure or real route event overwrites it, so set it immediately before the check
"$S" select_tab playlist # or favorites, files, search (the UISearchTab circle)
"$S" dump_favorites      # {favorites: [{name, location, path}]} — the starred folders as the Favorites tab draws them; nothing is resolved, so a favorite on a dead path still lists
"$S" tap_favorite_star   # what tapping the star on the Playlist tab's bar does: toggles the open folder in and out of favorites. TRAP: the ADD is asynchronous (the bookmark is minted off main), so ok:true means the handler ran — poll dump_favorites for the row. Errors with no folder open
"$S" open_favorite 0     # index into dump_favorites.favorites; drives the row's own didSelectRow:, so the resolve, the open and the unreachable-folder alert are the tap's. Needs select_tab favorites first — the tab's provider is lazy
"$S" append_favorite 0   # the same row ADDED instead of opened: the screen's own openFavorite:appending:YES, so resolve and alert are the row action's. Same lazy-provider caveat
"$S" search zebra        # {query, sections:[{header, rows:[{text, secondaryText}]}]} — runs a query and replies once the table settles (the files half answers off a walk). The field takes KEYSTROKES neither this channel nor the touch driver synthesizes, so this is the only way to query. Needs select_tab search first
"$S" open_search_hit 0   # index into search.sections[1].rows — taps a FILE hit: its folder becomes the playlist with that file playing
"$S" dump_search         # {roots, folders} — the search scope. roots: the open BASE folder and every folder an append added, the folders added in Settings, the app's Documents, plus the STARRED folders once the search screen has been visited (FavoritesStore resolves their grants on that appearance); it is the composition before FileSearchIndex prunes nested and duplicate roots, so a folder can legitimately appear twice — re-appending the base folder is one ordinary way to see that. folders: just the added ones, the rows Settings shows
"$S" add_search_folder <dir>  # {ok, added, roots, folders} — widens the scope as picking a folder in Settings would; remove_search_folder <index into dump_search.folders>. The channel cannot drive the system document picker (another process's UI), so these are the only way to set a scope up. added:false = a persistent root already covers it, not a failure. NOT security-scoped — SKILL.md's trap
"$S" set_fake_cloud 4 100   # a common verb: references/test-audio.md
VIBE_DEBUG_TIMEOUT=20 "$S" clear_caches   # blocks until both PINCaches are empty
```

The search screen's index lives in its view controller, so what a query matched is read from `dump_view_tree`: the playlist section's rows draw `displayTitle` (no extension), the files section's the filename over the containing folder.

## What the simulator cannot show

Interruptions (calls, Siri), route changes (headphone unplug), background audio past lock, and the lock-screen card need a real device; the `AVAudioSession` code runs but is not exercised faithfully. The card's route indicator draws and its picker opens on a tap — `dump_state`'s `ui.routePickerUp` flips — but the simulator offers no second route, so the sheet shows nothing and AVKit never sends the did-end edge; only `set_output_route` shows the off-device renderings there. Per `SKILL.md`'s simulator-only rule, report these as unverified rather than driving a phone.

## Feeding audio

```bash
UDID=$(.claude/skills/vibe-debug/scripts/sim-udid.sh)
DATA=$(xcrun simctl get_app_container "$UDID" com.commonwealthrecordings.Vibe data)
xcrun simctl openurl "$UDID" "file://$DATA/Documents/Music/tone-long.wav"   # open-in-place a seeded file
xcrun simctl io "$UDID" screenshot shot.png                                   # device pixels (3x), top-left origin
```

## The touch driver

`drive-ios.sh` executes gestures through the resident `VibeiOSDriver` XCUITest (`Tests/iOSDriver/`, not part of `VibeTests`) over the same file protocol — the only sanctioned touch-synthesis path on iOS. Its header comment lists every gesture verb and its arguments.

- **Latency**: ~1s per gesture at steady state. The FIRST gesture after `start` or an app relaunch pays the accessibility attach, which can run tens of seconds — send a throwaway `tap` on dead space as a warm-up. The runner disables XCTest's per-event quiescence waits (a playing app never idles under Vibe's display link; without this every gesture costs ~2 minutes); that reaches XCTest internals, harness-only, and degrades to slow-but-working if an Xcode update renames them (`Tests/iOSDriver/VibeiOSDriverTests.m`).
- Run `start` before `launch-ios.sh` so the app it launches is the one the driver attached to; either order installs correctly, this one skips a relaunch. If the app is dead, the next gesture relaunches it with the silencing flags.
- One session per DEVICE: `start` kills only this device's previous driver.
- `pinch scale velocity` is the one element-targeted verb — XCUITest has no coordinate multi-touch, so it finds the scrubber by accessibilityIdentifier and needs the card expanded.
- `type "key"` is how the keyboard is driven: it sits in a window of its own, so a tap aimed at a key hits the app BEHIND it.
- `input.swift` clicks on the Simulator window are obsolete for this.

## Staleness: `install-ios.sh`

`install-ios.sh` is the single home of "the installed app matches the built one"; `launch-ios.sh` and `drive-ios.sh start` both call it, and it installs only when the bundles differ, which is what makes it safe with a driver session live. It exists because `xcodebuild test` leaves the app-under-test it built on disk without installing it, so `start` installs after the build finishes, never before. `drive-ios.sh status` reports `appStale` as the backstop, since a driver session outlives any number of rebuilds. Staleness is decided by hashing every file of both bundles (~80ms), never by mtime: a `make strings` run counts, a relink that changed nothing does not — every xcodebuild run relinks the executable even when it compiles nothing, so an mtime rule fired for every other session in the checkout whenever one built.

## Per-session simulators and the build lock

`sim-udid.sh` names the device `Vibe-<dir>-<hash>` from the checkout path plus `CLAUDE_CODE_SESSION_ID` (one stable device per checkout outside Claude Code). Each session therefore has its own app container, debug channel and touch driver (command dir `build/ios-driver/<UDID>`, session kills scoped to that device). Stale devices from ended sessions are GC'd on the next create (Shutdown and untouched for a day). `VIBE_SIM_UDID` pins a device; `VIBE_SIM_NAME` renames.

What same-checkout sessions share is `build/DerivedData`, `Vibe.xcodeproj` and the one built `.app`, so builds and installs are serialized by `scripts/build-lock.sh`: `drive-ios.sh start` holds it across `xcodegen generate`, the `xcodebuild test` build and the install, and drops it once the runner is up. Without it `xcodegen` rewrote the project under another session's live `xcodebuild`, two builds clobbered one products directory, and `simctl install` copied a bundle another session's linker was midway through writing. A stuck lock is `build/.build-lock`; it names its holder's pid and is broken automatically once that process is gone.

## iPad

The target is device family `1,2`; the app is a resizable iPadOS 26 window (min 320×480, `VibeiOSSceneDelegate`): wider-than-tall shows the landscape layout, taller-than-wide the portrait one. `sim-udid.sh` models iPhones only, so `xcrun simctl create` an iPad and export `VIBE_SIM_UDID`; all three scripts honor it. `drive-ios.sh rotate left|right|portrait` flips orientation (there is no simctl rotation); assert from `dump_screenshot`'s `pointWidth`/`pointHeight` and check the current track index survived. iPadOS windowed mode (floating windows, corner-drag resize) is enabled per device in Settings → Multitasking & Gestures, not scriptable, so window-resize testing is manual.
