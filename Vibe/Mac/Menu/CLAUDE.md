# Menu bar (macOS)

There is no main nib. `MainMenuBuilder` is a stateless one-shot class method, called from `AppDelegate.applicationWillFinishLaunching:` **after `MainPlayerController` exists**, one builder method per top-level menu. **An item that appears in more than one menu is built by a vended constructor** (`copyNameItemWithTarget:`, `copyFileItemWithTarget:`, `convertToFLACItemWithTarget:`) so it carries the same identifier, SF Symbol and action everywhere; the window-body and playlist context menus build theirs from these. Identifiers and the domain that validates each are `MenuValidationRules.h` (`MainWindow/CLAUDE.md`).

**Live submenus belong to per-menu delegates**, each owned by the object it works for and wired at build time: Open Recent to `AppDelegate`'s `OpenRecentMenuController` (over `NSDocumentController.recentDocumentURLs`), Output to `MainPlayerController`'s `OutputDevicesMenuController`, View > Theme to the player controller itself.

## Key equivalents

**TRAP: bare key equivalents must set `keyEquivalentModifierMask = 0` explicitly**, since `NSMenuItem` defaults to Command. Every item here goes through a helper that takes the mask as a parameter, so the bare-key items (Space, B, N, Return, Backspace, A/S/D, Z/X/C, Q/W/E/R/T) pass `0`.

**TRAP: a shifted key equivalent rides in the capital letter** (`"Z"`, `"C"`) per the `NSMenuItem` contract — a lowercase key with Shift in the mask draws right but never matches a real press.

Bare-key items are **display and fallback only**: `TransportKeyMonitor` (`Mac/MainWindow/`) handles the actual presses, because only it can tell a tap from a hold.

## Edit

**Every Edit item explicitly targets the player controller** — there is no text editing, so no responder-chain ambiguity to serve — **except Select All, which is nil-targeted** so ⌘A reaches whichever list has keyboard focus (the granted-folder list in Settings > Permissions). Without a menu item carrying that key equivalent nothing sends `selectAll:` at all: AppKit dispatches ⌘A through the menu bar and `NSTableView` never claims it itself. A table reachable by the chain must answer honestly, since `NSTableView` responds to the selector whether or not it can act: `PlaylistTableView.validateMenuItem:` answers `allowsMultipleSelection`.

**TRAP: macOS force-appends AutoFill, Start Dictation and Emoji & Symbols to any menu it takes for an Edit menu**, all inert in an app with no text input. `VibeEditMenuCleaner` (in `MainMenuBuilder.m`), the Edit menu's delegate, strips them in `menuNeedsUpdate:` by dropping every item without a `menu_edit_*` identifier — the one uniform public-API path, since AppKit's suppression defaults cover only Dictation and the character palette. **So every Edit separator carries the prefix too** (`menu_edit_separator_remove`, `menu_edit_separator_select`). **The cleaner deliberately does not implement `menuHasKeyEquivalent:…`** as the other delegates do: Edit carries real key equivalents, and that override would answer for them instead of letting AppKit walk the items.

**Undo and Redo use the responder chain.** Text fields retain native undo; the Settings window routes to theme history on Appearance, while the main window forwards to the player controller to retain conversion guards.

**The player's Undo and Redo validate from the stack alone — `canUndo`/`canRedo`, titles from `undoMenuItemTitle`/`redoMenuItemTitle` — never a stat**, since no Convert-adjacent rule may touch the file system during validation (`Audio/Mac/Convert/CLAUDE.md`). Three actions register: Convert to FLAC, Remove from Playlist, Reorder (`MainWindow/CLAUDE.md`).

**Remove from Playlist is the one Edit item acting on the *selected* rows rather than the current track, and the only one that changes the playlist.** Its symbol is `minus.circle`, never `trash`: it edits the in-memory list and leaves the file on disk. Its bare Backspace is spelled `NSBackspaceCharacter`, which AppKit draws as ⌫ while a real press delivers `NSDeleteCharacter`, so `TransportKeyMonitor` is the actual handler, for the unadvertised Forward Delete twin as well. Validation needs all three of the player window key, the playlist showing and a selection, so a Delete press with Settings or About in front cannot edit an invisible playlist. The row menu carries the same command against the **clicked** row under its own identifier (`Playlist/Mac/CLAUDE.md`).

**There is deliberately no Clear Playlist item.** File > Close retitles itself Close All Files and `closeFile:` owns the complete teardown; a second whole-list command would be an alias or a second teardown path liable to omit a future piece of playback state.

## Playback

**Play Selected Track (bare Return) is the one Playback item validated against the *window*** — enabled only while the playlist is showing and a row is selected, because with the pane collapsed the arrow keys do not move a selection either (`MainWindow/Transport/CLAUDE.md`).

## Convert

