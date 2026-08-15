//
//  DebugInvariants.h
//  Vibe
//
//  The consistency checks that hold on both platforms, behind
//  VibeDebugPlayerSurface. `check_invariants` is these plus whatever the
//  platform adds through debugAppendPlatformInvariants:.
//
//  A violation is a statement about state that should never be legal. A few
//  checks compare published or rendered values against the state that should
//  have produced them, and those can lag by a runloop turn — callers must
//  re-check after a short settle and believe only what survives both samples,
//  which is what the stress driver does.
//

#if DEBUG

#import <Foundation/Foundation.h>
#import "DebugPlayerSurface.h"

NS_ASSUME_NONNULL_BEGIN

// Appends one entry per violation and returns how many checks ran.
NSUInteger VibeDebugAppendSharedInvariants(NSMutableArray<NSDictionary *> *violations,
                                           id<VibeDebugPlayerSurface> surface);

// Records one violation. Platform check sets use it too, so every entry has
// the same {"id", "detail"} shape.
void VibeDebugViolation(NSMutableArray<NSDictionary *> *violations, NSString *identifier,
                        NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

NS_ASSUME_NONNULL_END

#endif
