# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Building

The `Brewfile` declares the dev tools, XcodeGen and jq. Install them with `make setup`, which runs `brew bundle`.

XcodeGen generates `Vibe.xcodeproj` from `project.yml`. The project file is **not** checked in, so regenerate it after cloning, after pulling and after every edit to `project.yml`:

```bash
xcodegen generate          # or: make project
```

Then build in Xcode — open `Vibe.xcodeproj`, pick the `Vibe` scheme, press ⌘R — or run `make build`. The debug command channel needs a **Debug** build; see Debugging and verification.

Two wrappers regenerate the project first and write to `build/DerivedData`: `make build` (Release, or `make build CONFIG=Debug`) and `scripts/build.sh [Debug|Release]`.

Use the **`vibe-release` skill** (`.claude/skills/vibe-release/`) to sign, notarize or ship a build. It covers the Developer ID path (`make release`), the App Store path (`make appstore-build` and `make appstore-upload-signed-build`), the shared App Store Connect API key and the signing traps each script preflights. The two paths are not interchangeable, so do not improvise from the scripts.

There is no package manager. All third-party code is vendored under `Vibe/ThirdParty/` and compiles into the app target; CocoaPods is gone and TagLib and PINCache are now in-tree.

`make test` runs the unit tests, in `Tests/` at the repo root. They cover pure logic only — sample and geometry math, archive validation, formatting, precedence and fallback rules — and the bundle is host-less, so the suite needs no window server, no audio hardware and no running app. See `Tests/CLAUDE.md` before adding to it: sources under test are compiled into the test target rather than linked from the app, and a test file placed under `Vibe/` would be swept into the shipping binary.

Anything that has to be verified against the *running* app belongs in the debug command channel below, not in a unit test.

GitHub Actions runs the Debug and Release builds and the test suite on every push and pull request (`.github/workflows/build.yml`).

## Debugging and verification

Use the **`vibe-debug` skill** (`.claude/skills/vibe-debug/`) to launch, drive, inspect or screenshot the app — anything that verifies a change against the running app. It is the canonical reference for the debug command channel (`Vibe --debug-cmd <command>`, debug builds only, implemented in `Vibe/Debug/`): inspection dumps of player and UI state, the view tree, menus, Now Playing and screenshots; transport, FX and UI driving; opening files; per-file waveform-cache control; and the BPM and key scans (`scan_bpm`/`scan-bpm.sh` and `scan_key`/`scan-key.sh`, which run in the CLI process itself and need no running app). It also covers the two screenshot paths and their blind spots, sandbox launch pitfalls, the bundled capture and pixel-probing scripts, log streaming and the launch-time build-provenance block.

For test audio, use the generated files in `Assets/test_audio_files/` (gitignored). If they are missing, generate them with the skill's `generate-test-audio.sh` rather than synthesizing your own.

The command list lives in the skill and in the channel's own unknown-command reply, deliberately not here, so it cannot drift.

## Architecture

Vibe is a native macOS music player written in Objective-C and Objective-C++. Playback rests entirely on Apple frameworks — AVFAudio's `AVAudioEngine` and CoreAudio — with no third-party audio library, because CoreAudio decodes MP3 and FLAC natively. The app has no external dependencies; the vendored libraries in `Vibe/ThirdParty/` compile into the app target.

### Subsystem map

Nested `CLAUDE.md` files hold the detail for each directory and load only when you work under it. **Read the relevant one before changing anything it covers.**

