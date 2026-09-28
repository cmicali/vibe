//
//  SymbolButton.h
//  Vibe
//
//  A borderless icon button drawing an SF Symbol. The symbol is rendered into
//  an alpha mask over a flat color layer, so that state changes stay color
//  fades composited on the render server. No asset-catalog images are involved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A momentary push button. It fades to its highlight color on hover and dims
// to half that opacity while pressed, tracking a drag off and back. It sends
// its action on a mouse-up inside, and is click-through when disabled.
@interface SymbolButton : NSControl

// SF Symbol name (e.g. "play.fill"). Swapping it redraws instantly, no fade.
@property (nonatomic, copy) NSString *symbolName;

// Replaces the symbol, drawn in its own colors, aspect-fit in the glyph's box.
// While set the colors are ignored and the states fade its opacity by the same
// ratios. nil returns to the symbol.
@property (nonatomic, strong, nullable) NSImage *image;

// All three state colors from one resting color, alpha included, by the
// factory ratios.
- (void)setSymbolColorsFromRestingColor:(NSColor *)color;

// Glyphs draw at roughly 0.8 times it, centered in the bounds.
@property (nonatomic) CGFloat symbolPointSize;

@property (nonatomic, strong) NSColor *symbolNormalColor;    // idle
@property (nonatomic, strong) NSColor *symbolHighlightColor; // hover (a press shows it at half alpha)

@end

NS_ASSUME_NONNULL_END
