# App Store assets

Everything the Mac App Store product page shows, per locale. `copy/` is the
tracked source of truth; `screenshots/` is generated from it (only the English
set is tracked). Locales are App Store Connect's set, mapped from the catalog
languages — the app's catalogs (`Resources/Localizable.xcstrings`) stay the
single source of which languages exist.

```
copy/<lang>/
  promotional-text.txt   one line, ≤170 chars (ASC limit)
  description.txt        literal plain text as uploaded — no markdown
  keywords.txt           one line, comma-separated, ≤100 chars
  screenshots.json       captions per shot, in App Store display order
screenshots/<lang>/      composited 2880x1800 shots (make appstore-generate-store-screenshots)
```

`screenshots.json` is an ordered array of `{id, headline, subhead}`. The shot
ids (`player`, `playlist`, `pitch`, `keys`) are defined in
`scripts/appstore-generate-store-screenshots.sh`, which maps each to a window capture
and an output file; the captions here are the only per-language part.

- `make appstore-validate-copy` validates every catalog language has all four files
  within ASC limits and captions that fit the screenshot layout.
- `make appstore-generate-store-screenshots [LOCALE=de]` / `make appstore-generate-store-screenshots-all`
  regenerates `screenshots/`.
- `make appstore-upload-metadata` uploads copy and screenshots to App Store Connect
  (`scripts/appstore-upload-metadata.sh`, the Swift tool in
  `scripts/asc-upload/`).
