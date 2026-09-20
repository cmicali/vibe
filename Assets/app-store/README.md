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
Vibe-sample-track.mp4    the attachment that goes with review-notes.txt, so a
                         reviewer never has to find audio of their own. MP4 is
                         the only media type App Store Connect accepts there.
                         Generated from Assets/test_audio_files/bpm-120.wav
                         (gitignored, so the product is tracked and not the
                         source), tagged, and confirmed to open and play
review-notes.txt         App Review Information -> Notes, and the same text
                         for TestFlight's Beta App Review Information. English
                         only, not a version field, and nothing uploads it -
                         paste it into App Store Connect. Tracked because it
                         is needed twice per release and rewriting it from
                         memory is how a reviewer ends up at an empty app
copy/<lang>/<platform>/   platform is macos or ios
  promotional-text.txt   one line, ≤170 chars (ASC limit)
  description.txt        literal plain text as uploaded — no markdown
  keywords.txt           one line, comma-separated, ≤100 chars
  whats-new.txt          the version's release notes, ≤4000 chars — rewrite
                         for EVERY release (ASC blocks submission when a
                         locale lacks it); "* " bullets upload verbatim
  screenshots.json       captions per shot, in App Store display order
screenshots/<lang>/macos/        composited 2880x1800 shots
screenshots/<lang>/ios/iphone/   composited 1290x2796 shots
screenshots/<lang>/ios/ipad/     composited 2048x2732 shots
                                 (all three: make appstore-generate-store-screenshots)
```

`screenshots.json` is an ordered array of `{id, headline, subhead}`, and the
shot ids are per platform — `player`, `playlist`, `themes`, `pitch` on macOS;
`player`, `seek`, `playlist`, `widget` on iOS. They are defined in
`scripts/appstore-generate-store-screenshots.sh`, which maps each to a capture
and an output file; the captions here are the only per-language part.

**iOS captions carry no subhead**, and `appstore-validate-copy` rejects one
written into an iOS `screenshots.json`. At the size the store draws a phone
screenshot a second, smaller line is unreadable and only takes room from the
one line that is, so the headline runs at 1.9x nominal and says the whole
thing. iPhone and iPad share the caption but are **separate ASC screenshot
sets** (`APP_IPHONE_67`, `APP_IPAD_PRO_3GEN_129`), which is why iOS has a
directory per device and macOS does not. iPad is required, not optional —
`TARGETED_DEVICE_FAMILY` is `1,2`.

The iOS copy deliberately does NOT reuse the macOS text: BPM and key analysis,
the pitch fader, the FX rack, folder art and conversion are all macOS-only.
A page describing features the app does not have is a review rejection.

- `make appstore-validate-copy` validates every catalog language has all five files
  within ASC limits and captions that fit the screenshot layout.
- `make appstore-generate-store-screenshots [LOCALE=de]` / `make appstore-generate-store-screenshots-all`
  regenerates `screenshots/`.
- `make appstore-upload-metadata` uploads copy and screenshots to App Store Connect
  (`scripts/appstore-upload-metadata.sh`, the Swift tool in
  `scripts/asc-upload/`).
