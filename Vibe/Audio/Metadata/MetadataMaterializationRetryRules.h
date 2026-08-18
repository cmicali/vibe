//
//  MetadataMaterializationRetryRules.h
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

// didStartPlaying: can arrive on either side of an earlier Yielded callback.
// Every held delivery parks; the duplicate load call records the successful
// play edge, and hold release retries only a park carrying that marker.
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
