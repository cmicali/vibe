# Screenshot and log mechanics

How the in-process snapshot chooses a window and what it cannot render, real capture and pixel probes, and the on-device `--log-stderr` commands. Read when a screenshot shows something unexpected or a log has to come off a phone; the one-line hows and the rules are in `SKILL.md`.

## The in-process snapshot

`dump_screenshot -` renders the key window's Core Animation layer tree in-process, falling back to the main window and then to the frontmost visible one, so the app need not be frontmost. That last rung is what captures the **settings or about window** while the app is inactive, since neither key nor main window exists then — and why a mouse-injection verb, which makes the *player* key, silently redirects the next screenshot back to the player. No screen-recording permission; works occluded or with the display asleep.

Always use the `-` form: the client, which owns the container, streams the PNG to stdout and the JSON reply to stderr. Without it the reply carries a path inside the sandbox container, and reading that with `cp` or `cat` trips the "access data from other apps" TCC prompt against the terminal's host app. `notifyutil -p com.vibe.debug.screenshot` also works but is async and leaves the same copy-by-hand — avoid it. Inside a command script the reply carries the PNG as base64 (`SKILL.md`, Command scripts).

**Blind spots.** `NSVisualEffectView` materials and vibrancy do not render, nor does the `NSGlassEffectView` glass chrome (the window-spanning backdrop and the header panel): the window server composites those. The snapshot hides the glass layers and paints an appearance-matched flat proxy fill where they would be, which keeps dark-mode content legible. Hiding them forces a *model*-tree render on glass-bearing windows, so animations are captured at their target values; glass-free windows render the presentation tree. Metal content (the About window) does not render either. Window background, material, tint-wash and appearance-blending questions need real capture.

## Real capture and probes

```bash
.claude/skills/vibe-debug/scripts/capture-window.sh out.png [pid]     # CGWindowList → screencapture -x -l<windowID>; needs Screen Recording. Pass the pid with two instances running
swift .claude/skills/vibe-debug/scripts/probe-pixel.swift out.png 700 600 [x y ...]   # image size plus RGBA per point; bitmap pixels, top-left origin, 2x on retina
swift .claude/skills/vibe-debug/scripts/find-window.swift [pid]        # windowID pid x y w h per Vibe window — geometry to aim probes
```

Eyeballing near-identical grays is unreliable; assert numerically with the probe.

## On a real device: `--log-stderr`

`log stream` has no device mode on current macOS, and `idevicesyslog` (`brew install libimobiledevice`, over USB) carries SpringBoard and runningboardd chatter *about* the app but nothing the app logs — a third-party subsystem's `os_log` never reaches `syslog_relay`. Debug builds take `--log-stderr` (`Vibe-Prefix.pch`), which mirrors every `Log*` message to stderr, timestamped, alongside `os_log`; `devicectl` relays stderr back. Off by default, so the simulator and mac loops keep the unified log.

```bash
make install-ios CONFIG=Debug          # signed build onto the one paired phone; DEVICE=<name or identifier> with several
xcrun devicectl device process launch --timeout 3600 --device <identifier> --console --terminate-existing \
    com.commonwealthrecordings.Vibe --log-stderr > build/device.log 2>&1   # run it in the background and read the file
```

`<identifier>` is devicectl's own (`xcrun devicectl list devices`), not the hardware UDID. A reinstall ends the console session, so relaunch after each one. `--timeout` (seconds) ends one left in the background, which would otherwise outlive the session that started it; size it to a round and relaunch after it the same way. The audio session's lines to read a pass by:

```bash
grep -E "AudioSession|AudioOutputUnit|idle stop|Scene:|no verdict" build/device.log
```

**What a picked file is on the phone** (an SMB server or a USB drive in the Files app, any provider). Add `--dataless-diag` after `--log-stderr`. Each directory's first dataless check then logs one line: the directory's path, the verdict, the raw `st_flags`, the mount's filesystem type and mount point, and whether the mount is local. Pick the folder in Vibe and play one file from it.

```bash
grep "Dataless diag:" build/device.log
```

**An on-device pass runs only on an explicit request** (the simulator-only rule in `SKILL.md`), and it is a log-only loop: nothing can synthesize a call or a route change, so the user's hands and the log are the instruments. Install a Debug build, launch it as above with the log in a file, and hand the user the physical steps in numbered rounds (a call, AirPods in and out, the lock screen, Settings > Developer > Reset Media Services); they reply with what they saw, and each step is judged from the log. Installing replaces the user's installed Vibe (same bundle id, data kept), so say so. Ask for about ten seconds between steps so they separate in the log, and for the phone to stay plugged in and unlocked. When the log cannot attribute a result, add a log line and rerun rather than guess. Siri ducks and does not interrupt; a timer or a call is a real interruption.

Two profiling traps on a device:

- TRAP: **`--log-stderr` under a recording tool manufactures stalls.** devicectl relays stderr over USB; when the pipe backs up, `fprintf` blocks the main thread, UIKit's own warnings flood the same pipe, and the app freezes for seconds on the rig and never off it, worse with Instruments recording high-frequency signposts on top. Confirm any perceived stall unplugged, launched from the home screen with no Instruments, before treating it as real. Prefer the `VibeWorkTally` counters (`Vibe/Debug/AGENTS.md`) to Instruments for A/B work on a device: they come back over `--log-stderr` with little overhead and diff directly; keep hot counters on `VibeTallyCount`, not `VibeSignpostCount`.
- TRAP: **`xctrace record --attach` against a device usually yields a trace with no run data** (`Trace1.run/` holds only `RunIssues.storedata`, and export fails with "instrument run data is missing"), with no reliable fix, and `--instrument` combined with `--template` breaks the export every time. `xctrace` wants the hardware UDID (`xcrun xctrace list devices`), not devicectl's identifier. Reach for it only for hitch counts, and expect to retry.

The `--console` trap is in `SKILL.md`. The channel does not reach a device: it is command and response files in the app container, which the host cannot write directly. `xcrun devicectl device copy to/from --domain-type appDataContainer --domain-identifier com.commonwealthrecordings.Vibe` can, so the same protocol would work over it — unbuilt, which is why the device loop is log-only.
