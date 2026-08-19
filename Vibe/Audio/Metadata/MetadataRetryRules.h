//
//  MetadataRetryRules.h
//  Vibe
//

#import "AudioFileMaterializationCoordinator.h"

typedef NS_ENUM(NSUInteger, VibeMetadataMaterializationRetry) {
    VibeMetadataMaterializationRetryNone = 0,
    VibeMetadataMaterializationRetryAtCurrentRank,
    VibeMetadataMaterializationRetryDeferred,
    VibeMetadataMaterializationRetryDeferredAfterDelay,
};

// priorFailures excludes the result being judged. Yielding is not a file
// failure and never consumes the configured attempt budget.
static inline VibeMetadataMaterializationRetry
VibeMetadataMaterializationRetryForResult(
        VibeAudioFileMaterializationResult result,
        NSUInteger priorFailures,
        NSUInteger maximumAttempts) {
    if (result == VibeAudioFileMaterializationResultYielded) {
        return VibeMetadataMaterializationRetryAtCurrentRank;
    }
    if (result != VibeAudioFileMaterializationResultFailed
            && result != VibeAudioFileMaterializationResultAdmissionExhausted) {
        return VibeMetadataMaterializationRetryNone;
    }
    if (maximumAttempts > 0 && priorFailures < maximumAttempts - 1) {
        return result == VibeAudioFileMaterializationResultAdmissionExhausted
                ? VibeMetadataMaterializationRetryDeferredAfterDelay
                : VibeMetadataMaterializationRetryDeferred;
    }
    return VibeMetadataMaterializationRetryNone;
}

static inline NSUInteger VibeMetadataMaximumAttemptsForRetryCount(
        NSUInteger retryCount) {
    return retryCount == NSUIntegerMax ? NSUIntegerMax : retryCount + 1;
}

// Admission exhaustion is capacity pressure, not a file verdict. Give a live
// claim time to settle without allowing diagnostics to stretch a scan forever.
static inline NSTimeInterval VibeMetadataAdmissionRetryDelay(
        NSUInteger priorFailures) {
    const NSTimeInterval step = 0.25;
    const NSTimeInterval maximum = 2.0;
    if (priorFailures >= (NSUInteger)(maximum / step) - 1) {
        return maximum;
    }
    return step * (priorFailures + 1);
}

// didStartPlaying: can arrive on either side of an earlier Yielded callback.
// Every held delivery parks; hold release retries only a park for which a later
// priority load was requested.
typedef NS_ENUM(NSUInteger, VibeMetadataPriorityYieldAction) {
    VibeMetadataPriorityYieldActionClear = 0,
    VibeMetadataPriorityYieldActionRetry,
    VibeMetadataPriorityYieldActionPark,
};

static inline VibeMetadataPriorityYieldAction VibeMetadataPriorityActionForYield(
        BOOL laterLoadRequested,
        BOOL held,
        BOOL cancelled) {
    if (cancelled) {
        return VibeMetadataPriorityYieldActionClear;
    }
    if (held) {
        return VibeMetadataPriorityYieldActionPark;
    }
    return laterLoadRequested ? VibeMetadataPriorityYieldActionRetry
                              : VibeMetadataPriorityYieldActionClear;
}

static inline VibeMetadataPriorityYieldAction
VibeMetadataPriorityActionForHoldRelease(BOOL laterLoadRequested,
                                         BOOL cancelled) {
    return !cancelled && laterLoadRequested
            ? VibeMetadataPriorityYieldActionRetry
            : VibeMetadataPriorityYieldActionClear;
}
