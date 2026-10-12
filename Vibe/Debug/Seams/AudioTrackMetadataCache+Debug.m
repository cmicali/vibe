//
//  AudioTrackMetadataCache+Debug.m
//  Vibe
//

#import "AudioTrackMetadataCache+Debug.h"

#if DEBUG

#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataLoader+Debug.h"
#import "AudioFileMaterializationCoordinator.h"

@implementation AudioTrackMetadataCache (DebugMaterialization)

- (NSUInteger)debugPendingBackgroundMaterializationCount {
    return [_currentLoader debugPendingBackgroundMaterializationCount];
}

- (BOOL)debugBackgroundMaterializationHeld {
    // Stopped and settled means no foreground claims, so this must read NO.
    return [AudioFileMaterializationCoordinator.sharedCoordinator
            isForegroundTransferActive];
}

- (NSDictionary *)debugPriorityLaneState {
    return [_currentLoader debugPriorityLaneState] ?: @{};
}

- (NSDictionary *)debugScanLaneState {
    return [_currentLoader debugScanLaneState] ?: @{};
}

@end

#endif
