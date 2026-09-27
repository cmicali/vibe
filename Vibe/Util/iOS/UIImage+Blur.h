//
//  UIImage+Blur.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIImage (VibeBlur)

// A blurred, darkened copy for a STATIC backdrop. Baked because a
// UIVisualEffectView re-blurs every frame anything behind it moves — two
// full-screen blurs through every pager swipe. Blurred at a few dozen pixels,
// so the cost is size-independent, and memoized on the receiver. Main thread
// only.
- (nullable UIImage *)vibeBlurredBackdrop;

@end

NS_ASSUME_NONNULL_END
