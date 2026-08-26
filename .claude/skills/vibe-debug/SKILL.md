---
name: vibe-debug
description: Launch, drive, inspect, and visually verify the Vibe app — macOS, and the iOS simulator loop (launch-ios.sh, the debug-ios.sh command channel, the drive-ios.sh touch driver for taps and drags, silent flags, screenshots, host-side log streaming). Use whenever a change needs end-to-end verification, a screenshot of the running app, playback/UI state inspection, or appearance (light/dark) testing.
---

# Debugging and verifying Vibe

All debug tooling compiles into **debug builds only** (`Vibe/Debug/`), and XcodeGen generates `Vibe.xcodeproj`, which is not checked in, so generate and build first. `make build` and `scripts/build.sh` write to `build/DerivedData`, which is exactly where `launch.sh` looks:

```bash
make build CONFIG=Debug          # or: scripts/build.sh Debug
# by hand: xcodegen generate && \
#   xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
#       -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Debug/Vibe.app
V="$APP/Contents/MacOS/Vibe"
```

## Launching: pitfalls first

```bash
.claude/skills/vibe-debug/scripts/launch.sh [audio-file ...]   # quit, open -a, wait until ready
```

`launch.sh` relaunches the build and polls the debug channel until the app answers, then prints its `dump_state` JSON. No guessed sleeps. It honors `$VIBE_APP` when the app lives somewhere other than `build/DerivedData`.

**It launches with audio off the hardware.** Two independent debug-only argv flags, and `launch.sh` passes both by default: `--no-audio-hw` runs the engine in manual rendering mode with a real-time-paced render pump — no CoreAudio output device is ever opened, so a test run cannot trigger macOS's automatic AirPods switching, while playback, position, waveform and FX state all behave normally — and `--silent` zeroes the main mixer, which mutes playback but still opens and drives the real output device. Use both (the default) unless a test genuinely needs hardware: `--silent` alone for real-HAL behavior without noise (device switching against real devices, engine config-change notifications, output-latency-dependent timing), neither for audible playback. `dump_state` reports them as `player.silent` and `player.noAudioHw` — plus `player.manualRendering`, which is what actually happened rather than what argv asked for: `enableManualRenderingMode` can fail, and the engine then opens the output device as usual, so **trust `manualRendering`, not `noAudioHw`**. Set `VIBE_AUDIBLE=1` to use real hardware and hear playback.

**The default launch cannot validate the live equalizer.** `--silent` zeroes `mainMixerNode.outputVolume`, and the FFT is intentionally downstream, so a healthy run publishes flat zero bands and draws dots. `--no-audio-hw` **by itself** preserves the manually rendered signal and the reactive tap; use a manual launch with only that flag when functional EQ verification must stay off hardware. Do not use that run for audible-start-latency claims — the manual pump timing warning below still applies. `dump_equalizer` reports the launch flags and is the first check before treating flat bars as a defect.

**Do NOT measure START LATENCY under `--no-audio-hw` either.** The render pump paces the engine itself, and a file whose sample rate differs from the manual render format takes far longer to start advancing `position` than it does on real hardware. Measured on the same 20MB WAV, resampled: 44.1kHz first moved at 27ms, 48kHz at 515ms — and a 13MB 48kHz MP3 sat at position 0.000 for **2.7 seconds** before advancing. On a real device (`VIBE_AUDIBLE=silent`) all of them start in ~40ms. Nothing is wrong with the app; the pump is not a clock. Anything about click-to-first-sound needs `VIBE_AUDIBLE=silent`, which opens the real device with the mixer zeroed.

**Time to first audio is recoverable exactly, without instrumentation.** `position` is the audio actually rendered, so at poll time `T` with position `P`, playback began at `T - P` — the answer does not depend on how coarsely you polled. Measured that way on a real device, a single open settles in ~25ms and audio flows ~40ms after the command, independent of file size (2.4MB to 202MB), container, and entry point (`open`, `play_index`, `drag_drop`). Note `dump_state`'s `player.state` reports the pending *intent*, so it reads `playing` during a cloud open that has not landed; use position movement, not the state string, to time a cloud open.

**Do NOT use `--no-audio-hw` to test or verify the Now Playing integration — it suppresses it outright.** The flag's promise is that a test run leaves the system's audio state alone, and publishing to `MPNowPlayingInfoCenter` breaks that by itself: registering as the active media app is enough for macOS to pull auto-switching AirPods over from another device, with no output device ever opened. So under the flag nothing is published and no remote commands are registered, and `dump_now_playing` reports `hasInfo: 0` with `playbackState: unknown` — correct behavior, not a bug. Anything touching Now Playing, Control Center, the media keys or Bluetooth transport must launch with `VIBE_AUDIBLE=1` (or without the flag), and will then take the AirPods with it.

To launch by hand instead:

- **Keep manual launches off the hardware too**: `open -a "$APP" <files> --args --no-audio-hw --silent`. `--args` must come last, since everything after it becomes the app's argv. The direct-exec second-instance path takes argv natively: `"$V" --no-audio-hw --silent &`.
- **Feed it a file with `open -a "$APP" <file>`.** The App Sandbox denies reading raw `argv` paths, because there is no Launch Services grant, so `"$V" <file>` parses the path but the open fails. `open` grants access properly. An already-running instance can also load files with `--debug-cmd open <path>`, but that grants no sandbox access either, so it suits container paths or paths already granted. `open -a` works mid-session too and remains the way to feed arbitrary files.
- **Check which binary is running before you trust any observation.** If the user has Vibe running from Xcode, Launch Services routes `open -a` and `open -n` to that instance, and you will test a stale build with no error at all. Verify with:
  ```bash
  ps -o pid,command -p $(pgrep -x Vibe)
  ```
  If the path is not your build, either ask the user to stop the Xcode session or run a **second instance** by executing the binary directly: `"$V" &`. That bypasses Launch Services but cannot open files, and it restores prior window state. A raw-launched instance is a child of your shell and dies when the shell exits, so treat it as scoped to one command block, or relaunch per test.
- **Never `pkill` an instance Xcode is debugging.** The debugger traps SIGTERM and *stops* the process instead of ending it, so it survives, keeps its pid, and answers nothing — every later `--debug-cmd` then burns its full timeout, which reads as the app hanging. `launch.sh` handles this: it ends a running instance with `--debug-cmd quit` (no signal, so a debugged instance quits cleanly and Xcode ends the session), signals only an instance no debugger is attached to, and refuses outright — in milliseconds, with a message — when one is suspended under a debugger. To do it by hand, `quit` first, and check for the trap with `ps -o stat= -p $(pgrep -x Vibe)`: a leading `T` means stopped, so continue or stop it in Xcode (⌘.).

## Test audio files

Use the generated files in `Assets/test_audio_files/` (gitignored) rather than synthesizing your own; `.claude/skills/vibe-debug/scripts/generate-test-audio.sh` creates them (idempotent, `--force` regenerates). Tones for transport and playlist tests, a FLAC, three MP3s (CBR, VBR, ID3v2-tagged with art — these need `lame` or `ffmpeg`, since `afconvert` cannot encode MP3), two tagged files with art, five exact-tempo loops and four in known keys. Which file for which test, plus how to simulate a slow cloud open (`set_fake_cloud`) and the one-shot BPM/key scans: **`references/test-audio.md`**.

## Equalizer counters

`dump_equalizer` has the same schema on both apps: `{levelsEnabled, outputAudioActive, published, sequence, bands, audio: {requested, tapObject, installed, callbacks, analyzedWindows, publications, sequence, lastFrameLength, sampleRate, retiredOutputCount, outputAudioActive, normalizationMode}, renderer: {activeDisplayLinks, displayTicks, geometryLayouts, transformWrites}, silent, noAudioHw, manualRendering}`. `audio.normalizationMode` is the canonical `balanced`, `activity` or `spectrum` string.

