---
name: vibe-debug
description: Launch, drive, inspect, and visually verify the Vibe app. Use whenever a change needs end-to-end verification, a screenshot of the running app, playback/UI state inspection, or appearance (light/dark) testing.
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
.claude/skills/vibe-debug/scripts/launch.sh [audio-file ...]   # kill, open -a, wait until ready
```

`launch.sh` relaunches the build and polls the debug channel until the app answers, then prints its `dump_state` JSON. No guessed sleeps. It honors `$VIBE_APP` when the app lives somewhere other than `build/DerivedData`.

**It launches with audio off the hardware.** Two independent debug-only argv flags, and `launch.sh` passes both by default: `--no-audio-hw` runs the engine in manual rendering mode with a real-time-paced render pump — no CoreAudio output device is ever opened, so a test run cannot trigger macOS's automatic AirPods switching, while playback, position, waveform and FX state all behave normally — and `--silent` zeroes the main mixer, which mutes playback but still opens and drives the real output device. Use both (the default) unless a test genuinely needs hardware: `--silent` alone for real-HAL behavior without noise (device switching against real devices, engine config-change notifications, output-latency-dependent timing), neither for audible playback. `dump_state` reports them as `player.silent` and `player.noAudioHw` — plus `player.manualRendering`, which is what actually happened rather than what argv asked for: `enableManualRenderingMode` can fail, and the engine then opens the output device as usual, so **trust `manualRendering`, not `noAudioHw`**. Set `VIBE_AUDIBLE=1` to use real hardware and hear playback.

**Do NOT use `--no-audio-hw` to test or verify the Now Playing integration — it suppresses it outright.** The flag's promise is that a test run leaves the system's audio state alone, and publishing to `MPNowPlayingInfoCenter` breaks that by itself: registering as the active media app is enough for macOS to pull auto-switching AirPods over from another device, with no output device ever opened. So under the flag nothing is published and no remote commands are registered, and `dump_now_playing` reports `hasInfo: 0` with `playbackState: unknown` — correct behavior, not a bug. Anything touching Now Playing, Control Center, the media keys or Bluetooth transport must launch with `VIBE_AUDIBLE=1` (or without the flag), and will then take the AirPods with it.

To launch by hand instead:

- **Keep manual launches off the hardware too**: `open -a "$APP" <files> --args --no-audio-hw --silent`. `--args` must come last, since everything after it becomes the app's argv. The direct-exec second-instance path takes argv natively: `"$V" --no-audio-hw --silent &`.
- **Feed it a file with `open -a "$APP" <file>`.** The App Sandbox denies reading raw `argv` paths, because there is no Launch Services grant, so `"$V" <file>` parses the path but the open fails. `open` grants access properly. An already-running instance can also load files with `--debug-cmd open <path>`, but that grants no sandbox access either, so it suits container paths or paths already granted. `open -a` works mid-session too and remains the way to feed arbitrary files.
- **Check which binary is running before you trust any observation.** If the user has Vibe running from Xcode, Launch Services routes `open -a` and `open -n` to that instance, and you will test a stale build with no error at all. Verify with:
  ```bash
  ps -o pid,command -p $(pgrep -x Vibe)
  ```
  If the path is not your build, either ask the user to stop the Xcode session or run a **second instance** by executing the binary directly: `"$V" &`. That bypasses Launch Services but cannot open files, and it restores prior window state. A raw-launched instance is a child of your shell and dies when the shell exits, so treat it as scoped to one command block, or relaunch per test.

## Test audio files

Use the generated files in `Assets/test_audio_files/` (gitignored) rather than synthesizing your own:

```bash
.claude/skills/vibe-debug/scripts/generate-test-audio.sh   # idempotent; --force regenerates
```

| File | For |
| --- | --- |
| `tone-short-1.wav` / `-2` / `-3` | single-file and playlist/multi-file tests (8s, distinct pitches) |
| `tone-long.wav` | seek and skip tests (120s — skips reach ±60s) |
| `tone.flac` | FLAC/codec-label coverage |
| `tone-art-red.m4a` / `tone-art-blue.m4a` | tagged metadata (titles "Red Art Test"/"Blue Art Test", artist "Art Tester") with solid red/blue covers — art, header-tint, and dock-icon tests; play one then the other to exercise the art crossfade and tint animation |
| `bpm-85.wav`, `bpm-120.wav`, `bpm-128.wav`, `bpm-140.wav`, `bpm-174.wav` | 30s kick+hat loops at exactly the named tempo — BPM-analyzer tests (see `scan-bpm.sh` below; compare against the filename). Atonal, so they double as the key analyzer's negative case: `scan-key.sh` must report no key |
| `key-am.wav`, `key-c.wav`, `key-fsm.wav`, `key-eb.wav` | 24s chord-progression loops in the named key (Am, C, F#m, Eb) — key-analyzer tests (see `scan-key.sh` below) |

The short files end after eight seconds. Pause early, or use `tone-long.wav`, when a test needs playback still running at capture time.

**Simulating a slow cloud file open.** The Loading state, the shimmer, the load-timeout error and anything else gated on `didBeginLoading:` need an open that blocks, which no local file provides:

```bash
.claude/skills/vibe-debug/scripts/slow-open.sh           # app enters Loading; shimmer at 0.5s, inline timeout error at 20s
.claude/skills/vibe-debug/scripts/slow-open.sh cleanup   # after your checks — fails a still-pending open instantly (into the inline error) and removes the pipe
```

It opens a named pipe in the app container's tmp. `AVAudioFile`'s open blocks reading it forever, exactly as it would on an undownloaded iCloud or Dropbox placeholder.

**One-shot BPM and key measurement.** `scan_bpm` (and its twin `scan_key`) runs in the CLI's own process with no channel round-trip: no app launch, no window, no caches. It works with no app running and leaves a running Vibe instance untouched. The script streams the file through stdin (`scan_bpm - < file`) because the direct-exec'd binary is still sandboxed and cannot read arbitrary argv paths, for the same reason argv opens fail. The client stages the bytes in its own container tmp, which keeps shell processes out of `~/Library/Containers/` and so avoids the TCC prompt described under Screenshots:

```bash
.claude/skills/vibe-debug/scripts/scan-bpm.sh <audio-file>   # {"ok":true,"bpm":120.01} — bpm 0 = no confident tempo
.claude/skills/vibe-debug/scripts/scan-key.sh <audio-file>   # {"ok":true,"key":"Am","camelot":"8A","index":21} — empty strings / index -1 = no confident key
```

`scan_key` has the same contract as `scan_bpm` throughout: it runs in the CLI process, needs no app, ignores caches and tags (it reports pure analysis — the app's own display prefers a tagged key), and streams the file via stdin for the same sandbox reasons.

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

`.player.state` is lowercase and only ever `playing`, `paused` or `stopped`. There is **no `loading` value**: an in-flight open reports `playing`, with zero position and duration, which matches the transport button. Asserting `== "Playing"` silently never matches.

```bash
"$V" --debug-cmd dump_state          # {player, currentTrack, playlist, ui (label text), window, settings}
"$V" --debug-cmd dump_now_playing    # {playbackState, hasInfo, title, artist, duration, elapsed, rate, hasArtwork} — what we publish to the system Now Playing UI (Control Center / media keys). REQUIRES a launch WITHOUT --no-audio-hw (VIBE_AUDIBLE=1), which suppresses the publish entirely; under the flag this always reports hasInfo: 0
"$V" --debug-cmd dump_stats          # {filesOpened, foldersOpened, secondsPlayed} — AppStats lifetime counters, live (secondsPlayed includes the in-progress run)
"$V" --debug-cmd dump_view_tree      # {windows: [{class, frame, visible, key, contentView: {…, subviews}}]}
"$V" --debug-cmd dump_menu           # {menu: [{title, id, key, action, enabled, state, items}]} — LIVE enabled/checkmark
"$V" --debug-cmd click_menu menu_show_pitch   # {ok, clicked, action} — by identifier (preferred) or exact title
"$V" --debug-cmd dump_screenshot -   # PNG bytes on stdout (redirect to a file), JSON reply on stderr — in-process snapshot
"$V" --debug-cmd play_pause          # also: next, previous, skip_forward[_more|_most], skip_back[_more|_most], toggle_size, toggle_pitch_panel
"$V" --debug-cmd set_loading 0.42   # {ok, fraction} — drives the waveform loading indicator directly: `off`, `indeterminate`, or a 0..1 fraction for the determinate fill. The only way to capture either mode without a real slow cloud open
"$V" --debug-cmd set_window_width 900  # {ok, frame, bodyWidth} — body width in points (pitch panel excluded); the window is user-resizable and restores the autosaved width, so a reproducible capture has to set one
"$V" --debug-cmd toggle_low_kill     # FX, also: low_kill_boost_on/_off, reverb_send_on/_off, delay_send_on/_off, short_delay_send_on/_off (the *_on/_off pairs mirror the hold-down W/E/R/T keys)
"$V" --debug-cmd set_pitch -4.5      # drives fader (clamps), player, and time labels together
"$V" --debug-cmd seek 120            # seconds
"$V" --debug-cmd open ~/Music/album  # {ok, opening} — file or dir, same expand/filter/play pipeline as a drop; poll dump_state
"$V" --debug-cmd drag_hover 520 275  # {ok, well} — synthetic external-file drag-over at a window point (top-left origin, like click): drives the playlist drop zone's wells through the real FileDropDelegate path. NOT an event: a genuine NSDraggingSession can't be synthesized, so these call the delegate directly. well = replace|add|none = what a drop there would hit
"$V" --debug-cmd drag_drop 520 275 ~/Music/track.wav  # {ok, dropping, well} — completes the synthetic drag: expands + delivers the drop at that point (well routing: replace|add|none→replace), then tears the drag-over UI down. ABSOLUTE path; same sandbox caveat as open; poll dump_state
"$V" --debug-cmd drag_end            # {ok} — the drag left the window without a drop: back to the rest presentation
"$V" --debug-cmd file_cache song.flac        # {ok, wasCached, bpm, key, camelot, timing} — decode + cache one file's waveform (UI untouched); waits up to 60s. `timing` is that decode's own phase breakdown, absent on a cache hit
"$V" --debug-cmd dump_timing                 # {loads: [...]} — in-process phase timings of recent waveform decodes, newest first: readSeconds (the decode), chunkSeconds, bpmSeconds/keySeconds (each split into Append + Finish), otherSeconds, realtimeFactor. Covers every load, from playing a track as well as from file_cache
"$V" --debug-cmd clear_timing                # {ok} — empties that store before a measurement run
"$V" --debug-cmd file_clear_cache song.flac  # {ok, wasPresent} — evict one file's cached waveform
"$V" --debug-cmd convert_to_flac [keep|delete]  # {ok, output, row, source, sourceDeleted, sourceRemains} — the whole Convert to FLAC path on the CURRENT track, swap and source disposal included; default: current setting. Waits up to 120s
"$V" --debug-cmd undo                # {ok, undid, canUndo, canRedo} — Edit > Undo; replies once the file moves have settled. {"error": "nothing to undo"} on an empty stack
"$V" --debug-cmd redo                # {ok, redid, canUndo, canRedo} — Edit > Redo, same contract, {"error": "nothing to redo"}
"$V" --debug-cmd clear_caches        # {ok, cleared} — empties metadata + waveform PINCaches
"$V" --debug-cmd scan_bpm - < file   # {ok, bpm} — fresh decode+analyze, runs IN THE CLI PROCESS (no app needed; see Test audio files). Audio rides stdin; prefer the scan-bpm.sh wrapper
"$V" --debug-cmd scan_key - < file   # {ok, key, camelot, index} — the key-analyzer twin of scan_bpm, same contract; prefer scan-key.sh. Ignores tags: dump_state's currentTrack.key/.camelot show the app's tag-over-analysis resolution instead
"$V" --debug-cmd clear_disk_caches   # {ok, cleared} — CLI-process deletion of the PINDiskCache dirs, ONLY for when the app is NOT running (prefer clear-caches.sh, which picks the right one)
"$V" --debug-cmd set_appearance dark # {ok, windowAppearance} — light|dark|system, CLI-process prefs write for the NEXT launch (live toggle: click_menu view_appearance_*)
"$V" --debug-cmd set_analysis bpm off # {ok, analyzeBPM, analyzeKey} — <bpm|key> <on|off>, CLI-process prefs write a running app sees immediately (the next waveform decode reads it — no relaunch), so this is how you A/B the analyzers' cost; dump_state.settings reports the live values
"$V" --debug-cmd set_key_display musical colors # {ok, keyNotation, keyColors} — <camelot|musical> <colors|plain>, same live prefs write; the label repaints at its next re-render (key delivery, fader tick, or track change), not on the write itself
"$V" --debug-cmd sleep 0.5           # client-side pause (0–600s, sub-second OK) — for scripts; the app's main thread never sleeps
"$V" --debug-cmd script - <<'EOF'    # command script: see Command scripts below
seek 30
sleep 0.5
key space
EOF
.claude/skills/vibe-debug/scripts/run-script.sh <shots-dir> [file]  # script wrapper that decodes in-script screenshots to numbered PNGs
```

Input injection posts synthesized NSEvents into the app's own event queue. See **In-process input injection** below for coordinates and caveats:

```bash
"$V" --debug-cmd click 75 122        # {ok, posted, hitView, windowKey} — down+up at window point (also: click x y right, click x y left 2 = double-click)
"$V" --debug-cmd drag 728 219 728 299   # full left-button gesture in ONE command (down, 12 dragged steps, up); optional [steps]
"$V" --debug-cmd mouse_move 400 200  # plain move; add left|right for a lone dragged event
"$V" --debug-cmd mouse_down 75 122   # primitives (default left; also right) — see the tracking-loop caveat below
"$V" --debug-cmd mouse_up 75 122
"$V" --debug-cmd key p               # keyDown+keyUp through the real dispatch path (TransportKeyMonitor sees it); mods: key p cmd shift
"$V" --debug-cmd key_down w          # one edge — how the held W/E/R/T momentary FX are driven…
"$V" --debug-cmd key_up w            # …and released (keys: a-z, 0-9, space, tab, return, esc, delete, up/down/left/right)
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

