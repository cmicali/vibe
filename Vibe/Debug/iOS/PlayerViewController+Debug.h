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

@class AudioWaveformCache;

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

- (AudioWaveformCache *)debugWaveformCache;

@end

#endif
