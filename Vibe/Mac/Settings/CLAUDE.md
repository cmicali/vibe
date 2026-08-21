# Settings window (macOS)

Vibe > Settings… (⌘,): `SettingsWindowController`, in the System Settings shape — an `NSSplitViewController` holding a full-height source-list sidebar (`SettingsSidebarController`) that drives a tab-less `NSTabViewController` of panes, under a full-size content view and a unified toolbar whose only item is the sidebar tracking separator (AppKit vends it for a split-view content controller; it is what carries the sidebar divider through the titlebar). The sidebar rows are built from the tab items themselves — same order, labels and symbols — and selection syncs both ways through `didSelectTabViewItem:`, so the debug channel's programmatic pane switch moves the highlighted row too. Created lazily by `AppDelegate` and kept alive across closes. ⌘W closes it — File > Close is nil-targeted, and this window controller's own `closeFile:` catches it ahead of the player's. The window is deliberately not resizable.

The *store* is `AppSettings` (`Vibe/Common/`); this directory is only the window. `DefaultAppRegistration` also lives here, because it is the AppKit/Launch Services half of `Common/DocumentTypes`.

## Pane scaffolding

One pane per `SettingsPaneViewController` subclass, one file each, on shared scaffolding in the base class: the pane size and the top-centered two-column form grid.

**The design size is a minimum**, grown to the form grid's fitting size, so a long localization widens the pane instead of clipping — and the height is additionally floored at `kSettingsPaneMinHeight`, so every pane presents the same roomy window rather than hugging its content. The titlebar overlays the pane (full-size content view), which is why the grid pins to the safe-area top and the height constraint rides the safe-area guide: the pane's design height is a content-layout budget, below the toolbar.

Panes reload control state in `refreshFromSettings`, which the base runs on every appearance, whenever the window regains key (a system panel returned), and after any menu-bar tracking ends (a menu changed a mirrored setting while the pane stayed visible).

**The window title is the title-propagation chain, never set directly.** Each pane's `NSViewController.title` names its sidebar row **and** the window: `didSelectTabViewItem:` pushes it onto the split controller, whose title the window binds to (the split controller does not propagate a selected child's title on its own, which is also why the first pane's title is seeded at init — the initial selection ran before the split controller existed).

Sidebar labels reuse menu strings where the word is the same (Playback, Appearance, Convert); settings-only strings live in the `settings.*` key family. Each tab item also carries a **stable, unlocalized identifier** (`general`, `playback`, …), which is what the debug channel's `settings_open` selects by.

## TRAP: the pane's fitting size IS the window's settled size, and the pane-switch resize is animated by exactly one path

The constraint engine re-sizes a `contentViewController` window to its content's fitting size after every layout pass (`_changeWindowFrameFromConstraintsIfNecessary`), so a frame held anywhere else snaps back on the next flush. There is no fighting it; the design leans on it instead: the pane's 999 constraints define the fitting size the window settles at (safe-area height + width, so the titlebar overlay is the engine's to add), the frame autosave's restored size needs no correction because the first layout pass corrects it, and the sidebar's fixed thickness plus divider joins the width on its own.

`SettingsTabViewController.didSelectTabViewItem:` animates the switch at `kWindowResizeAnimationDuration` through `[window animator] setFrame:` in an explicit `NSAnimationContext` — **not** `setFrame:display:animate:`, whose legacy blocking stepper consumes its duration here without rendering a single intermediate frame. Its target is computed from the engine's own numbers (the tab view's leading edge in the window, `contentLayoutRect` for the titlebar overlay), because a target that differs from the fitting answer gets visibly re-snapped at animation end.

Two mechanisms would still snap the window to the incoming pane's size before the animation can run, turning it into a no-op, and both are disarmed:

- **The pane constraints sit at 999**, just below required. A required size forces the window there in one layout pass; at 999 the window edge wins while the frame animates, so the pane stretches with it.
- **Both the tab controller and the split controller swallow `setPreferredContentSize:`**, because AppKit resizes a window immediately when its `contentViewController`'s `preferredContentSize` changes — and the split controller adopts one from its children on layout.

## Panes

