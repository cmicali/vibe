//
//  PlayerViewController+Debug.h
//  Vibe (iOS)
//
//  What the debug channel needs from the card; RootViewController+Debug
//  composes it into the surface. The implementation reaches the card's state
//  through PlayerViewControllerInternal.h.
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

// The pager's art window and each page's art state: on screen, "not decoded
// yet" and "no art" are both the placeholder.
- (NSDictionary *)debugArtDictionary;

// Live regressions for neighbor preparation: refresh, transition, artwork,
// widget, interaction, work and work_inputs (ios-verbs.md).
- (void)debugCheckWaveformPreparation:(NSString *)scenario
                          completion:(void (^)(NSDictionary *result))completion;

// Through the scrubber's didSeek path, so the seek-in-flight guard behaves as
// on a real drag's release.
- (void)debugSeekToProgress:(float)progress;

// Through the delegate callback a released pinch takes, so the fan-out across
// pages and the persistence are a real gesture's. What is drawn is clamped
// further by each view's geometry; read back waveformZoomEffective.
- (void)debugSetWaveformZoom:(CGFloat)fraction;

// Draws the route indicator as `kind` with no session behind it, the only way
// to see the off-device renderings in the simulator. The model is untouched;
// the next real route event overwrites it.
- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(nullable NSString *)name;

- (AudioWaveformCache *)debugWaveformCache;

@end

NS_ASSUME_NONNULL_END

#endif
