# OS-level input: CGEvents through the window server

The fallback input path. **Prefer the in-process `click`, `drag` and `key*` verbs** in the
`vibe-debug` skill — no permissions, no frontmost requirement, and they drive the same
key monitor and view mouse handling. This path exists only for what posted events
cannot reach — including hotkeys and mouse mechanics such as a fader drag or a
double-click reset only when the in-process verbs have already failed you.

`input.swift` sends **CGEvents through the window server** and remains the only way to test what posted events cannot reach: tracking-area and hover effects, OS-level focus and activation semantics, and drop targets.

```bash
osascript -e 'tell application "Vibe" to activate'   # events land in the frontmost app
swift .claude/skills/vibe-debug/scripts/input.swift key p          # a-z, 0-9, space, tab, return, esc
swift .claude/skills/vibe-debug/scripts/input.swift move 700 200          # plain cursor move — hover states
swift .claude/skills/vibe-debug/scripts/input.swift drag 882 461 882 552   # x1 y1 x2 y2 [steps]
swift .claude/skills/vibe-debug/scripts/input.swift dblclick 882 500       # also: click
```

Coordinates are global screen coordinates with a top-left origin; `find-window.swift` prints window origin and size in the same space. `move` is what the transport-button reveal needs, through the window-wide `NSTrackingArea` in `MainPlayerContentView`: enter and exit fire only on **boundary crossings**, so move *outside* the window first and then back in. A move from one inside point to another changes nothing, and `CGWarpMouseCursorPosition` does not drive tracking areas at all. This path needs Accessibility permission and turns flaky if focus is stolen mid-test, so verify the result with `dump_state` rather than assuming the event landed. For everything else, prefer `--debug-cmd`.

