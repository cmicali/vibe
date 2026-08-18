//
//  ForegroundContentHoldRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

// A release belongs to one play submission. Track and URL identity cannot
// answer this because replaying the same row preserves both.
static inline BOOL VibeForegroundContentHoldMayRelease(
        NSUInteger owningGeneration,
        NSUInteger newestGeneration) {
    return owningGeneration == newestGeneration;
}
