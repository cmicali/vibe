//
//  UIImage+DominantColor.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIImage (VibeDominantColor)

// The image's dominant color, memoized on the image itself — the same shape as
// vibeBlurredBackdrop, and for the same reason: the track pager reconfigures a
// page every time it comes back out of the reuse pool, and re-running the
// sample per configure would put a rasterize on the swipe. The memo dies with
// the image, so a replaced cover can never inherit the previous one's color.
//
// The extraction is PlatformImage.h's VibeDominantColorOfImage, shared with the
// mac. nil for art that cannot be rasterized — not memoized, since there is
// nothing to keep and the case is rare.
@property (nonatomic, readonly, nullable) UIColor *vibeDominantColor;

@end

NS_ASSUME_NONNULL_END
