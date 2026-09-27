//
//  AudioTrackMetadataLoader+Debug.h
//  Vibe
//
//  Declaration-only visibility into one loader's materialization lanes. The
//  implementation stays beside the lane state in AudioTrackMetadataLoader.m.
//

#if DEBUG

#import "AudioTrackMetadataLoaderInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataLoader (Debug)

- (NSUInteger)debugPendingBackgroundMaterializationCount;
- (NSDictionary *)debugPriorityLaneState;
- (NSDictionary *)debugScanLaneState;

// Test seams for AudioTrackMetadataLoaderTests. Their implementations are
// DEBUG-only, so declaring them in the shipping Internal.h would leave them
// unimplemented in Release.
// Fires before every off-lock scan-pick validation until cleared.
- (void)debugSetBeforeScanPickValidation:(nullable dispatch_block_t)block;
- (NSQualityOfService)debugLastScheduledParseQualityOfService;
- (NSQualityOfService)debugParseQualityOfServiceForTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END

#endif
