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

// A picture in place of the symbol — a theme's custom button image, drawn in
// its own colors rather than tinted, aspect-fit in the box the symbol glyph
// would fill. While set, the symbol and the three colors are ignored and the
// states fade the image's opacity by the same ratios the colors' alphas
// keep. nil returns to the symbol.
@property (nonatomic, strong, nullable) NSImage *image;

// Sets all three state colors from one resting color, keeping the factory
// ratios — hover brighter, disabled dimmer — so a theme picks one color and
// the states follow. Alpha is part of the pick.
- (void)setSymbolColorsFromRestingColor:(NSColor *)color;

// Point size the symbol is configured at — SF Symbol glyphs draw at roughly
// 0.8 times it. The icon is drawn centered in the bounds, so the frame can be
// much larger (the transport buttons are 50pt frames around 31pt-configured,
// ~25pt-drawn symbols).
@property (nonatomic) CGFloat symbolPointSize;
@property (nonatomic) NSFontWeight symbolWeight;

@property (nonatomic, strong) NSColor *symbolNormalColor;    // idle
@property (nonatomic, strong) NSColor *symbolHighlightColor; // hover (a press shows it at half alpha)
@property (nonatomic, strong) NSColor *symbolDisabledColor;

@end

NS_ASSUME_NONNULL_END
