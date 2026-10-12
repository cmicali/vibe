//
//  AudioTrackMetadataLoader+Debug.h
//  Vibe
//
//  Visibility into one loader's materialization lanes. Implemented in
//  AudioTrackMetadataLoader+Debug.m.
//

#if DEBUG

#import "AudioTrackMetadataLoader.h"

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
// How the lane and the parse reach those debug-only ivars from their own files.
// The first needs _materializationLock held.
- (void)debugNoteScheduledParseQualityOfService:(NSQualityOfService)qualityOfService;
- (nullable dispatch_block_t)debugBeforeScanPickValidation;

@end

NS_ASSUME_NONNULL_END

#endif
