//
//  NSImage+Util.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSImage (Util)

// The palette is applied OVER the sized configuration: a second
// imageWithSymbolConfiguration: would replace the first. A dynamic palette
// color stays dynamic.
+ (NSImage *)symbolNamed:(NSString *)name
               pointSize:(CGFloat)pointSize
                  weight:(NSFontWeight)weight
                 palette:(NSArray<NSColor *> *)palette
accessibilityDescription:(nullable NSString *)description;

// Runs draw in a fresh sRGB RGBA8 bitmap of `size` pixels (one point per
// pixel); nil when the rep or context cannot be built. Not lockFocus, whose
// rep takes the deepest screen's scale, nor a drawingHandler image, which
// re-renders per destination and yields no readable bitmap.
+ (nullable NSImage *)imageWithSize:(NSSize)size drawnBy:(void (NS_NOESCAPE ^ _Nonnull)(void))draw;

// nil on failure, never the full-size original: callers resize to shed its
// memory.
- (nullable NSImage *)resizedImage:(NSSize)newSize;

// The largest centered square; a square image is returned unchanged. Art's
// square frames aspect-fit, so a wide cover would otherwise letterbox. nil
// only if the crop cannot be rasterized.
- (nullable NSImage *)squareCroppedImage;

// VibeDominantColorOfImage (PlatformImage.h).
- (nullable NSColor *)dominantColor;
@end

NS_ASSUME_NONNULL_END
