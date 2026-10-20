# Menu bar (macOS)

This directory holds the menu bar's builder (`MainMenuBuilder`) and the controllers of the Open Recent and Output submenus. It also holds the menu validation rules (`MenuValidationRules.h`) and the default shortcuts (`ShortcutRules.h`).

**The menus are Vibe, File, Edit, View, Playback, FX, Convert, Output and Window, in Apple's order.** There is no Help menu, since the app ships no help book. Output stays top level for quick access while playing. **The menu bar carries no symbols**, as Apple's own menus do not. Its only images show content: Open Recent's file icons and View > Theme's swatches. The context menus keep their SF Symbols (`symbolItemWithTitle:`).

There is no main nib. `MainMenuBuilder` is a stateless one-shot class method. `AppDelegate.applicationWillFinishLaunching:` calls it **after `MainPlayerController` exists**. There is one builder method per top-level menu. The window-body context menu and the playlist row menu build their own items with `symbolItemWithTitle:`. The window-body items share the menu bar's identifiers, and so its validation. The row menu's act on the **clicked** row under its own actions and identifiers (`Playlist/Mac/AGENTS.md`).

**Menu identifiers and the domain that validates each are `MenuValidationRules.h`.** Each identifier has one `kVibeMenu*` constant, and the literal appears nowhere else, so a rename that misses a site fails the build. **TRAP: an identifier that reaches Unknown is DISABLED** (and asserts in Debug). A new controller-targeted menu item must be added there, or it never enables. **An identifier is a stored key** (`AppSettings.shortcutOverrides`), so an item that moves to another menu keeps its identifier. Move to Trash is `menu_edit_move_to_trash` in the File menu.

**Live submenus belong to per-menu delegates**, each owned by the object it works for and wired at build time. Open Recent is `AppDelegate`'s `OpenRecentMenuController` (over `NSDocumentController.recentDocumentURLs`). Output is `MainPlayerController`'s `OutputDevicesMenuController`. View > Theme is the player controller itself.

## App menu

**Check for Updates…** sits under About in the direct download only. It is compiled out of the Mac App Store build, never hidden, since App Review rejects an app that updates itself. It targets Sparkle's updater controller, which validates it (`Mac/App/AGENTS.md`, Updates). Like Settings…, it has no entry in `MenuValidationRules.h`, and it is not remappable.

**Send Feedback…** follows it and opens the support page (`kVibeSupportURL`, `Common/VibeProductURLs.h`). It targets the app delegate, which always enables it.

## Key equivalents

**Every remappable item's key equivalent is set in one place, `applyShortcuts`**, from the effective shortcut. `ShortcutRules.h` holds the defaults table, which `AppSettings.shortcutOverrides` overrides sparsely. The builder passes `@"", 0` for those items. The `Shortcuts` effect sets them half a second after the window is up (`AppDelegate`). It runs again on an input source change. The builder sets only the drop hint's shortcut, which the first frame draws (`applyOpenShortcutHint`).

**The fixed system shortcuts are reserved and never remappable**: ⌘, ⌘H ⌥⌘H ⌘Q ⌘W ⌘M ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A. They keep their literals in the builder. An override stored before its key was reserved stays stored but does nothing. The key monitor passes the press on, and `applyShortcuts` gives the item no equivalent (`VibeShortcutForMenuItem`). So a ⌘V bound before Edit > Paste existed never shadows Paste.

**A key two commands hold goes to the first in table order**, in the menu bar as in the key monitor. `VibeShortcutForMenuItem` asks `VibeShortcutOwner`, and the later command's item carries no equivalent. **A new default therefore goes last in the table.** An override stored on its key before the default existed then keeps that key. Open Location's ⌘L and Show in Finder's ⇧⌘R are the cases. The Shortcuts pane lists what each item carries (`carriedShortcutForIdentifier:overrides:`). The losing command's row reads unassigned, as does a row whose override landed on a reserved key.

