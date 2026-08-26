# Util/Mac (AppKit only)

The AppKit half of `Vibe/Util/`. Same admission test as the parent: **no feature**. The iOS mirror is `Util/iOS/`, and neither target names the other's directory.

- **`Fonts`** — the app's typography. The three themed slots (main, info, playlist) resolve against configuration **pushed** by `MainPlayerController.applyStoredFonts` — Util may not read a setting — with sizes as offsets from each slot's reference base, so a call site's own base survives any chosen size. An empty face is the slot's built-in font; an uninstalled one falls back the same way, so a slot accessor never returns nil.
- **`WindowAnimation.h`** — `kWindowResizeAnimationDuration` (0.12s), the one window-chrome timing every window the app resizes shares. It is here rather than in a feature directory only because *two* windows share it (the player and Settings) and no single feature owns it. All programmatic resizes use it through `animationResizeTime:` rather than AppKit's distance-scaled default, which drags on big jumps.
- **`TrackCommands`** — the single-track commands: reveal in Finder, and write the pasteboard.
- **`NSColor+OKLCH`** — perceptual lightness/chroma clamping for the artwork-derived header wash, because HSB brightness is hue-blind. See `Mac/MainWindow/APPEARANCE.md`.
- **`NSImage+Util`** — including `dominantColor`, the hue histogram behind the art tint. Tested (`NSImageUtilTests`).
- **`NSView+DarkMode`** — the mirror of `iOS/`'s `UIView+DarkMode`. They are separate *names*, which is what lets `make check-layout` allow both.
- **`NSDockTile+Util`**, **`NSDraggingImageComponent+Util`** — small AppKit categories.

A category on an AppKit class belongs here; a portable one belongs in `Util/Categories/`; a category on one of the app's own classes belongs beside that class.
