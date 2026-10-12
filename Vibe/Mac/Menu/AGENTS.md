# Menu bar (macOS)

There is no main nib. `MainMenuBuilder` is a stateless one-shot class method. `AppDelegate.applicationWillFinishLaunching:` calls it **after `MainPlayerController` exists**. There is one builder method per top-level menu. **An item that appears in more than one menu is built by a vended constructor** (`copyNameItemWithTarget:`, `copyFileItemWithTarget:`, `convertToFLACItemWithTarget:`), so it carries the same identifier, SF Symbol and action everywhere. The window-body context menu builds its copies from these. The playlist row menu shares only titles and symbols (`symbolItemWithTitle:`), under its own clicked-row actions and identifiers (`Playlist/Mac/AGENTS.md`).

**Menu identifiers and the domain that validates each are `MenuValidationRules.h`.** Each identifier has one `kVibeMenu*` constant, and the literal appears nowhere else, so a rename that misses a site fails the build. **TRAP: an identifier that reaches Unknown is DISABLED** (and asserts in Debug). A new controller-targeted menu item must be added there, or it never enables.

**Live submenus belong to per-menu delegates**, each owned by the object it works for and wired at build time. Open Recent is `AppDelegate`'s `OpenRecentMenuController` (over `NSDocumentController.recentDocumentURLs`). Output is `MainPlayerController`'s `OutputDevicesMenuController`. View > Theme is the player controller itself.

## App menu

**Check for Updates…** sits under About in the direct download only. It is compiled out of the Mac App Store build, never hidden, since App Review rejects an app that updates itself. It targets Sparkle's updater controller, which validates it (`Mac/App/AGENTS.md`, Updates). Like Settings…, it has no entry in `MenuValidationRules.h`, and it is not remappable.

## Key equivalents

**Every remappable item's key equivalent is set in one place, `applyShortcuts`**, from the effective shortcut. `ShortcutRules.h` holds the defaults table, which `AppSettings.shortcutOverrides` overrides sparsely. The builder passes `@"", 0` for those items, then requests the `Shortcuts` effect. That effect also runs on an input source change.

**The fixed system shortcuts are reserved and never remappable**: ⌘, ⌘H ⌥⌘H ⌘Q ⌘W ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A. They keep their literals in the builder. An override stored before its key was reserved stays stored but does nothing. The key monitor passes the press on, and `applyShortcuts` gives the item no equivalent (`VibeShortcutForMenuItem`). So a ⌘V bound before Edit > Paste existed never shadows Paste.

**A key two commands hold goes to the first in table order**, in the menu bar as in the key monitor. `VibeShortcutForMenuItem` asks `VibeShortcutOwner`, and the later command's item carries no equivalent. **A new default therefore goes last in the table.** An override stored on its key before the default existed then keeps that key. Open URL's ⌘U is the case. The Shortcuts pane lists what each item carries (`carriedShortcutForIdentifier:overrides:`). The losing command's row reads unassigned, as does a row whose override landed on a reserved key.

**A key-code shortcut is shown in the current ASCII-capable layout's character.** It is looked up with TIS and `UCKeyTranslate`, the one Carbon use, and rebuilt after `kTISNotifySelectedKeyboardInputSourceChanged`. `allowsAutomaticKeyEquivalentLocalization` is off, so AppKit does not localize it again. **A ⌘ key-code shortcut is named in the layout's Command layer** (`UCKeyTranslate` with `cmdKey`), for its equivalent, its label and the reserved check alike. A layout such as Dvorak – QWERTY ⌘ types other letters there, and the press is the letter that layer types. The character defaults (⌘O, ⌘U, ⌘S, ⇧⌘C, ⌥⌘S, ⌘R) follow the letter, as every Mac app's Command shortcuts do. A key no layout names gets no equivalent, but the monitor still matches it. The arrows, Escape and keypad Clear are named by glyph, and the other keypad keys as "Keypad 1". They only ever appear in a refusal, since all are reserved.

**TRAP: a shifted key rides in the character Shift types** (`"C"` with Command is ⇧⌘C, `"!"` is ⇧1 on US), per the `NSMenuItem` contract. The unshifted character with Shift in the mask draws right but never matches a real press, which reports the shifted one. `ApplyShortcut` converts from the layout's Shift layer, so no caller spells it. The special keys keep the flag.

**TRAP: a bare key equivalent must set `keyEquivalentModifierMask = 0` explicitly**, since `NSMenuItem` defaults to Command. Every helper takes the mask as a parameter.