`displayTicks` counts snapshot polls, not animation frames, and must remain at or below 30 per second. With stable bounds, `geometryLayouts` stays flat. `transformWrites` counts model-target and immediate-reconciliation writes: at most one per changed bar for each newly observed publication, plus changed-bar passes for geometry, source, activity and one stale-to-zero settle. A visible pause or stop may add one synchronous changed-bar pass to put the model at dots; Core Animation then displays the 0.55-second release without any further transform writes, display ticks, FFT callbacks, timer or completion callback. Pixel loss cancels that release immediately. After an inactive transition and queue/handoff settlement, audio counters and `displayTicks` stay flat and `activeDisplayLinks` is zero. Geometry and transform-write counters additionally require no resizing, scrolling or cell population during the sample.

`set_equalizer_mode balanced|activity|spectrum` is the same session-only comparison command on both apps. `balanced` is the launch default: it starts from the coherent shared energy-per-octave callback average, reserves 9% display headroom, and adds a shared-support-gated 35% of only the positive difference to the existing per-window private-reference activity summary; unsupported bands remain dark. It reuses one FFT and callback cadence. `spectrum` exposes the unmodified coherent common-reference endpoint, while `activity` exposes the unmodified five-private-reference endpoint. Success returns `ok:true`, the selected canonical `normalizationMode`, and `requested`, `tapObject` and `installed`; the last three make a failed active-tap replacement visible. Any other grammar returns the usage error. Changing an active mode synchronously replaces the tap, invalidates the old publication and resets the analyzer's partial window and reference history. Wait for `published:true` and an advancing `sequence` in `dump_equalizer` before judging the new mode; counters are cumulative and do not reset. The selected mode survives later demand and engine-graph tap reinstalls in that process, while each replacement starts fresh analyzer history; relaunch restores `balanced`. These are comparisons between Vibe's own three modes, not claims that any reproduces Apple's unpublished visualizer internals.

## iOS: the simulator loop

iOS has its **own debug command channel** (below); the `--debug-cmd` verbs in the mac section are still mac-only. The build is the `VibeiOS` scheme (`xcodebuild -scheme VibeiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`); products land in `Debug-iphonesimulator/`.