**A key-code shortcut is shown in the current ASCII-capable layout's character.** It is looked up with TIS and `UCKeyTranslate`, the one Carbon use, and rebuilt after `kTISNotifySelectedKeyboardInputSourceChanged`. `allowsAutomaticKeyEquivalentLocalization` is off, so AppKit does not localize it again. **A ⌘ key-code shortcut is named in the layout's Command layer** (`UCKeyTranslate` with `cmdKey`), for its equivalent, its label and the reserved check alike. A layout such as Dvorak – QWERTY ⌘ types other letters there, and the press is the letter that layer types. The character defaults (⌘O, ⇧⌘O, ⌘L, ⌘S, ⇧⌘C, ⌥⌘S, ⌘R, ⇧⌘R) follow the letter, as every Mac app's Command shortcuts do. A key no layout names gets no equivalent, but the monitor still matches it. The arrows, Escape and keypad Clear are named by glyph, and the other keypad keys as "Keypad 1". They only ever appear in a refusal, since all are reserved.

**TRAP: a shifted key rides in the character Shift types** (`"C"` with Command is ⇧⌘C, `"!"` is ⇧1 on US), per the `NSMenuItem` contract. The unshifted character with Shift in the mask draws right but never matches a real press, which reports the shifted one. `ApplyShortcut` converts from the layout's Shift layer, so no caller spells it. The special keys keep the flag.

**TRAP: a bare key equivalent must set `keyEquivalentModifierMask = 0` explicitly**, since `NSMenuItem` defaults to Command. Every helper takes the mask as a parameter.

**In the player window every remappable item's equivalent is display and fallback only.** `TransportKeyMonitor` (`Mac/MainWindow/Transport/`) handles the presses. It handles the bare keys because only it can tell a tap from a hold. It handles all of them so one path applies the repeat rule, since AppKit repeats every key equivalent and a held ⌘R would cycle the repeat mode. Anything but an effect it performs through `MainPlayerController.performMenuItem:`, which runs the menu's validation first. Outside the player window the menu bar performs the shortcuts, and the monitor only drops the repeats of a Command binding whose command does not repeat. **A bare key typed into a focused text field in another window never reaches the menu bar.** AppKit offers an unmodified key equivalent to the menu only after the key window's responder chain declines the key, and a field editor consumes it. The Open Location field and the theme editor's Name field were checked in the running app, so validation needs no text-focus guard for the transport and FX items.

**Repeat's ⌘R has no menu item.** Repeat is a submenu, and AppKit performs nothing for a submenu's own item. That item carries `kVibeMenuRepeat` so the Shortcuts pane lists the command, `applyShortcuts` skips it, and `performMenuCommandWithIdentifier:` cycles the mode for it. So ⌘R works in the player window only.

## File

**Open…, Add to Playlist… and Open Location… target the app delegate, which always enables them.** Add to Playlist… (`menu_add_to_playlist`, ⇧⌘O) sits after Open… and shares its panel (`Mac/App/AGENTS.md`). Open Location… (`menu_open_link`, ⌘L) comes next and asks for a link in a window of its own (`Mac/App/AGENTS.md`). The name is QuickTime Player's and Safari's. Open Recent shows each file's icon, and names a file twice listed by its folder.

**Show in Finder (⇧⌘R) acts on the current track. Move to Trash (⌘⌫) acts on the selected rows.** They sit together in the Finder's order. Show in Finder validates on the track having a URL. Move to Trash validates on the visible selection, or on the loaded track while the playlist is collapsed (`VibeMenuHasTrashTarget`), waits for `fileMoveInFlight` as Remove does, and its default is the Finder's. The row menu carries both for the **clicked** row (`Playlist/Mac/AGENTS.md`). Close is nil-targeted (`MainWindow/AGENTS.md`).

**Close File retitles itself Clear Playlist with more than one track loaded.** `closeFile:` owns the whole teardown either way. There is deliberately no second whole-list command, which would be an alias, or a second teardown path that could miss a future piece of playback state.

## Edit

**Copy, Copy Name and Remove from Playlist target the player controller. Undo, Redo, Cut, Paste and Select All are nil-targeted.**

