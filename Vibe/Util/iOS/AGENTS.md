# Util/iOS (UIKit only)

The UIKit half of `Vibe/Util/`, under the parent's admission test: **no feature**. The AppKit mirror is `Util/Mac/`.

`UIView+DarkMode`, `UIImage+Blur`, and `UIImage+DominantColor` are in vibe-libs' `core/Graphics`, and its `AGENTS.md` describes them. The now-playing page draws its blurred art as a baked image from `vibeBlurredBackdrop`, because a live `UIVisualEffectView` would re-blur through every pager swipe. The pager, `TrackPageCell`, and `WidgetPublisher` read the dominant color through `vibeDominantColor`'s memo.

- **`UIViewController+Alert`**: `vibePresentAlertWithTitle:message:` shows an alert with one OK button. `vibeTopmostPresenter` is what an alert goes over: the top of the receiver's presentation stack, past one being dismissed. Every iOS screen uses them.
