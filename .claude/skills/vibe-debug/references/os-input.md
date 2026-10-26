# Targeted gesture and OS-input tests

Controller and delegate commands cover ordinary verification and unattended stress: `seek`, `set_pitch`, `select_rows`, `remove_selected`, `reorder_*` and `file_drag_*` need no pointer input. Keyboard routing, hover, drag thresholds, autoscroll, external drag-out and OS activation need separate, explicit tests.

**Run real input only on a dedicated test Mac or disposable macOS VM.** A different Space, window-bound coordinates, app activation and app-local event posting are not containment. Artwork and playlist mouse handlers can start a native drag carrying real files. Never use global input to recover a hung stress run, replay or shrink. Capture diagnostics and stop.

## Named in-process gesture probes

Start with `vibe-stress/scripts/stress.py --gesture-test pitch-reset|pitch-drag --isolated-desktop` against a running Debug app. Each case resolves the pitch fader's current geometry, verifies the target, queues the whole gesture and asserts the resulting pitch. It restores the original pitch and panel visibility. The flag asserts the test environment; it is not a sandbox.

For another gesture, define one named case and its expected state first. Read `dump_view_tree` and `dump_state` just before the gesture, resolve the control, verify its visibility and hit target, and abort if layout, focus or target differs. Never reuse coordinates from another run or aim at random points. Check the resulting state, since an event-queued reply proves nothing.

## Global events, for what the window server owns

`input.swift` sends CGEvents through the global input stream and needs Accessibility permission. Use it only for a planned OS-input case in the isolated environment, such as hover or an external file drop onto a controlled destination with disposable files. App-local `click`, `drag` and `key*` already reach view handlers and key monitors.

```bash
# Only in the isolated test environment. Resolve this run's window geometry first.
swift .claude/skills/vibe-debug/scripts/find-window.swift <pid>
swift .claude/skills/vibe-debug/scripts/input.swift --isolated-desktop move <x> <y>
swift .claude/skills/vibe-debug/scripts/input.swift --isolated-desktop click <x> <y>
swift .claude/skills/vibe-debug/scripts/input.swift --isolated-desktop drag <x1> <y1> <x2> <y2> [steps]
```

Coordinates here are global screen points with a top-left origin, unlike the channel's window points. Confirm the intended app is frontmost just before input, and abort if focus changes. For drag-out, verify the destination and the payload, then confirm the session ended.

Hover tracking needs boundary crossings: move from outside the target into it, using fresh geometry. `CGWarpMouseCursorPosition` alone does not drive tracking areas. Read back the state or capture the target to verify the outcome.
