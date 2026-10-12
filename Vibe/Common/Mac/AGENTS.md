# Common/Mac: the macOS half of the store

`AppSettings+Mac` is the `(Mac)` category on `AppSettings` (`../AGENTS.md`). It holds every mac-only preference with its identifiers and preset ladders, and the theme store. **A macOS reader imports `AppSettings+Mac.h` explicitly beside `AppSettings.h`.** The shared `AppSettings.m` reaches this half only through the hooks `AppSettingsInternal.h` declares. That header's class extension holds the ivars a category cannot. The theme record (`AppTheme`, its sanitization gate, colors, images, archive and dice) is `Theme/AGENTS.md`'s.

## The theme store

**Three keys.**
- `Appearance.userThemes` holds the user themes as flat records plus `id` and `name`.
- `Appearance.activeTheme` names the theme the working state derives from. Its registered default is `vibe`, and it snaps to `vibe` when it names nothing.
- `Appearance.currentTheme` is the persisted **working record**. It is present only while the working record diverges from the active theme's own record.

`currentTheme` materializes once and is mutated in place.

**Every field edit funnels through `currentThemeDidChange`** (root `AGENTS.md`'s guarantee). It writes the active user theme's record from the same dictionary, so the two cannot drift. When a built-in is active it writes the divergence key instead. `applyThemeWithIdentifier:` resets the divergence. The store never applies effects. The caller requests the mapped `VibeSettingsLiveEffect`.

**Duplicating the active theme copies its working record**, built-in divergence included, so Customize keeps quick waveform edits. Duplicating another theme reads its stored record. Both use `duplicateThemeWithIdentifier:`. Callers apply the returned copy and request effects.

**Built-in immutability is enforced in the store paths.** `+[AppTheme isBuiltInIdentifier:]` gates every mutation. UI disablement alone is not the guard.

**Display names are never identifiers.** A built-in's English name is its JSON's `name`. `displayNameForThemeIdentifier:` overlays the hand-managed `ThemeNames` catalog, keyed by identifier, per language.

**`windowAppearance` is the one answer** that the window, the View menu's validation and the Settings toolbar's preview toggle read. It folds the single-mode pin (`AppTheme.requiredWindowAppearance`) above the preview, and the preview above the stored style.

## Undo and redo are the store's

**Theme edits, renames and removals share one fifty-entry history with a cursor, and every entry has the same shape.** Each side is a store snapshot (`ThemeStoreSnapshot`): the whole user-theme list, the active identifier and the working record. An edit, a committed rename and a removal differ only in which of the three moved. One restore serves all of them: persist the list, activate, replace the working record. `currentThemeDidChange` records custom-theme edits and built-in divergence. A removal's fallback goes through the store-only `activateThemeWithIdentifier:`, so earlier history survives. The user's explicit pick, `applyThemeWithIdentifier:`, is that activation plus a cleared history. Either reset action clears it too.

**Unrecorded library changes discard history.** Adding a theme (imports and duplicates included), or renaming an inactive theme, clears undo and redo after persisting, then sweeps images. Otherwise an older snapshot would erase the addition or rename. An unchanged name keeps history. Renaming the active theme is an undoable edit.

**Only a continuous gesture coalesces.** `currentThemeDidChangeContinuous:YES` folds the same working-record keys moving within two seconds onto the first tick's before-snapshot, and updates the final after-snapshot. The theme list counts as one more key, so a rename or a removal never folds into the drag after it. Discrete edits stay separate. Undo and redo end coalescing. A new edit discards the redo branch, and an unchanged write keeps it.

**Both directions use `restoreThemeHistoryForward:` without recording.** `_themeHistoryRestoring` means only "do not record". A restore sweeps nothing, since everything it puts back is still held by the entry it crossed. The caller requests `ThemeApply`. `AppThemeTests` covers both directions, removal order and fallback, branch invalidation, the history cap and gesture boundaries.

## The image sweep

**`sweepUnreferencedThemeImages` covers every image field of every record.** That is the stored themes, the built-in divergence, and every theme list and working record on both sides of every history entry (`ThemeHistoryRecords`). It is keyed on `AppTheme.customImageFilesInRecord:`. An image stays available while undo or redo can restore it. Dropping an image-bearing redo branch, or evicting an entry at the cap, sweeps even when the latest edit changed no image field, a rename included. Both reset actions clear history and the appearance preview *before* sweeping. Reset to defaults keeps stored user themes and their images. Factory reset removes the user-theme key first, then uses the same reset path.

## Migrations

**`AppSettings` init runs three migrations, in order, before `registerDefaults`.** The ordering is load-bearing: their presence checks must not see the registration domain. Each makes itself run once.

1. **`migrateLooseAppearanceSettingsToTheme`** moves the pre-theme loose keys into a user theme. It runs only while no active theme is stored. `+[AppTheme migratedRecordFromLegacyValues:]` decides the record. Before that, the migration maps an old build's display-name style to its identifier, and gives a themeless Sonic Cirrus store the orange it drew (`VibeMigratedWaveformTheme`). It consumes every loose key it reads, the shared-named waveform keys included. iOS is a separate app over a separate store. It must not read the pre-theme display keys (`MainWindow.showFileInfo` and friends), since today's settings use those same keys.
2. **`migrateThemeRecordsToVersion2`** rewrites every stored record and the divergence key once (`AppTheme recordUpgradedFromVersion1:`). A version-1 window "solid" meant today's `frosted`. `Appearance.themeRecordVersion` makes it run once, so a Solid picked since stays Solid. Theme JSON carries the same number. An import below version 2 is upgraded the same way, and every export and built-in says 2. It writes raw records, so the next migration still finds their version-1 fields.
3. **`migrateThemeDisplaySettings`** moves the display choices that version-1 records carried (`Theme/AGENTS.md`, What a theme is not) into the app-wide settings. It reads the active theme's: the divergence key, else the active user theme's entry. Nothing on screen changes. Then every stored record drops them, which is what makes it run once. A divergence left equal to its built-in is removed. No shipped built-in set a display field, so only stored records are read.
