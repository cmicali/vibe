//
//  NowPlayingController+Debug.h
//  Vibe
//
//  Implemented beside the controller, whose publish state is private to it.
//

#if DEBUG

#import "NowPlayingController.h"

NS_ASSUME_NONNULL_BEGIN

@interface NowPlayingController (Debug)

// The source image of the published artwork (the track's art, its thumbnail
// or the shell's placeholder, by identity), or nil when none is published.
- (nullable VibeImage *)debugPublishedArtwork;

@end

NS_ASSUME_NONNULL_END

#endif
