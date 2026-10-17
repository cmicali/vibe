---
name: vibe-debug
description: Launch, drive, inspect, and visually verify the Vibe app — macOS, and the iOS simulator loop (launch-ios.sh, the debug-ios.sh command channel, the drive-ios.sh touch driver for taps and drags, silent flags, screenshots, host-side log streaming). Use whenever a change needs end-to-end verification, a screenshot of the running app, playback/UI state inspection, or appearance (light/dark) testing.
---

# Debugging and verifying Vibe

All debug tooling compiles into **debug builds only** (`Vibe/Debug/`). `launch.sh` looks in `build/DerivedData`, where `make build` writes:

```bash
make build CONFIG=Debug
APP=build/DerivedData/Build/Products/Debug/Vibe.app
V="$APP/Contents/MacOS/Vibe"      # the binary is its own CLI client (same sandbox and container)
```

**Every script here returns when its work is done.** Nothing a script leaves running holds the caller's stdout or stderr, so `| tail`, `| jq` and `$(…)` are safe on all of them. A script that does not return is a bug in that script. Fix it with the pattern in `drive-ios.sh`'s TRAP (one backgrounded simple command, all three streams redirected). Never pipe or redirect around it.

## macOS: launch, drive, inspect

```bash
.claude/skills/vibe-debug/scripts/launch.sh [audio-file ...]   # quit, open -a, poll the channel, print dump_state, raise the window; honors $VIBE_APP, VIBE_LANGUAGE=de
"$V" --debug-cmd dump_state                                     # {player, currentTrack, playlist, fx, ui, window, settings}
"$V" --debug-cmd check_consistency                              # the app's own rules against live state; re-check after a settle
"$V" --debug-cmd dump_screenshot - > shot.png                   # always the `-` form: a path reply is inside the container, and reading it trips TCC
/usr/bin/log stream --timeout 30m --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'   # info/debug need streaming when verbose logging is off; full path, zsh has a `log` builtin
```

`references/mac-verbs.md` describes the channel verbs and their replies. The channel's unknown-command reply is the authoritative list. Prefer the channel to lldb, CGEvents or AppleScript: it needs no permissions, no frontmost window and no pausing.

The opt-in bit-perfect acceptance matrix is `make test-bit-perfect`. Setup and coverage are in `references/test-audio.md`. It is excluded from regular tests and CI. `make build-test-blackhole` builds its driver fixtures, and installing them needs administrator authentication.

**Audio flags.** `launch.sh` passes both debug-only argv flags by default:

- `--no-audio-hw`: the debug pump calls the production render at real-time pace instead of the output unit. No CoreAudio device opens, so a run cannot trigger AirPods auto-switching. Playback, position, waveform, FX and the equalizer behave normally. `dump_state.player.manualRendering` is true once the pump is attached.
- `--silent`: zeroes the output's buffers after the meter but drives the real output device. Use it for real-HAL behavior without noise (device switching, rate changes, output latency).
- `VIBE_AUDIBLE=1` uses real hardware audibly. `VIBE_AUDIBLE=silent` is `--silent` alone.
- `--no-now-playing` is also passed by default. It suppresses media focus and remote commands without changing the render path. Set `VIBE_NOW_PLAYING=1` only to verify media integration. Loopback captures keep it suppressed.
- TRAP: **select the output before any real-HAL run opens a file.** The system default is often Bluetooth headphones, and starting output on them can pull them off the user's other device. `set_bit_perfect` is also a no-op on System Output, so a bit-perfect check that skipped the selection tests ordinary mode and reports `bp off` for every file. The launchers do not select or restore an output. Start without files, select the intended device, then open the fixture. Restore the previous selection after the run. `--no-audio-hw` launches open no device and need nothing.

Which run proves what:

- **Equalizer bars.** The meter reads the final samples before `--silent` zeroes them, so the bars are live under the default launch and under `--silent`. `dump_equalizer` reports the launch flags. Counters and bounds are in `references/equalizer-counters.md`.
- **Start latency.** TRAP: never measure it under `--no-audio-hw`. The pump is a timer, not the device's clock. Use `VIBE_AUDIBLE=silent`. For a fresh start at position zero, `T - P` estimates the start time from poll time `T` and position `P`. It does not measure when sound leaves the device. `player.state` is the pending intent (`playing` during a cloud open that has not landed), so time an open by position movement, never by the state string.
- **Now Playing, media keys, Control Center, Bluetooth transport.** `--no-audio-hw` and `--no-now-playing` suppress the publish, since registering as the active media app pulls AirPods over. `dump_now_playing` then reports `hasInfo: 0`, which is correct. Launch with `VIBE_NOW_PLAYING=1 VIBE_AUDIBLE=1` and expect it to take the AirPods.