`undo` and `redo` drive the window's NSUndoManager, whose only registered action is Convert to FLAC: undo restores the trashed original, returns its playlist row to it, and trashes the FLAC; redo reverses that from the Trash without re-encoding. Both reply only once the file moves have settled, so assert file state directly from the reply's ordering, and read the live stack from `dump_state`'s `ui.canUndo`/`ui.canRedo`. To exercise the menu path instead use `click_menu menu_edit_undo` / `menu_edit_redo`; validation retitles the items from the manager ("Undo Convert to FLAC") and `dump_menu` shows the live titles and enables — but the menu action has no settled signal, so prefer the verbs when a follow-up step depends on the moves having landed.

```bash
undo_enabled() { "$V" --debug-cmd dump_menu | jq -r '.menu[]|select(.title=="Edit")|.items[]|select(.id=="menu_edit_undo")|.enabled'; }
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

### In-process input injection

`click`, `drag`, `mouse_*` and the `key*` verbs post synthesized NSEvents into the app's own event queue. Unlike the other `--debug-cmd` verbs, which call controller actions directly, these exercise the **real event dispatch path**: `TransportKeyMonitor`, view `mouseDown:` and tracking loops, and menu key equivalents. Unlike CGEvent injection through `input.swift`, they need no Accessibility permission and no help from the OS frontmost state.

- **Coordinates are main-window points with a top-left origin**, the same frame as `dump_screenshot`, which is the retina pixel divided by two. Get view frames from `dump_view_tree`, remembering that those are AppKit **bottom-left**-origin frames in the superview; convert with the window height.
- Mouse replies include `hitView`, the hit-tested view class, so a missed aim shows up immediately. Mouse injection **self-activates the app**, bringing Vibe frontmost and making the window key, because a non-key window swallows the first click as activation. Keyboard injection needs no activation: the key monitor sees posted events regardless.
- Replies are written when the events are *queued*, before they are processed, so poll `dump_state` to observe the effect. That is the same lag caveat as the action verbs.
- **Tracking-loop caveat.** A lone `mouse_down` on a control that runs a modal mouse-tracking loop, such as the pitch fader or a button, stalls the app inside that loop, and the command channel cannot deliver the matching `mouse_up` while it spins. Recovery then takes a real physical click. Use `click` or `drag`, which queue the whole gesture before the loop starts. Keep `mouse_down` and `mouse_up` for views with plain responder-method handling.
- **Right-click caveat.** `click x y right` on a view with a context menu, such as a playlist row, opens a *real* menu that blocks the channel until it is dismissed. Do it only when something can dismiss the menu: a human, or a pre-posted `key esc`. Post the esc *before* the right-click, since it cannot be delivered afterwards.
- Tracking areas and hover effects do not fire from posted events, because the window server drives those. Hover styling still needs `input.swift`.

## Screenshots: two paths, each showing what the other cannot

**1. In-process snapshot.** A synchronous one-liner; `-` streams the PNG bytes to stdout and the JSON reply goes to stderr:

```bash
"$V" --debug-cmd dump_screenshot - > shot.png
```

Always use the `-` form. Inside a command script the reply carries the PNG as base64 instead; see Command scripts. With neither, the reply carries the PNG's path, but that path is inside the app's sandbox container, and reading it with shell tools such as `cp` or `cat` trips macOS's "access data from other apps" TCC prompt against the terminal's host app. The `-` streaming happens in the Vibe CLI client, which owns the container, so no prompt appears. `notifyutil -p com.vibe.debug.screenshot` also works, but it is async and leaves you copying from the container by hand, with the same TCC prompt. Avoid it.

This path renders the key window's Core Animation layer tree in-process, falling back to the main window and then the first visible one, so the app need not be frontmost. It needs no screen-recording permission and works while occluded or with the display asleep. **Default to it** for layout, label text and color, artwork and waveform checks.

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

For hotkeys and mouse mechanics such as a fader drag or a double-click reset, prefer the in-process injection verbs `key`, `click` and `drag` described above: no permissions, no frontmost requirement, and they drive the same key monitor and view mouse handling.

`input.swift` sends **CGEvents through the window server** and remains the only way to test what posted events cannot reach: tracking-area and hover effects, OS-level focus and activation semantics, and drop targets.

```bash
osascript -e 'tell application "Vibe" to activate'   # events land in the frontmost app
swift .claude/skills/vibe-debug/scripts/input.swift key p          # a-z, 0-9, space, tab, return, esc
swift .claude/skills/vibe-debug/scripts/input.swift move 700 200          # plain cursor move — hover states
swift .claude/skills/vibe-debug/scripts/input.swift drag 882 461 882 552   # x1 y1 x2 y2 [steps]
swift .claude/skills/vibe-debug/scripts/input.swift dblclick 882 500       # also: click
```

Coordinates are global screen coordinates with a top-left origin; `find-window.swift` prints window origin and size in the same space. `move` is what the transport-button reveal needs, through the window-wide `NSTrackingArea` in `MainPlayerContentView`: enter and exit fire only on **boundary crossings**, so move *outside* the window first and then back in. A move from one inside point to another changes nothing, and `CGWarpMouseCursorPosition` does not drive tracking areas at all. This path needs Accessibility permission and turns flaky if focus is stolen mid-test, so verify the result with `dump_state` rather than assuming the event landed. For everything else, prefer `--debug-cmd`.

## Logs

The `LogError`, `LogWarn`, `LogInfo` and `LogDebug` macros in `Vibe-Prefix.pch` wrap Apple's unified logging (`os_log`) under the subsystem `com.commonwealthrecordings.Vibe`. Info and debug are not persisted to the log store, so stream them live. Use the full path, since zsh has a `log` builtin:

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'
```

