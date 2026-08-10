# Menus and app bootstrap

The bootstrap guidance below also governs `main.m` (repo root) and `AppDelegate` (`Vibe/Common/`), which live outside this directory.

## Bootstrap

There is no main nib. `main.m` creates the `AppDelegate` and keeps it alive in a global, because `NSApplication.delegate` is weak. `applicationWillFinishLaunching:` creates `MainPlayerController`, which owns its `OutputDevicesMenuController`, and installs the menu bar through `MainMenuBuilder`, a stateless one-shot class method.

The live submenus belong to per-menu delegates, each owned by the object it works for and wired at build time: Open Recent to the app delegate's `OpenRecentMenuController`, backed by `NSDocumentController.recentDocumentURLs`; Output to the player controller's `OutputDevicesMenuController`; and waveform Style to the player controller itself.

Bare key equivalents must set `keyEquivalentModifierMask = 0` explicitly, since `NSMenuItem` defaults to Command.

## Vibe > Set Vibe as Default Music Player

This claims every audio type the app declares, so the user never has to walk Finder's Get Info > Open With > Change All once per extension.

`DocumentTypes` (in `Common/`, stateless) reads the `CFBundleDocumentTypes` declarations out of Info.plist as `UTType`s. It is the single source of truth shared by the ⌘O panel's filter, the types offered to Launch Services and the already-default check. It hands them to `NSWorkspace.setDefaultApplicationAtURL:toOpenContentType:` one at a time, because a request can raise its own system confirmation panel, and a refusal then stops the walk rather than nagging for the remaining types.

The app puts up no alert of its own on either outcome. The system's panel is the whole conversation, and the menu title reports the result. `AppDelegate.validateMenuItem:` flips the item to a disabled "Vibe Is the Default Music Player" once it holds them all.

The folder declaration is excluded on purpose: `declaredFileTypes` drops directory-conforming types. Vibe accepts a dropped folder, but it should never become the system's default folder handler.

## Menu items

Menu items carry SF Symbol icons through the `SymbolItem()` and `AddSymbolItem()` static helpers in `MainMenuBuilder.m`. The Play item's icon flips with its Play/Pause title in validation.

The **Edit** menu, between File and Playback, is Undo (⌘Z) and Redo (⇧⌘Z), then a separator and Copy Name (⇧⌘C) and Copy File (⌘C) — the standard Edit shape, undo group before the copy group — all explicitly targeting the player controller: the app has no text editing, so there is no responder-chain ambiguity to serve. Undo/Redo forward to the window's lazily created `NSUndoManager`; the only registered action is Convert to FLAC; see `Main Window/CLAUDE.md` for what its undo round trip does. Validation takes the titles from `undoMenuItemTitle` and `redoMenuItemTitle` and enables from `canUndo`/`canRedo`, the stack alone, never a stat — see `Audio/CLAUDE.md` for why no Convert-adjacent rule may touch the file system during validation. Copy Name copies the current track's `singleLineTitle` and Copy File puts its file URL on the general pasteboard (a Finder paste then duplicates the file) — both validate against `currentTrack`, like Show in Finder, and both also appear in the window-body and playlist context menus (`Main Window/CLAUDE.md` and `Playlist/`; the playlist's pair acts on the clicked row). macOS force-appends AutoFill, Start Dictation and Emoji & Symbols to any menu it takes for an Edit menu, all inert in an app with no text input. `VibeEditMenuCleaner` (in `MainMenuBuilder.m`), the Edit menu's delegate, strips them in `menuNeedsUpdate:` by dropping every item without a `menu_edit_*` identifier — the one uniform public-API path, since AppKit's suppression defaults cover only Dictation and the character palette, and nothing covers AutoFill. The cleaner deliberately does **not** implement `menuHasKeyEquivalent:…` the way the app's other menu delegates do: Edit carries real key equivalents, and that override would answer for them instead of letting AppKit walk the items. Shifted equivalents ride in the capital letter (`"Z"`, `"C"`) per the NSMenuItem contract — a lowercase key with Shift in the mask draws right but never matches a real press.

The top-level **Convert** menu, between View and Output, is Convert to FLAC, a separator, then Delete Original.

**Convert to FLAC** re-encodes an uncompressed current track as FLAC beside it: enabled only for WAV and AIFF with no FLAC already there, retitled with the reason otherwise — "Converting…" or "FLAC Already Exists". The rule is `AudioFileConverter.validateConvertMenuItem:forTrack:`, shared with the window-body menu's item, which reuses this one's identifier. Only the current track is convertible, so there is deliberately no playlist row item. The engine is in `Audio/Convert/`; the swap that follows is in `Main Window/`.

**Delete Original**, off by default, sends a converted source to the Trash once its FLAC is in place. A checkmarked preference rather than an action, so it is never disabled — one setting, `AppSettings.deleteOriginalAfterConvert`, one place that acts on it, `AudioFileConverter.trashSourceIfEnabled:convertedTo:`, which snapshots it as a conversion is accepted, so a mid-encode flip applies to the next conversion only. Undoing the deletion is Edit > Undo, which reverses the whole conversion, not just the trashing.

**View > Size** (Small, Default, Large) snaps the window to `kMainWindowMinContentWidth`, `kMainWindowContentWidth` or `kMainWindowLargeContentWidth`. These are *body* widths — the window is that plus the pitch panel's slice — and the height is deliberately untouched, since it belongs to Show Playlist and the resize handle. One identifier-to-width mapping, `contentWidthForSizeIdentifier:`, serves both the action and the checkmarks, so dragging off a preset simply matches none of them.

The top-level **FX** menu is one checkmarked toggle per performance effect: Low Kill, Low Kill Boost, Reverb, Delay 1/8 and Delay 1/16, on bare Q, W, E, R and T. They are always enabled, being deck controls that persist across tracks. As with the skip keys, their key equivalents are display and fallback only, since `TransportKeyMonitor` handles the presses and only it can tell a tap from a hold. The toggle actions live in `MainPlayerController+Transport` and are written against its state pass-throughs, so a menu toggle and a bare-key tap are the same flip.

## Output devices

`OutputDevicesMenuController` populates the audio device menu from the `AudioDeviceManager` singleton and, as an `AudioDeviceManagerObserver`, rebuilds the menu in place when devices change while it is open.

The layout is "System Output (<default device>)" — tag -1, the default choice — then a separator, then every output device. The checkmark tracks `AudioPlayer.currentlyRequestedAudioDeviceId`. An explicitly chosen device that disappears, whether mid-playback, while idle or at launch, falls back to System Output, and the fallback is persisted.
