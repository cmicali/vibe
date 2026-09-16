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
xcodebuild -scheme VibeiOS -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build/DerivedData build   # signs with the team in project.yml
xcrun devicectl device install app --device <udid> build/DerivedData/Build/Products/Debug-iphoneos/Vibe.app
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
    com.commonwealthrecordings.Vibe --log-stderr
```

The `--console` trap is in `SKILL.md`. The channel does not reach a device: it is command and response files in the app container, which the host cannot write directly. `xcrun devicectl device copy to/from --domain-type appDataContainer --domain-identifier com.commonwealthrecordings.Vibe` can, so the same protocol would work over it — unbuilt, which is why the device loop is log-only.