### Build provenance: which build produced this log?

`applicationDidFinishLaunching` logs a build-provenance block through `AppDelegate.logBuildInfo`, so a log excerpt identifies the exact build it came from: version and config, git commit, branch and dirty flag, link time, compiler, arch and -O level, the codegen build settings, SDK and Xcode, and the host OS.

`NSBundle+BuildInfo` reads all of it back from the binary: the `DT*` keys Xcode injects into Info.plist, a `VibeBuild` settings dictionary declared in `project.yml` — Xcode expands `$(SETTING)` inside it, nested dicts included — clang macros, and the executable's mtime for the link time. Only the git fields need build-time help. The `Generate Git Info` pre-build script phase (`scripts/generate-git-info.sh`) writes `build/generated/VibeGitInfo.h`, which is gitignored under `build/` and sits on the target's `HEADER_SEARCH_PATHS`. It is rewritten only when the git state actually changes, so it does not force recompiles, and it falls back to "unknown" in a tree with no git. Reading `.git` from a script phase is why the target sets `ENABLE_USER_SCRIPT_SANDBOXING: NO`.

The two arch fields differ on a universal Release build, and both are correct: the compiler line names the slice that is running, the flags line the whole requested `ARCHS` set. The literal clang argv is not recoverable at runtime — it exists only in the build log.
