//
//  DebugHealth.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

#import "DebugPlayerSurface.h"

NS_ASSUME_NONNULL_BEGIN

// The stress driver's oracles, on both platforms: dump_health gives it numbers
// to diff across a run, check_consistency (DebugConsistency.h) a verdict at a
// single instant.

// dump_health's blocks beside "ok" and "process": the UI's resource counts,
// the app's, its pending work, and the materialization lanes. Every field is
// for diffing between iteration N and N+k; none is meaningful in isolation.
// The surface gives the UI block and its platform's extra app and pending
// fields.
//
// Reads the player's counts synchronously on its serial queue, so a wedged
// player queue makes this command time out. That is deliberate: the command
// channel runs on the main thread and would otherwise never notice.
NSDictionary *VibeDebugHealthExtras(id<VibeDebugPlayerSurface> surface);

// Closes the file and polls pending work until zero or a deadline. Completion
// runs on main. Sample health after this to reduce in-flight allocation noise.
void VibeDebugQuiesce(id<VibeDebugPlayerSurface> surface, void (^completion)(NSString *responseJSON));

NS_ASSUME_NONNULL_END

#endif
