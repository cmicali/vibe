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

## macOS: launch, drive, inspect

```bash
.claude/skills/vibe-debug/scripts/launch.sh [audio-file ...]   # quit, open -a, poll the channel, print dump_state; honors $VIBE_APP, VIBE_LANGUAGE=de
"$V" --debug-cmd dump_state                                     # {player, currentTrack, playlist, ui, window, settings}
"$V" --debug-cmd check_consistency                              # the app's own rules against live state; re-check after a settle
"$V" --debug-cmd dump_screenshot - > shot.png                   # always the `-` form: a path reply is inside the container, and reading it trips TCC
/usr/bin/log stream --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'   # info/debug are never persisted; full path, zsh has a `log` builtin
```

Every verb with its arguments and reply schema is `references/mac-verbs.md`; the channel's unknown-command reply is the authoritative list. Prefer the channel to lldb, CGEvents, or AppleScript: no permissions, no frontmost requirement, no pausing.

**Audio flags, and what each run proves.** `launch.sh` passes both debug-only argv flags by default:

- `--no-audio-hw`: manual rendering with a real-time-paced pump. No CoreAudio device is opened, so a run cannot trigger AirPods auto-switching; playback, position, waveform, and FX behave normally. `dump_state.player.manualRendering` is what actually happened (`enableManualRenderingMode` can fail, and the engine then opens the device as usual) — **trust `manualRendering`, not `noAudioHw`**.
- `--silent`: zeroes the main mixer but opens and drives the real output device — real-HAL behavior without noise (device switching, config-change notifications, output-latency timing).
- `VIBE_AUDIBLE=1` uses real hardware audibly; `VIBE_AUDIBLE=silent` is `--silent` alone.

Which run proves what:

- **Equalizer bars.** `--silent` zeroes the signal above the tap, so a healthy default run draws dots. Functional EQ checks off hardware need a manual launch with only `--no-audio-hw`. `dump_equalizer` reports the launch flags — check them before calling flat bars a defect. Counters and bounds: `references/equalizer-counters.md`.
- **Start latency.** TRAP: never measure it under `--no-audio-hw`. The pump is not a clock: a file whose sample rate differs from the render format can sit at position 0 for seconds. Use `VIBE_AUDIBLE=silent`; the answer is then exact without instrumentation, since `position` is rendered audio and at poll time `T` with position `P` playback began at `T - P`. `player.state` is the pending *intent* (`playing` during a cloud open that has not landed), so time an open by position movement, never the state string.
- **Now Playing, media keys, Control Center, Bluetooth transport.** `--no-audio-hw` suppresses the publish outright, since registering as the active media app alone pulls AirPods over; `dump_now_playing` then reports `hasInfo: 0` — correct, not a bug. Launch with `VIBE_AUDIBLE=1`, and expect it to take the AirPods.

**Launching by hand.**

- Off the hardware too: `open -a "$APP" <files> --args --no-audio-hw --silent`, `--args` last since everything after it is argv. Direct exec takes argv natively: `"$V" --no-audio-hw --silent &`.
- **Feed files with `open -a "$APP" <file>`.** The sandbox denies raw argv paths (no Launch Services grant), so `"$V" <file>` fails. `--debug-cmd open <path>` grants nothing either: container paths or paths already granted this session only. The same denial reaches `file_cache`, `file_drag_drop`, and a `script <file>` argument.
- TRAP: **check which binary answers before trusting any observation.** With Vibe running from Xcode, Launch Services routes `open -a` to that instance and you test a stale build with no error: `ps -o pid,command -p $(pgrep -x Vibe)`. If it is not your build, stop the Xcode session or direct-exec a second instance (cannot open files, dies with the shell). With **two instances the channel is racy** — either may consume a command file — so quit one first.
- TRAP: **never `pkill` an instance Xcode is debugging.** The debugger traps SIGTERM and *stops* the process: it keeps its pid, answers nothing, and every later `--debug-cmd` burns its full timeout as a fake hang. `launch.sh` handles this (its header is the authority); by hand, `--debug-cmd quit` first — also the only exit that runs `applicationWillTerminate:` — and a leading `T` in `ps -o stat=` means stopped: continue it in Xcode (⌘.).