- **General** — the Output popup, which mirrors the menu bar's Output menu by using its own `OutputDevicesMenuController` instance as the popup menu's delegate and builder, so the two layouts cannot drift. Plus the default-player button: `DefaultAppRegistration` claims every declared audio type **one at a time**, because each request can raise its own system confirmation panel and a refusal stops the walk. No alert of our own — the system's panel is the whole conversation, and the button reports the result. **The folder declaration is excluded on purpose: Vibe must never become the default folder handler.** The always-on-top checkbox writes `AppSettings.alwaysOnTop` and calls `MainPlayerController.applyAlwaysOnTop`, the one place that pushes it to window levels — the player's, and through `AppDelegate.applyAuxiliaryWindowLevels` the About and Settings windows', which must ride at the player's level or the floating player would bury them.
- **Playback** — On track end (`pauseAtTrackEnd`, stable identifiers `play_next` and `pause` on `representedObject`). **TRAP: the pane must call `MainPlayerController.applyEndOfTrackAction` after writing it** — that is what re-parks or drops the player's successor handle, and a mid-track switch to Pause without it leaves an armed gapless splice that advances past the end anyway. Plus pitch range, the skip-step presets (`skipBaseBars`), the crossfade length (pushed live to `AudioPlayer.crossfadeMilliseconds`), the audio-FX toggle (`audioFXEnabled`, read once at player init, so the caption says it lands on relaunch), and the BPM/key analysis toggles. **How a key is *written* is Appearance's business; this pane only decides whether it is detected.**
- **Appearance** — appearance, waveform style (identifiers on `representedObject`, localized names display-only), the waveform theme (same identifier convention; `applyWaveformTheme:` is the write path), Show file info, the time-display mode, and the two key-label choices: notation (`keyNotation`) and `keyColorsEnabled`. All push live through their `refresh*` hooks, and both key choices govern **every** key shown including a tagged one, since a tag is parsed to a `VibeMusicalKey` when read and never displayed as written. The custom theme's four color wells — a played/unplayed pair per appearance, alpha included, since a color's alpha is its side's resting level — sit in two rows that are built always and hidden unless the theme is `custom`; a well's action writes the hex setting and calls `refreshWaveformTheme`, and choosing Custom seeds any unset color from the wells' displayed fallbacks so the waveform immediately matches them. The waveform drag popup (`waveformDragBehavior`, stable identifiers `drag_window` and `seek`) is the one row with **no live-apply hook** — the waveform view reads the setting per mouse-down (`WaveformUI/Mac/CLAUDE.md`).
- **Convert** — `convertAsksWhereToSave` and Delete Original After Convert, the same setting as the Convert menu's checkmarked item.
- **Files** — the Album art popup and the granted-folder list. See below.
- **Advanced** — the Playhead refresh cap (`uiUpdateHzCap`; the pane calls `syncUITimerRate`, the public live-apply hook, since only a track start or a resize would otherwise recompute it), the cache-size readout (both stores summed, generation-guarded against a stale reply landing after a clear), the Clear Cache button, and the lifetime `AppStats` readouts.

**A stored value that matches no preset is snapped on read** by `AppSettings`, not by the pane (`SettingsRules.h`, tested), so a hand-edited plist cannot leave the pane displaying one value while the audio uses another.

## The Files pane

Two things a folder grant ties together.

**Album art** — `AppSettings.useFolderArt`, with stable identifiers (`file_only`, `file_then_folder`) on `representedObject`. **TRAP: the pane must call `MainPlayerController.refreshFolderArt` after writing it** — not merely to redraw. The resolver caches that setting because it gates every accessor on every cell draw, and that call is the one thing that drops the cache, so a write without it is not observed at all. What the resolver has *settled* survives deliberately; see `Audio/Metadata/CLAUDE.md`.

**Granted folders**, over `FolderAccessManager` (`Mac/App/`). Every folder the user opens, drags onto the app, or adds through Add Folder is stored as an app-scoped security bookmark (`com.apple.security.files.bookmarks.app-scope`) and re-opened on the next launch. **Stored rows are visible immediately but do not authorize background reads until bookmark restoration has started the security scope**, which is why a row carries a `VibeGrantedFolderState` and the pane dims an unavailable one and appends "(Unavailable)".

**TRAP: never stat a row, or a drag, to decide anything.** `viewForTableColumn:` runs on the main thread for every reload and drag validation runs for every mouse move, and a dead path's mount can block a stat for an automounter timeout. So: the state comes from the resolve the manager already did, the icon is the generic folder content-type icon, and **what counts as a folder is asked of the *pasteboard*** (`NSPasteboardURLReadingContentsConformToTypesKey` against `public.folder`). A package is a directory but not a `public.folder`, so an app bundle is refused *during* the drag rather than silently discarded after it. The cost is that a folder deleted while the app runs still reads as active; the next launch settles it.

**TRAP: a Finder drag onto this list delivers file-reference URLs**, the same trap as the main window's drop — pin to `fileURLWithPath:`.

**TRAP: `getpwuid`, not `NSHomeDirectory`** — see `Mac/App/CLAUDE.md`. Add Common Folder stages on the *real* home, Documents, iCloud Drive or Dropbox.

Add Common Folder is a pull-down over the same panel with nothing selected, since the sandbox grants nothing the user has not picked; confirming returns the displayed folder. The button always opens, and each item carries its own state instead — disabled and suffixed "(Not found)" or "(Already accessible)" — so the menu says why rather than going quietly dead. **The not-found answers are probed off the main thread**, generation-guarded, because two of the four candidates are file-provider roots where a stat blocks for as long as the provider takes; an unprobed path counts as present. An unavailable row is excluded from the "(Already accessible)" test — it is exactly the folder worth offering again.

