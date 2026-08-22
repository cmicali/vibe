//
//  PlayerViewController+Debug.h
//  Vibe (iOS)
//
//  What the debug command channel needs from the card: its chrome's rendered
//  state, the pager's art window, and the scrubber's seek path. The shell's
//  RootViewController+Debug is what adopts VibeDebugPlayerSurface and composes
//  this with the model's own debug surface; nothing here answers a verb on its
//  own.
//
//  The implementation reaches the card's state through
//  PlayerViewControllerInternal.h, the same production surface the
//  controller's own categories share — the dependency runs this way round, so
//  no shipping file carries a declaration for a tool that does not ship.
//
//  Debug builds only.
//

#if DEBUG

#import "PlayerViewController.h"
#import "OutputRouteRules.h"

@class AudioWaveformCache;

NS_ASSUME_NONNULL_BEGIN

@interface PlayerViewController (Debug)

// The chrome as drawn: the time labels' text, the glyph's visibility, and the
// waveform's progress, bake and scrub state.
- (NSDictionary *)debugChromeDictionary;

// The pager's art window and each page's art state. Nothing on screen tells
// "not decoded yet" from "no art at all" — both are the placeholder — so this
// is the only way to see whether the prefetch is keeping up.
- (NSDictionary *)debugArtDictionary;

// Through the scrubber's didSeek path, so the seek-in-flight guard behaves
// exactly as a real drag's release does.
- (void)debugSeekToProgress:(float)progress;

// The waveform zoom, through the same delegate callback a released pinch
// takes: the fan-out across pages and the persistence behave as a real
// gesture's. What is DRAWN is clamped further by each view's own geometry —
// read waveformZoomEffective back to see whether that happened.
- (void)debugSetWaveformZoom:(CGFloat)fraction;

// Draws the route indicator as a given route, with no session behind it. The
// simulator only ever reports the built-in speaker, so this is the only way to
// see the Bluetooth, AirPlay and CarPlay renderings at all — the model is
// untouched, and the next real route event overwrites this.
- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(nullable NSString *)name;

- (AudioWaveformCache *)debugWaveformCache;

@end

NS_ASSUME_NONNULL_END

#endif
