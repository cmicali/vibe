# Common

What every other directory is written in terms of, and nothing else. Six things live here, and the bar for a seventh is high: **if you can name the feature it belongs to, it belongs there instead.**

The name is the danger. This is not a drawer for anything shared — `Vibe/System/` takes the OS-service bridges, `Vibe/Util/` the featureless helpers, and a feature's own directory takes everything else. What earns a place here is *vocabulary*: something the rest of the app is phrased in. It keeps that property only by being boring, and the import rule at the bottom is what enforces it.

## What is here

**`AppSettings`** — every persisted preference, as properties over `NSUserDefaults`, reached everywhere through the `Settings` macro in the prefix header rather than an import. Its pure decision logic — the value ladders a stored setting is snapped to on read — is `SettingsRules.h`, which is where a rule about a setting goes so that a test can reach it without a defaults store.

**Five of them are cached in the class**, because they are read far more often than the rest: the right time label's mode on every playback tick, `showFileInfo`, `keyNotation` and `keyColorsEnabled` on every `updateUI` pass, and `uiUpdateHzCap` on every live-resize frame. `FolderArtResolver` caches its own setting for the same reason — a defaults lookup per cell draw — but its cache has to be dropped by hand, so **a write that skips `refreshFolderArt` is not observed at all**. This one is coherent by construction instead: the setters invalidate, and so does `NSUserDefaultsDidChangeNotification`, which covers a `defaults write` from outside the process. Main thread only, asserted, which every reader of those five is; the analysis flags are deliberately *not* cached, since the waveform loader reads them off-main and once per decode is not a hot path.

The **`Settings > pane`** UI is `Vibe/Settings/`, not here. This side is the store; that side is the window. A live-apply hook, when a pane writes a setting the app has to act on immediately, is a method on whatever owns the affected state — usually `MainPlayerController` — and never a notification from here.

**`VibeStrings.h`** — the localized-string registry. **Every user-facing string is declared here and nowhere else**; call sites use a `STR_*` macro and nothing more. See the root `CLAUDE.md` and the `vibe-strings` skill before touching it, and run `make strings` after.

**`Vibe-Prefix.pch`** — the prefix header, and so the one place an import reaches every translation unit. It carries the log macros, the `Settings` accessor, and `VibeNotLocalized`. Adding an import here is a real cost — it recompiles the world and hides a dependency from the file that has it — so add one only for something genuinely universal.

**`PlatformTypes.h`** — `VibeImage` and `VibeColor`, `NSImage`/`NSColor` on macOS and `UIImage`/`UIColor` on iOS. They exist so that a model header carrying an image does not have to import AppKit or UIKit, which keeps the model layer's headers cheap and lets one model serve both targets. `PlatformImage.h` is their companion: the bounded ImageIO decode that *builds* a `VibeImage`, a free function rather than a category because the class it constructs differs per platform. Do not add aliases for their own sake.

## The rule that keeps this directory honest

Nothing in `Common/` may import from a feature directory. If something here needs to know about a track, a playlist or a window, it is in the wrong place — that dependency is what turned the *original* `Common/` — which did hold features — into a cycle with `Audio/`, where `Playlist.h` imported `AudioTrack.h` while `AudioTrack.h` imported `MusicalKey.h` back out of `Common/`.
