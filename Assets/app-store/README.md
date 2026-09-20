# App Store assets

Everything the App Store product pages show, per locale and per platform.
`copy/` is the tracked source of truth; `screenshots/` is generated from it
(only the English set is tracked). Locales are App Store Connect's set, mapped
from the catalog languages — the app's catalogs
(`Resources/Localizable.xcstrings`) stay the single source of which languages
exist.

**Why the platform directory.** ASC localizations hang off a *version*, and
versions are per platform, so every file under `copy/<lang>/<platform>/` is a
version field and each platform needs its own. The three URL files are not
version fields and stay shared at `copy/`. macOS and iOS are separate version
trains on one app record (Universal Purchase — both apps ship bundle id
`com.commonwealthrecordings.Vibe`).

```
copy/support-url.txt     one URL, shared by every locale (ASC requires it per
                         localization; missing blocks submission)
copy/marketing-url.txt   one URL, shared by every locale (optional in ASC,
                         kept uniform the same way)
copy/privacy-url.txt     one URL, shared by every locale. Unlike the two
                         above it is NOT a version field: it lives on ASC's
                         appInfoLocalizations, beside the app name and
                         subtitle, and the uploader patches it per locale
                         so it is not 29 identical edits by hand
copy/<lang>/<platform>/   platform is macos or ios
  promotional-text.txt   one line, ≤170 chars (ASC limit)
  description.txt        literal plain text as uploaded — no markdown
  keywords.txt           one line, comma-separated, ≤100 chars
  whats-new.txt          the version's release notes, ≤4000 chars — rewrite
                         for EVERY release (ASC blocks submission when a
                         locale lacks it); "* " bullets upload verbatim
  screenshots.json       captions per shot, in App Store display order
screenshots/<lang>/macos/  composited 2880x1800 shots (make appstore-generate-store-screenshots)
```

`screenshots.json` is an ordered array of `{id, headline, subhead}`. The shot
ids (`player`, `playlist`, `pitch`, `keys`) are defined in
`scripts/appstore-generate-store-screenshots.sh`, which maps each to a window capture
and an output file; the captions here are the only per-language part.

**iOS is partly wired.** `copy/en/ios/` holds the four text fields and uploads
with `make appstore-upload-metadata ARGS="--platform ios --skip-screenshots"`.
The other languages, the iOS screenshot pipeline and its `screenshots.json`
shot ids are still to do — `docs/ios-release-punchlist.md`, sections C and D.
The iOS copy deliberately does NOT reuse the macOS text: BPM and key analysis,
the pitch fader, the FX rack, folder art and conversion are all macOS-only.

- `make appstore-validate-copy` validates every catalog language has all five files
  within ASC limits and captions that fit the screenshot layout.
- `make appstore-generate-store-screenshots [LOCALE=de]` / `make appstore-generate-store-screenshots-all`
  regenerates `screenshots/`.
- `make appstore-upload-metadata` uploads copy and screenshots to App Store Connect
  (`scripts/appstore-upload-metadata.sh`, the Swift tool in
  `scripts/asc-upload/`).
