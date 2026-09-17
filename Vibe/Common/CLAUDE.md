# Common

**What every other directory is written in terms of, and nothing else. If you can name the feature it belongs to, it belongs there instead** — `Vibe/System/` takes OS-service bridges, `Vibe/Util/` the featureless helpers. **Nothing in `Common/` may import from a feature directory.** The one class importing from `Util/` is `Mac/Theme/AppTheme` (`NSData.sha1Hex`, `NSAppearance.isDark`), both featureless categories, so the rule holds; it lives under `Common/Mac/` because it is macOS-only, the platform split in directory form (`Mac/CLAUDE.md` owns the theme store, `Mac/Theme/CLAUDE.md` the record).

## The settings store

`AppSettings` is every persisted preference as properties over `NSUserDefaults`; `AppStats` is every persisted *counter*. **Every reader imports `AppSettings.h` explicitly and uses `sharedInstance`**, so a file's import list exposes the dependency — which is why `Vibe-Prefix.pch` carries only the log macros and `VibeNotLocalized`: a feature API there recompiles the world and hides a dependency from the file that has it. The macOS half — every mac-only preference and the theme store — is the `(Mac)` category in `Mac/AppSettings+Mac`, imported explicitly beside `AppSettings.h`; `AppSettingsInternal.h` is the seam between the two (`Mac/CLAUDE.md`). The value ladders a stored setting is snapped to on read are `SettingsRules.h`, so a rule about a setting is testable without a defaults store.

**The store never applies effects.** A store-first writer that needs immediate follow-up requests a named `VibeSettingsLiveEffect` from `MainPlayerController+Settings` — a central, synchronous mapping that calls the behavior owned by the affected object and never writes a setting or posts a notification. The Settings *window* is `Vibe/Mac/Settings/`; this side is the store.

The one in-memory value is `windowAppearancePreviewStyle`, an override that `windowAppearance` answers and `setWindowAppearanceStyle:` clears, held by the Settings window's Appearance page while it is open (`Mac/Settings/CLAUDE.md`). It lives here because that accessor is where the style-to-appearance ladder already is, so every consumer gets the preview for free.

## The platform split is the directory plus one `#if !TARGET_OS_OSX` block

**Adding a property means choosing a side**; "does the iOS app honor this?" is answered by which header it sits in. Almost everything configures something only macOS has, so it is `Mac/AppSettings+Mac`, and `AppSettings.h` compiles for iOS only:

- the iOS-only loose appearance keys, in the `#if !TARGET_OS_OSX` block: `waveformStyle` and `waveformTheme` with its custom colors (played and unplayed, each per appearance). On macOS the theme migration consumed these keys and `currentTheme.<field>` is the store of record, so they are compiled out there — a macOS caller fails to build instead of silently reading the registered default forever;
- `folderOpenSort`, `waveformNormalize` and `waveformGainDB`, genuinely shared. The level pair is set for a library's mastering level rather than a look, which is why it is a plain setting on both sides and never an `AppTheme` field;
- the store-wide entry points: `sharedInstance`, `applicationDidFinishLaunching`, `allSettingsAtDefaults`, `resetToDefaults`. On macOS, stored custom themes are content: normal reset preserves them; `factoryReset` removes them before resetting settings.

`AppStats` has the same shape: both shells feed it and both About screens read it, and its one `#if TARGET_OS_OSX` is how a RUNNING listening clock survives the process going quiet. The mac brackets the clock around system sleep — `systemUptime` is not frozen by sleep on Apple Silicon, so a night asleep would count as listening. iOS needs no bracket (nothing silences a running audio session without pausing the player) but needs a persistence edge, so it folds and restarts the clock at every background and terminate notification, since a backgrounded app is killed with no warning. Main thread only.

## There is no settings cache

Reads go straight to `NSUserDefaults` — a CFPreferences lookup apiece, cheap enough even for `uiUpdateHzCap` on every live-resize frame.

