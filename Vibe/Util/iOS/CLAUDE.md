# Util/iOS (UIKit only)

The UIKit half of `Vibe/Util/`. Same admission test as the parent: **no feature**. The AppKit mirror is `Util/Mac/`, and neither target names the other's directory.

- **`UIView+DarkMode`** — the mirror of `Mac/`'s `NSView+DarkMode`. They are separate *names*, which is what lets `make check-layout` allow both to exist.
- **`UIImage+Blur`** — bakes a blurred, darkened backdrop out of an image, memoized on the image it came from.
- **`UIImage+DominantColor`** — the image's dominant color, memoized on the image the same way and for the same reason: the track pager reconfigures a page every time it comes back out of the reuse pool, and re-sampling per configure would put a rasterize on the swipe. The extraction is shared with the mac (`Common/PlatformImage.h`'s `VibeDominantColorOfImage`); only the memo is iOS's. Its caller is `TrackPageCell`, which hands the result to that page's waveform scrubber for the `album_art` theme.

**Why `UIImage+Blur` exists at all:** a `UIVisualEffectView`'s blur is a live backdrop filter that the render server recomputes on every frame anything behind it moves. On the iOS track pager that meant two full-screen blurs per frame during a swipe — of a picture that never changes. Baking it also collapses the art view and the effect view above it into one image view. Its only caller is `TrackPageCell` (`Vibe/iOS/CLAUDE.md`).
