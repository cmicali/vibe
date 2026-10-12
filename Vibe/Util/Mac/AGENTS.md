# Util/Mac (AppKit only)

The AppKit half of `Vibe/Util/`, under the parent's admission test: **no feature**. The iOS mirror is `Util/iOS/`. A category on an AppKit class belongs here. A portable one belongs in `Util/Categories/`, and one on the app's own classes beside that class.

- **`WindowAnimation.h`**: `kWindowResizeAnimationDuration` (0.12s), the one resize timing the player and Settings windows share. No single feature owns it. Every programmatic resize uses it through `animationResizeTime:`, rather than AppKit's distance-scaled default, which drags on big jumps.
- **`NSColor+OKLCH`**: perceptual lightness and chroma clamping for the artwork-derived header wash, because HSB brightness is hue-blind (`Mac/MainWindow/LAYOUT.md`).
- **`NSImage+Util`**: includes `dominantColor`, a forward to `Common/PlatformImage.h`'s `VibeDominantColorOfImage`. It also has `symbolNamed:pointSize:weight:palette:accessibilityDescription:`, the one way an SF Symbol is built with palette colors. The palette configuration is applied over the sized one, since a symbol image holds only one. Tested (`NSImageUtilTests`).
- **`NSView+DarkMode`**: the mirror of `iOS/`'s `UIView+DarkMode`. The separate names are what let `make check-layout` allow both. The file also holds `NSAppearance (DarkMode)`, the Aqua/DarkAqua `bestMatch` fold the view's `isDark` is written in terms of. A caller holding an appearance rather than a view asks that one, as `AppTheme`'s dynamic colors and its two-sided artwork wrapper do.
- **`NSDraggingImageComponent+Util`**: the text label of a drag image.
