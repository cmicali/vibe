//
//  DebugConsistency.h
//  Vibe
//
//  The consistency checks that hold on both platforms; check_consistency adds
//  the platform's through debugCheckPlatform:. A violation is state that
//  should never be legal, but a check comparing a published or rendered value
//  against its source can lag a run-loop turn: believe only what survives a
//  re-check after a short settle, as the stress driver does.
//

#if DEBUG

#import <Foundation/Foundation.h>
#import "DebugPlayerSurface.h"

NS_ASSUME_NONNULL_BEGIN

// Appends one entry per violation and returns how many checks ran.
NSUInteger VibeDebugCheckShared(NSMutableArray<NSDictionary *> *violations,
                                id<VibeDebugPlayerSurface> surface);

// Platform checks use it too, so every entry has the same {"id", "detail"}
// shape.
void VibeDebugViolation(NSMutableArray<NSDictionary *> *violations, NSString *identifier,
                        NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

NS_ASSUME_NONNULL_END

#endif
