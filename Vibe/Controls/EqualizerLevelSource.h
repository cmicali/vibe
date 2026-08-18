//
//  EqualizerLevelSource.h
//  Vibe
//
//  The narrow boundary between the playing-row indicator and the playback
//  model that owns its audio levels. It lives beside the control so neither
//  platform's playback model has to import a view class merely to adopt the
//  protocol.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol EqualizerLevelSource <NSObject>

// Copies the latest coherent set of levels. A successful copy fills exactly
// `count` values in 0...1 and returns their nonzero sequence. NO leaves both
// outputs untouched.
//
// The sequence belongs to a source for its whole lifetime. It lets the snapshot
// poller, capped at 30 Hz, distinguish a new analysis result from a repeated read;
// only a new result can retarget the retained bars' explicit animations.
- (BOOL)copyEqualizerLevels:(float *)outLevels
                     count:(NSUInteger)count
                  sequence:(uint64_t *)outSequence;

// Declares whether this indicator is consuming levels. Calls are balanced per
// source: a source receives one NO for every YES, including when the source is
// replaced or the indicator is deallocated. A source can therefore count its
// consumers and leave production off at zero.
- (void)equalizerLevelsWanted:(BOOL)wanted;

@end

NS_ASSUME_NONNULL_END
