//
//  AudioLevelPublisher.h
//  Vibe
//
//  The coherent audio-thread to main-thread handoff of equalizer levels.
//

#import <Foundation/Foundation.h>

#import "AudioLevelMath.h"

NS_ASSUME_NONNULL_BEGIN

// One per player, for its life. Sessions come and go with the meter's
// installation; the sequence only moves forward.
@interface AudioLevelPublisher : NSObject

// One coherent snapshot. NO, `out` untouched, when the current session has
// published nothing. `sequence` (optional) identifies each publication.
- (BOOL)copyLevels:(float *)out
              count:(NSUInteger)count
           sequence:(nullable uint64_t *)sequence;

@end

NS_ASSUME_NONNULL_END
