//
//  UIImage+SquareFill.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIImage (VibeSquareFill)

// Aspect-fill into a square of `side` PIXELS, centre-cropped. For a surface
// that publishes artwork out of the app — the home-screen widget — where the
// crop has to happen once at write time rather than per render in a process
// that cannot afford it.
- (UIImage *)vibeSquareFilledToSide:(CGFloat)side;

@end

NS_ASSUME_NONNULL_END
