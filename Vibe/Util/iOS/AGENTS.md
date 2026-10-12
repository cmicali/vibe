# Util/iOS (UIKit only)

The UIKit half of `Vibe/Util/`, under the parent's admission test: **no feature**. The AppKit mirror is `Util/Mac/`.

- **`UIView+DarkMode`**: the mirror of `Mac/`'s `NSView+DarkMode`. The separate names are what let `make check-layout` allow both.
- **`UIImage+Blur`**: `vibeBlurredBackdrop` bakes a blurred, darkened backdrop out of an image. It memoizes a successful result on that image. A live `UIVisualEffectView` would recompute the blur during pager swipes. The baked image avoids that work and needs only one image view. Its only caller is `TrackPageCell` (`Vibe/iOS/Player/AGENTS.md`).
- **`UIImage+DominantColor`**: `vibeDominantColor`, memoized on the image. The pager reconfigures a page every time it leaves the reuse pool, and re-sampling per configure would put a rasterize on the swipe. A nil result is memoized too, so an empty or transparent image is sampled once. The extraction is the mac's too (`Common/PlatformImage.h`'s `VibeDominantColorOfImage`). Only the memo is iOS's. The pager and `TrackPageCell` hand it to the page's waveform scrubber for the `album_art` theme. `WidgetPublisher` reads the same memo for the widget's waveform strip.
- **`UIViewController+Alert`**: `vibePresentAlertWithTitle:message:` shows an alert with one OK button. `vibeTopmostPresenter` is what an alert goes over: the top of the receiver's presentation stack, past one being dismissed. Every iOS screen uses them.
