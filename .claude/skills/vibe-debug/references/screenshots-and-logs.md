# Screenshot and log mechanics

How the in-process snapshot chooses a window and what it cannot render, real capture and pixel probes, and on-device logging with `OS_ACTIVITY_DT_MODE`. Read when a screenshot shows something unexpected or a log has to come off a phone.

## The in-process snapshot

`dump_screenshot -` renders the key window's layer tree in-process. It falls back to the main window, then to the frontmost visible one, so the app need not be frontmost. That last rung captures the **settings or About window** while the app is inactive. A mouse-injection verb makes the player key, so it redirects the next screenshot back to the player. No Screen Recording permission is needed, and it works occluded or with the display asleep.

Always use the `-` form. The client streams the PNG to stdout and the JSON reply to stderr. Without it the reply carries a path inside the sandbox container, and reading that path with `cp` or `cat` trips the "access data from other apps" TCC prompt. The reply is `{ok, path, width, height, scale}`. `width` and `height` are the PNG's pixels, and `scale` is the window's backing scale. Inside a command script the reply is `{ok, pngBase64}` instead, plus `label` when the line names one (`SKILL.md`, Command scripts).

**Blind spots.** `NSVisualEffectView` materials, vibrancy, the `NSGlassEffectView` glass chrome and Metal content do not render, because the window server composites them. The snapshot hides each glass view's layer and each backdrop layer, and paints an appearance-matched flat fill in their place. Then it draws each glass view's content on top. That is how the Settings sidebar's rows show. The sidebar's search field still draws as a white box. Metal content (the About window) stays blank. Hiding the glass forces a model-tree render on those windows, so animations are captured at their target values. Window background, material, tint wash and appearance blending need real capture. The renderer is vibe-libs' `dev/DebugVerbs/Mac/DebugScreenshot.m`, and its doc has the details.

## Real capture and probes

```bash
.claude/skills/vibe-debug/scripts/capture-window.sh out.png [pid]     # screencapture of the window; needs Screen Recording. Without a pid, this slot's instance
swift .claude/skills/vibe-debug/scripts/probe-pixel.swift out.png 700 600 [x y ...]   # image size plus RGBA per point; bitmap pixels, top-left origin, 2x on retina
swift .claude/skills/vibe-debug/scripts/find-window.swift <pid>        # windowID pid x y w h per window of that pid
```

Assert near-identical grays numerically with the probe, never by eye.

## On a real device: `OS_ACTIVITY_DT_MODE`

`log stream` has no device mode, and `idevicesyslog` carries nothing the app logs. Launch with `OS_ACTIVITY_DT_MODE=1` in the environment instead. `os_log` then copies every message it keeps to stderr, with its timestamp, as it does for Xcode's console, and `devicectl --console` relays it back. A Debug build is always verbose, so its info and debug messages log at Default level and are copied too. It is off unless the variable is set.

```bash
make install-ios CONFIG=Debug          # signed build onto the one paired phone; DEVICE=<name or identifier> with several
xcrun devicectl device process launch --timeout 3600 --device <identifier> --console --terminate-existing \
    -e '{"OS_ACTIVITY_DT_MODE":"1"}' com.commonwealthrecordings.Vibe > build/device.log 2>&1   # run it in the background and read the file
grep -E "AudioSession|AudioOutputUnit|idle stop|Scene:|no verdict" build/device.log
```

`<identifier>` is devicectl's own (`xcrun devicectl list devices`), not the hardware UDID. A reinstall ends the console session, so relaunch after each one. `--timeout` (seconds) ends a session left in the background.

**What a picked file is on the phone** (an SMB server, a USB drive, any provider): add `--dataless-diag` after the bundle identifier. Each directory's first dataless check then logs one `Dataless diag:` line with the path, the verdict, the raw `st_flags`, the mount's filesystem type and mount point, and whether it is local.

**An on-device pass runs only on an explicit request** (`SKILL.md`'s simulator-only rule), and it is log-only. Nothing can synthesize a call or a route change, so the user's hands and the log are the instruments. Install a Debug build and say that it replaces the installed Vibe (data kept). Launch it as above with the log in a file. Hand the user the physical steps in numbered rounds (a call, AirPods in and out, the lock screen, Settings > Developer > Reset Media Services), about ten seconds apart, with the phone plugged in and unlocked. Judge each step from the log. When the log cannot attribute a result, add a log line and rerun. Siri ducks and does not interrupt; a timer or a call is a real interruption.

The channel does not reach a device. It is command and response files in the app container, which the host cannot write. `xcrun devicectl device copy to/from --domain-type appDataContainer` could carry the same protocol, but that is unbuilt.

Two profiling traps on a device:

- TRAP: **stderr logging under a recording tool manufactures stalls.** When the USB pipe backs up, the copy to stderr blocks the thread that logged, main included. Confirm any perceived stall unplugged, launched from the home screen, with no Instruments. For A/B work on a device, prefer the `VibeWorkTally` counters (`Vibe/Debug/AGENTS.md`), which come back over the console cheaply. Keep hot counters on `VibeTallyCount`, not `VibeSignpostCount`.
- TRAP: **`xctrace record --attach` against a device usually yields a trace with no run data**, and `--instrument` combined with `--template` always breaks the export. `xctrace` wants the hardware UDID (`xcrun xctrace list devices`). Use it only for hitch counts, and expect to retry.
