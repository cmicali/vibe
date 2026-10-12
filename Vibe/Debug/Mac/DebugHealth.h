//
//  DebugHealth.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

@class MainPlayerController;

// The macOS side of the stress driver's oracles: dump_health gives it numbers
// to diff across a run, check_consistency a verdict at a single instant.

// Process and UI resource counts: memory footprint, threads, file
// descriptors, mach ports, window/view/layer counts, and the player's
// hosted audio units. Every field is for diffing between iteration N and
// N+k; none is meaningful in isolation.
//
// Reads the player's counts synchronously on its serial queue, so a wedged
// player queue makes this command time out. That is deliberate: the command
// channel runs on the main thread and would otherwise never notice.
NSString *VibeDebugHealthJSON(MainPlayerController *controller);

// The macOS-only half of the shared `check_consistency` verb, reached through
// the surface protocol's debugCheckPlatform: hook after VibeDebugCheckShared:
// the playlist table and its row indexes, the pitch fader, the scaled tick
// rate, and the rendered header labels and artwork ownership. Main thread
// only; returns how many checks it ran. See DebugConsistency.h for the
// render-lag caveat.
NSUInteger VibeDebugCheckMac(NSMutableArray<NSDictionary *> *violations,
                                        MainPlayerController *controller);

// Closes the file and polls pending work until zero or a deadline. Completion
// runs on main. Sample health after this to reduce in-flight allocation noise.
void VibeDebugQuiesce(MainPlayerController *controller, void (^completion)(NSString *responseJSON));

#endif
