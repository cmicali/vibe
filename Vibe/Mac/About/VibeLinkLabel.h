//
//  VibeLinkLabel.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A label with one clickable range. A selectable NSTextField would give links
// for free, but these labels span the window's full width while their text is
// centered and short, so selectability would turn a full-width strip into an
// I-beam that also swallows the window's background drag. This hit-tests the
// link's own glyphs instead: only those characters take the click, the
// pointing-hand cursor and the focus ring, and the rest of the label stays
// transparent.
//
// With no link set it is an ordinary label: not focusable, not an
// accessibility link, and hit-test transparent everywhere.
@interface VibeLinkLabel : NSTextField

// Set both, or neither. linkRange indexes attributedStringValue, so assign the
// attributed string before relying on the geometry.
@property (nonatomic, copy, nullable) NSURL *linkURL;
@property (nonatomic) NSRange linkRange;

// The link's glyph rect in this label's own coordinates, NSZeroRect with no
// link. The pointer, the focus ring and the accessibility frame all use it, so
// the three cannot cover different pixels.
@property (nonatomic, readonly) NSRect linkRect;

// The one activation funnel: the click, Return/Space, and the accessibility
// press all land here. Overridden by tests so they need not open Mail.
- (void)activateLink;

@end

NS_ASSUME_NONNULL_END
