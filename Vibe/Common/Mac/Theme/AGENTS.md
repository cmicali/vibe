# AppTheme: the theme record

The theme record. The store that holds it (the keys, `currentThemeDidChange`, undo, the image sweep) is `../AGENTS.md`'s. The editor is `Mac/Settings/Appearance/AGENTS.md`'s. Root `AGENTS.md`'s theme guarantee is stated here and in `../AGENTS.md`.

## The guarantee

- **A theme is a sparse record over the factory defaults.** A missing field means the factory look. The built-in Vibe theme is the empty record.
- **Sanitization is one gate, on `AppTheme`** (below). Imports, stored records, UI edits and the built-ins shipped as `Resources/Themes/*.json` all pass through it. `make test` validates the built-ins.
- **Every store mutation refuses a built-in** (`+[AppTheme isBuiltInIdentifier:]`, `../AGENTS.md`). A casual toggle over a built-in lands in the divergence key, `Appearance.currentTheme`, until a theme is applied again.
- **A theme is `single` or `dual` mode** (`mode`). Dual keeps a palette per appearance. Single keeps one color per field in the dark-keyed slot, and pins the window dark (`requiredWindowAppearance`, Colors below).

## The record and its schema

**`FieldSpecs()` in `AppTheme.m` is the one schema.** It has one row per field: key, JSON home, default, sanitizer and archive stem. Every other table derives from it (defaults, known keys, the JSON groups both ways, the color-pair keys). A field therefore cannot exist without a JSON home or a clamp. The record is **flat**, and its keys are the accessor names. A theme **JSON file nests** them under the editor's sections: `version`, `name`, then `window`, `player`, `info`, `volume`, `waveform` and `playlist`. Each key is section-local, so `windowCornerRadius` travels as `window.cornerRadius`. Values are Foundation and JSON types throughout, and colors are `#RRGGBB[AA]`.

**The gate's clamps.** Identifiers snap to their ladders. Numbers clamp: the radius to `[0, kVibeThemeCornerRadiusMax]`, font sizes to narrow layout-safe bands. Colors must round-trip as hex. Bools are numbers only. Unknown fields drop, so a newer build's export imports with those fields at their defaults. `initWithRecord:`, `replaceWithRecord:`, every typed setter, `recordFromJSONData:` and the store's `+sanitizedRecord:` all run it. **Font faces are deliberately not validated against installed fonts.** `Fonts`' never-nil fallback owns that at resolve time, which keeps this class testable without a host (`AppThemeTests`).

`waveformBarDensity` and `waveformBarWidth` travel as `waveform.barDensity` and `waveform.barWidth`, default to 1, and clamp to 0.5–2. Density scales a supported style's count relative to its designed pitch, so window resizing still adds bars; width scales its thickness without changing that count. The renderer registry owns style eligibility; the record keeps the value across style changes.

3-Band takes its colors from the `kVibeThemeColorWaveformLow`/`Mid`/`High` pairs (`waveform.lowColor`, `midColor`, `highColor`) in place of `waveformTheme`, whose unset slots are Rekord Bin's bands, and `waveformShadeOverlaps` (`waveform.shadeOverlaps`, default on), which picks the CDJ's shaded overlaps or Engine DJ's plain ones. A named 3-Band look is a theme: `rekord_bin` leaves the bands unset, `dengine` sets Engine's and turns the shading off. The dice roll the switch; `randomizeColors` clears the bands with every other pair.

`waveformPlayheadLine` (`waveform.playheadLine`, default off) draws the whole waveform as played under a line at the playhead, in the `kVibeThemeColorWaveformPlayhead` pair (`waveform.playheadColor`), whose unset side is the appearance's contrast pole. Off is the default, so every record without the field keeps the dimmed unplayed side. The pair is held while the switch is off. What the line is, and who draws it, is `WaveformUI/AGENTS.md`'s.

## What a theme is not

**A theme is how the window looks, never what it shows.** The readouts are `AppSettings` (`Mac/Settings/Appearance/AGENTS.md`): time labels and remaining time, status icons, file info, BPM, key, key notation and Camelot colors. So are the playlist's number, artwork and duration columns, and the Dock tile. A theme switch must never hide what the user chose to see. Version-1 records carried these fields. A record or import still naming one drops it at the gate as an unknown key (`../AGENTS.md`, Migrations). **One exception is deliberate:** a theme whose volume slider is `always` shown in the top-right corner keeps the codec and BPM lines hidden, because the slider takes their place.

## The built-ins

**A built-in is `Resources/Themes/<identifier>.json`, read through the same `recordFromJSONData:` gate as a user import.** How to author and add one, and what `testBundledThemesAreValid` enforces, is `Resources/Themes-README.md`. Two facts are not authoring steps.
- **`vibe` always exists.** It is the store's snap-back anchor for unknown and deleted active themes, so the loader synthesizes the empty record when `vibe.json` is missing.
- **`cupertino` and `technical` are the dual-mode examples.** A `custom` waveform theme sets both palettes, because an incomplete pair falls back to Mono rather than half-applying.

