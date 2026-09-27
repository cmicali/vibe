//
//  UIImage+DominantColor.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIImage (VibeDominantColor)

// VibeDominantColorOfImage (PlatformImage.h), memoized on the image: the pager
// reconfigures a page on every reuse, and re-sampling would rasterize on the
// swipe. The memo dies with the image. nil is not memoized.
@property (nonatomic, readonly, nullable) UIColor *vibeDominantColor;

@end

NS_ASSUME_NONNULL_END
