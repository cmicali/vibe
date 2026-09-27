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

// priorFailures excludes the result being judged. A yield spends nothing.
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

// Capacity pressure, not a file verdict: a short, capped backoff.
static inline NSTimeInterval VibeMetadataAdmissionRetryDelay(
        NSUInteger priorFailures) {
    const NSTimeInterval step = 0.25;
    const NSTimeInterval maximum = 2.0;
    if (priorFailures >= (NSUInteger)(maximum / step) - 1) {
        return maximum;
    }
    return step * (priorFailures + 1);
}

// A priority record's Yielded result. A local file retries at once, hold or
// not: its parse starts no transfer, and waiting cost the now-playing tags a
// successor prefetch's whole download. A still-dataless record waits while
// the hold stands (a re-pick would burn a probe slot and yield again) and
// demotes to the sweep once it lifts: the open failed, and re-downloading
// behind its error is the sweep's call, at its rank.
typedef NS_ENUM(NSUInteger, VibeMetadataPriorityYieldOutcome) {
    VibeMetadataPriorityYieldWait = 0,
    VibeMetadataPriorityYieldRetry,
    VibeMetadataPriorityYieldDemote,
};

static inline VibeMetadataPriorityYieldOutcome VibeMetadataPriorityAfterYield(
        BOOL held, BOOL local) {
    if (local) {
        return VibeMetadataPriorityYieldRetry;
    }
    return held ? VibeMetadataPriorityYieldWait
                : VibeMetadataPriorityYieldDemote;
}
