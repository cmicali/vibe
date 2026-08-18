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
// VibeDebugPlayerSurface, which the state builder below reads through.
#import "DebugPlayerSurface.h"

@class AudioPlayer;

NS_ASSUME_NONNULL_BEGIN

// Shared transport, state, loading-configuration, fake-cloud and cache verbs.
NSArray<NSDictionary *> *VibeDebugCommonCommandTable(void);

// The three dump_state blocks both platforms answer identically — "player",
// "currentTrack" and "playlist" — built from the surface alone. Each platform
// adds its own "ui" block, and macOS extends "player" with the fields only it
// has (pitch, the FX flags, the output device). Returned mutable, and with
// mutable sub-dictionaries, for exactly that.
//
// It is shared because the two dumps had drifted into near-copies, the
// hundred-file truncation and its "… N more" included, and the stress oracles
// read these keys on both platforms.
NSMutableDictionary *VibeDebugCommonStateDictionary(id<VibeDebugPlayerSurface> surface);

// The player's state word — "playing", "paused" or "stopped". Loading reports
// isPlaying with a zero position and duration, so this reads "playing" during
// an in-flight open, as the transport control does.
NSString *VibeDebugPlayerStateName(AudioPlayer *player);

NS_ASSUME_NONNULL_END

#endif