## The channel's contract

**Every command replies with exactly one JSON object**; errors are `{"error": "…"}`. Exit codes: 0 ok, 1 no response (no debug build running), 2 command error, 64 usage. Action replies are read synchronously and lag async engine work — confirm with `dump_state`. Arguments reach the app as an array, never re-tokenized, so a quoted path with spaces is safe.

Never scrape text. Filter with `jq` — `-r` for shell substitution, `-e` to assert (nonzero on `false` or `null`, so it doubles as the test) — and pipe through `printf '%s' "$out"`, not `echo`, which in zsh rewrites `\t` inside the JSON into illegal control characters. **`jq`, not python**: before-and-after is two `-r` extractions and a shell compare; python earns its place only walking whole `dump_view_tree` subtrees.

```bash
"$V" --debug-cmd dump_state | jq -e '.player.state == "playing"' >/dev/null   # assert; nonzero if not
before=$("$V" --debug-cmd dump_state | jq -r .player.position)
"$V" --debug-cmd skip_forward >/dev/null
after=$("$V" --debug-cmd dump_state | jq -r .player.position)
awk -v a="$before" -v b="$after" 'BEGIN{exit !(b>a)}' || echo "FAIL: $before -> $after"
```

`.player.state` is lowercase and only ever `playing`, `paused`, or `stopped`. There is **no `loading`**: an in-flight open reports its pending intent with zero position and duration; `ui.displayState` is the settled UI. Asserting `== "Playing"` silently never matches.

**Verb naming rule.** Families take a verb-kind prefix (`dump_*` reads state, `set_*` writes a knob, `clear_*`, `settings_*`, `scan_*`); everything else is named for its feature (`seek`, `convert_to_flac`, `reorder_begin`). When two verbs could share a word, the object goes in the name: `file_drag_*` is an external file drop, `reorder_*` the internal row drag, bare `drag` posts pointer events. Never a subsystem prefix (`playlist_*`, `transport_*`): the feature name is the namespace. A verb both platforms can answer lives once in `Vibe/Debug/DebugCommonVerbs.m`; only a platform-specific one goes in `Mac/` or `iOS/`.

**Menus.** `dump_menu` and `click_menu` run the real `validateMenuItem` pass, so enabled state is live. TRAP: **items gated on the player window being key** — Save Playlist…, Play Selected Track, Remove from Playlist, Close — read `enabled: false` and `click_menu` refuses them whenever it is not, the normal state once the terminal has focus back after `launch.sh`. Re-activate with `open -a "$PWD/$APP"` (absolute; a relative path fails) and `dump_state.window.keyWindow` flips true. `click_menu menu_save_playlist` then raises the real powerbox sheet, which no verb can dismiss (a posted `key esc` never reaches the remote view): drive saves with `save_playlist` and leave the sheet to a human.

**Prefs.** Never `defaults write com.commonwealthrecordings.Vibe …`: the sandboxed prefs live in the container, and a shell `defaults` trips the "access data from other apps" TCC prompt. Use the `set_*` verbs and read `dump_state.settings`.

**Caches and conversion.** `clear_caches` blocks until both PINCaches are empty (allow 15s after feeding a long file); `scripts/clear-caches.sh` also works with the app down, deleting inside the CLI process so no shell `rm` touches the container. `convert_to_flac` writes beside the source: a working copy, never `Assets/test_audio_files/`.

### Command scripts

