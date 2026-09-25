# The settings window's verbs

`settings_open`, `dump_settings_ui`, `settings_click`, `settings_close` and `settings_resize` in detail: reply keys, how `settings_click` names a control, the control-kind table and the toolbar's reserved names. Read when driving a Settings pane; the traps are in `SKILL.md`'s settings section. The walker is `Vibe/Debug/Mac/DebugSettingsUI.m`, keyed off the pane classes in `Vibe/Mac/Settings/CLAUDE.md`.

```bash
"$V" --debug-cmd settings_open appearance     # {ok, pane, paneTitle, panes, frame, paneFrame, paneFillsTabView, key, appearance} — opens (creating) the window and selects a pane by identifier (general|audio|playback|appearance|files|advanced|about), index or displayed title; bare settings_open just opens
"$V" --debug-cmd dump_settings_ui             # {pane, paneTitle, panes, controls: [{index, kind, name, label, enabled, rect, alpha, effectiveAlpha, hidden, rowTitle?, rowCaption?, + the live value}], toolbar, window, sheet} — the SELECTED pane only
"$V" --debug-cmd settings_click "Detect key" on  # {ok, control, kind, action, + the live value} — one control of the selected pane BY NAME, no coordinates
"$V" --debug-cmd settings_resize 900 600      # {ok, frame, contentMinSize} — frame read after a layout flush; the request is clamped up to contentMinSize
"$V" --debug-cmd settings_close               # {ok, open, endedSheet} — ends an attached sheet first
```

- `settings_open audio light|dark|system` temporarily overrides only the Settings window appearance for visual checks; it writes no preference. Omit the last argument to keep the current override, or use `system` to clear it.
- `settings_open` replies with settled geometry. `paneFillsTabView`, read after a layout flush, is the collapsed-pane oracle.
- `dump_settings_ui`: each control carries `kind`, `name`, its row `label`, `enabled` (for NSControls), `rect` and live value. `alpha` is the view's opacity; `effectiveAlpha` multiplies it by all ancestor view opacities, excluding window opacity and native disabled text rendering. `hidden` includes hidden ancestors and is independent of opacity or scroll clipping. Optional `rowTitle` / `rowCaption` objects carry `value`, `rect`, `alpha`, `effectiveAlpha` and `hidden`; these structural labels do not consume control indices. A mixed row can have a disabled control and a fully opaque title when another control remains enabled. The toolbar sits outside the pane, so `toolbar` reports each segmented item's per-segment enabled flags by identifier (`theme_navigation`, `theme_randomize`, `appearance_toggle`); drive them by reserved name: `settings_click Back` / `Forward`, `randomize settings|colors`, `undo`, and `preview light|dark`, which replies `windowAppearancePreview` beside the untouched stored `windowAppearance`.

Check disabled controls without a Python view-tree walk. This example requires at least one visible disabled control, so an empty match cannot pass; add checks for the specific row's title/caption when the whole row should dim:

```bash
.claude/skills/vibe-debug/scripts/run-script.sh --assert '
  [ .[] | .controls[]? | select(.enabled == false and .hidden == false) ] as $disabled |
  ($disabled | length) > 0 and all($disabled[]; .alpha == 0.5)
' /tmp/settings-opacity <<'EOF'
settings_open audio
dump_settings_ui
EOF
```

## Naming

`settings_click` matches, case-insensitively, a button's title or its row's title — exactly first, then as a substring; two matches is an error. When several match, hidden ones are dropped first, then `label`, `field` and bare `control` step aside if exactly one other control remains, so a field is addressed by its row title only when it is the row's one control (the theme editor's Name field). `#3` addresses the dump's index — how the Files pane's folder list and the theme table are reached: a card's header labels every control in it, and the theme table's header rows take indices of their own. **Quote names with spaces**, since the second token is the value. Popup items match by title or by the stable identifier on `represented`: `settings_click Style sonic_cirrus`.

## Kinds

The wrong value for a kind is an error, never a silent no-op.

| kind | value | what happens |
| --- | --- | --- |
| `button` | none | `performClick:` |
| `switch` | `on`, `off`, `toggle` (default) | a state flip plus one action send — `NSSwitch` has no cell, so `performClick:` is not its click path; `on`/`off` are idempotent |
| `checkbox` | `on`, `off`, `toggle` (default) | the real click path; already there replies `action: "unchanged"` |
| `radio` | none, `on` or `toggle` | `off` is refused: clicking a radio cannot turn one off |
| `popup` | item title, `represented` identifier or `#index` | selects it, then sends the item's action if it has one, else the button's; the reply's `chose` names the item |
| `pulldown` | same | sends the item's action; `#0` is refused, being the button's title rather than a choice |
| `table` | `2`, `0,3`, `all`, `none` | sets the selection, delegate and all — what re-enables Remove |
| `slider` | a number | sets `doubleValue`, then sends the action; the dump carries `value`, `min`, `max` |
| `colorwell` | `#RRGGBB[AA]` | sets the color, alpha included, then sends the action; the dump's `value` is the same hex. The Appearance pane's wells share row labels, so address them as `#index` |
| `field` | the text | focuses, sets the text, moves first responder off — the Tab commit, so end-editing runs: `settings_click Name "New name"` is the editor's rename |
| `label`, `control` | — | refused: a readout, and the generic bucket the walker does not model yet |
