# Common

What every other directory is written in terms of, and nothing else. **If you can name the feature it belongs to, it belongs there instead.** This is not a drawer for anything shared — `Vibe/System/` takes OS-service bridges, `Vibe/Util/` the featureless helpers, and a feature's own directory takes everything else.

**Nothing in `Common/` may import from a feature directory.** If something here needs to know about a track, a playlist or a window, it is in the wrong place.

## What is here

**`AppSettings`** — every persisted preference, as properties over
`NSUserDefaults`. The one exception is `windowAppearancePreviewStyle`, an
in-memory override of the window appearance that `windowAppearance` answers
and `setWindowAppearanceStyle:` clears: the Settings window's Appearance page
holds it while it is open (`Mac/Settings/CLAUDE.md`), and it lives here rather
than on the window because that accessor is where the style-to-appearance
ladder already is, so every consumer of the answer gets the preview for free. Every reader imports `AppSettings.h` explicitly and uses
`AppSettings.sharedInstance`, so a file's import list exposes the dependency.
`AppSettings.{h,m}` is the shared store; the macOS half — every mac-only
preference and the theme store — is the `(Mac)` category in
`Mac/AppSettings+Mac.{h,m}`, which a macOS reader imports explicitly beside
`AppSettings.h` (`Mac/CLAUDE.md`). `AppSettingsInternal.h` is the seam between
the two: the stored keys both halves read, the ivars the mac half keeps (a
category cannot declare any), and the mac halves of the store-wide entry
points, which the shared file calls under `TARGET_OS_OSX` and nothing else
reaches. The preset ladders are exported once from the implementation rather
than copied from the header into every translation unit. Its pure decision
logic — the value ladders a stored setting is snapped to on read — is
`SettingsRules.h`, so a rule about a setting is testable without a defaults
store.

**`SettingsRules.h`** — the header-only seam above, tested by `SettingsRulesTests`.

**`Mac/AppTheme`** — the one class here that imports from `Util/` (`NSData.sha1Hex` for its content-addressed artwork names, `NSAppearance.isDark` for its dynamic colors); both are featureless categories, not a feature directory, so the rule above holds. One theme: every appearance choice the theme system governs, as typed accessors over a sparse record (a missing field is the default, so the built-in Vibe theme is the empty record and cannot drift from the factory look). All sanitization lives on it — `initWithRecord:`, every setter and the JSON import run the same clamps — and `AppSettings` owns the single `currentTheme` instance, its three keys and the CRUD. See `Mac/CLAUDE.md`. It is the platform-split rule's directory form: the class is macOS-only, so it lives under `Common/Mac/` rather than behind a guard.

**`AppStats`** — every persisted *counter*, as `AppSettings` is every persisted preference: lifetime files and folders opened, and lifetime listening time, over `NSUserDefaults`. Main thread only. Both shells feed it — the mac from its open funnel and player events, iOS from `FolderSession.finishOpenIntent` and `PlaybackController+PlayerEvents` — and both Settings > About screens read it. **What differs per platform is only how a RUNNING listening clock survives the process going quiet**, and that is the one `#if TARGET_OS_OSX` block below: the mac brackets the clock around system sleep (`systemUptime` is not frozen by sleep on Apple Silicon, so a night asleep would count as listening); iOS needs no such bracket — a device does not sleep out from under a running audio session, and anything that silences one pauses the player — but does need a persistence edge, so it folds and restarts the clock at every background and terminate notification, since a backgrounded app is killed with no warning.

**`VibeProductURLs.h`/`.m`** — the project's three web addresses (site, support, repo), spelled once. Both About screens list all three and the mac's Help menu opens the support page. An address is an identifier and is never localized; what a row is *called* is a `settings.about.*` string.

**`FolderOpenSort.h`** — `VibeFolderOpenSort` (name, newest-first, as-received) and its stored identifiers: the order a folder's tracks land in the playlist. It is a header of its own rather than a block in `AppSettings.h` because `Util/NSURLUtil` takes the enum as a walk parameter and may not import a setting to get it (`Util/CLAUDE.md`). The identifier-to-enum rules are in `SettingsRules.h` with the rest.

**`PlayableExtensions`** — every audio extension the app plays, spelled once: `ordered` for the playlist resolver's fallback walk (lossless before lossy, so the order decides which replacement a folder holding several yields), `lookup` for the open funnel's membership test. Stateless, all class methods and Foundation-only, so it sits below both readers — `NSURLUtil` imports `PlaylistFile`, so `PlaylistFile` cannot import `NSURLUtil` back, and a set either owned would have to be copied into the other. It must cover every spelling `CFBundleDocumentTypes` admits, or Finder offers Vibe a file the filter then silently discards. OGG is not in it.

**`VibeStrings.h`** — the localized-string registry. Every user-facing string is declared here and nowhere else; call sites use a `STR_*` macro. See the root `CLAUDE.md` and the `vibe-strings` skill, and run `make strings` after.

**`Vibe-Prefix.pch`** — the prefix header, the one place an import reaches
every translation unit. It carries the log macros and `VibeNotLocalized`.
Feature APIs, including `AppSettings`, never belong here: adding one
recompiles the world and hides a dependency from the file that has it.

**`PlatformTypes.h`** — `VibeImage` and `VibeColor`, `NSImage`/`NSColor` on macOS and `UIImage`/`UIColor` elsewhere. They let a model header carry an image without importing AppKit or UIKit, so one model serves both targets. Do not add aliases for their own sake.

