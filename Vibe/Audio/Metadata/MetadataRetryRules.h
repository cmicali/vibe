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

// A failed or capacity-exhausted priority materialization retries within the
// same bounded per-path budget the scan spends — the priority track is the one
// the user is hearing, and under a churning provider a cancellation is
// transient. Without this, one failed run left the playing track's tags
// waiting on the background sweep reaching its row.
static inline BOOL VibeMetadataPriorityRetryAfterFailure(
        NSUInteger priorFailures,
        NSUInteger maximumAttempts,
        BOOL cancelled) {
    return !cancelled && maximumAttempts > 0 && priorFailures < maximumAttempts - 1;
}

// A Yielded priority delivery only ever means "the foreground hold was up when
// the coordinator judged this request" — so it parks while the hold still
// reads up and retries the moment it does not, and hold release retries EVERY
// park. Both halves are earned: the winning play of a rapid track-change storm
// produces exactly ONE lifecycle edge, and its Yielded delivery can marshal to
// main on either side of the release — a rule that required a later-load
// marker dropped that one request in both interleavings, and the screen played
// on with no tags. A stale park's retried parse is a cheap win (its row fills
// in), bounded by the park set and the shared failure budget.
typedef NS_ENUM(NSUInteger, VibeMetadataPriorityYieldAction) {
    VibeMetadataPriorityYieldActionClear = 0,
    VibeMetadataPriorityYieldActionRetry,
    VibeMetadataPriorityYieldActionPark,
};

static inline VibeMetadataPriorityYieldAction VibeMetadataPriorityActionForYield(
        BOOL held,
        BOOL cancelled) {
    if (cancelled) {
        return VibeMetadataPriorityYieldActionClear;
    }
    return held ? VibeMetadataPriorityYieldActionPark
                : VibeMetadataPriorityYieldActionRetry;
}

static inline VibeMetadataPriorityYieldAction
VibeMetadataPriorityActionForHoldRelease(BOOL cancelled) {
    return cancelled ? VibeMetadataPriorityYieldActionClear
                     : VibeMetadataPriorityYieldActionRetry;
}
