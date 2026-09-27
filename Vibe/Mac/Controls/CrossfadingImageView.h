//
//  CrossfadingImageView.h
//  Vibe
//

#import <AppKit/AppKit.h>

// Art crossfade timing, shared with the header tint wash so both fade on the
// same clock.
extern const NSTimeInterval kVibeArtCrossfadeDuration;

// ArtworkImageView's base. setImage: cross-fades; opted out of drag-and-drop
// so file drops fall through to the window.
@interface CrossfadingImageView : NSImageView

@end
