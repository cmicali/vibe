# Common/Mac: the macOS half of the store

`AppSettings+Mac` is the `(Mac)` category on `AppSettings` (`../CLAUDE.md`): every mac-only preference with its identifiers and preset ladders, and the theme store. **A macOS reader imports `AppSettings+Mac.h` explicitly beside `AppSettings.h`**; the shared `AppSettings.m` reaches this half only through the hooks `AppSettingsInternal.h` declares, whose class extension holds the ivars a category cannot. The theme *record* — `AppTheme`, its sanitization gate, colors, images, archive and dice — is `Theme/CLAUDE.md`.

**TRAP: a stored key never follows a rename of its macro.** `SETTING_FOLDER_ART` is still `@"Audio.folderArtwork"`; changing the string resets every user's setting. The key list at the top of `AppSettings+Mac.m` is where the next one would be renamed.

## The theme store

**Three keys.** `Appearance.userThemes` holds the user themes as flat records plus `id`/`name`; `Appearance.activeTheme` names the theme the working state derives from (registered default `vibe`, snapped to `vibe` when it names nothing); `Appearance.currentTheme` is the persisted **working record**, present only while it diverges from the active theme's own record. `currentTheme` materializes once and is mutated in place.

**Every field edit funnels through `currentThemeDidChange`** (root `CLAUDE.md`'s guarantee). It writes the active user theme's record *from the same dictionary*, so the two cannot drift, or the divergence key when a built-in is active; `applyThemeWithIdentifier:` resets the divergence. The store never applies effects — the caller requests the mapped `VibeSettingsLiveEffect`.

**Built-in immutability is enforced in the store paths**, `+[AppTheme isBuiltInIdentifier:]` gating every mutation, not by UI disablement alone.

**Display names are never identifiers.** A built-in's English name is its JSON's `name`; `displayNameForThemeIdentifier:` overlays the hand-managed `ThemeNames` catalog, keyed by identifier, per language.

**`windowAppearance` is the one answer** the window, the View menu's validation and the Settings toolbar's preview toggle read: the single-mode pin (`AppTheme.requiredWindowAppearance`) folded above the preview and the stored style, in that order.

## Undo is the store's

**`currentThemeDidChange` pushes an entry for every persisted write of a USER theme** — fields and name, so a committed `renameUserThemeWithIdentifier:toName:` is an entry — fifty deep. A built-in's edits are divergence, not the theme's, and are not recorded; `applyThemeWithIdentifier:` drops the stack, so an undo never lands on another theme.

**Only a continuous gesture coalesces.** `currentThemeDidChangeContinuous:YES` — the corner-radius slider's and the color wells' ticks — folds the same keys moving within two seconds onto the first tick's entry; a discrete edit never coalesces, so two menu picks of one field are two undos.

**`undoThemeEdit` restores without recording** (`_themeUndoRestoring`): the top entry's name back through the rename path, its fields into the working record; the caller requests `ThemeApply`. `AppThemeTests` drives the funnel with explicit timestamps through `AppSettingsInternal.h`, the two-second boundary included.

## The image sweep

**`sweepUnreferencedThemeImages` covers every image field of every record** — the stored themes, the divergence record and the undo stack, whose entries can put a cleared reference back — keyed on `AppTheme.customImageFilesInRecord:`. Being the store's undo is what lets the sweep keep a file only a stacked record still names; evicting an image-bearing entry at the cap sweeps even when the latest edit changed no image field, a rename included. Factory reset clears undo and the appearance preview *before* sweeping.

## The loose-settings migration

**`migrateLooseAppearanceSettingsToTheme` runs at `AppSettings` init BEFORE `registerDefaults`** — the ordering is load-bearing, since its presence checks must not see the registration domain. `+[AppTheme migratedRecordFromLegacyValues:]` decides the record; the migration consumes the loose keys it reads, the shared-named waveform keys included: this is the Mac store, and iOS is a separate app over a separate one.
