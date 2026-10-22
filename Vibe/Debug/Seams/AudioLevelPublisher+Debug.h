//
//  AudioLevelPublisher+Debug.h
//  Vibe
//
//  The publisher's counters, for dump_equalizer through AudioPlayer's
//  debugEqualizerState. Implemented in AudioLevelPublisher+Debug.m.
//

#import "AudioLevelPublisher.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioLevelPublisher (Debug)
- (NSDictionary<NSString *, NSNumber *> *)debugState;
@end

NS_ASSUME_NONNULL_END
