# AppTheme: the theme record

One theme, the type the theme system is written in terms of: a **sparse record** of appearance overrides, a missing field meaning the factory look. The store that holds it — the three keys, `currentThemeDidChange`, undo, the image sweep — is `../CLAUDE.md`; the editor is `Mac/Settings/Appearance/CLAUDE.md`; the guarantee (one sanitization gate, single and dual mode, the single-mode window pin) is root `CLAUDE.md`'s.

## The record and its schema

**`FieldSpecs()` in `AppTheme.m` is the one schema.** One row per field — key, JSON home, default, sanitizer, archive stem — from which every other table (defaults, known keys, the JSON groups both ways, the color-pair keys) derives, so a field cannot exist without a JSON home or a clamp. The record is **flat**, its keys the accessor names; a theme **JSON file nests** them under the editor's sections (`version`, `name`, then `window`/`player`/`info`/`waveform`/`playlist`), each key section-local: `windowCornerRadius` travels as `window.cornerRadius`. Values are Foundation/JSON throughout, colors as `#RRGGBB[AA]`.

**The gate's clamps:** identifiers snap to their ladders, numbers clamp (radius `[0, kVibeThemeCornerRadiusMax]`, font sizes to narrow layout-safe bands), colors must round-trip as hex, bools are numbers only, unknown fields drop — so a newer build's export imports as the defaults. `initWithRecord:`, `replaceWithRecord:`, every typed setter, `recordFromJSONData:` and the store's `+sanitizedRecord:` all run it. **Font faces are deliberately not validated against installed fonts**: `Fonts`' never-nil fallback owns that at resolve time, which keeps this class host-lessly testable (`AppThemeTests`).

`waveformBarDensity` travels as `waveform.barDensity`, defaults to 1, and clamps to 0.5–4. It scales a supported style's count relative to its designed pitch, so window resizing still adds bars. The renderer registry owns style eligibility; the record keeps the value across style changes.

## The built-ins

**A built-in is `Resources/Themes/<identifier>.json`** — the stem is the stable identifier, `name` the English display name — read through the same `recordFromJSONData:` gate as a user import. Adding one is the file (the directory is a folder reference in both the app and VibeTests, so no project edit) plus its identifier in `testBuiltInIdentifiers`, which keeps a dropped file loud. Order is `vibe` first, then alphabetical.

