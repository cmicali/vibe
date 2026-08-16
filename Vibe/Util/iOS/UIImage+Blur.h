//
//  UIImage+Blur.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIImage (VibeBlur)

// A heavily blurred, darkened copy of this image, for use as a STATIC backdrop
// behind content — the track pager's blurred album art.
//
// It exists because a UIVisualEffectView cannot be told to stop. Its blur is a
// live backdrop filter: the render server re-samples and re-blurs whatever sits
// behind it on every frame that anything back there moves, and a full-screen one
// per pager page means two of them recomputing through every swipe. The art
// behind a page never changes while that page is up, so the blur is baked once
// here and shown as a plain image.
//
// Cost is independent of the source's size and of the size it is shown at: the
// image is downsampled into a box a few dozen pixels on a side, blurred there
// with vImage's three box passes (the standard gaussian approximation), and
// magnified back by whatever draws it — the magnification being itself part of
// the blur. The result is memoized on the receiver, so it is computed once per
// decoded artwork and dies with it.
//
// Main thread only, like the UIImage drawing it wraps.
- (nullable UIImage *)vibeBlurredBackdrop;

@end

NS_ASSUME_NONNULL_END