**In the player window every remappable item's equivalent is display and fallback only.** `TransportKeyMonitor` (`Mac/MainWindow/Transport/`) handles the presses. It handles the bare keys because only it can tell a tap from a hold. It handles all of them so one path applies the repeat rule, since AppKit repeats every key equivalent and a held ⌘R would cycle the repeat mode. Anything but an effect it performs through `MainPlayerController.performMenuItem:`, which runs the menu's validation first. Validation builds each symbol image once (`MenuSymbolImage`), since a held skip key runs it at key-repeat rate. Outside the player window the menu bar performs the shortcuts, and the monitor only drops the repeats of a Command binding whose command does not repeat.

## File

**Open… and Open URL… target the app delegate, which always enables them.** Open URL… (`menu_open_link`, ⌘U) sits after Open… and asks for a link in a window of its own (`Mac/App/AGENTS.md`). Close is nil-targeted (`MainWindow/AGENTS.md`).

## Edit

**Copy Name, Copy File and Remove from Playlist target the player controller. Undo, Redo, Cut, Paste and Select All are nil-targeted.**

- **Select All** is nil-targeted so ⌘A reaches whichever list has keyboard focus, such as the granted-folder list in Settings > Files. AppKit dispatches ⌘A only through the menu bar, and `NSTableView` never claims it itself. `NSTableView` responds to `selectAll:` whether or not it can act, so a table the chain can reach must answer honestly: `PlaylistTableView.validateMenuItem:` answers `allowsMultipleSelection`.
- **Cut and Paste exist for text fields**, such as the Open URL field and Settings' fields. They sit in Apple's order around the two Copy items. They reach the focused field and stay disabled anywhere else.
- **⌘C belongs to Copy File, which forwards to a focused text field.** While the key window's first responder is a text view, a field editor included, `copyFile:` sends `copy:` to it and returns. Validation then answers YES whatever the track (`VibeEditMenuEnabled`'s `textFocused`). The item keeps its title.

**TRAP: macOS force-appends AutoFill, Start Dictation and Emoji & Symbols to any menu it takes for an Edit menu.** They are no use in the app's few short text fields. `VibeEditMenuCleaner` (in `MainMenuBuilder.m`), the Edit menu's delegate, strips them in `menuNeedsUpdate:`. It drops every item without a `menu_edit_*` identifier (`VibeEditMenuKeepsItem`). That is the one uniform public-API path, since AppKit's opt-outs cover only Dictation and the character palette. **So every Edit separator carries the prefix too** (`menu_edit_separator`, `menu_edit_separator_remove`, `menu_edit_separator_select`). **The cleaner deliberately does not implement `menuHasKeyEquivalent:…`** as the other delegates do. Edit carries real key equivalents, and that override would answer for them instead of letting AppKit walk the items.

**Undo and Redo use the responder chain.** Text fields keep native undo. The Settings window routes them to theme history on the Themes pane and to the Shortcuts pane's own manager there. The main window forwards them to the player controller, which keeps the conversion guard.

**The player's Undo and Redo validate from the stack alone** (`canUndo` and `canRedo`, titles from `undoMenuItemTitle` and `redoMenuItemTitle`). Validation never stats a file (`Mac/Convert/AGENTS.md`). Three actions register: Convert to FLAC, Remove from Playlist and Reorder (`MainWindow/AGENTS.md`).

**Remove from Playlist is the one Edit item that acts on the *selected* rows, and the only one that changes the playlist.** Its symbol is `minus.circle`, never `trash`, because it edits the list and leaves the file on disk. Its default Delete is drawn as `NSBackspaceCharacter` (⌫), while a real press delivers `NSDeleteCharacter`. So `TransportKeyMonitor` is the actual handler, matching by key code, Forward Delete included. Validation needs the player window key, the playlist showing and a selection. The row menu carries the same command for the **clicked** row under its own identifier (`Playlist/Mac/AGENTS.md`).

**There is deliberately no Clear Playlist item.** File > Close retitles itself Close All Files, and `closeFile:` owns the whole teardown. A second whole-list command would be an alias, or a second teardown path that could miss a future piece of playback state.

## Playback

**Play Selected Track (bare Return) is the one Playback item validated against the window.** It enables only while the playlist is showing and a row is selected (`MainWindow/Transport/AGENTS.md`).

## Convert

**Settings > Files > Convert menu off hides the whole feature, live.** The menu is always built (`menu_convert`) and hidden in place. The `ConvertMenu` effect calls `MainMenuBuilder.applyConvertMenuVisibility`, and the build seeds the initial state. The context menus' shared item hides itself in validation and returns NO. A hidden item stays in `itemArray`, and `dump_menu` reports it with `hidden: true`.

