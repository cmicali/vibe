//
//  AudioLevelPublisher.h
//  Vibe
//
//  The coherent audio-thread to main-thread renderer handoff for equalizer
//  levels.
//

#import <Foundation/Foundation.h>

#import "AudioLevelMath.h"

NS_ASSUME_NONNULL_BEGIN

// AudioPlayer owns one for its lifetime. Tap sessions come and go as demand or
// the engine graph changes, while this object's sequence only moves forward.
@interface AudioLevelPublisher : NSObject

// Fills `out` atomically as one snapshot. NO leaves every output untouched and
// means there is no publication from the current tap session. `sequence` is
// optional and identifies each publication for the snapshot poller.
- (BOOL)copyLevels:(float *)out
              count:(NSUInteger)count
           sequence:(nullable uint64_t *)sequence;

@end

NS_ASSUME_NONNULL_END
