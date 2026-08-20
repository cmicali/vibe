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

// What happens to a priority record whose materialization came back Yielded.
// A yield only ever means "the foreground hold was up when the coordinator
// judged this request", so while the hold still reads up the record WAITS —
// requeued, marked, not re-picked until the release edge, or the pick/submit/
// yield cycle spins against the synchronous yield. At the release edge (or a
// yield delivered after it — the two orders of the same race), the file is
// probed: local means the settled open downloaded it, so the record retries
// and its parse lands immediately; still dataless means the open failed, and
// chasing it would spend the provider's next slot re-downloading a file
// behind a terminal error the user is looking at — the record DEMOTES to an
// ordinary sweep candidate at its rank. Yielding never spends the budget.
typedef NS_ENUM(NSUInteger, VibeMetadataPriorityYieldOutcome) {
    VibeMetadataPriorityYieldWait = 0,
    VibeMetadataPriorityYieldRetry,
    VibeMetadataPriorityYieldDemote,
};

static inline VibeMetadataPriorityYieldOutcome VibeMetadataPriorityAfterYield(
        BOOL held, BOOL local) {
    if (held) {
        return VibeMetadataPriorityYieldWait;
    }
    return local ? VibeMetadataPriorityYieldRetry
                 : VibeMetadataPriorityYieldDemote;
}
