# Settings (iOS)

The screens behind the Playlist tab's gear, **pushed onto that navigation stack rather than presented**, so the mini strip and the card behind it stay up. The shell is `../CLAUDE.md`.

**These screens write settings and post; they never reach for the screens that draw them.** Every writer ends on `VibeNotifyDisplaySettingsChanged()`, never a hand-composed post, and the card's `displaySettingsDidChange` (`../Player/CLAUDE.md`) is the reader. A notification is right here where macOS uses its synchronous named-effect mapping (`Common/CLAUDE.md`), because the settings screens and the card share no owner below `RootViewController`.

**"When opening a folder" notifies nothing.** No screen draws from it; it governs the next open. Its case writes `AppSettings.folderOpenSort`, reloads its section for the checkmark, and returns.

**`PlayerDisplaySettings`** holds `VibeiOSShowRemainingTime` and `VibeiOSShowFileInfo`: iOS-owned keys, not `AppSettings` — on macOS those are `AppTheme` fields, and iOS has no theme system. File info defaults on, so the key's absence is tested rather than registered. The waveform style stays an `AppSettings` property (both platforms offer the picker), and Normalize and Gain are shared `AppSettings` outright: they are set for a library's mastering level, not a look.

**TRAP: two `reloadSections:` calls in one turn coalesce into one batch update**, whose validation raises `_Bug_Detected_In_Client_Of_UITableView_Invalid_Batch_Updates` when a section's row count changed with no insert or delete. A lone `reloadSections:` is fine (the Files screen's folder list); the theme screen, which must move a checkmark and empty the colors section together, reloads the whole table.

**TRAP: a table header view is positioned by autoresizing, not constraints**, so it keeps whatever height it was given. The About screen sizes its identity block in `viewDidLayoutSubviews` and re-assigns `tableHeaderView` only on a real size change, since assigning re-enters layout.

**TRAP: the app icon is not reachable through the asset catalog.** `Resources/AppIcon.icon` is an Icon Composer package, so `AppIcon` is a layered stack there and `[UIImage imageNamed:@"AppIcon"]` *throws* rather than returning nil. The About header takes the loose PNG named by `CFBundleIcons`, and accepts that it is 120px.

**The `AppStats` counters are fed from the shell, not from here**: `FolderSession.finishOpenIntent` records opens, skipping `restored` or every cold start would add a folder, and `PlaybackController+PlayerEvents` brackets the listening clock. The About screen only reads.