**Simulator only — never a connected phone.** All iOS building, installing, launching, and testing targets the simulator, even when an iPhone or iPad is plugged in. Never pass a device destination (`platform=iOS`, a physical device's UDID or name), never use `devicectl`/`ios-deploy`, and never let `xcodebuild` auto-resolve a destination — always give it an explicit simulator one, as above. A connected phone is the user's personal device: installing on it consumes provisioning, can interrupt whatever they are doing, and leaves the app behind. The bundled scripts are already simulator-only (`simctl` cannot reach a physical device), so this rule binds ad-hoc commands. If the user **explicitly asks** for an on-device run, that authorization covers **that one run only** — it is not standing permission; the very next task returns to the simulator, and on-device use must never be recorded as a default in scripts, docs, or memory.

**Each session gets its own simulator device.** The scripts never target `booted` — `scripts/sim-udid.sh` prints the UDID of a device named `Vibe-<dir>-<hash>`, keyed to the checkout path plus `CLAUDE_CODE_SESSION_ID` (one stable device per checkout when run outside Claude Code); `launch-ios.sh` and `drive-ios.sh start` create and boot it on first use, everything else requires it to exist. Concurrent agent sessions therefore never collide on the simulator, even in the same checkout: each has its own device, app container, debug channel, and touch driver (the driver's command dir is `build/ios-driver/<UDID>` and its session kills are scoped to that device). What same-checkout sessions still share is `build/DerivedData`, `Vibe.xcodeproj` and the one built `.app`, so **builds and installs in a checkout are serialized by `scripts/build-lock.sh`** — `drive-ios.sh start` holds it across `xcodegen generate`, the `xcodebuild test` build and the install that follows, and drops it the moment the runner is up. Gestures, screenshots and the debug channel never take it, so only the building overlaps-and-waits; everything the per-session device exists for stays concurrent. Without it, `xcodegen` rewrote the project under another session's live `xcodebuild`, two builds clobbered one products directory (measured: a 1-2 minute `start` stretched to twelve, with zero files compiled), and `simctl install` could copy a bundle another session's linker was midway through writing. A stuck lock is `build/.build-lock`; it names its holder's pid and is broken automatically once that process is gone. Stale devices from ended sessions are GC'd on the next create (Shutdown + untouched for a day). `VIBE_SIM_UDID` pins a specific device (the value `booted` is the escape hatch for a manually managed one); `VIBE_SIM_NAME` renames. Raw `simctl` commands must target `"$(sim-udid.sh)"`, never `booted`, which is ambiguous once several devices are booted.

**iPad.** The target is device family `1,2`, and the app is a resizable iPadOS 26 window (min 320×480, set in `VibeiOSSceneDelegate`): wider-than-tall shows the landscape layout, taller-than-wide the portrait one. `sim-udid.sh` models iPhones only, so iPad testing means `xcrun simctl create` an iPad device and exporting `VIBE_SIM_UDID` — `launch-ios.sh`, `debug-ios.sh`, and `drive-ios.sh` all honor it. `drive-ios.sh rotate left|right|portrait` flips orientation (there is no simctl rotation); assert the result from `dump_screenshot`'s `pointWidth`/`pointHeight` and check the current track index survived the transition. iPadOS windowed mode (floating windows, corner-drag resize) must be enabled per device in Settings → Multitasking & Gestures — not scriptable via `simctl`, so window-resize testing is manual.

**Which tool for which job** — three tiers, cheapest first; most verification never needs the third:

1. **Looking and reading**: `launch-ios.sh` + `simctl io "$(sim-udid.sh)" screenshot` + `debug-ios.sh dump_state`/`dump_view_tree`. Layout, rendering, state after a code change — start and end here when nothing needs to *happen* mid-run.
2. **Making things happen without touches**: the channel's action verbs (`play_pause`, `seek`, `next`, `open`). They exercise the same controller paths as the UI at ~instant speed. A seek test does NOT need a real drag — `seek` routes through the scrubber's own didSeek path.
3. **Real gestures**: `drive-ios.sh` (below), ONLY when the gesture itself is the thing under test — the waveform drag's 1:1 tracking, the pager pull, tap targets, gesture arbitration. A driver session costs a 1–2 minute spin-up and an app reinstall, so don't start one speculatively; once started, keep it for the whole work session rather than cycling it per test — but rerun `launch-ios.sh` after any rebuild, and check `appStale` (below) before trusting a gesture result.

```bash
.claude/skills/vibe-debug/scripts/launch-ios.sh [audio-file ...]   # boot if needed, install, relaunch
```

`launch-ios.sh` is `launch.sh`'s iOS counterpart: it creates and boots this checkout's dedicated simulator as needed (`sim-udid.sh` + `bootstatus -b`, no guessed sleeps), installs the app from `build/DerivedData` (`$VIBE_IOS_APP` overrides), and relaunches it. **Audio is silent by default**: the shared engine honors the same debug argv flags as macOS, and the script passes `--no-audio-hw --silent` unless `VIBE_AUDIBLE=1` — so a simulator test never plays through the mac's speakers. That default cannot validate live EQ motion because `--silent` zeros the signal under its tap; use `VIBE_AUDIBLE=1` for reactive simulator validation. `VIBE_LANGUAGE=de` works as on macOS. The flags apply only at `simctl launch`; a later `openurl` reuses the running process, so relaunch to change them.

**Feeding it audio.** Files passed to the script are copied into the app container's `Documents/Music` — with `UIFileSharingEnabled` that is the folder the in-app picker reaches via Browse > On My iPhone > Vibe > Music — and the first is then opened via `openurl` (the open-in-place path). That makes a **one-track playlist**: a single-file open grants no siblings on iOS. To test the directory-as-playlist behavior, seed the files and pick the Music *folder* in-app.

```bash
UDID=$(.claude/skills/vibe-debug/scripts/sim-udid.sh)     # this checkout's device
DATA=$(xcrun simctl get_app_container "$UDID" com.commonwealthrecordings.Vibe data)
xcrun simctl openurl "$UDID" "file://$DATA/Documents/Music/tone-long.wav"   # open-in-place a seeded file
xcrun simctl io "$UDID" screenshot shot.png   # device pixels (3x), top-left origin
```

**The iOS debug command channel.** Same file protocol and one-JSON-object contract as the mac's, but with **no CLI client**: the simulator app's container tmp is a plain host directory, so the wrapper writes the command file and reads the reply directly, and the app's own tmp-directory watcher (no notification needed) answers. Debug builds only. All the mac channel's jq guidance applies verbatim.

```bash
S=.claude/skills/vibe-debug/scripts/debug-ios.sh
"$S" dump_state          # {player, currentTrack, playlist, ui, settings} — ui includes waveformProgress, waveformOverscroll (points past an end, + past the start, - past the end; the only way to assert the scrubber's rubber band from outside), waveformScrollGeom ([offset, min, max, contentWidth] — tells "resting at an end" apart from "pinned against one and refusing to give"), waveformBaked, isScrubbing, parked, foreground, plus the shell: playerPresentation ("minimized"|"full"), miniPlayerShown, selectedTab, libraryEmpty
"$S" dump_equalizer      # live producer/renderer snapshot; schema and counter interpretation are in Equalizer counters above
"$S" set_equalizer_mode activity # compare relative activity; use balanced to restore the launch default
"$S" dump_now_playing    # {hasInfo, title, artist, duration, elapsed, rate, hasArtwork} — the mac verb minus playbackState (macOS-only)
"$S" dump_view_tree      # {windows: [{class, frame, keyWindow, rootViewController, contentView: {…, subviews}}]} — UILabel text and button labels included
"$S" dump_art            # {currentIndex, window, held, pages: [{index, title, metadata, art, needsLoad, loading, inWindow, cellUp}]} — the pager's art window: which pages are fetched ahead, which hold decoded art, and what each has. The ONLY way to tell "not decoded yet" from "this track has no art" — on screen both are the vinyl placeholder. `held` past the budget, or a page landing with art:false, is the prefetch failing to keep up
"$S" dump_screenshot     # {ok, path, pointWidth, pointHeight, scale} — in-process render written into the container; the HOST can read the path directly (no TCC)
"$S" play_pause          # compact {ok, state, index, count, position, parked} summary; also: next, previous
"$S" seek 90             # seconds; routes through the scrubber's didSeek path, so the seek-in-flight guard behaves as a real drag release
"$S" open <path>         # file INSIDE the container (seed via launch-ios.sh); the FolderSession open-in-place path. Replaces the playlist, plays, AND expands the card
"$S" expand_player       # the card, without a gesture; also: minimize_player. The shell presents it only on an open, so this is how to get to it otherwise
"$S" set_waveform_zoom 0.12 # the DJ zoom, 0-1 = fraction of the track visible; through the same delegate callback a released pinch takes, so it fans out across pages and persists. Replies {waveformZoomRequested, waveformZoomEffective} — they DIFFER when the layout cannot draw the depth asked for, which is the only way to check the clamp
"$S" set_output_route airplay "Living Room"  # draws the card's route indicator as any route kind (none|speaker|receiver|wired|bluetooth|airplay|carplay|other), model untouched — the simulator reports the built-in speaker and NOTHING else, so this is the only way to see the off-device renderings. A page reconfigure or a real route event overwrites it, so set it immediately before the check
"$S" select_tab playlist # or favorites, or files, or search (the UISearchTab circle)
"$S" dump_favorites      # {favorites: [{name, location, path}]} — the starred folders, as the Favorites tab draws them. Nothing is resolved to answer it, so a favorite on a dead path still lists
"$S" tap_favorite_star   # exactly what tapping the star on the Playlist tab's bar does: toggles the open folder in and out of favorites. TRAP: the ADD is asynchronous (the bookmark is minted off main), so ok:true means the handler ran — poll dump_favorites for the row. Errors when no folder is open
"$S" open_favorite 0     # index into dump_favorites.favorites; drives the row's own didSelectRow:, so the resolve, the open and the unreachable-folder alert are the tap's. Needs `select_tab favorites` first — the tab's provider is lazy, so before that there is no screen to tap
"$S" search zebra        # {query, sections:[{header, rows:[{text, secondaryText}]}]} — runs a query through the search screen and replies once the table settles (the files half answers off a walk). The field takes KEYSTROKES, which neither this channel nor the touch driver can synthesize, so this is the only way to query. Needs `select_tab search` first
"$S" open_search_hit 0   # index into search.sections[1].rows — taps a FILE hit, which is an open: its folder becomes the playlist with that file selected and playing
"$S" dump_search         # {roots, folders} — the search screen's whole scope. roots is what its walk covers: the open folder, then the folders the user added in Settings, then the app's own Documents. folders is just the added ones, i.e. the rows Settings shows. roots also carries the STARRED folders once the search screen has been visited — FavoritesStore resolves their saved grants on that appearance — and it is the composition, before FileSearchIndex prunes nested and duplicate roots, so the same folder can legitimately appear twice
"$S" add_search_folder <dir>  # {ok, added, roots, folders} — widens the scope as picking a folder in Settings would; also: remove_search_folder <index into dump_search.folders>. The channel cannot drive the system document picker (another process's UI, out of the touch driver's reach either), so these are the only way to set a scope up for a test. added:false is the "a persistent root already covers it" answer, not a failure
VIBE_DEBUG_TIMEOUT=20 "$S" clear_caches   # blocks until both PINCaches are empty, like the mac verb
```

**TRAP: a folder added with `add_search_folder` is NOT security-scoped, so it survives only the session.** The real Settings path mints a bookmark from a picker grant; this one hands over a bare path, which works in the simulator because those paths are readable anyway. A test that relaunches has to add it again — and it is not exercising the bookmark round-trip at all.

**The search screen's own state is not on the channel.** Its index lives in the view controller, so what a query matched is read from `dump_view_tree` — the playlist section's rows draw `displayTitle` (no extension), the files section's draw the filename over the containing folder, which is how the two are told apart.

Exit codes match the mac client: 0 ok, 1 no response (no debug build running), 2 command error. The unknown-command reply is the authoritative verb list. Replies to action verbs are read synchronously and can lag async engine work — the same caveat as the mac: a `seek` or `play_pause` reply may show the pre-action state, so follow with `dump_state`. The app side is `Vibe/Debug/iOS/DebugCommands.m` over the shared transport in `Vibe/Debug/DebugChannel.m`. Most verbs are not there at all: the cross-platform ones live once in `Vibe/Debug/DebugCommonVerbs.m`, so a verb both platforms can answer is added there and appears on each; only a UIKit-specific one goes in the iOS table.

**Check `ui.waveformBaked` after an expand.** The card animates by transform precisely so the per-page waveform scrubbers do not re-bake their envelope bitmaps; `waveformBaked:false` shortly after `expand_player` means something started animating the card's bounds again (`Vibe/iOS/CLAUDE.md` carries the trap).

**Rebuilt mid-session? Relaunch, and check `appStale`.** `install-ios.sh` is the single home of "the installed app matches the built one", and both `launch-ios.sh` and `drive-ios.sh start` call it — installing only when the device's bundle differs from the built one, so it is safe to run with a driver session live. It exists because **`xcodebuild test` leaves the app-under-test it built on disk without installing it**, which used to leave `drive-ios.sh start` reporting ready against the *previous* binary; `start` therefore installs after the build finishes, never before. `drive-ios.sh status` reports `appStale` as the backstop, since a driver session outlives any number of rebuilds:

```bash
.claude/skills/vibe-debug/scripts/drive-ios.sh status     # {"ready": true, "appStale": false}
```

**`appStale: true` invalidates every gesture result taken since the rebuild** — a stale app launches, answers the debug channel and accepts touches exactly like a fresh one, so nothing else will tell you. Rerun `launch-ios.sh` (or `install-ios.sh "$(sim-udid.sh)"`) and repeat the run.

**Staleness is decided by content, never by time**: both bundles are hashed file by file (~80ms for 25MB), so it answers "is the device running these bytes" — resource-only changes such as a `make strings` run count, and a relink that changed nothing does not. It used to compare the executable's mtime, which made `appStale` fire for every *other* session in the checkout whenever any one of them built, because **every xcodebuild run relinks `Vibe.app/Vibe` even when it compiles nothing**. Sessions then discarded valid gesture results and bounced live apps over a rebuild that changed no code.

**What the iOS channel cannot do**: input injection — no public API synthesizes `UITouch`es in-process; real gestures go through the touch driver below — and the mac's menu, window, FX, pitch, convert, and file_cache verbs have no iOS counterparts yet. `dump_screenshot` renders in-process (UIVisualEffectView blurs only approximate); `simctl io "$(sim-udid.sh)" screenshot` remains the ground truth for real pixels.

**Logs stream from the HOST.** Simulator processes write into the mac's unified log, and `log stream` *inside* the simulator (`simctl spawn`) is refused as non-admin. Info and debug are not persisted (same as macOS), so stream, don't `log show`:

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'
```

**Driving the UI: the touch driver.** For state changes, prefer the channel's verbs (`play_pause`, `seek`, `open`, …) — instant, no focus needed, reply with state. For genuine *gestures* (the waveform drag, the track pager pull, tapping buttons), use the touch driver: a resident XCUITest (`VibeiOSDriver`, sources in `Tests/iOSDriver/`) that executes gesture commands over the same file protocol — the only sanctioned touch-synthesis path on iOS. The Simulator window does NOT need to be frontmost, and coordinates are app-window POINTS (top-left origin; `simctl` screenshot pixels ÷ the scale `dump_screenshot` reports).

```bash
D=.claude/skills/vibe-debug/scripts/drive-ios.sh
"$D" start                    # builds, installs, spins up the runner (~1-2 min).
                              #   Run it before launch-ios.sh so the app it launches is
                              #   the one the driver attached to; either order installs
                              #   correctly, but this one skips a relaunch
"$D" tap 201 250              # also: double_tap x y, press x y seconds, home
"$D" drag 300 560 100 560 1.0 # x1 y1 x2 y2 [seconds] — give seconds for a 1:1 scrub
                              #   (the waveform drag), omit for a flick
"$D" pinch 2.0 1.0            # scale velocity — the waveform zoom. The ONLY
                              #   element-targeted verb: XCUITest has no
                              #   coordinate multi-touch, so it finds the
                              #   scrubber by accessibilityIdentifier and needs
                              #   the card expanded. scale > 1 zooms in;
                              #   velocity must be negative to zoom out
"$D" status                   # {"ready": true|false, "appStale": true|false}
"$D" stop                     # end the session
```

Latency: ~1s per gesture at steady state; the FIRST gesture after a start or an app relaunch pays the accessibility attach (can run tens of seconds — send a throwaway `tap` on dead space as a warm-up). If the app is dead, the next gesture relaunches it with the audio-silencing flags. The reply means the gesture was *performed*, not that it landed where intended — verify with `debug-ios.sh dump_state` or a screenshot. One session per DEVICE; `start` kills only this device's previous driver, so a session driving another simulator is untouched. After any app rebuild mid-session, rerun `launch-ios.sh` — it installs unconditionally now (the install is a no-op when the bundles already match), so the driver re-attaches to the fresh build; `drive-ios.sh status`'s `appStale` is the backstop that tells you when this is owed. The runner disables XCTest's per-event quiescence waits (Vibe's display link means a playing app never idles; without this every gesture costs ~2 minutes) — that reaches XCTest internals, harness-only, never shipped, and degrades to slow-but-working if an Xcode update renames them (see `Tests/iOSDriver/VibeiOSDriverTests.m`).

`input.swift` clicks on the Simulator *window* are obsolete for this — no calibration, no frontmost dance.

**Simulator blind spots.** Interruptions (calls/Siri), route changes (headphone unplug), background audio past lock, and the lock-screen card need a real device. The card's route indicator draws and its picker opens on a tap — `dump_state`'s `ui.routePickerUp` flips — but the simulator offers no second route, so the sheet shows nothing and AVKit never sends the did-end edge; only `set_output_route` shows the off-device renderings there. The `AVAudioSession` code runs but the simulator does not exercise it faithfully. Per the simulator-only rule above, do not drive a connected phone to close these gaps — report them as unverified and let the user test on their own device, unless they explicitly ask for a one-time on-device run.

## Driving and inspecting the running app: `--debug-cmd`

The Vibe binary doubles as its own CLI client, with the same bundle ID and sandbox, so it shares the app's container tmp. **Prefer it to an lldb attach, CGEvent input or AppleScript menu clicks**: it needs no Accessibility or Automation permission, does not require the app to be frontmost, and never pauses the process.

**Every command replies with exactly one JSON object.** Never scrape text. Filter with `jq`: `-r` for shell substitution, `-e` to assert, which exits nonzero on `false` or `null` and so doubles as the test. Pipe through `printf '%s' "$out"`, not `echo`, because zsh's `echo` rewrites `\t` escapes inside the JSON into illegal raw control characters. Errors come back as `{"error": "…"}` with exit code 2.

**Use `jq`, not python.** Comparing before-and-after state is a `jq` job: two `-r` extractions and a shell compare. Python earns its place only when you need real data structures across many keys at once, such as walking or diffing whole `dump_view_tree` subtrees. Pulling scalars out and comparing them never qualifies:

```bash
out=$("$V" --debug-cmd dump_state)
printf '%s' "$out" | jq -r '.currentTrack.title, .ui.currentTime'    # scalars for the shell
printf '%s' "$out" | jq -e '.player.state == "playing"' >/dev/null   # assert; nonzero if not

# before/after: extract, act, extract, compare — no python
before=$("$V" --debug-cmd dump_state | jq -r .player.position)
"$V" --debug-cmd skip_forward >/dev/null
after=$("$V" --debug-cmd dump_state | jq -r .player.position)
awk -v a="$before" -v b="$after" 'BEGIN{exit !(b>a)}' || echo "FAIL: $before -> $after"
```

`.player.state` is lowercase and only ever `playing`, `paused` or `stopped`. There is **no `loading` value**: an in-flight open reports `playing` or `paused` according to its pending start intent, with zero position and duration, which matches the transport button. Asserting `== "Playing"` silently never matches.

```bash
"$V" --debug-cmd dump_state          # {player, currentTrack, playlist, ui, window, settings} — playlist includes resolvedRows; mac ui includes displayState (track|loading|empty|launch-grace|error), so a queued playback failure is observable without mistaking player.state's pending intent for settled UI
"$V" --debug-cmd dump_equalizer      # live producer/renderer snapshot; schema and counter interpretation are in Equalizer counters above
"$V" --debug-cmd set_equalizer_mode activity # compare relative activity; use balanced to restore the launch default
"$V" --debug-cmd dump_now_playing    # {playbackState, hasInfo, title, artist, duration, elapsed, rate, hasArtwork} — what we publish to the system Now Playing UI (Control Center / media keys). REQUIRES a launch WITHOUT --no-audio-hw (VIBE_AUDIBLE=1), which suppresses the publish entirely; under the flag this always reports hasInfo: 0
"$V" --debug-cmd dump_stats          # {filesOpened, foldersOpened, secondsPlayed} — AppStats lifetime counters, live (secondsPlayed includes the in-progress run)
"$V" --debug-cmd dump_health         # {process: {footprintBytes, residentBytes, mallocLiveBytes, mallocReservedBytes, threads, fileDescriptors, machPorts, uptimeSeconds}, ui: {windows, views, layers, trackingAreas}, app: {playlistCount, tableRows, engineNodes, …}, pending: {metadataHolders, metadataWaiters, openResultsBuffered, openBurstQueued, retiredFades, datalessProbesInFlight, …}} — resource counters for soak runs. Every field is meant to be DIFFED across a run, not read in isolation; see Stress and fuzz testing. **mallocLiveBytes, not footprintBytes, is the leak signal**: bytes live across every malloc zone. Two big-file decodes take the footprint to 203 MB against a 52 MB live heap, and a quiesce then reads 365 MB against 37 MB — the footprint carries the allocator's and the VM's high-water mark, the live heap does not
"$V" --debug-cmd quiesce             # {ok, settled, waitedSeconds, pending, pressureRelief: {releasedBytes, mallocLiveBytes, mallocReservedBytes, reservedFreedBytes}} — closes the file, then polls until every pending-work counter unwinds (15s deadline), and asks every zone to hand its free pages back. Sample dump_health straight after it for a reading taken at rest instead of mid-decode. settled:false names the counter that held out. **Check releasedBytes before trusting a resting footprint**: measured on a fresh launch it returns ~42 KB and after a heavy run 0, so the pages stay dirty and the footprint keeps the high-water mark — vmmap shows them as MALLOC_LARGE (empty)
"$V" --debug-cmd check_consistency    # {ok, checked, state, violations: [{id, detail}]} — the app's consistency rules asserted against live state: playlist index and player-track identity, table rows, position/pitch clamps, fader-vs-player agreement, the UI tick rate against its inputs, an engine node bound, the tag-over-analysis BPM/key precedence, and the header labels and settled artwork ownership against the track. Re-check after a settle before believing a violation: gapless promotion reaches the player before its playlist callback reaches main, and rendered state can lag its input by a runloop turn
"$V" --debug-cmd dump_view_tree      # {windows: [{class, frame, visible, key, contentView: {…, subviews}}]}
"$V" --debug-cmd dump_menu           # {menu: [{title, id, key, action, enabled, state, items}]} — LIVE enabled/checkmark
"$V" --debug-cmd click_menu menu_show_pitch   # {ok, clicked, action} — by identifier (preferred) or exact title
"$V" --debug-cmd settings_open appearance     # {ok, pane, paneTitle, panes, frame, key} — opens the Settings window, creating it, and selects a pane by identifier (general|playback|appearance|convert|permissions|advanced), index or displayed title; bare `settings_open` just opens it. See The settings window below
"$V" --debug-cmd dump_settings_ui             # {pane, paneTitle, panes, controls: [{index, kind, name, label, enabled, rect, + the live value}], window, sheet} — every control of the SELECTED pane
"$V" --debug-cmd settings_click "Detect key" on  # {ok, control, kind, action, + the live value} — activates one control of the selected pane BY NAME, no coordinates
"$V" --debug-cmd settings_close               # {ok, open, endedSheet} — ends an attached sheet first, then closes
"$V" --debug-cmd dump_screenshot -   # PNG bytes on stdout (redirect to a file), JSON reply on stderr — in-process snapshot
"$V" --debug-cmd play_pause          # also: next, previous, skip_forward[_more|_most], skip_back[_more|_most], toggle_size, toggle_pitch_panel
"$V" --debug-cmd set_loading 0.42   # {ok, fraction} — drives the waveform loading indicator directly: `off`, `indeterminate`, or a 0..1 fraction for the determinate fill. Draws the control with no play behind it; for a REAL Loading state use set_fake_cloud
"$V" --debug-cmd set_fake_cloud 4 100  # {installed, percent, baseSeconds, capacity, uniform, progressMode, materialized, completed, cancelled, maxConcurrency, metadataOverlapTransfers, foregroundContentionStarts, …} — makes the corpus answer as cloud placeholders and each open wait for a hashed transfer time; provider capacity defaults to 1 (`capacity=0` means unlimited), and `set_fake_cloud 0` uninstalls. `foregroundContentionStarts` counts metadata starts while a playback or prefetch transfer is actually running; each contention trace entry carries `foregroundInFlight`. The only way to reach the Loading state, the shimmer and the open timeout. Full grammar: set_fake_cloud <seconds> [<percent>] [capacity=N] [uniform] [progress=none|linear|sparse|stall] [unflagged] [sticky]. See references/test-audio.md
"$V" --debug-cmd dump_cloud_trace      # {stats, events} — the fake provider's admission trace: one entry per transfer event (requested / started with queuedMs / completed / cancelled), each with a sequence number, ms since install, the caller's role (playback, prefetch, metadata-priority, metadata-scan) and the file. `requested` is the app/provider boundary before fake-provider capacity; `started` is provider-slot admission. Ordering assertions read this rather than inferring order from elapsed time; `clear_cloud_trace` empties it
"$V" --debug-cmd dump_cloud_health     # {cloudParsesPending, cloudLaneHeld, priorityLane:{pending,yieldedUnderHold,inFlight,liveTokens,held}, scanLane:{pending,delayed,inFlight,liveTokens,stageOneFinished}, materialization:{claims,waiters,interactiveRunning,backgroundRunning,interactivePending,backgroundPending,metadataHolds,handleRuns,datalessProbesInFlight,handleOpensInFlight,…}} — loader and path-wide lanes on BOTH platforms. Every live count, pending list and hold belongs empty/zero once a sweep has settled; stageOneFinished is historical state, not residue
"$V" --debug-cmd dump_row_loading      # {transfers: [{file, progress}], loadingRows: [{index, file, progress}], playlistCount} — both halves of the row loading bar's guarantee: the CloudTransferRegistry's live provider transfers, and every playlist row it would mark. loadingRows is bounded by lane capacity (at most ~3), every row in it must appear in transfers, progress is -1 while indeterminate, and both lists are empty with everything local or settled
"$V" --debug-cmd dump_audio_loading    # {aligned, materialization, player, metadata} — immutable safe/diagnostic loading snapshots at each consumer; aligned should be true after the command below
"$V" --debug-cmd set_audio_loading defaults  # reset every loading knob. Partial key=value updates: background, local-parses, prefetch-depth; diagnostic-only interactive, interactive-pending, background-pending, interactive-grace, background-grace, retries, timeout-baseline, timeout-silence. Changes apply to new admissions/loaders/prefetch decisions/opens, never by cancelling live work
"$V" --debug-cmd block_main 0.5 play_index 3  # {ok, blockedSeconds, then, thenReply} — hold the main thread, then run another shared verb WITHOUT yielding it. Stages a callback the app dispatched to main from a worker arriving while a user action is already underway; two separate commands cannot, since the channel's own intake is on the main queue. Bounded to 5s
"$V" --debug-cmd set_dataless_diag on  # {ok} — record st_flags and lane routing per directory against a REAL provider; dump_dataless_diag reports it. Records nothing while the fake probe is installed, which replaces the stat it measures
"$V" --debug-cmd set_window_width 900  # {ok, frame, bodyWidth} — body width in points (pitch panel excluded); the window is user-resizable and restores the autosaved width, so a reproducible capture has to set one
"$V" --debug-cmd toggle_low_kill     # FX, also: low_kill_boost_on/_off, reverb_send_on/_off, delay_send_on/_off, short_delay_send_on/_off (the *_on/_off pairs mirror the hold-down W/E/R/T keys)
"$V" --debug-cmd set_pitch -4.5      # drives fader (clamps), player, and time labels together
"$V" --debug-cmd seek 120            # seconds
"$V" --debug-cmd open ~/Music/album  # {ok, opening} — file or dir, direct expand/filter/replace path on macOS; bypasses the AppDelegate open funnel; poll dump_state
"$V" --debug-cmd append ~/Music/track.flac  # {ok, appending} — macOS only; enters the real deliberate-open funnel with appending:YES, then expands and calls addURLs:; poll dump_state
"$V" --debug-cmd drag_hover 520 275  # {ok, well} — synthetic external-file drag-over at a window point (top-left origin, like click): drives the playlist drop zone's wells through the real FileDropDelegate path. NOT an event: a genuine NSDraggingSession can't be synthesized, so these call the delegate directly. well = replace|add|none = what a drop there would hit
"$V" --debug-cmd drag_drop 520 275 ~/Music/track.wav  # {ok, dropping, well} — completes the synthetic drag: expands + delivers the drop at that point (well routing: replace|add|none→replace), then tears the drag-over UI down. ABSOLUTE path; same sandbox caveat as open; poll dump_state
"$V" --debug-cmd drag_end            # {ok} — the drag left the window without a drop: back to the rest presentation
"$V" --debug-cmd file_cache song.flac        # {ok, wasCached, bpm, key, camelot, timing} — decode + cache one file's waveform (UI untouched); waits up to 60s. `timing` is that decode's own phase breakdown, absent on a cache hit
"$V" --debug-cmd dump_timing                 # {loads: [...]} — in-process phase timings of recent waveform decodes, newest first: readSeconds (the decode), chunkSeconds, bpmSeconds/keySeconds (each split into Append + Finish), otherSeconds, realtimeFactor. Covers every load, from playing a track as well as from file_cache
"$V" --debug-cmd clear_timing                # {ok} — empties that store before a measurement run
"$V" --debug-cmd file_clear_cache song.flac  # {ok, wasPresent} — evict one file's cached waveform
"$V" --debug-cmd convert_to_flac [keep|delete] [omit-trash-url]  # {ok, output, row, source, sourceDeleted, sourceRemains} — the whole Convert to FLAC path on the CURRENT track, swap and source disposal included; default: current setting. omit-trash-url is a one-shot undo-safety fault and requires delete. Waits up to 120s
"$V" --debug-cmd undo                # {ok, undid, committed, reason?, canUndo, canRedo} — Edit > Undo; replies once the file moves have settled. {"error": "nothing to undo"} on an empty stack
"$V" --debug-cmd redo                # {ok, redid, committed, reason?, canUndo, canRedo} — Edit > Redo, same contract, {"error": "nothing to redo"}
"$V" --debug-cmd clear_caches        # {ok, cleared} — empties metadata + waveform PINCaches
"$V" --debug-cmd quit                # {ok, quitting} — ends the app through the normal terminate path. **Prefer it to pkill**: an attached debugger traps SIGTERM and only stops the process, so an Xcode-run instance survives the kill, stays in the process table and answers nothing (see Launching). It is also the only exit that runs applicationWillTerminate:, so the AppStats flush happens
"$V" --debug-cmd scan_bpm - < file   # {ok, bpm} — fresh decode+analyze, runs IN THE CLI PROCESS (no app needed; see Test audio files). Audio rides stdin; prefer the scan-bpm.sh wrapper
"$V" --debug-cmd scan_key - < file   # {ok, key, camelot, index} — the key-analyzer twin of scan_bpm, same contract; prefer scan-key.sh. Ignores tags: dump_state's currentTrack.key/.camelot show the app's tag-over-analysis resolution instead
"$V" --debug-cmd clear_disk_caches   # {ok, cleared} — CLI-process deletion of the PINDiskCache dirs, ONLY for when the app is NOT running (prefer clear-caches.sh, which picks the right one)
"$V" --debug-cmd set_appearance dark # {ok, windowAppearance} — light|dark|system, CLI-process prefs write for the NEXT launch (live toggle: click_menu view_appearance_*)
"$V" --debug-cmd set_analysis bpm off # {ok, analyzeBPM, analyzeKey} — <bpm|key> <on|off>, CLI-process prefs write a running app sees immediately (the next waveform decode reads it — no relaunch), so this is how you A/B the analyzers' cost; dump_state.settings reports the live values
"$V" --debug-cmd set_key_display musical colors # {ok, keyNotation, keyColors} — <camelot|musical> <colors|plain>, same live prefs write; the label repaints at its next re-render (key delivery, fader tick, or track change), not on the write itself
"$V" --debug-cmd set_folder_art off # {ok, folderArt} — <on|off>, the Settings > Files album-art dropdown: writes the setting AND re-resolves the loaded playlist's folder art, header, dock and rows included. Unlike the prefs writes above this one needs a RUNNING app — the live re-resolve is the half worth testing, and the pane itself cannot be driven over this channel
"$V" --debug-cmd set_pause_at_track_end off # {ok, pauseAtTrackEnd} — <on|off>, the Settings > Playback “On track end” choice: writes it and requests the EndOfTrack live effect, which immediately re-parks or drops the already-armed successor
"$V" --debug-cmd sleep 0.5           # client-side pause (0–600s, sub-second OK) — for scripts; the app's main thread never sleeps
"$V" --debug-cmd script - <<'EOF'    # command script: see Command scripts below
seek 30
sleep 0.5
key space
EOF
.claude/skills/vibe-debug/scripts/run-script.sh <shots-dir> [file]  # script wrapper that decodes in-script screenshots to numbered PNGs
```

The direct FX verbs intentionally bypass `audioFXEnabled`: they drive the model for diagnostics. Use `key`, `key_down` and `key_up` to exercise the shipping menu/key gates.

Input injection posts synthesized NSEvents into the app's own event queue. See **In-process input injection** below for coordinates and caveats:

```bash
"$V" --debug-cmd click 75 122        # {ok, posted, hitView, windowKey} — down+up at window point (also: click x y right, click x y left 2 = double-click)
"$V" --debug-cmd drag 728 219 728 299   # full left-button gesture in ONE command (down, 12 dragged steps, up); optional [steps]
"$V" --debug-cmd mouse_move 400 200  # plain move; add left|right for a lone dragged event
"$V" --debug-cmd mouse_down 75 122   # primitives (default left; also right) — see the tracking-loop caveat below
"$V" --debug-cmd mouse_up 75 122
"$V" --debug-cmd key p               # keyDown+keyUp through the real dispatch path (TransportKeyMonitor sees it); mods: key p cmd shift
"$V" --debug-cmd key_down w          # one edge — how the held W/E/R/T momentary FX are driven…
"$V" --debug-cmd key_up w            # …and released (keys: a-z, 0-9, space, tab, return, esc, delete, forward_delete, up/down/left/right)
"$V" --debug-cmd key delete repeat   # `repeat` rides the modifier list but is not a modifier: it sets isARepeat, the only way to
                                     #   exercise a handler's repeat guard — Remove from Playlist takes ONE row per press, and the
                                     #   momentary FX keys ignore repeats. `delete` is Backspace and `forward_delete` is its twin;
                                     #   they are different characters reaching different code, so neither verb covers the other
```

`clear_caches` blocks until both disk caches are genuinely empty, so a follow-up launch is guaranteed a cold parse. The waveform clear queues behind any in-flight waveform load, so allow up to 15 seconds right after feeding it a long file. For the common cold-cache launch there is a wrapper that also works when the app is not running: it then runs `clear_disk_caches`, which deletes the PINDiskCache directories, superseded cache versions included, inside the CLI client process, keeping shell `rm` out of the container.

```bash
.claude/skills/vibe-debug/scripts/clear-caches.sh   # prints {ok, cleared: [...]}
```

`convert_to_flac` runs the same funnel the menu items use, so its reply describes the settled result — where the FLAC landed and which row now points at it, or `row: -1` when the playlist was replaced during the encode. It acts on the **current track**, the only thing the app converts, so load the file you mean to convert first. While one runs, `dump_state`'s `ui.converting` is true and `ui.convertSweep` is the encode fraction driving the waveform's brush-through progress — poll it to watch a conversion move. It converts **in place beside the source**, so point it at a working copy rather than at `Assets/test_audio_files/`. A source the app opened as a single file, rather than as part of a folder, exercises the related-item sandbox rung; watch for it in the log, which names the rung it fell through to.

**Testing Convert > Delete Original.** The optional `keep|delete` token writes the setting before converting, exactly as clicking the menu item does, and **leaves it written** — restore it if a later test depends on the default (off); `dump_state.settings.deleteOriginalAfterConvert` reports it. Assert from the reply, not the filesystem: `sourceDeleted` is what the disposal actually did and `sourceRemains` stats the original path, both only after the Trash move has settled — and `ls ~/.Trash` from a terminal trips the same TCC denial as reading the app container.

```bash
"$V" --debug-cmd convert_to_flac delete | jq -e '.sourceRemains == false' >/dev/null
"$V" --debug-cmd convert_to_flac keep   | jq -e '.sourceRemains == true'  >/dev/null
```

`undo` and `redo` drive the window's NSUndoManager, whose only registered action is Convert to FLAC: undo restores the trashed original, returns its playlist row to it, and trashes the FLAC; redo reverses that from the Trash without re-encoding. Both reply only once the file moves have settled, so assert file state directly from the reply's ordering, and read the live stack from `dump_state`'s `ui.canUndo`/`ui.canRedo`. `ok:true` means the command was accepted and settled; `committed` says whether the controller crossed its replacement commit gate. A refusal reports `committed:false` with one of `restore_failed`, `replacement_location_unknown`, `replacement_unavailable`, or `already_at_target`. To exercise the menu path instead use `click_menu menu_edit_undo` / `menu_edit_redo`; validation retitles the items from the manager ("Undo Convert to FLAC") and `dump_menu` shows the live titles and enables — but the menu action has no settled signal, so prefer the verbs when a follow-up step depends on the moves having landed.

```bash
undo_enabled() { "$V" --debug-cmd dump_menu | jq -r '.menu[]|select(.title=="Edit")|.items[]|select(.id=="menu_edit_undo")|.enabled'; }
```

The missing-Trash-URL regression is deterministic through the one-shot `omit-trash-url` fault. Run it only on a working copy: the real source is moved to the Trash, but its returned location is deliberately withheld from the controller. The refused undo must leave the converted row in place, and the inverse NSUndoManager registers for that refusal must settle as already satisfied rather than touching either path:

```bash
out=$("$V" --debug-cmd script - <<'EOF'
convert_to_flac delete omit-trash-url
undo
redo
dump_state
EOF
)
printf '%s\n' "$out" | jq -s -e '
  length == 4 and
  .[0].sourceDeleted == true and
  .[1].committed == false and .[1].reason == "replacement_location_unknown" and
  .[2].committed == false and .[2].reason == "already_at_target" and
  .[3].currentTrack.url == .[0].output
' >/dev/null
```

`file_cache` and `file_clear_cache` operate on the **waveform** cache for one file, keyed by size and mtime, independently of the current track. Use them to force a cold decode when testing the waveform loader or the BPM analyzer: run `file_clear_cache foo.flac`, then `file_cache foo.flac` reports the freshly detected `bpm`. The reply lands only once the entry is on disk, so a follow-up relaunch is guaranteed the cache hit. Quote paths as usual; arguments travel to the app as an array and are never re-tokenized, so filenames with whitespace are safe. `open` and `file_cache` read the path directly, so the App Sandbox may deny a file the app has not been granted — the same caveat as command-line arguments. Launching with `open -a "$APP" <file>` grants access, so prefer paths already opened this session.

`dump_menu` and `click_menu` run the same `validateMenuItem` pass that opening the menu would, so enabled state and checkmarks are live. This replaces AppleScript and System Events menu clicking, with no Automation permission and no frontmost requirement. Get identifiers from `dump_menu`.

The waveform style items carry `waveform_style_<identifier>` ids (`waveform_style_basic`, `_detailed`, `_sonic_cirrus`, `_oversampling_detailed_x2|x4|x8`), so they can be clicked without matching their display names. They are built by the submenu's delegate, though, so **run `dump_menu` first in each app run** — until something populates that submenu, `click_menu` can't find them. Matching `dump_state.settings.waveformStyle` uses those same identifiers (`oversampling_detailed_x4`), NOT the menu's display text ("Oversampling Detailed x4") — the two were split so a localized name can never reach NSUserDefaults.

Action replies are a compact `{ok, state, index, count, position, pitch, lowKill, reverbSend, delaySend, shortDelaySend, playlistShown, pitchPanelShown}` object, read synchronously, so they can lag async engine work. Run `dump_state` afterwards to confirm. Exit codes: 0 ok, 1 no response (no debug build running), 2 command error, 64 usage error. With **two instances running the channel is racy**, because commands travel as per-id files and either instance may consume one, so quit one first.

### Command scripts

`script <file | ->` runs commands line by line over the same channel: one command per line, blank lines and full-line `#` comments skipped, and single or double quotes grouping arguments with spaces, with no escape sequences. Replies stream as **compact one-line JSON objects, real NDJSON**. The script **stops at the first failing command** and exits with its code, so exit 0 doubles as "every step passed".

**Screenshots inside scripts.** A `dump_screenshot [label]` reply line carries the PNG **base64-encoded**, as `{"ok":true,"pngBase64":"…","label":"…"}`. The sandboxed CLI client is the only process that may read the snapshot from the app container, and the inherited stdout fd is the sanctioned crossing. Do not run that raw — it is roughly 100 KB of base64 per shot. Use the wrapper, which decodes each one to `<shots-dir>/shot-NN[-label].png` in command order and prints `{"ok":true,"screenshot":"<path>"}` in its place. Then `Read` the numbered PNGs to verify:

```bash
.claude/skills/vibe-debug/scripts/run-script.sh /tmp/shots <<'EOF'
open "/path/with spaces/track.wav"
sleep 1
dump_screenshot after-open
key space
seek 30
dump_screenshot after-seek
dump_state
EOF
```

When feeding `"$V" --debug-cmd script` directly, **always use stdin** — `script -` with a heredoc, or `script - < file`. The CLI client is sandboxed and usually cannot read a script file by path, the same denial as argv audio files, and the error says so. Two verbs are unavailable inside scripts: `scan_bpm -`, because stdin is the script, and a nested `script`. `sleep` runs client-side and accepts floats, such as `sleep 0.2`, so the app never blocks between steps.

### The settings window

The Settings window has four verbs of its own — `settings_open`, `settings_close`, `dump_settings_ui`, `settings_click` — and **must never be driven with `click`, `drag` or the `key*` verbs**, which post into the main player window's event stream. They live with the code they exercise, in **`Vibe/Mac/Settings/CLAUDE.md`**, along with the sheet, pane-animation and open-panel traps.

### In-process input injection

`click`, `drag`, `mouse_*` and the `key*` verbs post synthesized NSEvents into the app's own event queue. Unlike the other `--debug-cmd` verbs, which call controller actions directly, these exercise the **real event dispatch path**: `TransportKeyMonitor`, view `mouseDown:` and tracking loops, and menu key equivalents. Unlike CGEvent injection through `input.swift`, they need no Accessibility permission and no help from the OS frontmost state.

- **Coordinates are main-window points with a top-left origin**, the same frame as `dump_screenshot`, which is the retina pixel divided by two. Get view frames from `dump_view_tree`, remembering that those are AppKit **bottom-left**-origin frames in the superview; convert with the window height.
- Mouse replies include `hitView`, the hit-tested view class, so a missed aim shows up immediately. Mouse injection **self-activates the app**, bringing Vibe frontmost and making the window key, because a non-key window swallows the first click as activation. Keyboard injection needs no activation: the key monitor sees posted events regardless.
- Replies are written when the events are *queued*, before they are processed, so poll `dump_state` to observe the effect. That is the same lag caveat as the action verbs.
- **Tracking-loop caveat.** A lone `mouse_down` on a control that runs a modal mouse-tracking loop, such as the pitch fader or a button, stalls the app inside that loop, and the command channel cannot deliver the matching `mouse_up` while it spins. Recovery then takes a real physical click. Use `click` or `drag`, which queue the whole gesture before the loop starts. Keep `mouse_down` and `mouse_up` for views with plain responder-method handling.
- **Right-click caveat.** `click x y right` on a view with a context menu, such as a playlist row, opens a *real* menu that blocks the channel until it is dismissed. Do it only when something can dismiss the menu: a human, or a pre-posted `key esc`. Post the esc *before* the right-click, since it cannot be delivered afterwards.
- Tracking areas and hover effects do not fire from posted events, because the window server drives those. Hover styling still needs `input.swift`.

## Stress, soak and fuzz runs: the `vibe-stress` skill

Driving the app *randomly, for hours, with oracles that notice when something breaks* — soak runs, leak and resource-growth hunting, race hunting under TSan, fuzzing the file-loading path, and minimizing a failing run to a repro — lives in the **`vibe-stress` skill** (`.claude/skills/vibe-stress/`), built on this channel. `make stress CORPUS=<folder>` is its entry point.

The three verbs it leans on (`dump_health`, `check_consistency`, `quiesce`) stay in the command list above, because they are ordinary channel commands and are useful without it.

## Screenshots: two paths, each showing what the other cannot

**1. In-process snapshot.** A synchronous one-liner; `-` streams the PNG bytes to stdout and the JSON reply goes to stderr:

```bash
"$V" --debug-cmd dump_screenshot - > shot.png
```

Always use the `-` form. Inside a command script the reply carries the PNG as base64 instead; see Command scripts. With neither, the reply carries the PNG's path, but that path is inside the app's sandbox container, and reading it with shell tools such as `cp` or `cat` trips macOS's "access data from other apps" TCC prompt against the terminal's host app. The `-` streaming happens in the Vibe CLI client, which owns the container, so no prompt appears. `notifyutil -p com.vibe.debug.screenshot` also works, but it is async and leaves you copying from the container by hand, with the same TCC prompt. Avoid it.

This path renders the key window's Core Animation layer tree in-process, falling back to the main window and then to the frontmost visible one, so the app need not be frontmost. That last rung is what captures the **settings or about window** while the app is inactive, since neither key nor main window exists then; it is also why a mouse-injection verb, which makes the *player* key, silently redirects the next screenshot back to the player. It needs no screen-recording permission and works while occluded or with the display asleep. **Default to it** for layout, label text and color, artwork and waveform checks.

**Blind spots.** `NSVisualEffectView` materials and vibrancy do not render, and neither does the `NSGlassEffectView` glass chrome — the window-spanning backdrop and the header panel — because the window server composites those. The snapshot hides the glass layers and paints an appearance-matched flat proxy fill, dark or light gray, where they would be, which keeps dark-mode content legible. Hiding them also forces a *model*-tree render on glass-bearing windows, so animations are captured at their target values rather than mid-flight; glass-free windows still render the presentation tree. Metal content, such as the About window, does not render either. **Never judge window background, material, tint-wash or appearance-blending issues from this path.** It structurally cannot show them.

**2. Real screen capture**, for material, vibrancy and appearance verification:

```bash
.claude/skills/vibe-debug/scripts/capture-window.sh out.png [pid]
```

It finds the on-screen Vibe window through CGWindowList and runs `screencapture -x -l<windowID>`. The terminal needs Screen Recording permission. It captures real composited pixels, which makes it the ground truth for anything the snapshot path cannot show. Pass the pid when two instances are running; the script warns and lists the binaries.

## Pixel probing

Eyeballing near-identical grays is unreliable, so assert numerically:

```bash
swift .claude/skills/vibe-debug/scripts/probe-pixel.swift out.png 700 600 [x y ...]
```

It prints the image size and the RGBA at each point. Coordinates are bitmap pixels with a **top-left origin**, and captures are **2x on retina**, so a window point is roughly a pixel divided by two. `find-window.swift`, in the same directory, prints `windowID pid x y w h` per Vibe window when you need geometry to aim probes.

## Appearance (light and dark) testing

The app's appearance setting persists in its defaults. Set it for the next launch with:

```bash
"$V" --debug-cmd set_appearance light    # or: dark, system — runs in the CLI process, app need not be running
```

Do not use `defaults write com.commonwealthrecordings.Vibe …`. The sandboxed app's prefs live in its container, so a shell `defaults` call can trip the "access data from other apps" TCC prompt. `set_appearance` writes the same key from inside the CLI client.

Relaunch to apply, or toggle live with `"$V" --debug-cmd click_menu view_appearance_light`, and likewise `view_appearance_dark` and `view_appearance_system_default`. Test both modes for any color or material change, and use real capture, path 2, to verify backgrounds. The app's window appearance is independent of the system's: a light window over a dark system is a supported, and once buggy, combination.

## OS-level input path: hover states and focus semantics

`input.swift` sends CGEvents through the window server. It is the only way to reach tracking-area and hover effects, OS-level focus and activation semantics, and real drop targets — and it needs Accessibility permission and turns flaky if focus is stolen. **Prefer the in-process `click`, `drag` and `key*` verbs above for everything else.** Usage and coordinate rules: **`references/os-input.md`**.

## Logs

The `LogError`, `LogWarn`, `LogInfo` and `LogDebug` macros in `Vibe-Prefix.pch` wrap Apple's unified logging (`os_log`) under the subsystem `com.commonwealthrecordings.Vibe`. Info and debug are not persisted to the log store, so stream them live. Use the full path, since zsh has a `log` builtin:

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'
```

### On a real device, os_log is out of reach — use `--log-stderr`

**None of the log-streaming above works against an iPhone.** `log stream` has no device mode any more on current macOS (no `--device`/`--device-name`), and `idevicesyslog` — which does connect, over USB, once `brew install libimobiledevice` and a cable are in place — carries plenty *about* the app from SpringBoard and runningboardd but **nothing the app itself logs**: a third-party subsystem's `os_log` output never reaches `syslog_relay`. Measured: 62,833 syslog lines in eight seconds, not one of them from Vibe.

So debug builds take `--log-stderr` (`Vibe-Prefix.pch`), which mirrors every `Log*` message to stderr, timestamped, alongside `os_log`. `devicectl` relays stderr straight back:

```bash
xcrun devicectl device install app --device <udid> build/DerivedData/Build/Products/Debug-iphoneos/Vibe.app
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
    com.commonwealthrecordings.Vibe --log-stderr
```

Off by default, so the simulator and mac loops keep reading the unified log exactly as before. Build for a device with `-destination 'generic/platform=iOS' -allowProvisioningUpdates`; the app signs with the team already in `project.yml`.

TRAP: the `--console` session owns the process. When its tunnel drops — which it does — the app goes down with it, and the error names RemoteXPC rather than anything about Vibe. Relaunch without `--console` if you only need the app up.

The debug command channel does **not** reach a device yet: it is command and response files in the app container, and the host cannot write there directly. `xcrun devicectl device copy to/from --domain-type appDataContainer --domain-identifier com.commonwealthrecordings.Vibe` can, so the same protocol would work over it — unbuilt, and the reason the device loop is log-only today.

### Build provenance: which build produced this log?

`applicationDidFinishLaunching` logs a provenance block through `AppDelegate.logBuildInfo`, so a log excerpt identifies the exact build it came from — version, config, git commit and dirty flag, compiler, SDK and host OS. How it is recovered at runtime, and why the git fields need a build-time script phase: **`references/build-provenance.md`**.
