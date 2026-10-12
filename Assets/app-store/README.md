# App Store assets

Everything the App Store product pages show, per locale and per platform. `copy/` is the tracked source of truth. `screenshots/` is generated from it, and only the English set is tracked. The locales are the app's catalog languages (`Resources/Localizable.xcstrings`, listed by `scripts/strings/catalog-languages.sh`), mapped to App Store Connect's codes by `ascLocale` in `scripts/appstore/asc-upload/Sources/asc-upload/ASCUpload.swift`. A language with no App Store page maps to nil and is skipped (`bg` ships in-app only).

Descriptions, keywords, promotional text and release notes belong to a platform's version. Screenshot captions are local inputs to the compositor. The three URL files stay shared at `copy/`. Support and marketing URLs upload to each version localization. The privacy URL uploads to app-info localizations.

```
copy/support-url.txt     one URL for every locale. ASC requires it per localization.
copy/marketing-url.txt   one URL for every locale. Optional in ASC.
copy/privacy-url.txt     one URL for every locale. Not a version field: it lives on
                         ASC's appInfoLocalizations, and the uploader patches it per locale.
review-notes.txt         App Review Information -> Notes, and TestFlight's Beta App
                         Review Information. English only. Nothing uploads it.
Vibe-sample-track.mp4    the review attachment that goes with review-notes.txt. MP4 is
                         the only media type ASC accepts there. Generated from the
                         gitignored Assets/test_audio_files/bpm-120.wav and tagged.
copy/<lang>/<platform>/   platform is macos or ios
  promotional-text.txt   one line, ≤170 chars
  description.txt        plain text, uploaded as is. No markdown.
  keywords.txt           one line, comma-separated, ≤100 chars
  whats-new.txt          the version's release notes, ≤4000 chars. Rewrite for EVERY
                         release. The uploader omits it for a platform's first version.
                         "* " bullets upload as written.
  screenshots.json       captions per shot, in App Store display order
screenshots/<lang>/macos/        composited 2880x1800 shots
screenshots/<lang>/ios/iphone/   composited 1290x2796 shots
screenshots/<lang>/ios/ipad/     composited 2048x2732 shots
```

`screenshots.json` is an ordered array of `{id, headline, subhead}`. The shot ids are per platform: `player`, `playlist`, `themes` and `pitch` on macOS, and `player`, `seek`, `playlist` and `widget` on iOS. `scripts/appstore/appstore-generate-store-screenshots.sh` defines them and maps each to a capture and an output file. The captions are the only per-language part.

**iOS captions carry no subhead**, and `appstore-validate-copy` rejects one. At the size the store draws a phone screenshot, a second line is unreadable. So the headline runs at 1.9x nominal and says the whole thing. iPhone and iPad share the captions but are **separate ASC screenshot sets** (`APP_IPHONE_67`, `APP_IPAD_PRO_3GEN_129`), so iOS has a directory per device. The iPad set is required, because `TARGETED_DEVICE_FAMILY` is `1,2`.

Keep the copy specific to each platform. Key analysis, the pitch fader, folder art, conversion and bit-perfect output are macOS-only. BPM analysis and DJ FX run on both platforms.

**Translating a caption is constrained, and the check catches only half of it.** At 1.9x with a two-line cap, a caption that will not fit shrinks toward 72% of nominal and then **fails the build** rather than rendering small. Some languages need a looser translation than the English. The iPhone canvas is the one that binds. `appstore-validate-copy` measures whether text *fits*, not whether it *breaks well*. The compositor wraps ja and zh at any character, since kinsoku is not implemented, so a caption can split a word across lines and still validate. **Look at the rendered CJK screenshots**, and shorten a caption until it sits on one line.

## Commands

```bash
make appstore-validate-copy                         # every catalog language has all five files, within limits, captions fit
make screenshots                                    # only if the UI changed: re-capture the macOS windows into Assets/readme/
make appstore-generate-store-screenshots-all        # composite every language's macOS screenshots
make appstore-generate-store-screenshots LOCALE=de  # one language while iterating
scripts/appstore/appstore-generate-store-screenshots.sh --all --platform ios   # the iOS sets (no make target)
make appstore-upload-metadata                       # upload copy and screenshots (the vibe-release skill)
```

`make screenshots` needs a debug build, Screen Recording and Accessibility permission, and `ALLOW_GLOBAL_INPUT=1`. It captures the macOS windows only. The iOS composites read the `Assets/readme/screenshot-ios-<device>-<shot>.png` captures, which are made by hand (below). Every language shares the same English window captures. A missing translation fails rather than shipping English captions.

**Adding a language.** Localize the app first (`docs/localization.md`). Then add `copy/<lang>/` for both platforms, and extend `ascLocale` if the uploader asks for a mapping. `make appstore-validate-copy` fails until the copy is complete.

## Creative assets (iOS 27)

`scripts/appstore/appstore-generate-store-screenshots.sh --creative` builds three images at the sizes Apple's templates use. `creative/header.png` (3840x1646) is the product-page header. `creative/search-results.png` (3840x2560) is the search-results card. `creative/github-social-preview.jpg` is the repository's social preview. The two App Store images are **text-free on purpose**: one image serves every locale, and nothing needs translating.

- **The header** is the icon's waveform motif, its played bars white and the rest grey, across the full width over the icon's groove. The art safe area in Apple's header template is only the central 1646x661. The peak sits inside it, and everything outside it is decoration that a phone may crop.
- **The search result** is the iPhone playlist, player and seek captures side by side, from the same captures as the iOS screenshots. Re-capturing those means rebuilding this too. The widget capture is left out because it shows Apple's own app icons.

Nothing uploads them. They go into App Store Connect's Asset Library by hand.

## iOS screenshot music

The iOS captures use fictional artist and title tags and the four sleeve designs in `demo-music/artwork/`. `demo-music/catalog.json` maps those names to the local source recordings, and `demo-music/artwork-prompts.json` records the cover briefs. The audio is copied unchanged from the original FLAC files. Only the tags and embedded artwork are replaced.

`demo-music/tracks/` is local and gitignored, so the recordings are not distributed. The player and widget use **Soft Relay** (the audio from **Memorandum**). The seek shot uses **Negative Space** (the audio from **Trouble Symphony**). The macOS captures use other music.

Seed the copied FLACs with `launch-ios.sh` and open the seeded Music directory through `debug-ios.sh`. Capture at 1290×2796 (iPhone 15 Pro Max) and 2048×2732 (iPad Pro 12.9-inch), with the status bar set to 9:41. Use the signed simulator build for the widget, add it through the widget gallery, and check `dump_state.widget.placed` before capturing. `drive-ios.sh springboard …` drives that gallery without returning to the player between touches. After replacing the eight source captures, rebuild every iOS locale with `scripts/appstore/appstore-generate-store-screenshots.sh --all --platform ios`.
