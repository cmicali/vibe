# Util/iOS (UIKit only)

The UIKit half of `Vibe/Util/`, under the parent's admission test: **no feature**. The AppKit mirror is `Util/Mac/`.

- **`UIView+DarkMode`**: the mirror of `Mac/`'s `NSView+DarkMode`. The separate names are what let `make check-layout` allow both.
- **`UIImage+Blur`**: `vibeBlurredBackdrop` bakes a blurred, darkened backdrop out of an image, memoized on that image. It exists because a `UIVisualEffectView` blur is a live backdrop filter. The render server recomputes it on every frame anything behind it moves. On the track pager that meant two full-screen blurs per frame during a swipe, of a picture that never changes. Baking it also collapses the art view and the effect view into one image view. Its only caller is `TrackPageCell` (`Vibe/iOS/AGENTS.md`).
- **`UIImage+DominantColor`**: `vibeDominantColor`, memoized on the image. The pager reconfigures a page every time it leaves the reuse pool, and re-sampling per configure would put a rasterize on the swipe. A nil result is memoized too, so an empty or transparent image is sampled once. The extraction is the mac's too (`Common/PlatformImage.h`'s `VibeDominantColorOfImage`). Only the memo is iOS's. The pager and `TrackPageCell` hand it to the page's waveform scrubber for the `album_art` theme. `WidgetPublisher` reads the same memo for the widget's waveform strip.