**Launching by hand.**

- `open -a "$APP" <files> --args --no-audio-hw --silent`, with `--args` last since everything after it is argv. Direct exec takes argv natively: `"$V" --no-audio-hw --silent >/dev/null 2>&1 </dev/null &`. Redirect it so the app holds no pipe of yours.
- **A Debug build starts no updater** unless launched with `--update-feed <url>`. To test updates, build two versions with a throwaway key and serve a feed on `localhost` (`Vibe/ThirdParty/AGENTS.md`, Sparkle).
- **Feed files with `open -a "$APP" <file>`.** The sandbox denies raw argv paths, so `"$V" <file>` fails. `--debug-cmd open <path>` grants nothing either: it reaches container paths and paths already granted this session. The same applies to `file_cache`, `file_drag_drop` and a `script <file>` argument.
- TRAP: **check which binary answers before trusting any observation.** With Vibe running from Xcode, Launch Services routes `open -a` to that instance, and you test a stale build with no error. Check with `ps -o pid,command -p $(pgrep -x Vibe)`. With **two instances the channel is racy**, since either may consume a command file, so quit one first.
- TRAP: **`launch.sh` quits every mac Vibe, including the user's own `/Applications/Vibe.app`.** Check `pgrep -x Vibe` and `ps -o command=` first. A Release instance never answers the channel. To verify beside it, direct-exec a Debug instance (`nohup <literal path>/Contents/MacOS/Vibe --silent --no-now-playing &`; the sandbox refuses a variable under `nohup`). Stage files under `~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/` and open them with `--debug-cmd open`. Both instances share the container's defaults, so restore every setting the run touches. Quit only your own with `--debug-cmd quit`. `make test-audio-loopback`, `make stress`, `make torture` and `device-flap.py` need exactly one instance. Say so rather than kill the user's.
- **Counting instances.** `pgrep -x Vibe` also matches the iOS simulator's app (`launch.sh` excludes `CoreSimulator`). A `--debug-cmd` client is the same binary, so exclude it: `ps -eo command | grep MacOS/Vibe | grep -v -- --debug-cmd`. With no app running each client call waits its full timeout. A loop waiting for the channel needs `VIBE_DEBUG_TIMEOUT=1` and a check that the app process still exists.
- TRAP: **never `pkill` an instance Xcode is debugging.** The debugger traps SIGTERM and stops the process. It keeps its pid and answers nothing, so every later `--debug-cmd` burns its full timeout. `launch.sh` handles this (its header is the authority). By hand, send `--debug-cmd quit` first, which is also the only exit that runs `applicationWillTerminate:`. A leading `T` in `ps -o stat=` means stopped: continue it in Xcode.

## The channel's contract

**Every command replies with exactly one JSON object**. Errors are `{"error": "…"}`. Exit codes: 0 ok, 1 no response (no debug build running), 2 command error, 64 usage. The wait is 5 s unless the verb declares its own window. `VIBE_DEBUG_TIMEOUT=<seconds>` replaces that default for verbs with no window of their own. A script that drives the failure fixtures needs it, since a dead device can hold the main thread for 14 s and more. Action replies are read synchronously and lag async pipeline work, so confirm with `dump_state`. Arguments reach the app as an array and are never re-tokenized, so a quoted path with spaces is safe.

Never scrape text. Filter with `jq`: `-r` for shell substitution, `-e` to assert (nonzero on `false` or `null`). Pipe through `printf '%s' "$out"`, not `echo`, because zsh's `echo` rewrites `\t` inside the JSON into illegal control characters. **Use the script runner and `jq`, not generated Python**, for commands, saved snapshots and assertions.

```bash
"$V" --debug-cmd dump_state | jq -e '.player.state == "playing"' >/dev/null   # assert; nonzero if not
before=$("$V" --debug-cmd dump_state | jq -r .player.position)
"$V" --debug-cmd skip_forward >/dev/null
after=$("$V" --debug-cmd dump_state | jq -r .player.position)
awk -v a="$before" -v b="$after" 'BEGIN{exit !(b>a)}' || echo "FAIL: $before -> $after"
```

