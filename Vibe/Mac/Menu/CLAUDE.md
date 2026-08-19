# Menu bar (macOS)

There is no main nib. `MainMenuBuilder` is a stateless one-shot class method, called from `AppDelegate.applicationWillFinishLaunching:` after `MainPlayerController` exists. One builder method per top-level menu.

Vended item constructors (`copyNameItemWithTarget:`, `copyFileItemWithTarget:`, `convertToFLACItemWithTarget:`) exist so an item that appears in more than one menu carries the same identifier, SF Symbol and action everywhere — the window-body and playlist context menus build theirs from these.

**Live submenus belong to per-menu delegates**, each owned by the object it works for and wired at build time: Open Recent to `AppDelegate`'s `OpenRecentMenuController` (backed by `NSDocumentController.recentDocumentURLs`), Output to `MainPlayerController`'s `OutputDevicesMenuController`, and waveform Style to the player controller itself.

**TRAP: bare key equivalents must set `keyEquivalentModifierMask = 0` explicitly**, since `NSMenuItem` defaults to Command. Every item here goes through a helper that takes the mask as a parameter, so the bare-key items (Space, B, N, Return, A/S/D, Z/X/C, Q/W/E/R/T) pass `0`.

**TRAP: a shifted key equivalent rides in the capital letter** (`"Z"`, `"C"`) per the `NSMenuItem` contract — a lowercase key with Shift in the mask draws right but never matches a real press.

Bare-key items are **display and fallback only**: `TransportKeyMonitor` (`Mac/MainWindow/`) handles the actual presses, because only it can tell a tap from a hold.

## Edit

Every Edit item explicitly targets the player controller — the app has no text editing, so there is no responder-chain ambiguity to serve — **with one deliberate exception, Select All**, which is nil-targeted because ⌘A has to reach whichever list has keyboard focus (today the granted-folder list in Settings > Permissions). Without a menu item carrying that key equivalent nothing sends `selectAll:` at all: AppKit dispatches ⌘A through the menu bar and `NSTableView` never claims it itself.

It follows that any table reachable by the chain must answer honestly — `NSTableView` responds to the selector whether or not it can act — so `PlaylistTableView.validateMenuItem:` returns NO for it, being single-selection, rather than leaving the item enabled and inert whenever the playlist has focus.

**TRAP: macOS force-appends AutoFill, Start Dictation and Emoji & Symbols to any menu it takes for an Edit menu**, all inert in an app with no text input. `VibeEditMenuCleaner` (in `MainMenuBuilder.m`), the Edit menu's delegate, strips them in `menuNeedsUpdate:` by dropping every item without a `menu_edit_*` identifier — the one uniform public-API path, since AppKit's suppression defaults cover only Dictation and the character palette, and nothing covers AutoFill.

**The cleaner deliberately does not implement `menuHasKeyEquivalent:…`** the way the app's other menu delegates do: Edit carries real key equivalents, and that override would answer for them instead of letting AppKit walk the items.

Undo/Redo forward to the window's lazily created `NSUndoManager`; the only registered action is Convert to FLAC (`MainWindow/CLAUDE.md`). Validation takes titles from `undoMenuItemTitle`/`redoMenuItemTitle` and enables from `canUndo`/`canRedo` — **the stack alone, never a stat**, since no Convert-adjacent rule may touch the file system during validation (`Audio/Mac/Convert/CLAUDE.md`).

Copy Name copies the current track's `singleLineTitle`; Copy File puts its file URL on the general pasteboard. Both validate against `currentTrack`, like Show in Finder.

## Playback

Transport first — Play, Previous Track, Next Track, then **Play Selected Track** on bare Return, the keyboard twin of a double-click on a playlist row. It is the one Playback item validated against the *window*: enabled only while the playlist is showing and a row is selected, because with the pane collapsed the arrow keys do not move a selection either (`MainWindow/CLAUDE.md`). Below the separator are the six skip-seek items, then the Pitch Range submenu.

## Convert

Between View and Output: Convert to FLAC, a separator, then Delete Original.

**Convert to FLAC** re-encodes an uncompressed current track as FLAC beside it. The rule is `AudioFileConverter.validateConvertMenuItem:forTrack:`, shared with the window-body menu's item, which reuses this one's `menu_convert_to_flac` identifier: enabled only for WAV and AIFF with no FLAC already there, retitled with the reason otherwise — "Converting…" or "FLAC Already Exists". **Only the current track is convertible, so there is deliberately no playlist row item.**

**Delete Original**, off by default, sends a converted source to the Trash once its FLAC is in place. A checkmarked *preference* rather than an action, so it is never disabled — one setting (`AppSettings.deleteOriginalAfterConvert`), one place that acts on it (`AudioFileConverter.trashSourceIfEnabled:convertedTo:`), which snapshots it as a conversion is accepted, so a mid-encode flip applies to the next conversion only. Undoing the deletion is Edit > Undo, which reverses the whole conversion.

## View

- **Show File Info** — a checkmarked preference flipping `AppSettings.showFileInfo` (default on), repainted through `MainPlayerController.refreshFileInfoDisplay`, shared with the Settings > Appearance checkbox. Off hides the header's codec and BPM/key readouts; **the FX symbols riding the codec line are deck state, not file info, and keep rendering** (`MainWindow/APPEARANCE.md`).
- **Always on Top** — flips `AppSettings.alwaysOnTop` and funnels through `MainPlayerController.applyAlwaysOnTop`, shared with the Settings > General checkbox.
- **Size** (Small, Default, Large) — snaps the window to `kMainWindowMinContentWidth`, `kMainWindowContentWidth` or `kMainWindowLargeContentWidth`. These are *body* widths — the window is that plus the pitch panel's slice — and the height is deliberately untouched, since it belongs to Show Playlist and the resize handle. One identifier-to-width mapping, `contentWidthForSizeIdentifier:`, serves both the action and the checkmarks, so dragging off a preset simply matches none of them.

## FX

One checkmarked toggle per performance effect: Low Kill, Low Kill Boost, Reverb, Delay 1/8, Delay 1/16, on bare Q, W, E, R, T. Always enabled, being deck controls that persist across tracks. The toggle actions live in `MainPlayerController+Transport` and are written against its state pass-throughs, so a menu toggle and a bare-key tap are the same flip.

**With `AppSettings.audioFXEnabled` off, `MainMenuBuilder` omits the whole FX menu** and `TransportKeyMonitor` passes Q/W/E/R/T through unhandled. The setting is read once at player init, so it lands on relaunch.

## Output

`OutputDevicesMenuController` populates the audio device menu from the `AudioDeviceManager` singleton and, as an `AudioDeviceManagerObserver`, rebuilds it in place when devices change **while it is open** — which is why the manager fans out in the common run-loop modes (`Audio/Mac/Devices/CLAUDE.md`).

Layout: "System Output (<default device>)" — tag -1, the default choice — then a separator, then every output device. The checkmark tracks `AudioPlayer.currentlyRequestedAudioDeviceId`. An explicitly chosen device that disappears falls back to System Output, persisted.

**A second instance serves the Output popup in Settings > General**, using the same controller as the popup menu's delegate and builder, so the two layouts cannot drift.
