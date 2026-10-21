# Util/Mac (AppKit only)

The AppKit half of `Vibe/Util/`, under the parent's admission test: **no feature**. The iOS mirror is `Util/iOS/`. A category on an AppKit class belongs here. A portable one belongs in `Util/Categories/`, and one on the app's own classes beside that class. `NSColor+OKLCH`, `NSImage+Util`, and `NSView+DarkMode` are in vibe-libs' `core/Graphics`, and its `AGENTS.md` describes them. `WindowAnimation.h`, the resize timing the player and Settings windows share, is in vibe-libs' `ui/Controls`. The main window answers its `kWindowResizeAnimationDuration` from `animationResizeTime:`.

- **`NSDraggingImageComponent+Util`**: the text label of a drag image.
- **`NSTextField+Label`**: `labelWithFrame:`, the plain label (borderless, uneditable, clipping) every text of the main window's header and its volume control is made from. Both build their own labels from it, so neither reaches into the other.