- **`Vibe/Audio/`** — the playback engine and the audio data pipeline. `AudioPlayer` runs `AVAudioEngine` with a fresh player node and `AVAudioUnitVarispeed` per track, and handles click-free crossfades, seeks and fades, next-track prefetch and a deferred idle engine stop. `AudioFX` puts the DJ performance effects on the master bus. `Metadata/` extracts tags with TagLib and caches them in PINCache behind a two-stage playlist scan. `Waveform/` is the waveform *data* layer, `Analysis/` detects BPM and musical key, and `AudioDeviceManager` and `AudioPlayer+Devices` manage output devices. UI code relies on the threading contract: every engine mutation runs on a serial player queue, the UI-facing getters (`position`, `duration`, `isPlaying`) never block, and delegate callbacks arrive on the main thread.
- **`Vibe/Waveform/`** — the waveform *rendering* layer: `AudioWaveformView`, a pure rendering surface whose controller owns the cache and forwards the data; the renderer strategy hierarchy; and the shared `WaveformMorphEngine`.
- **`Vibe/Main Window/`** — `MainPlayerController` is the central coordinator. It implements the player, waveform and metadata-cache delegate protocols, resolves all header rendering through a single five-state `TrackDisplayState`, and owns `TransportKeyMonitor` for the bare transport and FX keys. The directory also holds `MainWindow` (drag-and-drop and resize behavior), the programmatic layout and the Liquid Glass chrome — the layout, chrome and rendering detail is split into that directory's `APPEARANCE.md`, its `CLAUDE.md` covering behavior.
- **`Vibe/Menu/`** — app bootstrap (`main.m` and `AppDelegate`), menu bar construction, View > Size, the FX menu and the output devices menu.
- **`Vibe/Playlist/`** — the split between table structure and content (`PlaylistTableView` and `PlaylistController`), plus Launch Services burst opens.
- **`Vibe/Controls/`** — controls drawn in CALayer rather than shipped as images: `SymbolButton`, `EqualizerIndicatorView` and the pitch fader.
- **`Vibe/ThirdParty/`** — the vendored TagLib subset and PINCache/PINOperation: what is included and why, how to update it and how the header search paths are wired.
- **`Vibe/About/`** — the About window and its Metal animation.
- **`Vibe/Settings/`** — the Settings window (Vibe > Settings…, ⌘,): a toolbar-style `NSTabViewController` in the standard macOS settings-window shape, owned lazily by `AppDelegate`. Five panes — General (output device, default-player claim via `DefaultAppClaim`), Playback (pitch range, skip steps, crossfade, BPM and key analysis), Appearance (including key notation and CDJ key colors), Convert, and Advanced (cache size and clear, `AppStats` readouts) — one `SettingsPaneViewController` subclass each.

### Cross-directory invariants

Each side is documented in its own directory's file. The coupling itself lives here.

- **Tag-over-analysis precedence**: a file's tagged tempo (`AudioTrackMetadata.bpm`) always beats the analyzed one (`AudioTrack.detectedBPM`) — the BPM label and the bar-based skip actions share the rule — and the tagged key (`AudioTrackMetadata.key`) likewise beats `AudioTrack.detectedKey`. `AudioTrack.bpm` and `.key` are the single homes of both rules.
- **Async deliveries race track changes**: waveform, BPM, key and metadata cache deliveries can arrive after the track has changed, so a receiver must match the delivered URL or track against the current one before applying it.
- **A `VibeMusicalKey` of 0 is C major, not "none"**: every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly, because a zero-filled ivar or a message to nil reads as tagged C major.
- **`AudioPlayer.stop` fires no delegate callback.** It is not a track-end event, so it must never drive auto-advance, and the caller owns the UI reset. Track-end and skip-past-end both funnel through `didFinishPlaying:` instead.

### Logging

The `LogError`, `LogWarn`, `LogInfo` and `LogDebug` macros in `Vibe-Prefix.pch` wrap Apple's unified logging (`os_log`) under the subsystem `com.commonwealthrecordings.Vibe`. The **`vibe-debug` skill** covers streaming, which matters because info and debug are not persisted, and the launch-time build-provenance block.

### Localization

English is the source language; **every other language is whatever the catalogs contain** — don't hardcode the list anywhere, read it from `Resources/Localizable.xcstrings` (`jq -r '[.strings[].localizations | keys] | flatten | unique'`). Translations are authored in the catalogs and are never touched by the extraction pipeline (`normalize()` only reaches `.localizations.en`, and `xcstringstool sync` preserves other languages — verified). Translations follow Apple's own macOS terminology for standard menu items rather than literal translation (German File is `Ablage`, not `Datei`), while DJ terms keep the loanwords the hardware uses (`FX`, `Delay`, and `PITCH` outside German, which uses `TEMPO`). Test a language with `open <app> --args -AppleLanguages '(xx)'`.

