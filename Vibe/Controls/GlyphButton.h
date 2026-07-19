//
//  GlyphButton.h
//  Vibe
//
//  Resolution-independent CAShapeLayer glyph buttons, in the same spirit as
//  EqualizerIndicatorView: geometry lives in a layer path and state changes
//  are color fades composited on the render server — no asset-catalog images.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GlyphButtonGlyph) {
    GlyphButtonGlyphPlay,
    GlyphButtonGlyphPause,
    GlyphButtonGlyphSkipNext,
    GlyphButtonGlyphPlaylist,   // four stacked lines (track-list icon)
    GlyphButtonGlyphClose,      // filled dot, traffic-light style
    GlyphButtonGlyphMinimize,   // filled dot, traffic-light style (matches close)
};

// Momentary push button: fades to its highlight color on hover and dims to
// half that opacity while pressed (tracking drag-off and drag-back), sends its
// action on mouse-up inside, and is click-through when disabled.
@interface GlyphButton : NSControl

@property (nonatomic) GlyphButtonGlyph glyph;

// Side of the centered square the glyph is drawn in. 0 (the default) means
// the full bounds; the close button uses this to shrink its dot.
@property (nonatomic) CGFloat glyphSize;

@property (nonatomic, strong) NSColor *glyphNormalColor;    // idle
@property (nonatomic, strong) NSColor *glyphHighlightColor; // hover (a press shows it at half alpha)
@property (nonatomic, strong) NSColor *glyphDisabledColor;

@end

NS_ASSUME_NONNULL_END
