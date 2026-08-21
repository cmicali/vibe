# Common

What every other directory is written in terms of, and nothing else. **If you can name the feature it belongs to, it belongs there instead.** This is not a drawer for anything shared — `Vibe/System/` takes OS-service bridges, `Vibe/Util/` the featureless helpers, and a feature's own directory takes everything else.

**Nothing in `Common/` may import from a feature directory.** If something here needs to know about a track, a playlist or a window, it is in the wrong place.

## What is here

**`AppSettings`** — every persisted preference, as properties over
`NSUserDefaults`. Every reader imports `AppSettings.h` explicitly and uses
`AppSettings.sharedInstance`, so a file's import list exposes the dependency.
The preset ladders are exported once from the implementation rather than copied
from the header into every translation unit. Its pure decision logic — the
value ladders a stored setting is snapped to on read — is `SettingsRules.h`,
so a rule about a setting is testable without a defaults store.

**`SettingsRules.h`** — the header-only seam above, tested by `SettingsRulesTests`.

**`VibeStrings.h`** — the localized-string registry. Every user-facing string is declared here and nowhere else; call sites use a `STR_*` macro. See the root `CLAUDE.md` and the `vibe-strings` skill, and run `make strings` after.

**`Vibe-Prefix.pch`** — the prefix header, the one place an import reaches
every translation unit. It carries the log macros and `VibeNotLocalized`.
Feature APIs, including `AppSettings`, never belong here: adding one
recompiles the world and hides a dependency from the file that has it.

**`PlatformTypes.h`** — `VibeImage` and `VibeColor`, `NSImage`/`NSColor` on macOS and `UIImage`/`UIColor` elsewhere. They let a model header carry an image without importing AppKit or UIKit, so one model serves both targets. Do not add aliases for their own sake.

**`PlatformColor.h`/`.m`** — `VibeColorFromHexString` / `VibeHexStringFromColor`, the `#RRGGBB[AA]` persisted form of a stored color setting (opaque stays six digits), and `VibeColorBlended`, the cross-platform linear blend. Free functions for the same reason as `PlatformImage.h`: the constructed class differs per platform. The header carries `extern "C"` guards because the `.mm` renderers include it.

**`PlatformImage.h`/`.m`** — `VibeDecodedImageWithData(data, maxPixelSize)`, the bounded ImageIO decode that *builds* a `VibeImage`, plus `kVibeThumbnailArtDimension`, `kVibeDisplayArtDimension`, and `kVibeArchivedDisplayArtDimension`. Unlike `initWithData:` + resize it never materializes the full-size bitmap. The decode takes 10–100ms, so it belongs off the main thread. It is a free function rather than a category because the class it constructs differs per platform.

**`DocumentTypes`** — the `CFBundleDocumentTypes` declarations from `Info.plist`, read back as `UTType`s; stateless, all class methods. `declaredTypes` is everything including the folder declaration, `declaredFileTypes` the files alone. `Info.plist` is the single source of truth, so the `⌘O` panel's filter and what the app is registered for cannot drift. The Launch Services side is `DefaultAppRegistration` (`Mac/Settings/`), which keeps this class AppKit-free.

## The platform split is one `#if TARGET_OS_OSX` block

Not a guard per property. Almost everything here configures something only macOS has — the window, the pitch fader, the FX graph, Convert to FLAC, the playlist table, folder art, BPM and key analysis — so what iOS compiles is the short list above the block: `waveformStyle`, `waveformTheme` and its custom color pair, and `applicationDidFinishLaunching`. "Does the iOS app honor this?" is answered by which side of the `#if` a property sits on. **Adding a property means choosing a side.**

## The hot-path cache lives for one turn of the main run loop

Five settings are read far more often than the rest and are cached in the class: `showRemainingTime`, `showFileInfo`, `keyNotation`, `keyColorsEnabled`, `uiUpdateHzCap`. All five are macOS settings, which is why the whole cache is inside the `#if`. Main thread only.

**TRAP: `NSUserDefaultsDidChangeNotification` does not fire for a write from another process**, and the debug channel's prefs verbs (`set_key_display`, `set_analysis`, `set_folder_art`) are exactly that — the CLI client writing while the app runs, as is a plain `defaults write`. Invalidating on that notification left the app reporting the old value for good. So the cache's lifetime is a run-loop turn instead: a `CFRunLoopObserver` drops it before the loop sleeps, and the setters drop it immediately (`invalidateHotCache`). A value is therefore never more than one turn stale, and no writer has to remember anything.

The analysis flags are deliberately **not** cached — the waveform loader is handed their values once per decode through its analysis provider, which is not a hot path.

`FolderArtResolver` caches its own setting for the same hot-path reason, but its cache must be dropped **by hand**: a write to `AppSettings.useFolderArt` that skips `MainPlayerController.refreshFolderArt` is not observed at all. See `Audio/Metadata/CLAUDE.md`.

**TRAP: a stored `NSUserDefaults` key must never follow a rename of its macro.** `SETTING_FOLDER_ART` is still `@"Audio.folderArtwork"`, predating the folder-artwork → folder-art vocabulary; changing the string would silently reset every existing user's setting to the default.

**TRAP: the file must be named `VibeStrings.h`, not `Strings.h`.** On a case-insensitive filesystem `Strings.h` shadows POSIX `<strings.h>` during explicit-modules dependency scanning: the SDK's CoreServices module includes `<strings.h>`, resolves it to this file, and this file's Foundation import completes a Foundation → CoreServices → Foundation cycle that fails every module build in the target. Relatedly, its Foundation import is wrapped in `#ifndef VIBE_STRINGS_EXTRACTION` because `extract-strings.sh` preprocesses the header with `-E` and needs `NSLocalizedStringWithDefaultValue` to survive unexpanded.

## Where the Settings *window* lives

`Vibe/Mac/Settings/`, not here. This side is the store; that side is the window. A live-apply hook — when a pane writes a setting the app must act on immediately — is a method on whatever owns the affected state, usually `MainPlayerController`, and never a notification from here.
