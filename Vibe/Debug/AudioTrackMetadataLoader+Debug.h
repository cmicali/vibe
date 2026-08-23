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
// Fires before every off-lock scan-pick validation until explicitly cleared.
- (void)debugSetBeforeScanPickValidation:(nullable dispatch_block_t)block;
- (NSQualityOfService)debugLastScheduledParseQualityOfService;
- (NSQualityOfService)debugParseQualityOfServiceForTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END

#endif
