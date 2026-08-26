# Built-in themes

Every `<identifier>.json` in this directory ships in the app as a read-only
built-in theme. **The filename stem is the theme's stable identifier**
(lowercase snake_case, e.g. `adolescent_engineering.json`); the `name` key is
its English display name. Adding a theme is adding one file here — no code
changes, no project edits.

## Making one

1. Design the theme in the app: Settings > Appearance > Add > New Theme, then
   edit it.
2. Export it: the Export… button (or, from a debug build,
   `Vibe --debug-cmd dump_theme <your-theme-name>`).
3. Rename the file to its identifier (`my_theme.json`) and drop it in this
   directory. Set `name` to the display name you want.
4. Open a pull request. CI's `make test` validates every file here.

## File format

`version` (always 1), `name`, an optional `description` (design rationale —
ignored by the app), and then only the fields the theme changes from the
factory look: a missing field means "the default". The field keys are the
`AppTheme` accessor names (`Vibe/Common/Mac/AppTheme.h`); colors are
`#RRGGBB[AA]` with a `…Light`/`…Dark` suffix per appearance. A theme with
`"mode": "single"` uses only the `…Dark`-keyed color slots.

The validation test (`Tests/AppThemeTests.m`, `testBundledThemesAreValid`)
fails a file whose keys or values would not survive the app's sanitizer
unchanged — a typo'd field key or malformed color is silently dropped at load
time, so the test is what makes it loud.

Display names ship in English from the JSON. A translated name is optional:
add a key (the identifier) to `Resources/ThemeNames.xcstrings` with every
catalog language — `make check-translations` enforces completeness.

`vibe.json` is special: it must stay field-free. The empty record IS the
factory look, and a test pins it.