**Convert to FLAC validates through `AudioFileConverter.validateConvertMenuItem:forTrack:`**, shared with the window-body item under the same `menu_convert_to_flac` identifier. It enables for WAV and AIFF with no FLAC beside them, and retitles to "FLAC Already Exists" otherwise. **While a conversion runs, the same item becomes the enabled Cancel Conversion.** `MainPlayerController.validateConvertMenuItem:` swaps its title and action to `cancelConversion:` ahead of the converter's rule (`Mac/Convert/AGENTS.md`). Only the current track is convertible, so there is deliberately no playlist row item. **The item is hidden for a file under a remote root** (`VibeConvertMenuItemHidden`), decided from the path alone. An Open URL link's file belongs to its store, and a FLAC beside it would land in the store's directory.

**Delete Original is a checkmarked preference, never disabled.** One setting, `AppSettings.deleteOriginalAfterConvert`, has one place that acts on it, `AudioFileConverter.trashSourceIfEnabled:convertedTo:completion:`. The converter snapshots it when a conversion is accepted, so a flip mid-encode applies to the next conversion only. Edit > Undo reverses the whole conversion, the deletion included.

## View

**Show Pitch Control and the P key are disabled while bit-perfect output is on** (`AppSettings.pitchControlAllowed`), since that mode has no varispeed. `togglePitchPanel:` refuses the reveal itself, so the debug verb cannot bypass it. Menu validation and the window's launch restore read the same answer.

- **Theme** is rebuilt whole on every open by `MainPlayerController.menuNeedsUpdate:`. It holds one checkmarked item per theme (`representedObject` the stable id, identifier `view_theme_<id>`), then the nil-targeted **Edit Themes…** (`menu_edit_themes`, `AppDelegate.showThemeSettings:`). Edit Themes… is owned like Settings…, so it has no validation domain. Selecting a theme applies it and requests `ThemeApply`.
- **Width** (Small, Default, Large) snaps to `kMainWindowMinContentWidth`, `kMainWindowContentWidth` or `kMainWindowLargeContentWidth`. These are *body* widths: the window is that plus the pitch panel's slice. The height is deliberately untouched, since it belongs to Show Playlist and the resize handle. One mapping, `contentWidthForSizeIdentifier:`, serves the action and the checkmarks, so a window dragged off a preset matches none.

## FX

There is one checkmarked toggle per effect, on bare Q, W, E, R and T by default. The actions are `MainPlayerController+Transport`'s, so a menu toggle and a bare-key tap are the same flip. **The menu is always built and hidden in place.** `FXControls` clears active effects before hiding it and sends the saved audio settings through the player's shared rebuild. Enabling can create the FX segment without a relaunch. Validation and `TransportKeyMonitor` both require `AppSettings.audioFXAllowed` *and* the FX controls object.

**TRAP: hiding a top-level submenu does not deactivate its children's key equivalents.** AppKit still matches the FX keys under a hidden `menu_fx`, even when validation returns NO. `applyShortcuts` gives no equivalent to any item under a hidden menu, FX and Convert alike, and both visibility hooks call it after hiding. Validation remains the gate for direct dispatch.

## Output

`OutputDevicesMenuController` builds "System Output (<default device>)" (tag -1), then every device from `AudioDeviceManager`. As an observer it **rebuilds the menu in place while it is open**, which is why the manager fans out in the common run-loop modes (`Audio/Mac/Devices/AGENTS.md`). The checkmark follows `AudioPlayer.currentlyRequestedAudioDeviceId`. A chosen device that disappears falls back to System Output, and the fallback is persisted.

**`selectOutputDevice:` is the one way the shell switches output**, for this menu and the Settings list alike. Bit-perfect and exclusive output are remembered per device UID (`AppSettings`), and the player asks for the resolved UID's modes before binding. The controller counts outstanding selections. It refreshes the Audio Output pane at submission and at completion, and both mode switches stay disabled until every selection settles, failures included. Nothing grays out for the mode, since an ineligible device simply has none.

## Help

**`NSApp.helpMenu` is set explicitly.** That is what puts AppKit's Search field at the top in every language. The app ships no help book, so Report Issue or Feature Request (`kVibeSupportURL`, `Common/VibeProductURLs.h`) is our only item. The search field is inserted when the menu opens, so `dump_menu` on an unopened Help menu reports our item alone.
