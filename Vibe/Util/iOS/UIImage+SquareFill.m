//
//  UIImage+SquareFill.m
//  Vibe (iOS)
//
//  See UIImage+SquareFill.h.
//

#import "UIImage+SquareFill.h"

@implementation UIImage (VibeSquareFill)

- (UIImage *)vibeSquareFilledToSide:(CGFloat)side {
    CGSize square = CGSizeMake(side, side);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;                 // the side is already in pixels
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:square
                                                                              format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGSize source = self.size;
        if (source.width <= 0 || source.height <= 0) {
            return;
        }
        CGFloat scale = MAX(square.width / source.width, square.height / source.height);
        CGSize filled = CGSizeMake(source.width * scale, source.height * scale);
        [self drawInRect:CGRectMake((square.width - filled.width) / 2,
                                    (square.height - filled.height) / 2,
                                    filled.width, filled.height)];
    }];
}

@end
