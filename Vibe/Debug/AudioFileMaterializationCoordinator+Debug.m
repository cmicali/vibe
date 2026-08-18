//
//  AudioFileMaterializationCoordinator+Debug.m
//  Vibe
//

#import "AudioFileMaterializationCoordinator+Debug.h"

#if DEBUG

#import "AudioFileMaterializationCoordinatorInternal.h"

@implementation AudioFileMaterializationCoordinator (Debug)

- (NSDictionary<NSString *, NSNumber *> *)debugState {
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [self stateSnapshotForTesting];
    return @{
        @"claims": @(snapshot.claimCount),
        @"waiters": @(snapshot.waiterCount),
        @"interactiveRunning": @(snapshot.interactiveRunningCount),
        @"backgroundRunning": @(snapshot.backgroundRunningCount),
        @"interactivePending": @(snapshot.interactivePendingCount),
        @"backgroundPending": @(snapshot.backgroundPendingCount),
        @"metadataHolds": @(snapshot.metadataHoldCount),
    };
}

@end

#endif