`.player.state` is lowercase and only ever `playing`, `paused` or `stopped`. There is **no `loading`**. An in-flight open reports its pending intent with zero position and duration. `ui.displayState` is the settled UI.

**Verb naming rule.** Families take a verb-kind prefix (`dump_*` reads state, `set_*` writes a knob, `clear_*`, `settings_*`, `scan_*`). Everything else is named for its feature (`seek`, `convert_to_flac`, `reorder_begin`). When two verbs could share a word, the object goes in the name: `file_drag_*` is an external file drop, `reorder_*` the internal row drag, bare `drag` posts pointer events. Never use a subsystem prefix (`playlist_*`). A verb both platforms can answer lives once in `Vibe/Debug/Verbs/`, in its topic's file: `DebugStallVerbs.m`, `DebugAudioVerbs.m` or `DebugLoadingVerbs.m`, else `DebugCommonVerbs.m`. Only a platform-specific one goes in `Mac/` or `iOS/`, again in its topic's file when it has one.

**Menus.** `dump_menu` and `click_menu` run the real `validateMenuItem` pass. TRAP: **items gated on the player window being key** (Save Playlist…, Play Selected Track, Remove from Playlist, Close) read `enabled: false`, and `click_menu` refuses them, whenever the window is not key. That is the normal state once the terminal has focus back after `launch.sh`. Re-activate with `open -a "$PWD/$APP"` (absolute path) and check `dump_state.window.keyWindow`. `click_menu menu_save_playlist` raises the real powerbox sheet, which no verb can dismiss. Drive saves with `save_playlist` instead.

**Prefs.** Never `defaults write com.commonwealthrecordings.Vibe …`. The sandboxed prefs live in the container, and a shell `defaults` trips the "access data from other apps" TCC prompt. Use the `set_*` verbs and read `dump_state.settings`.

**Caches and conversion.** `clear_caches` blocks until both PINCaches are empty (allow 15 s after feeding a long file). `scripts/clear-caches.sh` also works with the app down, deleting inside the CLI process so no shell `rm` touches the container. `convert_to_flac` writes beside the source, so use a working copy, never `Assets/test_audio_files/`.

### Command scripts

`script -` runs one verb per line. Blank lines and `#` comments are skipped, and quotes group arguments (no escapes). Replies stream as NDJSON, and the script **stops at the first failing command** with its exit code. **Always feed it on stdin** (a heredoc or `script - < file`), since the sandboxed client usually cannot read a script by path. `sleep 0.2` is client-side. `scan_bpm -` and a nested `script` are unavailable inside one. A `dump_screenshot [label]` line carries the PNG as base64 (about 100 KB, never run it raw). The wrapper decodes each to `<output-dir>/shot-NN[-label].png` and saves every reply to `replies.jsonl`, partial output included. Use a fresh output directory per run.

```bash
.claude/skills/vibe-debug/scripts/run-script.sh /tmp/shots <<'EOF'
open "/path/with spaces/track.wav"
sleep 1
dump_screenshot after-open
play_pause
dump_state
EOF
```

`--assert '<jq predicate>'`, before the output directory, checks the **array of all replies after the script succeeds**. The result must be `true`. Anything else fails with exit 2. Assertions do not interrupt the sequence, so split dependent phases into separate runs.

```bash
.claude/skills/vibe-debug/scripts/run-script.sh --assert '
  [ .[] | select(has("settings")) | .settings ] as $states |
  ($states | length) == 2 and $states[0] == $states[1]
' /tmp/settings-read-check <<'EOF'
dump_state
settings_open files
dump_settings_ui
dump_state
EOF
jq -s 'map(select(has("controls")))[0]' /tmp/settings-read-check/replies.jsonl   # a saved snapshot, no app read
```

### The settings window

Six verbs of its own: `settings_open`, `dump_settings_ui`, `settings_click`, `settings_reveal`, `settings_resize`, `settings_close`. **Never use `click`, `drag` or the `key*` verbs on it.** The mouse verbs post into the player window, and the key verbs into whichever window is key. Replies, control naming and the kind table are in `references/settings-window.md`. Traps:

