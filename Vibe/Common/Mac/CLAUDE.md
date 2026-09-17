# Common/Mac: the macOS half of the store

`AppSettings+Mac` is the `(Mac)` category on `AppSettings` (`../CLAUDE.md`): every mac-only preference with its identifiers and preset ladders, and the theme store. **A macOS reader imports `AppSettings+Mac.h` explicitly beside `AppSettings.h`**; the shared `AppSettings.m` reaches this half only through the hooks `AppSettingsInternal.h` declares, whose class extension holds the ivars a category cannot. The theme *record* — `AppTheme`, its sanitization gate, colors, images, archive and dice — is `Theme/CLAUDE.md`.

**TRAP: a stored key never follows a rename of its macro.** `SETTING_FOLDER_ART` is still `@"Audio.folderArtwork"`; changing the string resets every user's setting. The key list at the top of `AppSettings+Mac.m` is where the next one would be renamed.

## The theme store

**Three keys.** `Appearance.userThemes` holds the user themes as flat records plus `id`/`name`; `Appearance.activeTheme` names the theme the working state derives from (registered default `vibe`, snapped to `vibe` when it names nothing); `Appearance.currentTheme` is the persisted **working record**, present only while it diverges from the active theme's own record. `currentTheme` materializes once and is mutated in place.

**Every field edit funnels through `currentThemeDidChange`** (root `CLAUDE.md`'s guarantee). It writes the active user theme's record *from the same dictionary*, so the two cannot drift, or the divergence key when a built-in is active; `applyThemeWithIdentifier:` resets the divergence. The store never applies effects — the caller requests the mapped `VibeSettingsLiveEffect`.

**Duplicating the active theme copies its working record**, including built-in divergence, so Customize preserves quick waveform edits. Duplicating another theme reads its stored record. Both use `duplicateThemeWithIdentifier:`; callers apply the returned copy and request effects.

**Built-in immutability is enforced in the store paths**, `+[AppTheme isBuiltInIdentifier:]` gating every mutation, not by UI disablement alone.

**Display names are never identifiers.** A built-in's English name is its JSON's `name`; `displayNameForThemeIdentifier:` overlays the hand-managed `ThemeNames` catalog, keyed by identifier, per language.

**`windowAppearance` is the one answer** the window, the View menu's validation and the Settings toolbar's preview toggle read: the single-mode pin (`AppTheme.requiredWindowAppearance`) folded above the preview and the stored style, in that order.

## Undo and redo are the store's

**Theme edits, renames and removals share one fifty-entry history with a cursor, and every entry is the same shape.** Each side is a store snapshot — the whole user-theme list, the active identifier and the working record (`ThemeStoreSnapshot`) — so an edit, a committed rename and a removal differ only in which of the three moved, and one restore serves all of them: persist the list, activate, replace the working record. `currentThemeDidChange` records custom-theme edits and built-in divergence. A removal's fallback goes through the store-only `activateThemeWithIdentifier:`, so earlier history survives; the user's explicit pick, `applyThemeWithIdentifier:`, is that activation plus a cleared history, and either reset action clears it too.

**Unrecorded library changes discard history.** Adding a theme (imports and duplicates included) or renaming an inactive theme clears undo and redo after persisting, then sweeps images; otherwise an older snapshot would erase the addition or rename. An unchanged name preserves history. Renaming the active theme remains an undoable edit.

**Only a continuous gesture coalesces.** `currentThemeDidChangeContinuous:YES` folds the same working-record keys moving within two seconds onto the first tick's before-snapshot, updating the final after-snapshot; the theme list counts as one more key, so a rename or a removal never folds into the drag after it. Discrete edits remain separate. Undo and redo end coalescing; a new edit discards the redo branch, while an unchanged write preserves it.

**Both directions use `restoreThemeHistoryForward:` without recording** (`_themeHistoryRestoring`, whose only meaning is "do not record"). A restore sweeps nothing: everything it puts back is still held by the entry it crossed. The caller requests `ThemeApply`. `AppThemeTests` covers both directions, removal order/fallback, branch invalidation, the history cap and gesture boundaries.

## The image sweep

**`sweepUnreferencedThemeImages` covers every image field of every record** — stored themes, built-in divergence, and every theme list and working record in both sides of every history entry (`ThemeHistoryRecords`) — keyed on `AppTheme.customImageFilesInRecord:`. An image remains available while undo or redo can restore it. Dropping an image-bearing redo branch or evicting an entry at the cap sweeps even when the latest edit changed no image field, a rename included. Both reset actions clear history and the appearance preview *before* sweeping. Reset to defaults preserves stored user themes and their images; factory reset removes the user-theme key first, then uses the same reset path.

## The loose-settings migration

**`migrateLooseAppearanceSettingsToTheme` runs at `AppSettings` init BEFORE `registerDefaults`** — the ordering is load-bearing, since its presence checks must not see the registration domain. `+[AppTheme migratedRecordFromLegacyValues:]` decides the record; the migration consumes the loose keys it reads, the shared-named waveform keys included: this is the Mac store, and iOS is a separate app over a separate one.