**Settings > Convert > Enabled off hides the whole feature, live.** The menu is always built (`menu_convert`) and hidden in place: the `ConvertMenu` effect calls `MainMenuBuilder.applyConvertMenuVisibility`, and the build seeds the initial state. The context menus' shared item follows through its validation branch, which hides it and returns NO. A hidden item stays in `itemArray` — `dump_menu` reports it with `hidden: true`.

**Convert to FLAC validates through `AudioFileConverter.validateConvertMenuItem:forTrack:`**, shared with the window-body item under the same `menu_convert_to_flac` identifier: WAV and AIFF with no FLAC already beside them, retitled "FLAC Already Exists" otherwise. **While a conversion runs the same item becomes the enabled Cancel Conversion**: `MainPlayerController.validateConvertMenuItem:` swaps title and action to `cancelConversion:` ahead of the converter's rule, since the sweep has no place for a button (`Audio/Mac/Convert/CLAUDE.md`). Only the current track is convertible, so there is deliberately no playlist row item.

**Delete Original is a checkmarked preference, never disabled** — one setting, `AppSettings.deleteOriginalAfterConvert`, and one place that acts on it, `AudioFileConverter.trashSourceIfEnabled:convertedTo:`, which snapshots it as a conversion is accepted, so a mid-encode flip applies to the next conversion only. Undoing the deletion is Edit > Undo, which reverses the whole conversion.

## View

**Show Pitch Control** and the P key are disabled while bit-perfect output is on (`AppSettings.pitchControlAllowed`), since the mode creates no varispeed. `togglePitchPanel:` refuses the reveal itself, so the debug verb cannot bypass it; menu validation and the window’s launch restore read the same answer.

- **Theme** is rebuilt whole on every open by `MainPlayerController.menuNeedsUpdate:`: one checkmarked item per theme (`representedObject` the stable id, identifier `view_theme_<id>`), then the nil-targeted **Edit Themes…** (`menu_edit_themes` → `AppDelegate.showThemeSettings:`, the same ownership as Settings…, so deliberately absent from `MenuValidationRules.h`). Selecting applies the theme and requests `ThemeApply`.
- **Show File Info** flips the current theme's `showFileInfo` through the store's persist funnel, then requests `TrackDisplay`. Off hides the header's codec and BPM/key readouts; **the FX symbols on the codec line are deck state, not file info, and keep rendering** (`MainWindow/APPEARANCE.md`).
- **Size** (Small, Default, Large) snaps to `kMainWindowMinContentWidth`, `kMainWindowContentWidth` or `kMainWindowLargeContentWidth`. These are *body* widths — the window is that plus the pitch panel's slice — and the height is deliberately untouched, since it belongs to Show Playlist and the resize handle. One mapping, `contentWidthForSizeIdentifier:`, serves the action and the checkmarks, so dragging off a preset matches none.

## FX

One checkmarked toggle per effect on bare Q/W/E/R/T, actions in `MainPlayerController+Transport` against its state pass-throughs, so a menu toggle and a bare-key tap are the same flip. **The menu is always built and hidden in place.** `FXControls` clears active effects before hiding it and sends the saved audio settings through the player’s shared rebuild; enabling can create the FX segment without relaunch. Validation and `TransportKeyMonitor` both require `AppSettings.audioFXAllowed` (the FX setting with bit-perfect output outranking it) *and* the FX controls object, so the keys cannot change an effect while the controls are off.

**TRAP: hiding a top-level submenu does not deactivate its children's key equivalents.** AppKit still matches Q/W/E/R/T under a hidden `menu_fx`, even when validation returns NO. The visibility effect must clear and restore those equivalents as well as hiding the item; validation remains the direct-dispatch gate.

## Output

`OutputDevicesMenuController` builds "System Output (<default device>)" (tag -1) then every device from `AudioDeviceManager`, and as an observer **rebuilds it in place while it is open** — which is why the manager fans out in the common run-loop modes (`Audio/Mac/Devices/CLAUDE.md`). The checkmark tracks `AudioPlayer.currentlyRequestedAudioDeviceId`; a chosen device that disappears falls back to System Output, persisted. **`selectOutputDevice:` is the one way the shell switches output**, for this menu and the Settings list alike: bit-perfect and exclusive output are remembered per device UID (`AppSettings`), and the player queries those modes for the resolved UID before binding (`Audio/Mac/Devices/CLAUDE.md`). The controller counts outstanding selections and refreshes the Audio pane at submission and completion, keeping both mode switches disabled until every selection settles, including failures. Nothing grays out for the mode — an ineligible device simply has none. The Settings > Audio list is `SettingsGeneralViewController`'s own table over the same manager snapshot; only the selection funnel is shared.

## Help

**`NSApp.helpMenu` is set explicitly** — that is what puts AppKit's Search field at the top in every language, rather than AppKit finding a menu titled "Help". The app ships no help book, so Report Issue or Feature Request (`kVibeSupportURL`, `Common/VibeProductURLs.h`) is the only item of ours; the search field is inserted when the menu opens, so `dump_menu` on an unopened Help menu reports Report Issue or Feature Request alone.
