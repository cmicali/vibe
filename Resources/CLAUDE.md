# Resources

**Making or editing a built-in theme: read `Themes-README.md`, beside this
file, first.** It is the authoring guide for everything in `Themes/` — the
file format, the identifier/display-name split, `bundled:` artwork, and the
`vibe.json` must-stay-empty rule. The short version:

- A theme is one `Themes/<identifier>.json` (plus its `bundled:` PNGs if it
  carries artwork). No code changes, no project edits, no xcodegen run.
- The shipped themes in `Themes/` are working examples; the full field set is
  `ThemeJSONGroups()` in `Vibe/Common/Mac/AppTheme.m`.
- `make test` is the gate (`testBundledThemesAreValid`): the app's import
  path silently DROPS a typo'd key or malformed color, and the test's
  sanitizer round-trip is what makes that loud. Update the expected
  identifier list in `Tests/AppThemeTests.m` (`testBuiltInIdentifiers`) —
  order is `vibe` first, the rest alphabetical.
- See it in the running app through the `vibe-debug` skill:
  `--debug-cmd set_theme <identifier>`, then screenshot both appearances.
- A translated display name is optional (`ThemeNames.xcstrings`, below); a
  theme with no entry ships its JSON English name everywhere.

**TRAP: `Themes/` is a folder REFERENCE (`type: folder` in `project.yml`) and
is copied VERBATIM into the app bundle and the test bundle — folder
references take no excludes.** Nothing that is not meant to ship to users may
be added there: no `CLAUDE.md`, no scratch files, no README. That is why this
file sits one level up (it still loads for work under `Themes/`), and why the
authoring guide is `Themes-README.md` out here rather than inside.

The string catalogs live here too: `Localizable.xcstrings` is extracted —
never hand-edit it; run `make strings` after touching `VibeStrings.h` — while
`InfoPlist.xcstrings` and `ThemeNames.xcstrings` are hand-managed. The
`vibe-strings` skill is the reference for all three. The rest —
`Assets.xcassets`, `AppIcon.icon`, `PrivacyInfo.xcprivacy`,
`VectorBalls.metal.txt` — are app assets owned by their features.
