# Settings (iOS)

The screens behind the Playlist tab's gear, **pushed onto that navigation stack rather than presented**, so the mini strip and the card behind it stay up. The shell is `../AGENTS.md`.

**These screens write settings and never reach for the screens that draw them.** A display setting's writer ends on `VibeNotifyDisplaySettingsChanged()`, never a hand-composed post, and the card's `displaySettingsDidChange` (`../Player/AGENTS.md`) is the reader. A notification is right here where macOS uses its synchronous named-effect mapping (`Common/AGENTS.md`), because the settings screens and the card share no owner below `RootViewController`.

**The Playback screen's writes end on the model, because the player plays from them.** On track end and Crossfade — the mac pane's Track transitions group — each end on `PlaybackController.applyTrackTransitionSettings`, which is what the gear hands the model down the stack for; the rule it enforces is the root doc's. **Enable audio effects** ends on `applyFXSetting` and is the one Playback write that also posts the display notification, since the card's FX pad shows or hides on it. **Detect BPM automatically** ends nowhere: the waveform loader asks the provider on its next decode, and a file scanned while it was off is not re-analyzed until its cache entry goes (`Audio/Analysis/AGENTS.md`).

**"When opening a folder" notifies nothing.** No screen draws from it; it governs the next open. Its case writes `AppSettings.folderOpenSort`, reloads its section for the checkmark, and returns.

**With Show shuffle and repeat off, both modes are off, whoever asks.** `PlaybackController.pushTransportModes`, the one place the modes reach the playlist and Now Playing, clears both settings first while the switch is off. So a CarPlay or Siri request to turn one on is written back as off, and a mode saved on before the switch was turned off is cleared at launch. Appearance receives the same `PlaybackController` as Playback; turning the switch off calls `applyTrackTransitionSettings` before the display notification, so the playlist, Now Playing and the queued successor agree. Turning the switch on only reveals the controls.

**`PlayerDisplaySettings`** holds `VibeiOSShowRemainingTime`, `VibeiOSShowFileInfo` and `VibeiOSShowShuffleRepeat`: iOS-owned keys, not `AppSettings` — on macOS the first two are `AppTheme` fields, iOS has no theme system, and the mac has no shuffle or repeat buttons to hide. File info and the shuffle and repeat buttons default on, so the key's absence is tested rather than registered. The waveform style stays an `AppSettings` property (both platforms offer the picker); Normalize and Gain are macOS-only (`AppSettings+Mac.h`) — the scrubber draws the normalized mapping, and this screen offers no knob.

**TRAP: two `reloadSections:` calls in one turn coalesce into one batch update**, whose validation raises `_Bug_Detected_In_Client_Of_UITableView_Invalid_Batch_Updates` when a section's row count changed with no insert or delete. A lone `reloadSections:` is fine (the Files screen's folder list); the theme screen, which must move a checkmark and empty the colors section together, reloads the whole table.

**TRAP: a table header view is positioned by autoresizing, not constraints**, so it keeps whatever height it was given. The About screen sizes its identity block in `viewDidLayoutSubviews` and re-assigns `tableHeaderView` only on a real size change, since assigning re-enters layout.

**TRAP: the app icon is not reachable through the asset catalog.** `Resources/AppIcon.icon` is an Icon Composer package, so `AppIcon` is a layered stack there and `[UIImage imageNamed:@"AppIcon"]` *throws* rather than returning nil. The About header takes the loose PNG named by `CFBundleIcons`, and accepts that it is 120px.

**The `AppStats` counters are fed from the shell, not from here**: `FolderSession.finishOpenIntent` records opens, skipping `restored` or every cold start would add a folder, and `PlaybackController+PlayerEvents` brackets the listening clock. The About screen only reads.
