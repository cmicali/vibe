# Built-in themes

Every `<identifier>.json` in `Resources/Themes/` ships in the mac app as a read-only built-in theme. **The filename stem is the theme's stable identifier**, in lowercase snake_case (`sonic_cirrus.json`). The `name` key is its English display name. How themes work in the app is `docs/themes.md`. The record and its gate are `Vibe/Common/Mac/Theme/AGENTS.md`.

## Making one

1. Design the theme in the app: Settings > Themes > Add > New Theme, then edit it.
2. Export it with the Export… button. A debug build can also print it: `Vibe --debug-cmd dump_theme <your-theme-name>`.
3. For a JSON export, rename the file to its identifier (`my_theme.json`) and put it in `Resources/Themes/`. For a ZIP export, extract `theme.json` and its images first. Rename the JSON, put those files together in `Resources/Themes/`, and change each image reference to `bundled:<filename>`. Set `name` to the display name you want.
4. Add the identifier to `testBuiltInIdentifiers` in `Tests/Common/AppThemeTests.m`. The order is `vibe` first, then alphabetical. The list keeps a dropped or renamed file loud.
5. Open a pull request. CI's `make test` validates every file here.

## File format

`version` is `kVibeThemeRecordVersion` (currently 2). Then come `name`, an optional `description` that the app ignores, and one object per group. The groups are `window`, `player`, `info`, `volume`, `waveform` and `playlist`, in that order. Each holds only the fields the theme changes from the factory look. A missing field or a missing group means the default.

Keys are local to their group (`window.cornerRadius`, `waveform.style`, `playlist.durationFontFace`). The full set is `VibeThemeFieldSpecs()` in `Vibe/Common/Mac/Theme/AppTheme.m`. Colors are `#RRGGBB[AA]`, with a `…Dark`/`…Light` suffix per appearance. A theme with `"window": {"mode": "single"}` uses the dark slots for appearance-based pairs. Transport button pairs follow the artwork brightness and keep both slots.

**`testBundledThemesAreValid` is the gate.** The app's import silently drops a typo'd key or a malformed color. The test fails any file whose keys or values would not survive the sanitizer unchanged. A built-in that sets a corner radius must also set `window.customCornerRadius` to `true`, or the round trip fails.

`vibe.json` must stay field-free. The empty record is the factory look, and a test pins it.

A translated display name is optional. Add the identifier as a key in `Resources/ThemeNames.xcstrings`, with every catalog language. `make check-translations` enforces that. A theme with no entry shows its JSON `name` in every language.

## Default artwork

`player.defaultArtworkDark` and `defaultArtworkLight` pick the placeholder drawn when a track has no artwork. A built-in may only use `bundled:<name>.<ext>`, a square JPEG or PNG beside the JSON, or `""` for the factory image. The test checks that each file resolves, is square, and stays within the pixel and byte caps.

**Author it at 640px, and use JPEG unless it needs alpha.** `imageForReference:` decodes every theme image bounded to `kVibeArchivedDisplayArtDimension`, which is 640 on macOS. Pixels beyond that only cost bundle size. Use PNG where transparency matters: `glassy.png` is transparent by design, and its whole look depends on it.
