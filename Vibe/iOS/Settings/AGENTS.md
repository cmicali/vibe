# Settings (iOS)

The screens behind the Playlist tab's gear. They are **pushed onto that navigation stack, not presented**, so the mini strip and the card stay up. The shell is `../AGENTS.md`.

**These screens write settings and never reach for the screens that draw them.** A display setting's writer ends on `VibeNotifyDisplaySettingsChanged()`, never a hand-composed post, and the card's `displaySettingsDidChange` (`../Player/AGENTS.md`) reads it. A notification is right here, where macOS maps named live effects (`Common/AGENTS.md`), because the settings screens and the card share no owner below `RootViewController`.

**The Playback screen's writes end on the model, because the player plays from them.** On track end and Crossfade each end on `PlaybackController.applyTrackTransitionSettings`, which is why the gear hands the model down the stack. **Enable audio effects** ends on `applyFXSetting`. It also posts the display notification, since the card's FX pad shows or hides on it. **Detect BPM automatically** writes only the setting. The waveform cache asks its analysis provider on the next request. An entry decoded without BPM is a miss when that request asks for BPM (`Audio/Waveform/AGENTS.md`).

**Files and Dropbox holds the Dropbox account**: Connect (Dropbox's sign-in sheet), Remove Downloads with their size (a row shown only while something is downloaded, `dropboxRowAtIndex:`), Maximum Size and Disconnect. Maximum Size is chosen on the shared choice screen, saved, then set on the mirror's `downloadBudget`, which applies it (`Loading/iOS/Dropbox/AGENTS.md`). Disconnect asks first, because it deletes the downloads and clears a Dropbox playlist. The screen reloads on `VibeDropboxAccountDidChangeNotification`. It takes updated download sizes from `VibeDropboxDownloadsDidChangeNotification` without another disk walk.

**Allow Pasting Links opens this app's page in the Settings app** (`UIApplicationOpenSettingsURLString`). There the user can set Paste from Other Apps to Allow, and the Files tab's paste row then opens a copied link without the prompt (`../Files/AGENTS.md`). No public API reads that permission, so the row is always there and shows no state.

**"Sort folders by" notifies nothing.** No screen draws from it, since it governs the next open. Its case writes `AppSettings.folderOpenSort` and reloads its section for the checkmark.

**With Show shuffle and repeat off, both modes are off, whoever asks.** `PlaybackController.pushTransportModes` is the one place the modes reach the playlist and Now Playing. While the switch is off it clears both settings and disables the two system commands, so CarPlay draws neither button. A request that still arrives is written back as off, and a mode saved before the switch was turned off is cleared at launch. The switch calls `applyTrackTransitionSettings` before the display notification, so the playlist, Now Playing, CarPlay and the queued successor agree. Turning it on leaves both modes off.

**The display switches are shared `AppSettings` properties**: `showRemainingTime`, `showFileInfo` and `showShuffleRepeat`, each under the key its platform shipped (`AppSettingsInternal.h`). iOS's file info combines the codec, tempo and tagged key. Only iOS draws shuffle and repeat buttons. `VibeDisplaySettingsDidChangeNotification` is declared in `AppSettings.h`'s iOS block. iOS stores the waveform style in `AppSettings.waveformStyle`. macOS stores it in `AppSettings.currentTheme`. Normalize and Gain are macOS-only (`AppSettings+Mac.h`); the scrubber draws the normalized mapping.

**Centered is the card's, in Waveform. The Widget group holds the widget's own style and Centered** (`AppSettings.waveformCentered`, `widgetWaveformCentered`). Under Match app the widget reads the card's, and its switch dims. Each switch also dims for a style that ignores it. `migrateLegacyWiggleMCInDefaults:` turns a stored Wiggle MC, a retired style, into Wiggle with its own Centered off.

**Playhead line shows what is drawn, not what is stored.** `AppSettings.waveformPlayheadLine` is nil until the switch is touched. Until then the row asks `WaveformRendererRegistry.drawsPlayheadLineForIdentifier:chosen:`, as the scrubber does, so it reads on under 3-Band and off under every other style. The first touch stores a choice that holds for every style.

**Waveform theme follows the card's style.** Under 3-Band the screen offers the band palettes, Rekord Bin, Dengine and Custom, since that style ignores `waveformTheme`. Every other style offers the waveform themes. Custom shows its wells in a Dark colors and a Light colors section: Played and Unplayed, or Low, Mid and High. The band wells are opaque and show Rekord Bin's band while unset, so choosing Custom seeds nothing. The widget draws the same palettes.

**TRAP: two `reloadSections:` calls in one turn coalesce into one batch update.** Its validation raises `_Bug_Detected_In_Client_Of_UITableView_Invalid_Batch_Updates` when a section's row count changed with no insert or delete. A lone `reloadSections:` is fine. The theme screen must move a checkmark and empty the colors sections together, so it reloads the whole table.

**TRAP: a table header view is positioned by autoresizing, not constraints**, so it keeps whatever height it was given. The About screen sizes its identity block in `viewDidLayoutSubviews` and re-assigns `tableHeaderView` only on a real size change, since assigning re-enters layout.

**TRAP: the app icon is not reachable through the asset catalog.** `Resources/AppIcon.icon` is an Icon Composer package, so `AppIcon` is a layered stack, and `[UIImage imageNamed:@"AppIcon"]` throws rather than returning nil. The About header takes the last PNG named by `CFBundleIcons`.

**The `AppStats` counters are fed from the shell, not from here.** `FolderSession`'s `finishOpenIntent:` records opens, skipping a restore so a cold start adds nothing. `PlaybackController+PlayerEvents` brackets the listening clock. The About screen only reads.