- **Select All** is nil-targeted so ⌘A reaches whichever list has keyboard focus, such as the granted-folder list in Settings > Files. AppKit dispatches ⌘A only through the menu bar, and `NSTableView` never claims it itself. `NSTableView` responds to `selectAll:` whether or not it can act, so a table the chain can reach must answer honestly: `PlaylistTableView.validateMenuItem:` answers `allowsMultipleSelection`.
- **Cut and Paste exist for text fields**, such as the Open Location field and Settings' fields. They sit in Apple's order around the two Copy items. They reach the focused field and stay disabled anywhere else.
- **⌘C is Copy, which copies the current track's file and forwards to a focused text field.** While the key window's first responder is a text view, a field editor included, `copyFile:` sends `copy:` to it and returns. Validation then answers YES whatever the track (`VibeEditMenuEnabled`'s `textFocused`). The title is Copy in both states, so it never lies. The row menu's item is titled Copy File, beside Copy Name.

**TRAP: macOS force-appends AutoFill, Start Dictation and Emoji & Symbols to any menu it takes for an Edit menu.** They are no use in the app's few short text fields. `VibeEditMenuCleaner` (in `MainMenuBuilder.m`), the Edit menu's delegate, strips them in `menuNeedsUpdate:`. It drops every item without a `menu_edit_*` identifier (`VibeEditMenuKeepsItem`). That is the one uniform public-API path, since AppKit's opt-outs cover only Dictation and the character palette. **So every Edit separator carries the prefix too** (`menu_edit_separator`, `menu_edit_separator_remove`, `menu_edit_separator_select`). **The cleaner deliberately does not implement `menuHasKeyEquivalent:…`** as the other delegates do. Edit carries real key equivalents, and that override would answer for them instead of letting AppKit walk the items.

**Undo and Redo use the responder chain.** Text fields keep native undo. The Settings window routes them to theme history on the Themes pane and to the Shortcuts pane's own manager there. The main window forwards them to the player controller, which keeps the file-move gate.

**The player's Undo and Redo validate from the stack alone** (`canUndo` and `canRedo`, titles from `undoMenuItemTitle` and `redoMenuItemTitle`). Validation never stats a file (`Mac/Convert/AGENTS.md`). Four actions register: Convert to FLAC, Remove from Playlist, Move to Trash and Reorder (`MainWindow/AGENTS.md`).

**Remove from Playlist is the Edit item that acts on the *selected* rows, and with File > Move to Trash the only ones that change the playlist.** Its default Delete is drawn as `NSBackspaceCharacter` (⌫), while a real press delivers `NSDeleteCharacter`. So `TransportKeyMonitor` is the actual handler, matching by key code, Forward Delete included. It validates on the player window key, the playlist showing and a selection, and waits for `fileMoveInFlight`.

## View

**Show Playlist and Show Pitch Control retitle themselves Hide while shown** (`VibeViewToggleTitle`), as a panel's View item does. They carry no checkmark. **Show Pitch Control and the P key are disabled while bit-perfect output is on** (`AppSettings.pitchControlAllowed`), since that mode has no varispeed. `togglePitchPanel:` refuses the reveal itself, so the debug verb cannot bypass it. Menu validation and the window's launch restore read the same answer.

**Theme** is rebuilt whole on every open by `MainPlayerController.menuNeedsUpdate:`. It holds one checkmarked item per theme, with the theme's swatch (`representedObject` the stable id, identifier `view_theme_<id>`), then the nil-targeted **Edit Themes…** (`menu_edit_themes`, `AppDelegate.showThemeSettings:`). Edit Themes… is owned like Settings…, so it has no validation domain. Selecting a theme applies it and requests `ThemeApply`.

**The swatches are the theme list's, from the cache the list shares** (`SettingsThemesViewController.swatchForThemeIdentifier:dark:`, `Settings/Themes/AGENTS.md`). They take the app's appearance, which the menu draws in. `dump_menu` reports an `imageDigest` of each item's image.

**TRAP: macOS 27 hides a menu item's image unless the item asks to show it** (`preferredImageVisibility`). Each theme item asks, through KVC, since CI's SDK predates the property. Open Recent's items do not ask, so macOS 27 hides their file icons.

## Playback

**Play Selected Track (bare Return) is the one Playback item validated against the window.** It enables only while the playlist is showing and a row is selected (`MainWindow/Transport/AGENTS.md`).

**Repeat is a submenu of radio-marked modes**, Off, All and One (`VibeRepeatMenuIdentifier`, `selectRepeatMode:`). The transport button and ⌘R still cycle. Shuffle is a checkmarked toggle.

**Skip Back and Skip Forward are submenus of three distances each** (`VibeSkipMenuTitle`): whole bars while the track's tempo is known, else seconds, from `AppSettings.skipBaseBars` and `TransportMath.h`'s three levels. An item names only its distance, since its submenu names the direction. The Shortcuts pane labels each as "Skip Back: 4 Bars", in the bars form whatever the track. Back comes before forward, as Previous and Next do.

## Convert

**Settings > Files > Convert menu off hides the whole menu, live.** The menu is always built (`menu_convert`) and hidden in place. The `ConvertMenu` effect calls `MainMenuBuilder.applyConvertMenuVisibility`, and the build seeds the initial state.

**Move Original to Trash After Conversion is a checkmarked preference, never disabled.** One setting, `AppSettings.deleteOriginalAfterConvert`, has one place that acts on it, `AudioFileConverter.trashSourceIfEnabled:convertedTo:completion:`. The converter snapshots it when a conversion is accepted, so a flip mid-encode applies to the next conversion only. Edit > Undo reverses the whole conversion, the deletion included. Settings > Files carries the same switch.

**Convert to FLAC validates through `AudioFileConverter.validateConvertMenuItem:forTrack:`**, shared with the window-body item under the same `menu_convert_to_flac` identifier. It enables for WAV and AIFF. In automatic-placement mode an existing sibling FLAC disables it and changes its title to "FLAC Already Exists". Ask-mode leaves destination selection to the save panel. **While a conversion runs, the same item becomes the enabled Cancel Conversion.** `MainPlayerController.validateConvertMenuItem:` swaps its title and action to `cancelConversion:` ahead of the converter's rule (`Mac/Convert/AGENTS.md`). Only the current track is convertible, so there is deliberately no playlist row item. **The item hides itself in validation** while Convert is off and for a file under a remote root (`VibeConvertMenuItemHidden`), decided from the path alone. That is how the context menus follow the setting live. An Open Location link's file belongs to its store, and a FLAC beside it would land in the store's directory. A hidden item stays in `itemArray`, and `dump_menu` reports it with `hidden: true`.

## FX

There is one checkmarked toggle per effect, on bare Q, W, E, R and T by default. The actions are `MainPlayerController+Transport`'s, so a menu toggle and a bare-key tap are the same flip. **The menu is always built and hidden in place.** `FXControls` clears active effects before hiding it and sends the saved audio settings through the player's shared rebuild. Enabling can create the FX segment without a relaunch. Validation and `TransportKeyMonitor` both require `AppSettings.audioFXAllowed` *and* the FX controls object.

**TRAP: hiding a top-level submenu does not deactivate its children's key equivalents.** AppKit still matches the FX keys under a hidden `menu_fx`, even when validation returns NO. `applyShortcuts` gives no equivalent to any item under a hidden menu, FX and Convert alike, and both visibility hooks call it after hiding. Validation remains the gate for direct dispatch.

## Window

**Minimize (⌘M) and Bring All to Front are nil-targeted, and `NSApp.windowsMenu` is the menu**, so AppKit appends the window list. The player window is borderless, so AppKit does not list it, and `MainWindow` answers `performMiniaturize:` itself, since the default implementation presses a title bar button it does not have. The body's own minimize button sends the same action up the chain.

- **Window Width** (Small, Default, Large) snaps to `kMainWindowMinContentWidth`, `kMainWindowContentWidth` or `kMainWindowLargeContentWidth`. These are *body* widths: the window is that plus the pitch panel's slice. The height is deliberately untouched, since it belongs to Show Playlist and the resize handle. One mapping, `contentWidthForSizeIdentifier:`, serves the action and the checkmarks, so a window dragged off a preset matches none.
- **Always on Top and Lock Window Position** are checkmarked toggles of the window's state, shared with Settings > General.

## Output

`OutputDevicesMenuController` builds "System Output (<default device>)" (tag -1), then every device from `AudioDeviceManager`. As an observer it **rebuilds the menu in place while it is open**, which is why the manager fans out in the common run-loop modes (`Audio/Mac/Devices/AGENTS.md`). The checkmark follows `AudioPlayer.currentlyRequestedAudioDeviceId`. A vanished device falls back to System Output for playback. Its saved preference stays available for re-adoption. Explicitly choosing System Output clears that preference.

**`selectOutputDevice:` is the one way the shell switches output**, for this menu and the Settings list alike. Bit-perfect and exclusive output are remembered per device UID (`AppSettings`), and the player asks for the resolved UID's modes before binding. The controller counts outstanding selections. It refreshes the Audio Output pane at submission and at completion, and both mode switches stay disabled until every selection settles, failures included. Nothing grays out for the mode, since an ineligible device simply has none.
