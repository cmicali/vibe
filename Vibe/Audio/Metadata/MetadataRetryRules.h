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
// A yield means dataless metadata was stopped by the foreground rule: the hold
// was active at classification, or its same-path foreground waiter departed
// while classification was outstanding. While the hold remains, a
// still-dataless record WAITS: re-picking would install a fresh Probing claim,
// occupy a bounded probe slot, repeat the filesystem probe, and yield when the
// result lands. At the release edge (or a yield delivered after it — the two
// orders of the same race), the file is probed: local means the settled open
// downloaded it, so the record retries and its parse lands immediately; still
// dataless means the open failed, and chasing it would spend the provider's
// next slot re-downloading a file behind a terminal error the user is looking
// at — the record DEMOTES to an ordinary sweep candidate at its rank. Yielding
// never spends the budget.
typedef NS_ENUM(NSUInteger, VibeMetadataPriorityYieldOutcome) {
    VibeMetadataPriorityYieldWait = 0,
    VibeMetadataPriorityYieldRetry,
    VibeMetadataPriorityYieldDemote,
};

static inline VibeMetadataPriorityYieldOutcome VibeMetadataPriorityAfterYield(
        BOOL held, BOOL local) {
    // A local file retries even while the rule holds: its parse starts no
    // transfer, and waiting it out costs the now-playing tags the length of
    // whatever the foreground is still downloading — measured, a successor's
    // prefetch held the current track's art hostage for its whole transfer.
    // Only a still-dataless record waits, and only a settled foreground can
    // demote it: mid-hold the open that would make it local is still running.
    if (local) {
        return VibeMetadataPriorityYieldRetry;
    }
    return held ? VibeMetadataPriorityYieldWait
                : VibeMetadataPriorityYieldDemote;
}
