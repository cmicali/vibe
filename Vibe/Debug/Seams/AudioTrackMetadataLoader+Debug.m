//
//  AudioTrackMetadataLoader+Debug.m
//  Vibe
//

#import "AudioTrackMetadataLoader+Debug.h"

#if DEBUG

#import "AudioFileMaterializationCoordinator.h"
#import "MetadataScanEntry.h"

@implementation AudioTrackMetadataLoader (Debug)

- (NSUInteger)debugPendingBackgroundMaterializationCount {
    os_unfair_lock_lock(&_materializationLock);
    NSUInteger count = _pendingMaterializations.count + _delayedScanRetryEntries.count
            + (_scanMaterializationInFlight ? 1 : 0)
            + (_priorityMaterializationInFlight ? 1 : 0);
    os_unfair_lock_unlock(&_materializationLock);
    return count;
}

- (NSDictionary *)debugPriorityLaneState {
    BOOL held = [_materializationCoordinator isForegroundTransferActive];
    NSMutableArray *pendingNames = [NSMutableArray array];
    NSUInteger yielded = 0;
    NSUInteger tokens;
    BOOL inFlight;
    os_unfair_lock_lock(&_materializationLock);
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if ([self priorityMarkForEntryLocked:entry]) {
            [pendingNames addObject:entry.url.lastPathComponent ?: @"?"];
            if (entry.yieldedUnderHold) {
                yielded++;
            }
        }
    }
    tokens = _priorityMaterializationToken != nil ? 1 : 0;
    inFlight = _priorityMaterializationInFlight;
    os_unfair_lock_unlock(&_materializationLock);
    return @{@"pending": pendingNames,
             @"yieldedUnderHold": @(yielded),
             @"inFlight": @(inFlight),
             @"liveTokens": @(tokens),
             @"held": @(held)};
}

- (NSDictionary *)debugScanLaneState {
    NSMutableArray<NSString *> *pendingNames = [NSMutableArray array];
    NSMutableArray<NSString *> *delayedNames = [NSMutableArray array];
    BOOL inFlight;
    NSUInteger tokens;
    BOOL stageOneFinished;
    BOOL gatedRepickPending;
    os_unfair_lock_lock(&_materializationLock);
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (![self priorityMarkForEntryLocked:entry]) {
            [pendingNames addObject:entry.url.lastPathComponent ?: @"?"];
        }
    }
    for (MetadataScanEntry *entry in _delayedScanRetryEntries) {
        if (![self priorityMarkForEntryLocked:entry]) {
            [delayedNames addObject:entry.url.lastPathComponent ?: @"?"];
        }
    }
    inFlight = _scanMaterializationInFlight;
    tokens = _scanMaterializationToken != nil ? 1 : 0;
    stageOneFinished = _stageOneFinished;
    gatedRepickPending = _gatedRepickPending;
    os_unfair_lock_unlock(&_materializationLock);
    return @{@"pending": pendingNames,
             @"delayed": delayedNames,
             @"inFlight": @(inFlight),
             @"liveTokens": @(tokens),
             @"stageOneFinished": @(stageOneFinished),
             @"gatedRepickPending": @(gatedRepickPending)};
}

- (void)debugSetBeforeScanPickValidation:(dispatch_block_t)block {
    os_unfair_lock_lock(&_materializationLock);
    _debugBeforeScanPickValidation = [block copy];
    os_unfair_lock_unlock(&_materializationLock);
}

// _materializationLock held.
- (void)debugNoteScheduledParseQualityOfService:(NSQualityOfService)qualityOfService {
    _debugLastScheduledParseQualityOfService = qualityOfService;
}

- (dispatch_block_t)debugBeforeScanPickValidation {
    os_unfair_lock_lock(&_materializationLock);
    dispatch_block_t block = [_debugBeforeScanPickValidation copy];
    os_unfair_lock_unlock(&_materializationLock);
    return block;
}

- (NSQualityOfService)debugLastScheduledParseQualityOfService {
    os_unfair_lock_lock(&_materializationLock);
    NSQualityOfService qualityOfService = _debugLastScheduledParseQualityOfService;
    os_unfair_lock_unlock(&_materializationLock);
    return qualityOfService;
}

- (NSQualityOfService)debugParseQualityOfServiceForTrack:(AudioTrack *)track {
    os_unfair_lock_lock(&_materializationLock);
    NSOperation *operation = [_parseOperationsByTrack objectForKey:track];
    NSQualityOfService qualityOfService = operation
            ? operation.qualityOfService : NSQualityOfServiceDefault;
    os_unfair_lock_unlock(&_materializationLock);
    return qualityOfService;
}

@end

#endif