**TRAP: `NSUserDefaultsDidChangeNotification` does not fire for a write from another process**, and the debug channel's CLI-side prefs verbs (`set_analysis`) are exactly that, as is a plain `defaults write`. A cache invalidated on that notification reports the old value for good; observed, not hypothetical. Any future cache over a stored key must invalidate some other way. `FolderArtResolver` caches its own setting on the cell-draw path and must be dropped **by hand**: a write to `useFolderArt` that skips `VibeSettingsLiveEffectFolderArt` is not observed at all (`Audio/Metadata/FolderArt/CLAUDE.md`).

**TRAP: a stored `NSUserDefaults` key must never follow a rename of its macro.** `SETTING_FOLDER_ART` is still `@"Audio.folderArtwork"`; changing the string would silently reset every existing user's setting to the default.

## Single homes

- **`VibeStrings.h`** — every user-facing string, declared here and nowhere else; call sites use `STR_*` (root `CLAUDE.md`, the `vibe-strings` skill, `make strings` after). **TRAP: the file must be named `VibeStrings.h`, not `Strings.h`.** On a case-insensitive filesystem `Strings.h` shadows POSIX `<strings.h>` during explicit-modules dependency scanning: CoreServices includes `<strings.h>`, resolves it to this file, and its Foundation import completes a Foundation → CoreServices → Foundation cycle that fails every module build in the target. Its Foundation import is wrapped in `#ifndef VIBE_STRINGS_EXTRACTION` because `extract-strings.sh` preprocesses the header with `-E` and needs `NSLocalizedStringWithDefaultValue` to survive unexpanded.
- **`PlayableExtensions`** — every audio extension the app plays: `ordered` for the playlist resolver's fallback walk (lossless before lossy, so the order decides which replacement a folder holding several yields), `lookup` for the open funnel's membership test. Stateless and Foundation-only so it sits below both readers — `NSURLUtil` imports `PlaylistFile`, so `PlaylistFile` cannot import `NSURLUtil` back, and a set either owned would be copied into the other. **It must cover every spelling `CFBundleDocumentTypes` admits**, or Finder offers Vibe a file the filter then silently discards. OGG is not in it.
- **`DocumentTypes`** — the `CFBundleDocumentTypes` declarations read back as `UTType`s (`declaredTypes` includes the folder, `declaredFileTypes` the files alone), so the ⌘O filter and what the app is registered for cannot drift. The Launch Services side is `DefaultAppRegistration` (`Mac/Settings/`), which keeps this class AppKit-free.
- **`FolderOpenSort.h`** — `VibeFolderOpenSort` and its stored identifiers, a header of its own because `Util/NSURLUtil` takes the enum as a walk parameter and may not import a setting to get it (`Util/CLAUDE.md`). The identifier-to-enum rules are in `SettingsRules.h`.
- **`VibeProductURLs`** — the three web addresses, spelled once. An address is an identifier and is never localized; what a row is *called* is a `settings.about.*` string.

## Platform aliases and the two free-function headers

`PlatformTypes.h` defines `VibeImage` and `VibeColor` (`NSImage`/`NSColor` on macOS, `UIImage`/`UIColor` elsewhere) so a model header can carry an image without importing AppKit or UIKit. **Do not add aliases for their own sake.**

`PlatformImage.h` and `PlatformColor.h` are the two homes of free functions over a foreign class (root `CLAUDE.md`, Vocabulary): the class involved differs per target, so there is no single one to hang a category on. `VibeDecodedImageWithData(data, maxPixelSize)` is the bounded ImageIO decode that never materializes the full-size bitmap; it takes 10–100ms, so it belongs off the main thread. `VibeDominantColorOfImage` is the weighted hue histogram behind the window tint, the dock icon and the `album_art` waveform theme, over a fixed 32×32 downsample so its cost is independent of image size. **It works in CoreGraphics terms rather than either platform's bitmap type**: `NSBitmapImageRep` and `UIImage`'s backing store agree on nothing, while a `CGBitmapContext` we create has a layout the pixel loop can rely on — which is what lets one implementation serve both (`NSImage+Util.dominantColor` and `UIImage+DominantColor` forward to it). `PlatformColor.h` carries the `#RRGGBB[AA]` persisted form of a stored color (opaque stays six digits) and the linear blend, with `extern "C"` guards because the `.mm` renderers include it.
