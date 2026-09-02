# Built-in themes

Every `<identifier>.json` in `Resources/Themes/` ships in the app as a read-only
built-in theme. **The filename stem is the theme's stable identifier**
(lowercase snake_case, e.g. `sonic_cirrus.json`); the `name` key is
its English display name. Adding a theme is adding one file here — no project
edits, and the only code it touches is the expected identifier list in
`testBuiltInIdentifiers` (`Tests/AppThemeTests.m`), which is what keeps a
dropped or renamed theme file loud.

## Making one

1. Design the theme in the app: Settings > Appearance > Add > New Theme, then
   edit it.
2. Export it: the Export… button (or, from a debug build,
   `Vibe --debug-cmd dump_theme <your-theme-name>`).
3. Rename the file to its identifier (`my_theme.json`) and drop it in this
   directory. Set `name` to the display name you want.
4. Add the identifier to `testBuiltInIdentifiers` (`Tests/AppThemeTests.m`) —
   `vibe` first, the rest alphabetical.
5. Open a pull request. CI's `make test` validates every file here.

## File format

`version` (always 1), `name`, an optional `description` (design rationale —
ignored by the app), and then one object per Settings editor section —
`window`, `player`, `info`, `waveform`, `playlist`, in that order — holding
only the fields the theme changes from the factory look: a missing field (or
a whole missing section) means "the default". Keys are section-local
(`window.cornerRadius`, `waveform.style`, `playlist.showArtworkColumn`); the
full set is `ThemeJSONGroups()` in `Vibe/Common/Mac/AppTheme.m`. Colors are
`#RRGGBB[AA]` with a `…Light`/`…Dark` suffix per appearance. A theme with
`"window": {"mode": "single"}` uses only the `…Dark`-keyed slots.

The validation test (`Tests/AppThemeTests.m`, `testBundledThemesAreValid`)
fails a file whose keys or values would not survive the app's sanitizer
unchanged — a typo'd field key or malformed color is silently dropped at load
time, so the test is what makes it loud.

Display names ship in English from the JSON. A translated name is optional:
add a key (the identifier) to `Resources/ThemeNames.xcstrings` with every
catalog language — `make check-translations` enforces completeness.

`vibe.json` is special: it must stay field-free. The empty record IS the
factory look, and a test pins it.

## Default artwork

`player.defaultArtworkDark`/`defaultArtworkLight` pick the placeholder drawn
when a track has no artwork, one per appearance like every color pair:
`bundled:<name>.<ext>` for a square JPEG or PNG beside the built-in JSON,
`custom:<sha1>.<ext>` for an image the user picked in the app, or `""` for the
factory record image. A theme carrying a custom image exports as a **ZIP** of
`theme.json` plus the image(s), and imports the same way (each image is
re-validated and re-hashed on import). In a hand-made ZIP an image reference
may simply be the basename of an entry in the archive — `cover_dark.png`,
with the `custom:` prefix optional — and is normalized to the stored
`custom:<sha1>.<ext>` form on import. Built-in themes may only use bundled
references; the validation test enforces that each file resolves, is square,
and stays within the pixel and byte caps.