- A `settings_click` that changes a pane's height starts the 0.12 s coordinated resize. Wait 0.2 s before asserting frames. `paneFillsTabView` is the collapsed-pane oracle, since `dump_settings_ui` still reports plausible rects while nothing can be clicked.
- **A sheet blocks everything behind it.** `settings_click` refuses and `dump_settings_ui` reports `sheet`. Only `settings_close` clears it. Add Folder, Add Common Folder, an editor image preview click and Set Vibe as Default Music Player raise system panels no verb can dismiss. Leave them to a human.
- Hover badges (the editor's clear-image ✕) need a real hover through `input.swift`. Posted events never fire tracking areas. The font panel cannot be driven: `import_theme` and `set_theme` are the scripted route to a font change.
- **Assert the setting through `dump_state.settings`, not the control.** The control moving proves the click landed. The setting proves the action ran.
- For disabled styling, read each control's `alpha`, `effectiveAlpha`, `rowTitle` and `rowCaption` from `dump_settings_ui`. `hidden` is independent of opacity.
- `settings_resize` replies with the frame after a layout flush, so a constraint snap-back shows in the reply.

### In-process input injection

**Reserve raw input for explicit gesture tests.** Unattended stress uses controller and delegate commands (`seek`, `set_pitch`, `select_rows`, `remove_selected`, `reorder_*`, `file_drag_*`), never clicks or drags. For pitch-fader gestures use `vibe-stress`'s named `--gesture-test` cases on an isolated test desktop. For another gesture, follow `references/os-input.md`. Never fall back to global input to recover a stress run.

`click`, `drag`, `mouse_*` and the `key*` verbs post synthesized NSEvents into the app's own event queue. They exercise the **real event dispatch path** (`TransportKeyMonitor`, view `mouseDown:` and tracking loops, menu key equivalents) and need no Accessibility permission. **They do not contain their effects.** A handler may start a native file drag (artwork and playlist rows) or a window drag (background and waveform), and mouse injection activates Vibe. Real input tests belong on a dedicated test Mac or disposable macOS VM. `input.swift`, the global-input helper, requires `--isolated-desktop`, which asserts isolation rather than creating it.

- **Coordinates are main-window points, top-left origin**: the `dump_screenshot` frame, screenshot pixels divided by its reported scale. `dump_view_tree` frames are AppKit bottom-left in the superview. Mouse replies carry `hitView`, so a missed aim shows at once.
- Mouse injection **activates the app**, since a non-key window swallows the first click. Keyboard injection needs no activation. Replies are written when events are queued, so poll `dump_state`.
- TRAP: **a lone `mouse_down` on a control that runs a modal tracking loop** (a button) stalls the app inside that loop, and the channel cannot deliver the `mouse_up`. Use `click` or `drag`, which queue the whole gesture first. Keep `mouse_down`/`mouse_up` for plain responder-method views.
- TRAP: **`click x y right` on a view with a context menu** (a playlist row) opens a real menu that blocks the channel until dismissed. Do it only with a dismisser in place: a human, or a `key esc` posted before the right-click.

## Screenshots and appearance

`dump_screenshot -` renders the layer tree in-process. It needs no permission and works occluded, so default to it for layout, text, color, artwork and waveform checks. It **cannot** show `NSVisualEffectView` materials, the `NSGlassEffectView` chrome or Metal content. Never judge window background, material, tint wash or appearance blending from it. Those need real capture with `scripts/capture-window.sh out.png [pid]` (Screen Recording permission), and `probe-pixel.swift` to assert numerically. Details are in `references/screenshots-and-logs.md`.

`set_appearance light|dark|system` flips the window live (`AppSettings.windowAppearanceStyle`). A theme's color mode (`AppTheme.mode`) is separate and is driven through `import_theme` or `set_theme`. Test both appearances for any color or material change, with real capture for backgrounds. A light window over a dark system is a supported combination.

## Logs

Stream with the command above. Verbose builds persist info, debug and warning messages at Default level. Settings > Advanced > Save Debug Info retrieves those logs. TRAP: a stream never ends by itself, so every one takes `--timeout` (`-T <num>[m|h|d]`). One left in the background outlives the session and keeps `diagnosticd` busy. A real phone has no unified-log stream, so debug builds take `--log-stderr`, which mirrors every `Log*` line to stderr for `devicectl` to relay (`references/screenshots-and-logs.md`). TRAP: the `--console` session owns the process. When its tunnel drops, the app dies with it and the error names RemoteXPC, not Vibe. Relaunch without `--console` if you only need the app up. Which build produced a log: `references/build-provenance.md`.

## iOS: the simulator loop

```bash
.claude/skills/vibe-debug/scripts/launch-ios.sh [audio-file ...]   # create+boot this session's device, install if stale, seed files, relaunch, wait for the channel
.claude/skills/vibe-debug/scripts/debug-ios.sh dump_state          # same JSON contract as the mac; waits 10 s or the verb's own longer window, VIBE_DEBUG_TIMEOUT overrides
.claude/skills/vibe-debug/scripts/debug-ios.sh --all dump_state dump_row_loading   # several dumps in one round trip, a JSON array in order
.claude/skills/vibe-debug/scripts/drive-ios.sh start|status|tap|drag|pinch|type|rotate|stop   # real touches via the resident XCUITest driver
xcrun simctl io "$(.claude/skills/vibe-debug/scripts/sim-udid.sh)" screenshot shot.png   # ground-truth pixels (3x, top-left)
```

Build with `make build-ios CONFIG=Debug`. Every iOS verb, the driver's gestures, install staleness, per-session simulators, the build lock and iPad are in `references/ios-verbs.md`.

- **Simulator only, never a connected phone.** Never use a device destination (`platform=iOS`, a UDID, a name), `devicectl`, `ios-deploy` or an auto-resolved destination. A plugged-in phone is the user's personal device. An explicit request for an on-device run covers that one run only and is never recorded as a default in scripts, docs or memory.
- **The simulator name uses the checkout path and `CLAUDE_CODE_SESSION_ID`** (`sim-udid.sh`). Without that variable, callers in one checkout share a device. Set `VIBE_SIM_UDID` or `VIBE_SIM_NAME` to isolate them. Target raw `simctl` commands at `"$(sim-udid.sh)"`. Same-checkout sessions share one build tree, so builds and installs serialize through `scripts/build/build-lock.sh`.
- **Three tiers, cheapest first.** (1) Look and read: `launch-ios.sh`, a screenshot, `dump_state`, `dump_view_tree`. (2) Make things happen with the action verbs. `seek` takes the scrubber's own `didSeek` path, so a seek test needs no drag. (3) Real gestures with `drive-ios.sh`, only when the gesture itself is under test. Starting the driver can require a build and reinstall. Keep it for the work session when gestures are needed.
- **No input injection on iOS.** No public API synthesizes `UITouch`es, so the driver is the only touch path. The mac's menu, window, FX, pitch and convert verbs have no iOS counterparts.
- TRAP: **`appStale: true` (`drive-ios.sh status`) invalidates every gesture result since the rebuild.** A stale app behaves exactly like a fresh one. Rerun `launch-ios.sh` after any rebuild.
- **TRAP: anything involving the home-screen widget needs `VIBE_SIGN_SIM=1 make build-ios CONFIG=Debug`.** The default build is unsigned, so it has no app-group entitlement and no group container. The app then publishes no snapshot and the widget sits on its placeholder, which looks like a broken widget. The flag ad-hoc signs with the entitlements, and the simulator needs no credentials. Do not check with `codesign -d --entitlements`, which prints an empty dict for any simulator build. Check that `xcrun simctl get_app_container "$(sim-udid.sh)" com.commonwealthrecordings.Vibe groups` resolves to a path.
- `dump_state.widget.placed` is the gate the app reads. False means WidgetKit reports no widget on any Home screen, and **the app then publishes nothing**, by design. Adding one from the widget gallery flips it, and the app republishes at once.
- **Audio is silent by default** (same flags as macOS). `VIBE_AUDIBLE=1` to hear it, `VIBE_AUDIBLE=silent` for the real RemoteIO output unit without sound. Flags apply only at `simctl launch`, since a later `openurl` reuses the process, so relaunch to change them.
- TRAP: **never run the simulator on real audio while the Mac's default output is the RME Fireface 802.** The simulator's RemoteIO builds an aggregate over the host default. Against that 30-channel interface `AURemoteIO::Initialize` times out and AudioToolbox aborts the app ("Initialize: RPC timeout. Apparently deadlocked"). From then on every new process that opens the Fireface hangs in `AudioComponentInstanceNew` until coreaudiod restarts (`sudo killall coreaudiod`, or a reboot), `make test` included. Switch the default first and put it back after. **After coreaudiod restarts, reboot the simulator** (`simctl shutdown`, then `boot`) before any real-audio run. Otherwise RemoteIO refuses every format (`OSStatus -10851`) and every play parks Paused with "Could not start the audio output".
- **Real-RemoteIO runs need a stable host audio lane.** The simulator shares the host's CoreAudio. Do not overlap a real-RemoteIO run with Mac bit-perfect or exclusive runs, host format writes, default-device changes or device-flap tests. A passing `check_consistency` and `state == playing` do not prove audio. At settled checkpoints, play a known long local file and require position or render counters to advance. On sustained no-progress, sample the app before sending more commands. An idle-stop check must allow the declared FX tail and require the output's actual `idle` edge. Eight seconds is not enough after enabling reverb. An unexplained RemoteIO abort under overlap is tracked in `docs/bugs/open-issues.md` ("iPad simulator aborts in RemoteIO stop").
- **Seeded files make a one-track playlist**, since a single-file open grants no siblings on iOS. For directory-as-playlist, seed the files and pick the Music folder in-app.
- **Two oracles for what a screenshot cannot judge.** `scripts/check-layout-stability.sh <gesture>` samples the live layout under the card across a gesture and fails if anything moved. `sample_frame_rate` and `dump_frame_rate` count the frames an animation got and how many ran long. On a phone the same probe runs from `--frame-rate-probe` into the log.
- **Dropbox needs no account in the simulator.** `set_fake_dropbox <host directory> [<transfer-seconds>]` makes that directory the account. `fake_dropbox_fault` scripts the streaming faults, and `scripts/dropbox-streaming.sh` runs every streaming scenario with JSON assertions (`references/ios-verbs.md`, "Streaming scenarios").
- **TRAP: a folder added with `add_search_folder` is not security-scoped**, so the scope round trip goes unexercised. It is still persisted and restored at the next launch. Remove what a test adds, and check `dump_search` after a relaunch.
- **TRAP: `tap_favorite_star`'s add is asynchronous.** `ok:true` means the handler ran. Poll `dump_favorites` for the row.
- **Check `ui.waveformShown` after `expand_player`.** The scrubber draws its waveform in the turn it is handed one (`Vibe/WaveformUI/iOS/AGENTS.md`). `false` with a loaded track means no waveform reached the page.
- **Logs stream from the host.** The simulator writes into the mac's unified log, and `simctl spawn … log stream` is refused. Use the same `/usr/bin/log stream` line as macOS.
- **Simulator blind spots** (interruptions, route changes, background audio past lock, the lock-screen card) need a real device. Report them as unverified rather than driving a phone.

## Test audio

`Assets/test_audio_files/` (gitignored) is generated by the repo's `scripts/test/generate-test-audio.sh`. Never synthesize your own. Which file suits which test, the slow-cloud-open simulation (`set_fake_cloud`) and the one-shot `scan-bpm.sh`/`scan-key.sh` are in `references/test-audio.md`.

## Stress, soak and fuzz

The **`vibe-stress` skill** (`make stress`, `make torture`) drives this channel randomly for hours with oracles. Its oracle verbs (`dump_health`, `check_consistency`, `quiesce`, `dump_cloud_trace`) are ordinary channel commands in `references/mac-verbs.md`.

## Supporting files

- `references/mac-verbs.md`: every macOS verb with arguments and reply schema, conversion and undo, cloud staging, row reorder, themes, measurement, output devices. Read when a verb's arguments or reply keys are needed.
- `references/ios-verbs.md`: every `debug-ios.sh` verb, the touch driver, install staleness, per-session simulators and the build lock, iPad, streaming scenarios. Read when driving the simulator beyond `dump_state`.
- `references/settings-window.md`: the settings verbs' replies, control naming, the kind table. Read when driving a Settings pane.
- `references/equalizer-counters.md`: `dump_equalizer`'s schema and bounds, `set_equalizer_mode`. Read when judging the equalizer bars.
- `references/screenshots-and-logs.md`: how the snapshot picks a window and what it cannot render, real capture and pixel probes, on-device `--log-stderr`. Read when a screenshot looks wrong or a log must come off a phone.
- `references/test-audio.md`: the fixture table, `set_fake_cloud` and its prefetch trap, `scan_bpm`/`scan_key`, render tests and bit-perfect acceptance. Read before picking a file for a test.
- `references/os-input.md`: CGEvents through the window server for hover, focus and drop targets. Read when an explicit gesture test needs OS input on an isolated test desktop.
- `references/build-provenance.md`: the launch-time provenance block. Read when a log must be tied to a build.
