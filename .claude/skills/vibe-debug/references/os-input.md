# Targeted gesture and OS-input tests

Use controller/delegate commands for ordinary verification and unattended stress. `seek`, `set_pitch`, `select_rows`, `remove_selected`, synthetic `reorder_*` and `file_drag_*` exercise app behavior without pointer input. Keyboard routing, hover, drag thresholds, autoscroll, external drag-out and OS activation need separate, explicit tests.

**Run real input only on a dedicated test Mac or disposable macOS VM.** A different Space, window-bound coordinate checks, app activation or app-local event posting is not containment. Artwork and playlist mouse handlers can initiate a native drag carrying actual files. Never use global mouse/key input to recover a hung stress run, replay or shrink. Capture diagnostics and stop instead.

## Named in-process gesture probes

Start with `vibe-stress/scripts/stress.py --gesture-test pitch-reset|pitch-drag --isolated-desktop` against an already running Debug app. Each case resolves the pitch fader's current geometry, verifies the target before injection, queues the complete gesture and asserts the resulting player/fader pitch. Original pitch and panel visibility are restored. The flag is an explicit assertion about the test environment, not a sandbox.

For other gestures, define one named case and its expected state before sending input. Read `dump_view_tree`/`dump_state` immediately before the gesture, resolve the specific control, verify visibility and its hit target, and abort if layout, focus or target differs. Do not use fixed screen coordinates copied from another run or random points across the window. Check the resulting state; an event-queued reply alone proves nothing. Test keyboard selection/removal routing separately from the direct selection/removal commands.

## Global events, for what the window server owns

`input.swift` sends CGEvents through the global window-server input stream. Use it only for an explicitly planned OS-input case inside the isolated environment, such as hover or an external file drop onto a controlled destination holding disposable test files. It needs Accessibility permission. App-local `click`, `drag` and `key*` already reach view handlers and key monitors, so global events are not required for those merely because they are gestures.

```bash
# Only in the isolated test environment. Resolve this run's window geometry first.
swift .claude/skills/vibe-debug/scripts/find-window.swift
swift .claude/skills/vibe-debug/scripts/input.swift --isolated-desktop move <x> <y>
swift .claude/skills/vibe-debug/scripts/input.swift --isolated-desktop click <x> <y>
swift .claude/skills/vibe-debug/scripts/input.swift --isolated-desktop drag <x1> <y1> <x2> <y2> [steps]
```

Coordinates here are global screen points with a top-left origin, unlike the debug channel's window points. Confirm the intended app is frontmost immediately before input; abort if focus changes. Do not activate repeatedly and continue blindly. For drag-out, verify the intended destination and resulting disposable payload, then confirm the session ended. These checks improve test accuracy but are not a substitute for desktop isolation.

Hover tracking uses boundary crossings: move from outside the named target into it, using freshly resolved geometry. `CGWarpMouseCursorPosition` alone does not drive tracking areas. Always read back the relevant state or capture the target appearance to verify the expected outcome.