`knownRegions` stays at XcodeGen's default `(Base, en)` and that is *not* a bug: it doesn't gate which languages ship. The XCStrings compiler emits every language present in the catalogs, CFBundle negotiates on the `.lproj` directories actually in the bundle, and XcodeGen derives `knownRegions` from localized file references so a spec key for it is ignored. It only affects Xcode's project UI and which languages `-exportLocalizations` defaults to.

**Every user-facing string is declared in `Vibe/Common/VibeStrings.h` and nowhere else.** Call sites use a `STR_*` macro and nothing more — no key, no English text, no translator comment inline:

```objc
NSMenu *fileMenu = Submenu(mainMenu, STR_MENU_FILE).submenu;
NSString *bpmText = [NSString stringWithFormat:STR_LABEL_BPM, formatted];
```

Each entry is one line: `NSLS(key, value, comment)`, a local macro that lifts out the invariant `NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, …)` scaffolding, with columns padded per `#pragma mark` section so the file reads as a table. Keys are **symbolic and stable** (`menu.file`, `label.bpm`, `waveform.style.detailed`), never the English text, so rewording a button doesn't orphan its translations: extraction rewrites the catalog's `en` from the new default and flips every other language to `needs_review` — they keep shipping while awaiting review — rather than minting a new key. The English lives in the macro's *default value*: it is the enforced source of the catalog's `en` values (`xcstringstool sync` alone only stamps `en` on first sight, so the script copies a changed default over it) AND the fallback if a lookup ever misses, so the app can never render a raw `menu.file`. Key prefixes: `menu.*`, `transport.*` (shared by menu items and the transport buttons' a11y labels), `label.*`, `a11y.*`, `error.*`, `waveform.style.*`, `settings.*`.

**`make strings` after touching any UI string**; `make check-strings` fails when the catalog is stale (it also catches a key whose last call site went away — `sync` marks it `extractionState: stale`). `scripts/extract-strings.sh` first runs `VibeStrings.h` through the C preprocessor — it builds a throwaway TU referencing every `STR_*` and `clang -E`s it — because `xcstringstool` matches localization macros by name AND arity, and a three-argument `NSLS(key, value, comment)` fits no shape it knows; even `-s NSLS` extracts zero keys. Parsing the real expansion is exact where a regex over the header would quietly mis-parse, and clang fails loudly on a malformed entry. It then extracts from that expansion plus every other first-party `.m`/`.mm`/`.h` (so a stray inline `NSLocalizedString` can't hide), syncs, and normalizes: source-language units get promoted `new` → `translated` (the XCStrings compiler emits a `.strings` file only for `translated` units, so without this the app would ship no `en.lproj/Localizable.strings` at all), and every live key is marked `extractionState: manual`. The manual mark is a shield, not bookkeeping: **an Xcode build emits no `.stringsdata` for ObjC, so Xcode's own catalog pass sees every non-manual key as unreferenced, flags each one stale — one warning apiece — and writes the stale marks into the checked-in catalog.** `manual` declares a key externally managed and Xcode then leaves it alone. But `xcstringstool sync` honors `manual` too — it skips such keys entirely, no comment updates and no staleness — so the script strips the marks just before syncing and re-applies them after; a key whose `VibeStrings.h` entry was deleted comes through that gap marked `stale` and stays visible (in `--check` diffs and as a single honest Xcode warning) until it is deleted from the catalog.

Extraction is deliberately NOT a build phase: Xcode has **no build-time String Catalog extraction for Objective-C** (clang emits `.stringsdata` only for Swift; the only xcstrings build task is `compile`), and a phase rewriting a checked-in file would flip `VIBE_GIT_DIRTY` on every build. Keep the stock `NSLocalizedString*` names — a custom macro would need `LOCALIZED_STRING_MACRO_NAMES`, which no shipped Xcode binary reads. One consequence of the registry living in a header: a macro nothing references still yields a catalog key, so delete the entry when the last call site goes.

`Resources/InfoPlist.xcstrings` carries the bundle name, the copyright, and the `CFBundleTypeName` values. Its keys are plist keys, EXCEPT the document-type names, which are keyed on the **English type name** — that is how Launch Services looks them up, and it does work (`lsregister -dump` shows the localized names). `CFBundleName` is added to this catalog by Xcode's build, not by hand: it is kept with the same value in every language so the entry stays stable instead of reappearing as an untranslated `new` unit on the next build. The copyright reaches the About window only through `objectForInfoDictionaryKey:`; plain `infoDictionary[…]` does NOT apply `InfoPlist.strings`.

`VibeNotLocalized(s)` (in the pch, no runtime effect) marks a user-visible string deliberately kept in English — format acronyms, layout punctuation, instrument-scale glyphs, product names, titles AppKit never draws. Every unwrapped `@"..."` in UI code should be one or the other.

**Display names are never identifiers.** `AudioWaveformRenderer` splits `+styleIdentifier` (stable; the registry key, the `NSUserDefaults` value, the menu item's `waveform_style_*` identifier) from `+displayName` (localized, display only); `AppSettings` migrates the English display names persisted before the split. `FILETYPE_*` is the inverse case — never localized, because it is compared with `isEqualToString:` and archived into the metadata cache. Locale-dependent numbers (kHz, BPM, pitch %) go through `Formatters`' `decimalString:fractionDigits:` / `signedPercentString:`, not `%.1f`.

To find strings that escaped: build a pseudolocale from the catalog (bracket + accent + pad every value, copying format specifiers verbatim), `xcstringstool compile … -l en-XA` it into the built app's `Contents/Resources`, rename the output to `Localizable.strings`, re-sign (`codesign -f -s - --preserve-metadata=entitlements`), and launch with `--args -AppleLanguages '(en-XA)'`. Anything rendering *without* brackets never went through the bundle. Padding also surfaces layout overflow — the menu bar and the 96pt `PITCH` label are the tightest spots.

The App Store product page is localized too, from `Assets/app-store/` (copy, screenshot captions, and generated screenshots per catalog language — format in its README). `make appstore-validate-copy` validates it; `make appstore-upload-metadata` uploads it via the **vibe-release** skill's shared API key. The catalog remains the source of which languages exist; `bg` ships in-app only, because the App Store has no Bulgarian product page.

### Key patterns

- **No private APIs, ever.** This app ships in the Mac App Store. Do not call, override or otherwise depend on undocumented selectors, classes or notifications — overriding a private method such as `resignKeyAppearance` counts, even though it compiles without any private declaration. When a visual or behavioral goal has no public-API path, as with `NSGlassEffectView`'s inactive dimming, accept the system behavior or redesign. Do not reach for SPI.
- **Delegation** runs throughout: `AudioPlayer` → `MainPlayerController`, waveform views → controller, metadata cache → controller.
- **Singletons**: `AppSettings`, `AudioDeviceManager`, and `AppStats` (lifetime usage counters — files/folders opened, seconds played — in `NSUserDefaults`; the open sinks and the player-delegate transitions feed it, `stop` and quit have no callback so `closeFile:` and `applicationWillTerminate:` flush by hand).
- **File hashing**: `NSURL+Hash` supplies the cache key for metadata and waveform data, `<size>-<mtime_us>-<sha1(path)>`, built from file attributes alone. Hashing no content keeps it cheap but misses a rewrite or a move.
- **ObjC++ (.mm files)** appear only where C++ is genuinely needed: the TagLib integration and the waveform data structures and renderers. Everything else, the whole UI layer included, is plain ObjC (.m), so keep C++ types out of headers that ObjC files import.
- **Comments only when required, and terse.** A comment earns its place by stating what the code cannot show: a trap, an ordering or threading constraint, a contract, a non-obvious why. Most code needs none. Never narrate what the next line does, justify a change, or record how something was verified or what it used to be — that history belongs in commits. If a comment runs long, it should be recording a hard-won trap; otherwise shorten it or simplify the code instead.
- **Third-party sources** in `ThirdParty/` are other authors' code. Do not restyle them.

### Supported audio formats

MP3, MP2, FLAC, MP4/M4A, AAC, AIFF and WAV, all decoded natively by CoreAudio. OGG is not supported.