## Colors

**A pair is keyed by its exported base name** (`kVibeThemeColor*`): `colorForBase:dark:` and `setColor:forBase:dark:` are the slots, and the only way in. Under single mode both force the dark-keyed slot from either side; the light halves lie dormant, never mirrored or consumed, so a mode flip round-trips. `requiredWindowAppearance` is nil for a dual theme.

**The four `resolved*Color` accessors are the one home of override-over-semantic-fallback**, and `DefaultColorForBase` the only spelling of what an unset slot draws as (the label pairs' semantic fallback under that side, the solid cover, the neutral tint wash and row fill, Mono's resting levels): the window and playlist covers, the row fills, the editor's wells and the seed a popup writes when it reveals a pair all read it. `displayColorForBase:dark:` pins any pair to one side for the wells.

**The playlist's four text columns are pairs behind switches** (`kVibeThemeColorPlaylistNumber`/`Title`/`Artist`/`Duration`, `playlistColorEnabledForBase:`, JSON `playlist.numberColorEnabled` beside the pair). `resolvedPlaylistColorForBase:` is a column's one answer: the label pair it always drew while off — title over the title pair, the other three over the artist pair — and its own pair while on, an unset side inheriting that same label pair; `displayColorForBase:dark:` shows the inheritance, so the wells never disagree with the table. A pair set while its switch is off is held, not drawn, so toggling round-trips a pick. **A resolved color is captured at call time**: an appearance flip re-resolves by itself, but a theme change must rebuild whatever holds one — the `TrackDisplay`/`PlaylistAppearance` effects' invalidations.

## The corner radius

**Two fields, one accessor.** `windowCornerRadius` is what the slider holds; `customCornerRadius` (default off) says whether the window draws it; `resolvedWindowCornerRadius`, the only accessor consumers read, answers the slider under custom and `kVibeThemeCornerRadiusDefault` (16pt — the window is borderless and draws its own shape, so macOS 26's radius is a constant of ours) otherwise.

**A record naming a radius with no word on the switch reads as custom.** Records written before the switch existed keep the shape they chose. `replaceWithRecord:` decides it, as the one place a record is read, so the setters stay plain. The sparse rule has one exception for the same reason. The switch's *off* beside a stored radius is kept (`storeSanitized:`, which is why its spec row follows the radius's). Dropped as the default, it would read back as custom.

**A record's Wiggle MC (`wiggle`) reads as Wiggle with `waveformCentered` off**, in `replaceWithRecord:` too. That holds whatever version the record claims, since version-2 records can carry it too, past `recordUpgradedFromVersion1:`.

## The transport buttons

`showTransportButtons` (`player`) defaults on. It only governs presentation. Dependent glyphs, images and colors stay stored while hidden.

**Three fields apiece.** A glyph (`playlistButtonGlyph`, `playButtonGlyph` with `pauseButtonGlyph` beside it, `nextButtonGlyph`) is free text in the SF Symbol name shape, like a font face: the record knows no symbol catalog, the draw site (`MainPlayerContentView`) falls back to the factory glyph for a name this macOS lacks, and the editor's curated menus are `SettingsRules.h`'s. A color pair (`kVibeThemeColorPlaylistButton`/`PlayButton`/`NextButton`, white and black at 0.55 unset) is **keyed Dark/Light by the art under the buttons, not the appearance** (`Mac/MainWindow/APPEARANCE.md`) — **the one exception to single mode**: `colorKeyForBase:dark:` never collapses an art-keyed pair. Hover and disabled derive by `SymbolButton`'s factory ratios. An image pair, keyed the same way, wins over glyph and color when either side names one. `buttonGradient` is the darkening behind them: `none`, `hover`, `artwork` (track covers only), or `always` (default). Glassy uses `artwork` so its transparent default image stays clear. Its sanitizer maps legacy booleans to `none`/`always`, preserving stored and imported themes; `appIcon` replaces the application icon everywhere.

## The volume slider

`volumeBar` (`mono`/`artwork`/`waveform`/`custom`, default `waveform`, with the `kVibeThemeColorVolumeBar` pair), `volumeKnob` (the same ladder plus `bar`, the default, whatever color the bar draws, the system accent under None; with the `kVibeThemeColorVolumeKnob` pair), `showVolumeLabels` (default on) and `volumeLocation` (`top_right`, the default, or `bottom`) travel as `volume.bar`, `volume.barColor`, `volume.knob`, `volume.knobColor`, `volume.showLabels` and `volume.location`. `volumeVisibility` travels as `volume.visibility`. Its values are `always`, `hover_close` (the default) and `hover_exact`. The pairs' unset slots draw the system accent and the white knob, so Custom starts from None's look. The dice roll both colors but never the labels, the location or the visibility, which are layout, not look.

