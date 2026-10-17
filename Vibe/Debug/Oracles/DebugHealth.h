//
//  DebugHealth.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

#import <QuartzCore/QuartzCore.h>
#import "DebugPlayerSurface.h"

NS_ASSUME_NONNULL_BEGIN

// The stress driver's oracles, on both platforms: dump_health gives it numbers
// to diff across a run, check_consistency (DebugConsistency.h) a verdict at a
// single instant.

// Process and UI resource counts: memory footprint, threads, file
// descriptors, mach ports, window/view/layer counts, and the player's
// hosted audio units. Every field is for diffing between iteration N and
// N+k; none is meaningful in isolation. The surface gives the UI block and
// its platform's extra app and pending fields.
//
// Reads the player's counts synchronously on its serial queue, so a wedged
// player queue makes this command time out. That is deliberate: the command
// channel runs on the main thread and would otherwise never notice.
NSString *VibeDebugHealthJSON(id<VibeDebugPlayerSurface> surface);

// Closes the file and polls pending work until zero or a deadline. Completion
// runs on main. Sample health after this to reduce in-flight allocation noise.
void VibeDebugQuiesce(id<VibeDebugPlayerSurface> surface, void (^completion)(NSString *responseJSON));

// Layers under and including layer, for each platform's UI block.
NSUInteger VibeDebugLayerCount(CALayer *layer);

NS_ASSUME_NONNULL_END

#endif
