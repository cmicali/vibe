//
//  DebugCommonVerbs.h
//  Vibe
//
//  The verbs both platforms answer identically, written once against
//  VibeDebugPlayerSurface. Each platform's table is this one plus its own; the
//  split is by what the verb needs, not by what it is about — a verb lands
//  here only when the surface protocol is enough to implement it.
//

#if DEBUG

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// dump_state, dump_now_playing, play_pause, next, previous, seek, open,
// clear_caches.
NSArray<NSDictionary *> *VibeDebugCommonCommandTable(void);

NS_ASSUME_NONNULL_END

#endif