A playlist file is the one open that has to *ask*: opening a .cue/.m3u grants that file alone, not the audio it names, so an unreadable entry raises `requestAccessForPlaylistFolder:` — the same picker and bookmark as Add Folder, **serialized on its own gate because powerbox prompts must not stack**, and blocking the expansion worker that called it. It lives here rather than in `NSURLUtil`, which only detects that a grant is needed and reaches this through the handler `AppDelegate` installs at launch.

The auto-add hook lives at the single open funnel — `AppDelegate.openURLsWithRestoredAccess:token:` — and bookmarks only directories, skipping anything under an active grant or under ~/Music, which the `com.apple.security.assets.music.read-write` entitlement covers standing.

The list is multiple-selection, so Remove takes a batch, and Edit > Select All (nil-targeted, `Mac/Menu/CLAUDE.md`) reaches it through the responder chain once a row has been clicked. Persistence is the manager's own `VibeGrantedFolders` defaults key — bookmark blobs, not settings, so deliberately not `AppSettings`.

## Driving this window from the debug channel

**Never drive this window with `click`, `drag` or the `key*` verbs.** They post into the *main player window's* event stream, so at best they miss and at worst they hit the player behind it — and these panes are built in code with no view identifiers, leaving nothing to aim at but coordinates that move with every localization and pane resize.

Four verbs address it structurally instead — pane by stable identifier, control by the name the pane shows. They are documented here rather than in the `vibe-debug` skill because they are useless anywhere else.

```bash
"$V" --debug-cmd settings_open playback                    # by identifier, index or displayed title
"$V" --debug-cmd dump_settings_ui | jq -c '.controls[]|{index,kind,name,state,value}'
"$V" --debug-cmd settings_click "Detect key automatically" on
"$V" --debug-cmd dump_state | jq -e '.settings.analyzeKey' >/dev/null   # assert the setting, not the pane
"$V" --debug-cmd settings_close
```

`dump_settings_ui` covers the **selected pane only**. Each control carries `kind`, `name`, the row `label` it sits against, `enabled`, a `rect`, and its live value: `state` for a checkbox or radio, `value` + `selected` + `items[]` for a popup, `rows` + `selectedRows` for a list, `value` for a label. `settings_click` replies with that same live value, so the reply alone shows the result.

**Anything a pane gains shows up here first** — a control kind the walker does not model, a name two controls now share — so re-run `dump_settings_ui` after changing a pane's layout.

**Naming.** `settings_click` matches, case-insensitively, a button's own title or the form grid's row label — exactly first, then as a substring, so `"Detect key"` works but `"Detect"` is an error naming both matches. `#3` addresses the dump's index, which is how the **folder list** is reached, since a row label names every control beside it. **Quote any name with spaces**: unlike `click_menu`, this verb needs the second token for the value. Popup items match by title *or* by the stable identifier on `represented`, which is how a waveform style, key notation or appearance is chosen without touching localized text: `settings_click Waveform sonic_cirrus`.

| kind | value | what happens |
| --- | --- | --- |
| `button` | none | `performClick:` |
| `checkbox` | `on`, `off`, `toggle` (default) | the real click path, so `on`/`off` are idempotent — already there replies `action: "unchanged"` |
| `radio` | none, or `on` | same; `off` is refused, since clicking a radio cannot turn one off |
| `popup` | item title, `represented` identifier or `#index` | selects it, then sends the item's own action if it has one, else the button's |
| `pulldown` | same | sends the item's action; `#0` is refused, being the button's title rather than a choice |
| `table` | `2`, `0,3`, `all`, `none` | sets the selection, delegate and all — this is what re-enables Remove |
| `slider` | a number | sets `doubleValue`, then sends the action; the dump carries `value`, `min`, `max` |
| `colorwell` | `#RRGGBB[AA]` | sets the well's color, alpha included, then sends the action; the dump's `value` is the same hex, so the setting round-trips through this verb. The Appearance pane's wells share their row labels — address them as `#index` |
| `label`, `field`, `control` | — | refused: a readout, an editable field with no click path, and the generic bucket the walker does not model yet |

The wrong value for a kind is an error rather than a silent no-op. No pane uses a `slider`, `field` or bare `control` today; the walker classifies all three anyway, so a pane that gains one is reported honestly rather than skipped.

**Traps.**

- **A pane switch animates the window resize** (0.12s) and `settings_open` replies while it is still running — its own `frame` is the mid-flight one, as is any `rect` or screenshot taken in the same breath. `sleep 0.2`, then read.
- **A sheet blocks everything behind it**, as it does for a real click, so `settings_click` refuses while one is up and `dump_settings_ui` reports it as `sheet`. Only `settings_close` can clear it — it calls `endSheet:` before closing. This matters because **Add Folder and Add Common Folder open a sandbox open panel that no injection verb can dismiss**: powerbox owns it, and the `key*` verbs go to the player.
- **Clicking Set Vibe as Default Music Player raises a real system confirmation panel**, outside the app entirely. Leave it to a human.
- **Assert the setting, through `dump_state.settings`, not just the control.** The control moving proves the click landed; the setting proves the action ran.
