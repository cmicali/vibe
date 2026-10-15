# The settings window's verbs

The settings verbs in detail: reply keys, how `settings_click` names a control, the control-kind table and the toolbar's reserved names. Read when driving a Settings pane. The traps are in `SKILL.md`'s settings section. The walker is `Vibe/Debug/Mac/DebugSettingsUI.m`, keyed off the pane classes in `Vibe/Mac/Settings/AGENTS.md`.

```bash
"$V" --debug-cmd settings_open appearance     # {ok, pane, paneTitle, panes, frame, paneFrame, paneFillsTabView, key, appearance} — opens (creating) the window and selects a pane by identifier (general|appearance|themes|playback|audio|files|shortcuts|advanced|about), index or displayed title; bare settings_open just opens
"$V" --debug-cmd dump_settings_ui             # {pane, paneTitle, panes, controls: [{index, kind, name, label, enabled, rect, alpha, effectiveAlpha, hidden, rowTitle?, rowCaption?, + the live value}], toolbar, window, sheet} — the SELECTED pane only
"$V" --debug-cmd settings_click "Detect key" on  # {ok, control, kind, action, + the live value} — one control of the selected pane BY NAME, no coordinates
"$V" --debug-cmd settings_reveal "Show key"   # {ok, control, kind, action: "revealed", + the live value} — scrolls that control's card to the top of the pane and acts on nothing: how a screenshot reaches a long page's lower cards
"$V" --debug-cmd settings_resize 900 600      # {ok, frame, contentMinSize} — frame read after a layout flush; the request is clamped up to contentMinSize
"$V" --debug-cmd settings_close               # {ok, open, endedSheet} — ends an attached sheet first
```

- `settings_open audio light|dark|system` overrides only the Settings window's appearance for visual checks and writes no preference. Omit the last argument to keep the current override. `system` clears it.
- `settings_open` replies with settled geometry. `paneFillsTabView`, read after a layout flush, is the collapsed-pane oracle.
- `dump_settings_ui`: each control carries `kind`, `name`, its row `label`, `enabled` (for NSControls), `rect` and live value. `alpha` is the view's opacity. `effectiveAlpha` multiplies in every ancestor view's opacity, but not the window's or native disabled text rendering. `hidden` includes hidden ancestors and is independent of opacity or scroll clipping. Optional `rowTitle` and `rowCaption` objects carry `value`, `rect`, `alpha`, `effectiveAlpha` and `hidden`, and take no control index. A row with one disabled control keeps an opaque title while another control in it is enabled.
- The toolbar sits outside the pane. `toolbar` reports each segmented item's per-segment enabled flags by identifier (`navigation`, `theme_randomize`, `theme_history`, `appearance_toggle`). Drive them by reserved name: `settings_click Back` / `Forward` (the window's history), `randomize settings|colors`, `undo` (theme history on Themes, the pane's own undo stack elsewhere), and `preview light|dark`, which replies `windowAppearancePreview` beside the stored `windowAppearance`.
- `settings_click search "<text>"` types into the sidebar's search field and replies `{panes, pane}`: the panes left and the one now selected. `search ""` clears it.

Check disabled controls with an assertion, not a Python view-tree walk. This example needs at least one visible disabled control, so an empty match cannot pass:

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

`settings_click` matches a button's title or its row's title, case-insensitively, exactly first and then as a substring. Two matches is an error. When several match, hidden ones are dropped first. Then `label`, `field` and bare `control` step aside if exactly one other control remains, so a field is addressed by its row title only when it is the row's one control. `#3` addresses the dump's index. That is how the Files pane's folder list and the theme table are reached, since a card's header labels every control in it. **Quote names with spaces**, since the second token is the value. Popup items match by title or by the stable identifier on `represented`: `settings_click Style sonic_cirrus`.

## Kinds

The wrong value for a kind is an error, never a silent no-op.

| kind | value | what happens |
| --- | --- | --- |
| `button` | none | `performClick:` |
| `switch` | `on`, `off`, `toggle` (default) | `performClick:`, the `VibeSwitch`'s own toggle: a state flip plus one action send; `on`/`off` are idempotent |
| `checkbox` | `on`, `off`, `toggle` (default) | the real click path; already there replies `action: "unchanged"` |
| `radio` | none, `on` or `toggle` | `off` is refused: clicking a radio cannot turn one off |
| `popup` | item title, `represented` identifier or `#index` | selects it, then sends the item's action if it has one, else the button's; the reply's `chose` names the item |
| `pulldown` | same | sends the item's action; `#0` is refused, being the button's title rather than a choice |
| `table` | `2`, `0,3`, `all`, `none` | sets the selection, delegate and all — what re-enables Remove |
| `slider` | a number | sets `doubleValue`, then sends the action; the dump carries `value`, `min`, `max` |
| `colorwell` | `#RRGGBB[AA]` | sets the color, alpha included, then sends the action; the dump's `value` is the same hex. The Themes pane's wells share row labels, so address them as `#index` |
| `field` | the text | focuses, sets the text, moves first responder off — the Tab commit, so end-editing runs: `settings_click Name "New name"` is the editor's rename |
| `label`, `control` | — | refused: a readout, and the generic bucket the walker does not model |
