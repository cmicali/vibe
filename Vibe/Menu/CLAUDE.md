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

**View > Size** (Small, Default, Large) snaps the window to `kMainWindowMinContentWidth`, `kMainWindowContentWidth` or `kMainWindowLargeContentWidth`. These are *body* widths — the window is that plus the pitch panel's slice — and the height is deliberately untouched, since it belongs to Show Playlist and the resize handle. One identifier-to-width mapping, `contentWidthForSizeIdentifier:`, serves both the action and the checkmarks, so dragging off a preset simply matches none of them.

The top-level **FX** menu is one checkmarked toggle per performance effect: Low Kill, Low Kill Boost, Reverb, Delay 1/8 and Delay 1/16, on bare Q, W, E, R and T. They are always enabled, being deck controls that persist across tracks. As with the skip keys, their key equivalents are display and fallback only, since `TransportKeyMonitor` handles the presses and only it can tell a tap from a hold. The toggle actions live in `MainPlayerController+Transport` and are written against its state pass-throughs, so a menu toggle and a bare-key tap are the same flip.

## Output devices

`OutputDevicesMenuController` populates the audio device menu from the `AudioDeviceManager` singleton and, as an `AudioDeviceManagerObserver`, rebuilds the menu in place when devices change while it is open.

The layout is "System Output (<default device>)" — tag -1, the default choice — then a separator, then every output device. The checkmark tracks `AudioPlayer.currentlyRequestedAudioDeviceId`. An explicitly chosen device that disappears, whether mid-playback, while idle or at launch, falls back to System Output, and the fallback is persisted.
