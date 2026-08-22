//
//  NSImage+Util.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSImage (Util)

// Runs draw inside a fresh explicit-sRGB RGBA8 bitmap context of `size`
// pixels (one point per pixel) and returns the image wrapping that bitmap,
// or nil when the rep or context cannot be built. This — not lockFocus,
// which is soft-deprecated and whose backing rep picks up the deepest
// screen's scale, and not imageWithSize:flipped:drawingHandler:, whose
// deferred handler re-renders per destination and yields no readable bitmap
// — is the one home of the rep-retagging ballet shared by resizedImage:,
// the dock icon, and the drag label.
+ (nullable NSImage *)imageWithSize:(NSSize)size drawnBy:(void (NS_NOESCAPE ^ _Nonnull)(void))draw;

// Redraws the image at newSize into an sRGB bitmap. It returns nil if the
// bitmap or its drawing context cannot be created, and never falls back to the
// full-size original, because callers resize precisely to shed its memory.
- (nullable NSImage *)resizedImage:(NSSize)newSize;

// The largest centered square of the image, redrawn into an sRGB bitmap.
// An already-square image is returned unchanged, so the common case costs
// nothing. Album art is displayed and composed in square frames — the header
// view, the dock tile — which all aspect-*fit*, so a wide or tall cover would
// otherwise letterbox inside them. Returns nil only if the crop cannot be
// rasterized.
- (nullable NSImage *)squareCroppedImage;

// The image's dominant color, for tinting a backdrop to match album art.
// A thin forward to PlatformImage.h's VibeDominantColorOfImage, which both
// platforms share; the rules and the cost are documented there. It stays a
// category because that is how a mac call site asks an NSImage for it.
- (nullable NSColor *)dominantColor;
@end