## Images

**Eleven fields name an image and are one kind** (`kVibeThemeImage*`, `imageFieldKeys`): the placeholder pair `defaultArtworkDark`/`Light`, `appIcon`, and the four buttons' art-keyed Dark/Light pairs. A value is an **image reference**: `""` for the slot's factory image, `bundled:<name>.<ext>` beside the built-in JSON, or `custom:<sha1>.<ext>` in `Application Support/<bundle id>/ThemeArt`. Do not rename that directory, since every install's images are there. `VIBE_THEME_ART_DIR` redirects it under test. Content hashing is what makes `imageForReference:`'s lifetime cache safe — a changed image is a new key — and its custom-entry bound is the field count, so a theme's live set stays pinned while auditioned predecessors do not. The placeholder is the one *paired* image field and follows single mode like a color pair.

**TRAP: a gone or undecodable image falls back, but the fallback is never cached under the missing image's key** — names are content hashes, so re-storing that image reuses the key and the theme would draw the factory record until relaunch.

**The factory fallback differs by slot.** `imageForReference:` answers the record image for anything missing — the placeholder's fallback; the app icon and the buttons ask `customImageForKey:`, nil for `""` and for a gone file, so they fall back to the bundle icon and the glyph, never the record. `referenceIsMissing:` is the only way to tell "deliberately the default" from "the chosen image is gone" — the editor's (!) badge.

**`resolvedDefaultArtworkImage` is the placeholder pair as ONE image**: when the sides differ, a cached dynamic wrapper draws whichever side the drawing appearance asks for, so consumers carry no dark flag. **A consumer that reads its PIXELS must sample under the window's appearance and again on every flip** (`ArtworkDisplayController.refreshTintWashes`), since the same pointer samples dark under one and light under the other.

## The archive form (`AppTheme+Archive`)

**A theme naming any image exports as a ZIP of `theme.json` plus its images, the dormant half included; one naming none stays plain JSON.** A built-in's `bundled:` image travels even though this build ships it — the build that opens the archive may not be this one. `AppThemeInternal.h` is the seam between the codec and the record; what stays in `AppTheme.m` is the record and nothing else.

**Entries are named by slot** (`artwork_default_front`/`_back`, `app_icon`, `button_<name>_dark`/`_light`, each field's stem in its `FieldSpecs()` row), `theme.json` referencing them bare: a content hash or a resource filename reads as nothing to a person opening the ZIP. Two fields naming one image share its entry. The prefix never travels, and `JSONDataForRecord:name:entryNames:` applies the rename *after* sanitization because the gate admits only the prefixed shapes and would drop a bare name.

**Import trusts nothing.** `recordFromJSONOrArchiveData:` takes either form, reads references from the raw JSON (`rawImageReferencesInJSONData:`, since the gate has already dropped bare names; a prefix is tolerated for a hand-edited file), re-validates and re-hashes each shipped image, and **lands every archived image as `custom:<sha1>`, a built-in's included** — a slot name says nothing about which build's Resources the bytes came from. A dangling reference in a JSON-only import drops the field. The byte budget is one image per image field at `kVibeThemeImageByteCap`, so it grows with the field table.

**The codec is self-contained**: stored entries written, stored and raw-deflate read (a hand-made Finder zip), no archive library. Two traps in the reader:

- **TRAP: the 46-byte central-directory check does not cover the variable-length name, extra and comment after it** — guard them before reading the name or advancing the offset.
- **TRAP: test the byte budget against the HEADER's sizes before materializing any bytes.** Every header can point at the same large stream, so copies that each fit the remaining budget would together exhaust memory.

## The dice

**Two dice, neither uniform noise, both `AppTheme` operations** so the host-less suite can roll them by the hundred. `randomizeSettingsWithWaveformStyles:` rolls the appearance choices — backgrounds and tints (never custom, which is a color), corner radius, waveform style/theme/gradient, button gradient and glyphs from the `SettingsRules.h` tables — and the fonts as one face from `randomizableFontFaces` (test-checked installed), the numeric slots monospace half the time, every size at its factory value; colors, the playhead line and the images stay. The styles are passed in because their registry is the renderer's. `randomizeColors` resets every pair, then paints one hue (`HueColor`: a pastel for dark, a deeper shade for light) in one of five schemes, switching on only what shows a painted pair and snapping a leftover custom choice back.

## Fonts

**`Fonts`**: the app's typography. The five themed slots (`VibeFontSlot`, declared with the theme) resolve against the theme that `MainPlayerController.applyStoredFonts` **pushes** through `applyThemeFonts:`. Fonts reads no setting. Until the first push they resolve the factory look. An empty or uninstalled face falls back to the slot's built-in font, so a slot accessor never returns nil.
