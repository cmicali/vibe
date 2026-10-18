# Transport: bare keys, skips and FX toggles

`TransportKeyMonitor` handles the keys. `MainPlayerController+Transport` is the skips and the five effect setters. It also holds shuffle, repeat and On track end, the successor prefetch, the pitch fader, the volume slider and the waveform's seek. `TransportMath.h` is the skip arithmetic and the volume's steps, tested. The controller is `../AGENTS.md`, and the menu twins are `Mac/Menu/AGENTS.md`.

## Keys

**Keys are remappable and matched by physical key.** The defaults are Space, B, N, P and Tab. A, S and D skip forward, and Z, X and C skip back. The playlist has Return and Delete. Q, W, E, R and T are the dual-mode effect keys, with R the 1/8-note delay and T the 1/16. The monitor matches a keyDown's key code and exact ⌘⌥⌃⇧ set against `ShortcutRules.h` over `AppSettings.shortcutOverrides`, read per keypress. So the A/S/D row skips under AZERTY and Greek alike.

**The character defaults (⌘O, ⇧⌘O, ⌘L, ⌘S, ⇧⌘C, ⌥⌘S, ⌘R, ⇧⌘R) match by the character typed.** Under Command the layout's ⌘-layer letter (`characters`) is tried first, so Dvorak – QWERTY ⌘ and Greek agree with the menu bar. The unmodified letter is tried next, since Option bends the typed letter (⌥⌘S types ß). `VibeShortcutCommandForPress` is that whole match, reserved shortcuts included.

**Some keys are never bindings** (`VibeShortcutIsReserved`). The fixed system shortcuts pass on even when a key-code binding lands on one after a layout switch, so ⌘Q wins. So do the arrows, Escape and every keypad key but Enter, which a menu cannot draw apart from the main keyboard's.

Every command but the effect keys goes through `performMenuCommandWithIdentifier:` and `MainPlayerController.performMenuItem:`, so its menu validation applies. Repeat is the one command with no menu item to perform: it is a submenu, and the controller cycles the mode for its identifier (`Mac/Menu/AGENTS.md`). **A disabled command swallows its key.** That keeps Play Selected and Remove dead over a collapsed playlist. **A hidden command passes its key on as unbound**, such as Convert to FLAC bound to K with Convert switched off.

**Only Next, Previous and the six skips honor hardware repeat.** A held Space, P, Tab or ⌘R would flutter. In the player window the monitor applies that rule to every binding. Elsewhere the menu bar performs a binding and AppKit repeats it. There the monitor swallows only the repeats of a non-repeating Command binding, since a bare key elsewhere may be typing.

**A tap toggles an effect, a hold is momentary.** The effect flips at keyDown. keyUp reverts it when the press ran past the 0.35 s threshold. **keyUp decides tap or hold**, matched by the key code remembered at keyDown, so a modifier released first cannot hide the release. That is why the menu items' key equivalents are display and fallback only.

## The playlist keys

**The playlist keys never reach the table while the playlist is collapsed.** That is the physical Return, keypad Enter, Up and Down, Backspace and Forward Delete, unmodified, whatever is bound to them, and Play Selected and Remove wherever they are bound. The table keeps focus off screen when the window shrinks. An unhandled key reaching the focused table wedges its input context, so the monitor swallows these keys rather than passing them on. **Up and Down move the volume instead**, 5% a press (`kVibeVolumeStep`). A held arrow repeats. They do nothing while the volume control is off (`../LAYOUT.md`). While the playlist shows, the arrows go to the table's `moveUp:` and `moveDown:`, and Return plays the selection through `PlaylistController.playSelectedTrack`. The monitor acts only on the player window's own events. Play Selected Track and Remove from Playlist validate on `hasVisiblePlaylistSelection` (player window key, playlist showing, a row selected). So a Return or Delete falling through to their key equivalents from Settings or About cannot act on an invisible playlist.

**Backspace and Forward Delete are the delete pair.** They remove every selected row through `removeSelectedPlaylistTracks:`, the Edit menu's target. Remove **ignores hardware repeat**, so a held delete takes one gesture's rows rather than walking the playlist. Keypad Enter and Forward Delete fold into Return and Delete (`VibeShortcutCanonicalKeyCode`), so a binding of either answers both. The menu shows Backspace alone (`Mac/Menu/AGENTS.md`). With Command, the pair is Move to Trash, which ignores hardware repeat too. Over a collapsed playlist, Move to Trash takes the loaded track (`Mac/MainWindow/AGENTS.md`).

`TransportKeyMonitorTests` runs the real monitor handler with constructed key events and stand-in controller and window objects. `ShortcutRulesTests` covers the rules. The native callback passes `event.window` to `handleKeyEvent:inWindow:`, so tests supply the window's identity without creating a window.

## FX toggles

**The FX keys act only while this run has an `AudioFX` controls object and `AppSettings.audioFXAllowed` is true** (the FX setting, with bit-perfect output outranking it). Turning the setting off clears all five live states and stops the keys at once. The player disconnects the FX segment in the same output-stopped rebuild. The menu builder drops the fallback equivalents, and validation disables the items. **The five effect setters are the single funnel** for menus, keys and debug commands. Each calls `updateFXIndicators`, which re-reads the live `AudioFX` flags rather than the caller's intent. The codec line is the indicator (`../LAYOUT.md`).

## Skips

**Skips seek by bars when the tempo is known**, with the BPM label's precedence of tag over analysis. The three distances are `AppSettings.skipBaseBars` (4, 8 or 16), twice it and four times it (`VibeSkipBars`). Bars are file time, so the jump stays on the beat grid at any pitch. Without a tempo the distances are 10, 30 and 60 wall-clock seconds (`VibeSkipWallClockSeconds`). The menu items name the distance in force (`Mac/Menu/AGENTS.md`). A forward skip past the end calls `AudioPlayer.finishCurrentTrack`, so the ordinary track-end path handles it.

**Skips need a player that is not Stopped**, gated in both `skipByFileSeconds:` (which the debug verbs call directly) and menu validation. After the playlist ends the finished file can stay open. Its `duration` still looks seekable without an active voice. Re-parking a successor in that state would start an unasked download.