**`PlatformColor.h`/`.m`** — `VibeColorFromHexString` / `VibeHexStringFromColor`, the `#RRGGBB[AA]` persisted form of a stored color setting (opaque stays six digits), and `VibeColorBlended`, the cross-platform linear blend. Free functions for the same reason as `PlatformImage.h`: the constructed class differs per platform. The header carries `extern "C"` guards because the `.mm` renderers include it.

**`PlatformImage.h`/`.m`** — `VibeDecodedImageWithData(data, maxPixelSize)`, the bounded ImageIO decode that *builds* a `VibeImage`, plus `kVibeThumbnailArtDimension`, `kVibeDisplayArtDimension`, and `kVibeArchivedDisplayArtDimension`. Unlike `initWithData:` + resize it never materializes the full-size bitmap. The decode takes 10–100ms, so it belongs off the main thread.

It also vends **`VibeDominantColorOfImage`** — the weighted hue histogram behind the window tint, the dock icon and the `album_art` waveform theme, over a fixed 32×32 downsample so its cost is independent of image size. It works in **CoreGraphics** terms rather than each platform's own bitmap type, which is exactly what lets one implementation serve both: `NSBitmapImageRep` and `UIImage`'s backing store agree on nothing, while a `CGBitmapContext` we create has a layout the pixel loop can rely on. `NSImage+Util.dominantColor` is a thin forward to it; iOS memoizes it per image (`UIImage+DominantColor`).

Both are free functions rather than categories because there is no single foreign class to hang them on — the image is `NSImage` or `UIImage`, and the color one returns `NSColor` or `UIColor` — the same reason `PlatformColor.h`'s functions are.

**`DocumentTypes`** — the `CFBundleDocumentTypes` declarations from `Info.plist`, read back as `UTType`s; stateless, all class methods. `declaredTypes` is everything including the folder declaration, `declaredFileTypes` the files alone. `Info.plist` is the single source of truth, so the `⌘O` panel's filter and what the app is registered for cannot drift. The Launch Services side is `DefaultAppRegistration` (`Mac/Settings/`), which keeps this class AppKit-free.

## The platform split is the directory plus one `#if !TARGET_OS_OSX` block

Not a guard per property. Almost everything here configures something only macOS has — the window, the pitch fader, the FX graph, Convert to FLAC, the playlist table, folder art, BPM and key analysis — so all of that is `Mac/AppSettings+Mac`, and what iOS compiles is the short list in `AppSettings.h`:

- the iOS-only loose appearance keys, in their own `#if !TARGET_OS_OSX`: `waveformStyle`, `waveformTheme` with its custom colors (a played *and* an unplayed accessor, each taking the appearance, so four colors in all). On macOS the theme migration consumed these keys and `currentTheme.<field>` is the store of record, so they are compiled out there — a macOS caller fails to build instead of silently reading the registered default forever;
- `folderOpenSort`, genuinely shared;
- `waveformNormalize` and `waveformGainDB`, genuinely shared too — the waveform's level mapping, which both platforms' renderers draw through (`WaveformUI/CLAUDE.md`). They are set for a library's mastering level rather than for a look, which is why they are plain settings on both sides and were never `AppTheme` fields on macOS;
- the store-wide entry points, which belong to no one setting: `sharedInstance`, `applicationDidFinishLaunching`, `allSettingsAtDefaults` and `resetToDefaults`.

"Does the iOS app honor this?" is answered by which header a property sits in. **Adding a property means choosing a side.**

## There is no settings cache

Reads go straight to `NSUserDefaults` — a CFPreferences lookup apiece, cheap enough even for `uiUpdateHzCap`'s read on every live-resize frame. The display flags that once justified a per-turn hot cache moved into `AppTheme`, whose fields are in-memory; the cache mechanism went with them.

**TRAP: `NSUserDefaultsDidChangeNotification` does not fire for a write from another process**, and the debug channel's CLI-side prefs verbs (`set_analysis`) are exactly that — the CLI client writing while the app runs, as is a plain `defaults write`. A cache invalidated on that notification reports the old value for good; observed, not hypothetical. Any future cache over a stored key must invalidate some other way (the old hot cache used a per-run-loop-turn lifetime).

`FolderArtResolver` caches its own setting for the same hot-path reason, but its cache must be dropped **by hand**: a write to `AppSettings.useFolderArt` that skips `VibeSettingsLiveEffectFolderArt` is not observed at all. See `Audio/Metadata/CLAUDE.md`.

**TRAP: a stored `NSUserDefaults` key must never follow a rename of its macro.** `SETTING_FOLDER_ART` is still `@"Audio.folderArtwork"`, predating the folder-artwork → folder-art vocabulary; changing the string would silently reset every existing user's setting to the default.

**TRAP: the file must be named `VibeStrings.h`, not `Strings.h`.** On a case-insensitive filesystem `Strings.h` shadows POSIX `<strings.h>` during explicit-modules dependency scanning: the SDK's CoreServices module includes `<strings.h>`, resolves it to this file, and this file's Foundation import completes a Foundation → CoreServices → Foundation cycle that fails every module build in the target. Relatedly, its Foundation import is wrapped in `#ifndef VIBE_STRINGS_EXTRACTION` because `extract-strings.sh` preprocesses the header with `-E` and needs `NSLocalizedStringWithDefaultValue` to survive unexpanded.

## Where the Settings *window* lives

`Vibe/Mac/Settings/`, not here. This side is the store; that side is the window. On macOS, a store-first writer that needs immediate follow-up requests a named effect from `MainPlayerController+Settings`; that central, synchronous mapping calls the behavior owned by the affected object. It never writes settings or uses a notification.