**`testBundledThemesAreValid` is the gate and is load-bearing**: the import gate is tolerant — a typo'd key or bad color is silently dropped — and only the test's sanitizer round-trip makes that loud. Two consequences it enforces: **`vibe.json` stays field-free** (`testVibeBuiltInIsTheEmptyRecord`; the loader synthesizes the empty record if the file goes missing, since `vibe` is the store's snap-back anchor for unknown and deleted-active themes), and **a built-in that sets a radius spells `customCornerRadius: true`**, or the round-trip would see the gate add it. `technical` and `signal_workshop` are the dual-mode exemplars: a `custom` waveform theme forces both palettes, because an incomplete pair falls back to Mono rather than half-applying.

## Colors

**A pair is keyed by its exported base name** (`kVibeThemeColor*`): `colorForBase:dark:` and `setColor:forBase:dark:` are the slots, the typed `*ColorForDark:` accessors the same slots by name. Under single mode both force the dark-keyed slot from either side; the light halves lie dormant, never mirrored or consumed, so a mode flip round-trips. `requiredWindowAppearance` is nil for a dual theme.

**The four `resolved*Color` accessors are the one home of override-over-semantic-fallback**, and `DefaultColorForBase` the only spelling of what an unset slot draws as (the label pairs' semantic fallback under that side, the solid cover, the neutral tint wash and row fill, Mono's resting levels): the window and playlist covers, the row fills, the editor's wells and the seed a popup writes when it reveals a pair all read it. `displayColorForBase:dark:` pins any pair to one side for the wells.

**The playlist's four text columns are pairs behind switches** (`kVibeThemeColorPlaylistNumber`/`Title`/`Artist`/`Duration`, `playlistColorEnabledForBase:`, JSON `playlist.numberColorEnabled` beside the pair). `resolvedPlaylistColorForBase:` is a column's one answer: the label pair it always drew while off — title over the title pair, the other three over the artist pair — and its own pair while on, an unset side inheriting that same label pair; `displayColorForBase:dark:` shows the inheritance, so the wells never disagree with the table. A pair set while its switch is off is held, not drawn, so toggling round-trips a pick. **A resolved color is captured at call time**: an appearance flip re-resolves by itself, but a theme change must rebuild whatever holds one — the `TrackDisplay`/`PlaylistAppearance` effects' invalidations.

## The corner radius

**Two fields, one accessor.** `windowCornerRadius` is what the slider holds; `customCornerRadius` (default off) says whether the window draws it; `resolvedWindowCornerRadius`, the only accessor consumers read, answers the slider under custom and `kVibeThemeCornerRadiusDefault` (16pt — the window is borderless and draws its own shape, so macOS 26's radius is a constant of ours) otherwise.

**A record naming a radius with no word on the switch reads as custom**, decided in `replaceWithRecord:` — the one place a record is read, so the setters stay plain — because the switch postdates the radius and every older theme keeps the shape it chose. The sparse rule has one exception for the same reason: the switch's *off* beside a stored radius is kept (`storeSanitized:`, and why its spec row follows the radius's), since dropped as the default it would read back as custom.

## The transport buttons

**Three fields apiece.** A glyph (`playlistButtonGlyph`, `playButtonGlyph` with `pauseButtonGlyph` beside it, `nextButtonGlyph`) is free text in the SF Symbol name shape, like a font face: the record knows no symbol catalog, the draw site (`MainPlayerContentView`) falls back to the factory glyph for a name this macOS lacks, and the editor's curated menus are `SettingsRules.h`'s. A color pair (`kVibeThemeColorPlaylistButton`/`PlayButton`/`NextButton`, white and black at 0.55 unset) is **keyed Dark/Light by the art under the buttons, not the appearance** (`Mac/MainWindow/APPEARANCE.md`) — **the one exception to single mode**: `colorKeyForBase:dark:` never collapses an art-keyed pair. Hover and disabled derive by `SymbolButton`'s factory ratios. An image pair, keyed the same way, wins over glyph and color when either side names one. `buttonGradient` (default on) is the darkening behind them; `dockIcon` (`album_art` or `app_icon`) is the Dock tile while art is up; `appIcon` replaces the application icon everywhere.

## Images

**Eleven fields name an image and are one kind** (`kVibeThemeImage*`, `imageFieldKeys`): the placeholder pair `defaultArtworkDark`/`Light`, `appIcon`, and the four buttons' art-keyed Dark/Light pairs. A value is an **image reference**: `""` for the slot's factory image, `bundled:<name>.<ext>` beside the built-in JSON, or `custom:<sha1>.<ext>` in `Application Support/<bundle id>/ThemeArt` (the name predates themes and stays — it is where every install's images already are; `VIBE_THEME_ART_DIR` redirects it under test). Content hashing is what makes `imageForReference:`'s lifetime cache safe — a changed image is a new key — and its custom-entry bound is the field count, so a theme's live set stays pinned while auditioned predecessors do not. The placeholder is the one *paired* image field and follows single mode like a color pair.

**TRAP: a gone or undecodable image falls back but is never cached under ITS key** — the name is a content hash, so re-storing the same image later reuses the poisoned name and the theme would draw the factory record until relaunch.

**The factory fallback differs by slot.** `imageForReference:` answers the record image for anything missing — the placeholder's fallback; the app icon and the buttons ask `customImageForKey:`, nil for `""` and for a gone file, so they fall back to the bundle icon and the glyph, never the record. `referenceIsMissing:` is the only way to tell "deliberately the default" from "the chosen image is gone" — the editor's (!) badge.

**`resolvedDefaultArtworkImage` is the placeholder pair as ONE image**: when the sides differ, a cached dynamic wrapper draws whichever side the drawing appearance asks for, so consumers carry no dark flag. **A consumer that reads its PIXELS must sample under the window's appearance and again on every flip** (`ArtworkDisplayController.refreshTintWashes`), since the same pointer samples dark under one and light under the other.

## The archive form (`AppTheme+Archive`)

**A theme naming any image exports as a ZIP of `theme.json` plus its images, the dormant half included; one naming none stays plain JSON.** A built-in's `bundled:` image travels even though this build ships it — the build that opens the archive may not be this one. `AppThemeInternal.h` is the seam between the codec and the record; what stays in `AppTheme.m` is the record and nothing else.

**Entries are named by slot** (`artwork_default_front`/`_back`, `app_icon`, `button_<name>_dark`/`_light`, each field's stem in its `FieldSpecs()` row), `theme.json` referencing them bare: a content hash or a resource filename reads as nothing to a person opening the ZIP. Two fields naming one image share its entry. The prefix never travels, and `JSONDataForRecord:name:entryNames:` applies the rename *after* sanitization because the gate admits only the prefixed shapes and would drop a bare name.

**Import trusts nothing.** `recordFromJSONOrArchiveData:` takes either form, reads references from the raw JSON (`rawImageReferencesInJSONData:`, since the gate has already dropped bare names; a prefix is tolerated for a hand-edited file), re-validates and re-hashes each shipped image, and **lands every archived image as `custom:<sha1>`, a built-in's included** — a slot name says nothing about which build's Resources the bytes came from. A dangling reference in a JSON-only import drops the field. The byte budget is one image per image field at `kVibeThemeImageByteCap`, so it grows with the field table.

**The codec is self-contained**: stored entries written, stored and raw-deflate read (a hand-made Finder zip), no archive library. Two traps in the reader:

- **TRAP: the fixed 46-byte central-directory header is bounds-checked, the variable-length name after it is NOT** — guard the name and the offset advance before touching either.
- **TRAP: charge the byte budget from the HEADER's sizes before materializing any bytes.** Every header in a small archive can point at the same large stream; copying first lets each copy measure under the remaining budget while together they exhaust memory.

## The dice

**Two dice, neither uniform noise, both `AppTheme` operations** so the host-less suite can roll them by the hundred. `randomizeSettingsWithWaveformStyles:` rolls the appearance choices — backgrounds and tints (never custom, which is a color), corner radius, waveform style/theme/gradient, button gradient and glyphs from the `SettingsRules.h` tables, the playlist columns — and the fonts as one face from `randomizableFontFaces` (test-checked installed), the numeric slots monospace half the time, every size at its factory value; colors, the column switches, the Info card, the Dock choice and the images stay. The styles are passed in because their registry is the renderer's. `randomizeColors` resets every pair, then paints one hue (`HueColor`: a pastel for dark, a deeper shade for light) in one of five schemes, switching on only what shows a painted pair and snapping a leftover custom choice back.