`script -` runs one verb per line (blank lines and `#` comments skipped; quotes group arguments, no escapes). Replies stream as NDJSON, and the script **stops at the first failing command** with its exit code, so exit 0 means every step passed. **Always feed it on stdin** — a heredoc or `script - < file` — since the sandboxed client usually cannot read a script by path. `sleep 0.2` is client-side, so the app never blocks; `scan_bpm -` and a nested `script` are unavailable inside one. A `dump_screenshot [label]` line carries the PNG as base64 (~100 KB — never run that raw): the wrapper decodes each to `<shots-dir>/shot-NN[-label].png` in command order, then `Read` the PNGs:

```bash
.claude/skills/vibe-debug/scripts/run-script.sh /tmp/shots <<'EOF'
open "/path/with spaces/track.wav"
sleep 1
dump_screenshot after-open
play_pause
dump_state
EOF
```

### The settings window

Five verbs of its own — `settings_open`, `dump_settings_ui`, `settings_click`, `settings_resize`, `settings_close` — and **never `click`, `drag`, or the `key*` verbs**, which post into the player window. Replies, control naming, and the kind table: `references/settings-window.md`. Traps:

- A `settings_click` that changes a pane's measured height starts the 0.12s coordinated resize; wait 0.2s before asserting frames or rects. `paneFillsTabView` is the collapsed-pane oracle: `dump_settings_ui` still reports plausible rects while nothing can be clicked.
- **A sheet blocks everything behind it**: `settings_click` refuses and `dump_settings_ui` reports `sheet`; only `settings_close` clears it. Add Folder, Add Common Folder, an editor image preview click, and Set Vibe as Default Music Player raise system panels no verb can dismiss — leave them to a human.
- Hover badges (the editor's clear-image ✕) need a real hover through `input.swift` first; posted events never fire tracking areas. The font panel cannot be driven: `import_theme`/`set_theme` are the scripted route to a font change.
- **Assert the setting through `dump_state.settings`, not the control.** The control moving proves the click landed; the setting proves the action ran.
- `settings_resize` replies with the frame after a layout flush, so a constraint snap-back is observable in the reply.

### In-process input injection

**Reserve raw input for explicit gesture tests.** Unattended stress uses controller/delegate commands (`seek`, `set_pitch`, `select_rows`, `remove_selected`, `reorder_*`, `file_drag_*`), never arbitrary clicks or drags. Use `vibe-stress`'s named `--gesture-test` cases for pitch-fader mechanics on an isolated test desktop. For another gesture, follow the [targeted OS-input workflow](references/os-input.md): identify a control, resolve fresh geometry, check the result, and stop on a missed target. Never fall back to global input to recover a stress run.

**App-local injection does not contain its effects.** A handler may initiate native file dragging (artwork and playlist rows) or window dragging (background and waveform). Mouse injection also activates Vibe. Real input tests belong on a dedicated test Mac or disposable macOS VM, not the user's working desktop.

`click`, `drag`, `mouse_*` and the `key*` verbs post synthesized NSEvents into the app's own event queue. Unlike the other `--debug-cmd` verbs, which call controller actions directly, these exercise the **real event dispatch path**: `TransportKeyMonitor`, view `mouseDown:` and tracking loops, and menu key equivalents. Unlike CGEvent injection through `input.swift`, they need no Accessibility permission and target Vibe's event queue directly. This does not prevent a handler from starting an OS interaction.


The global-input helper `input.swift` requires `--isolated-desktop`, which asserts isolation rather than creating it.

- **Coordinates are main-window points, top-left origin** — the `dump_screenshot` frame, retina pixel ÷ 2. `dump_view_tree` frames are AppKit **bottom-left** in the superview; convert with the window height. Mouse replies carry `hitView`, so a missed aim shows at once.
- Mouse injection **self-activates the app**, since a non-key window swallows the first click as activation; keyboard injection needs no activation. Replies are written when events are *queued*, so poll `dump_state`.
- TRAP: **a lone `mouse_down` on a control that runs a modal tracking loop** (a button) stalls the app inside that loop and the channel cannot deliver the `mouse_up`. Stop the test and capture diagnostics; do not attempt global-input recovery during stress. Use `click` or `drag`, which queue the whole gesture before the loop starts; keep `mouse_down`/`mouse_up` for plain responder-method views.
- TRAP: **`click x y right` on a view with a context menu** (a playlist row) opens a *real* menu that blocks the channel until dismissed. Do it only with a dismisser in place: a human, or a `key esc` posted *before* the right-click, since it cannot be delivered afterwards.

## Screenshots and appearance

`dump_screenshot -` renders the layer tree in-process — no permission, works occluded, frontmost not required — so default to it for layout, text, color, artwork, and waveform checks. It structurally **cannot** show `NSVisualEffectView` materials, the `NSGlassEffectView` chrome, or Metal content: never judge window background, material, tint-wash, or appearance blending from it. Those need real capture, `scripts/capture-window.sh out.png [pid]` (Screen Recording permission), with `probe-pixel.swift` to assert numerically instead of eyeballing grays. Window selection, blind spots, probes: `references/screenshots-and-logs.md`.

`set_appearance light|dark|system` flips the window live (`AppSettings.windowAppearanceStyle`); a theme's color *mode* (`AppTheme.mode`) is separate, driven through `import_theme`/`set_theme`. Test both modes for any color or material change, with real capture for backgrounds: a light window over a dark system is a supported, once buggy, combination.

## Logs

Stream, never `log show` — the one-liner above. A real phone offers no unified-log stream at all, so debug builds take `--log-stderr`, which mirrors every `Log*` line to stderr for `devicectl` to relay (commands: `references/screenshots-and-logs.md`). TRAP: the `--console` session owns the process — when its tunnel drops, which it does, the app dies with it and the error names RemoteXPC, not Vibe. Relaunch without `--console` if you only need the app up. Which build produced a log: `references/build-provenance.md`.

## iOS: the simulator loop

```bash
.claude/skills/vibe-debug/scripts/launch-ios.sh [audio-file ...]   # create+boot this session's device, install if stale, seed files, relaunch, wait for the channel
.claude/skills/vibe-debug/scripts/debug-ios.sh dump_state          # the channel: same JSON contract and jq rules as the mac; VIBE_DEBUG_TIMEOUT overrides 10s
.claude/skills/vibe-debug/scripts/drive-ios.sh start|status|tap|drag|pinch|type|rotate|stop   # real touches via the resident XCUITest driver
xcrun simctl io "$(.claude/skills/vibe-debug/scripts/sim-udid.sh)" screenshot shot.png   # ground-truth pixels (3x, top-left)
```

Build with `make build-ios CONFIG=Debug` (generic simulator destination, unsigned, into `build/DerivedData`). The mac `--debug-cmd` verbs are mac-only; every iOS verb, the driver's gestures and latency, install staleness, per-session simulators, the build lock, and iPad: `references/ios-verbs.md`.

- **Simulator only — never a connected phone.** Never a device destination (`platform=iOS`, a UDID, a name), never `devicectl` or `ios-deploy`, never an auto-resolved destination: a plugged-in phone is the user's personal device. An explicit request for an on-device run covers **that one run only** and is never recorded as a default in scripts, docs, or memory.
- **Each session has its own simulator device** (`sim-udid.sh`), so raw `simctl` commands target `"$(sim-udid.sh)"`, never `booted`. Same-checkout sessions still share one build tree, so builds and installs serialize through `scripts/build-lock.sh`; gestures, screenshots, and the channel never take it.
- **Audio is silent by default** (same flags as macOS); `VIBE_AUDIBLE=1` for live EQ motion. Flags apply only at `simctl launch` — a later `openurl` reuses the process — so relaunch to change them.
- **Seeded files make a one-track playlist**: a single-file open grants no siblings on iOS. For directory-as-playlist, seed the files and pick the Music *folder* in-app.
- **Three tiers, cheapest first.** (1) Look and read: `launch-ios.sh`, a screenshot, `dump_state`/`dump_view_tree`. (2) Make things happen: the channel's action verbs — `seek` takes the scrubber's own `didSeek` path, so a seek test needs no drag. (3) Real gestures: `drive-ios.sh`, only when the gesture itself is under test (1:1 waveform tracking, the pager pull, tap targets). A session costs 1–2 minutes and a reinstall: never start one speculatively, and keep it for the whole work session.
- **No input injection on iOS** — no public API synthesizes `UITouch`es, so the driver is the only touch path. The mac's menu, window, FX, pitch, convert, and file_cache verbs have no iOS counterparts.
- TRAP: **`appStale: true` (`drive-ios.sh status`) invalidates every gesture result since the rebuild** — a stale app launches, answers, and accepts touches exactly like a fresh one, so nothing else will tell you. Rerun `launch-ios.sh` after any rebuild.
- **TRAP: a folder added with `add_search_folder` is NOT security-scoped** and survives only the session: a bare path, not a picker bookmark, so a relaunch must add it again and the bookmark round-trip goes unexercised.
- **TRAP: `tap_favorite_star`'s ADD is asynchronous** (the bookmark is minted off main) — `ok:true` means the handler ran; poll `dump_favorites` for the row.
- **Check `ui.waveformBaked` after `expand_player`.** The card animates by transform so the scrubbers never re-bake; `waveformBaked:false` means something animated its bounds again (`Vibe/iOS/CLAUDE.md`).
- **Logs stream from the HOST** (the simulator writes into the mac's unified log; `simctl spawn … log stream` is refused): the same `/usr/bin/log stream` line as macOS.
- **Simulator blind spots** — interruptions, route changes, background audio past lock, the lock-screen card — need a real device; report them as unverified rather than driving a phone (`references/ios-verbs.md`).

## Test audio

`Assets/test_audio_files/` (gitignored), generated by `scripts/generate-test-audio.sh`; never synthesize your own. Which file for which test, the slow-cloud-open simulation (`set_fake_cloud`), and the one-shot `scan-bpm.sh`/`scan-key.sh`: `references/test-audio.md`.

## Stress, soak, and fuzz

The **`vibe-stress` skill** (`make stress`, `make torture`) drives this channel randomly for hours with oracles; its verbs (`dump_health`, `check_consistency`, `quiesce`, `dump_cloud_trace`) are ordinary channel commands in `references/mac-verbs.md`.

## Supporting files

- `references/mac-verbs.md` — every macOS verb with arguments and reply schema; conversion and undo, cloud staging, row reorder, themes, measurement. Read when a verb's arguments or reply keys are needed.
- `references/ios-verbs.md` — every `debug-ios.sh` verb, the touch driver, install staleness, per-session simulators and the build lock, iPad, the simulator's blind spots. Read when driving the simulator beyond `dump_state`.
- `references/settings-window.md` — the five settings verbs' replies, control naming, the kind table. Read when driving a Settings pane.
- `references/equalizer-counters.md` — `dump_equalizer`'s schema and bounds, `set_equalizer_mode`. Read when judging the equalizer bars.
- `references/screenshots-and-logs.md` — how the snapshot picks a window and what it cannot render, real capture and pixel probes, on-device `--log-stderr`. Read when a screenshot looks wrong or a log must come off a phone.
- `references/test-audio.md` — the fixture table, `set_fake_cloud` and its prefetch trap, `scan_bpm`/`scan_key`. Read before picking a file for a test.
- `references/os-input.md` — CGEvents through the window server for hover, focus, and drop targets. Read when an explicit gesture test needs OS input on an isolated test desktop.
- `references/build-provenance.md` — the launch-time provenance block and how the git fields reach the binary. Read when a log must be tied to a build.
