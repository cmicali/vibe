---
name: vibe-debug
description: Launch, drive, inspect, and visually verify the Vibe app. Use whenever a change needs end-to-end verification, a screenshot of the running app, playback/UI state inspection, or appearance (light/dark) testing.
---

# Debugging and verifying Vibe

All debug tooling is compiled in **debug builds only** (`Util/DebugUtil.mm`). Build first:

```bash
xcodebuild -workspace Vibe.xcworkspace -scheme Vibe -configuration Debug \
    -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Debug/Vibe.app
V="$APP/Contents/MacOS/Vibe"
```

## Launching — pitfalls first

```bash
.claude/skills/vibe-debug/scripts/launch.sh [audio-file ...]   # kill, open -a, wait until ready
```

`launch.sh` relaunches the build and polls the debug channel until the app answers, printing its `state` JSON — no guessed sleeps. It honors `$VIBE_APP` if the app lives somewhere other than `build/DerivedData`. Doing it by hand instead:

- **Feed it a file with `open -a "$APP" <file>`.** The App Sandbox denies reading raw `argv` paths (no Launch Services grant), so `"$V" <file>` parses the path but the open fails. `open` grants access properly.
- **Check WHICH binary is running before trusting any observation.** If the user has Vibe running from Xcode, LaunchServices routes `open -a` (and `open -n`) to that instance — you'll be testing a stale build without any error. Verify with:
  ```bash
  ps -o pid,command -p $(pgrep -x Vibe)
  ```
  If the path isn't your build, either ask the user to stop the Xcode session, or run a **second instance** by executing the binary directly: `"$V" &` (bypasses LaunchServices; can't open files — it restores prior window state). A raw-launched instance is a child of your shell and dies when the shell exits — treat it as per-command-block scoped, or relaunch per test.

## Driving and inspecting the running app: `--debug-cmd`

The Vibe binary doubles as its own CLI client (same bundle ID + sandbox, so it shares the app's container tmp). **Prefer this over lldb attach, CGEvent input, or AppleScript menu clicks** — no Accessibility/Automation permission, no frontmost requirement, doesn't pause the process.

**Every command replies with exactly one JSON object** — never scrape text. Filter with `jq` (`-r` for shell substitution, `-e` to assert); drop to python only when the logic outgrows filtering (multi-step transforms, comparing states). Pipe via `printf '%s' "$out"`, not `echo` — zsh's `echo` rewrites `\t` escapes inside the JSON into illegal raw control characters. Errors are `{"error": "…"}` (exit code 2).

```bash
"$V" --debug-cmd state           # {player, currentTrack, playlist, ui (label text), window, settings}
"$V" --debug-cmd viewtree        # {windows: [{class, frame, visible, key, contentView: {…, subviews}}]}
"$V" --debug-cmd menu            # {menu: [{title, id, key, action, enabled, state, items}]} — LIVE enabled/checkmark
"$V" --debug-cmd clickMenu menu_show_pitch   # {ok, clicked, action} — by identifier (preferred) or exact title
"$V" --debug-cmd screenshot      # {path: <PNG path>} — in-process snapshot
"$V" --debug-cmd playPause       # also: next, previous, togglePitchPanel, toggleSize
"$V" --debug-cmd setPitch -4.5   # drives fader (clamps), player, and time labels together
"$V" --debug-cmd seek 120        # seconds
```

`menu` and `clickMenu` run the same `validateMenuItem` pass opening the menu would, so enabled/checkmark are live — this replaces AppleScript/System Events menu clicking (no Automation permission, no frontmost requirement). Get identifiers from `menu`.

Action replies are a compact `{ok, state, index, count, position, pitch, playlistShown, pitchPanelShown}` object read synchronously, so they can lag async engine work — run `state` afterwards to confirm. Exit codes: 0 ok, 1 no response (no debug build running), 2 command error. With **two instances running, the command file is racy** (either instance may consume it) — quit one first.

## Screenshots: two paths, each shows what the other can't

**1. In-process snapshot** — synchronous one-liner (the reply carries the PNG path):

```bash
cp "$("$V" --debug-cmd screenshot | jq -r .path)" shot.png
```

(`notifyutil -p com.vibe.debug.screenshot` also works but is async — you'd have to sleep and copy from the container manually. Each capture overwrites the same file, so copy it out before the next one.)

Renders the frontmost window's Core Animation *presentation* layer tree in-process. No screen-recording permission, works occluded or with the display asleep, catches animations mid-flight. **Default to this** for layout, label text/color, artwork, and animation checks.

**Blind spots:** `NSVisualEffectView` materials/vibrancy render black/transparent (the window server composites those), and Metal content (About window) doesn't render. **Never judge window background, material, or appearance-blending issues from this path** — it structurally cannot show them.

**2. Real screen capture** — for material/vibrancy/appearance verification:

```bash
.claude/skills/vibe-debug/scripts/capture-window.sh out.png [pid]
```

Finds the on-screen Vibe window via CGWindowList and runs `screencapture -x -l<windowID>`. Needs Screen Recording permission for the terminal. Captures real composited pixels — this is the ground truth for anything the snapshot path can't show. Pass the pid when two instances are running (the script warns and lists binaries).

## Pixel probing

Eyeballing near-identical grays is unreliable — assert numerically:

```bash
swift .claude/skills/vibe-debug/scripts/probe-pixel.swift out.png 700 600 [x y ...]
```

Prints image size and RGBA per point. Coordinates are bitmap pixels, **origin top-left**, and captures are **2x on retina** (window point ≈ pixel/2). `find-window.swift` (same dir) prints `windowID pid x y w h` per Vibe window if you need geometry to aim probes.

## Appearance (light/dark) testing

The app's appearance setting persists in its defaults:

```bash
defaults write com.commonwealthrecordings.Vibe Settings.windowAppearance light   # or: dark
defaults delete com.commonwealthrecordings.Vibe Settings.windowAppearance        # follow system
```

Relaunch to apply, or toggle live: `"$V" --debug-cmd clickMenu view_appearance_light` (also `view_appearance_dark`, `view_appearance_system_default`). Test both modes for any color/material change; use real capture (path 2) to verify backgrounds. Note the app's window appearance is independent of the system's — a "light" window over a dark system is a supported (and previously buggy) combination.

## Real input path (hotkeys, fader mouse mechanics)

`--debug-cmd` calls actions directly, bypassing the key monitor and mouse handling. To test the input path *itself* (a hotkey binding, the fader's drag/double-click-reset behavior), send real events:

```bash
osascript -e 'tell application "Vibe" to activate'   # events land in the frontmost app
swift .claude/skills/vibe-debug/scripts/input.swift key p          # a-z, 0-9, space, tab, return, esc
swift .claude/skills/vibe-debug/scripts/input.swift drag 882 461 882 552   # x1 y1 x2 y2 [steps]
swift .claude/skills/vibe-debug/scripts/input.swift dblclick 882 500       # also: click
```

Global screen coordinates, origin top-left (`find-window.swift` prints window origin/size in the same space). Needs Accessibility permission; flaky if focus is stolen mid-test — verify the result with `state`, not by assuming the event landed. For everything else, prefer `--debug-cmd`.

## Logs

Info/debug aren't persisted — stream live (full path; zsh has a `log` builtin):

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "com.commonwealthrecordings.Vibe"'
```
