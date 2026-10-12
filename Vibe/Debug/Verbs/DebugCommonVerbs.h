//
//  DebugCommonVerbs.h
//  Vibe
//
//  The verbs both platforms answer identically, written once against
//  VibeDebugPlayerSurface. A verb lands here only when the surface is enough
//  to implement it; each platform's table is this one plus its own. The verbs
//  are split by topic, one file each.
//

#if DEBUG

#import <Foundation/Foundation.h>
#import "DebugPlayerSurface.h"

@class AudioPlayer;

NS_ASSUME_NONNULL_BEGIN

// DebugCommonVerbs.m's state and transport verbs, then each topic's below.
NSArray<NSDictionary *> *VibeDebugCommonCommandTable(void);

// The topic tables, which only the common table reads.
NSArray<NSDictionary *> *VibeDebugStallVerbs(void);   // DebugStallVerbs.m
NSArray<NSDictionary *> *VibeDebugAudioVerbs(void);   // DebugAudioVerbs.m
NSArray<NSDictionary *> *VibeDebugLoadingVerbs(void); // DebugLoadingVerbs.m

// dump_state's "player", "currentTrack" and "playlist" blocks, shared because
// the stress oracles read these keys on both platforms. Returned mutable, with
// mutable sub-dictionaries, so each platform can add its "ui" block and macOS
// its own "player" fields.
NSMutableDictionary *VibeDebugCommonStateDictionary(id<VibeDebugPlayerSurface> surface);

// "playing", "paused" or "stopped". Reads "playing" during an in-flight open,
// as the transport control does, since loading reports isPlaying.
NSString *VibeDebugPlayerStateName(AudioPlayer *player);

NS_ASSUME_NONNULL_END

#endif
