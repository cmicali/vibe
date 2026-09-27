//
//  VibeLinkLabel.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A label with one clickable range, hit-tested against the link's glyphs: a
// selectable NSTextField would make the full-width strip an I-beam that
// swallows the window's background drag. With no link it is an ordinary,
// unfocusable, hit-transparent label.
@interface VibeLinkLabel : NSTextField

// Set both, or neither. linkRange indexes attributedStringValue, so assign the
// attributed string before relying on the geometry.
@property (nonatomic, copy, nullable) NSURL *linkURL;
@property (nonatomic) NSRange linkRange;

// NSZeroRect with no link. The pointer, the focus ring and the accessibility
// frame all use it, so they cannot cover different pixels.
@property (nonatomic, readonly) NSRect linkRect;

// The one activation funnel; tests override it so they need not open Mail.
- (void)activateLink;

@end

NS_ASSUME_NONNULL_END
