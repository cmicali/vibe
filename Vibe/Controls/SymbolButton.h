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

// Point size the symbol is configured at; it is drawn centered in the bounds,
// so the frame can be much larger than the icon (the transport buttons are
// 50pt frames around ~26pt symbols).
@property (nonatomic) CGFloat symbolPointSize;
@property (nonatomic) NSFontWeight symbolWeight;

@property (nonatomic, strong) NSColor *symbolNormalColor;    // idle
@property (nonatomic, strong) NSColor *symbolHighlightColor; // hover (a press shows it at half alpha)
@property (nonatomic, strong) NSColor *symbolDisabledColor;

@end

NS_ASSUME_NONNULL_END
