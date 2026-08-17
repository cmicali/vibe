//
//  CloudMetadataRetryRules.h
//  Vibe
//
//  What the metadata cloud lane does with a failed materialization. Its own
//  foreground-open hold is requeued where it was, because nothing went wrong.
//  Anything else is a transient failure with a small attempt budget, requeued
//  behind every other track so one bad file cannot monopolize the serial lane.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Total materialization attempts for one track in one sweep, hold
// cancellations excluded. Three, matching the folder-art read-failure budget:
// enough to ride out a provider hiccup, few enough that a dead file costs a
// bounded number of transfers.
static const NSUInteger kVibeCloudMetadataMaxAttempts = 3;

typedef NS_ENUM(NSInteger, VibeCloudMetadataRetry) {
    // Out of attempts, or nothing left worth trying. The row keeps its
    // filename fallback until a later explicit scan re-queues the playlist.
    VibeCloudMetadataRetryNone = 0,
    // The foreground hold cancelled this transfer, so the track never had its
    // turn. Requeue at its current rank; the hold suspends the lane before it
    // cancels, so the replacement cannot start until the hold lifts.
    VibeCloudMetadataRetryAtCurrentRank,
    // A real failure with attempts left. Requeue at the bottom of the lane so
    // every track that has not tried yet goes first.
    VibeCloudMetadataRetryDeferred,
};

// TRAP: the hold verdict depends on CloudFileMaterializer reporting *every*
// cancellation as VibeMaterializationCancelledError — NSCocoaErrorDomain /
// NSUserCancelledError, which is also what NSFileCoordinator's own -cancel
// surfaces. If that class ever grew a second cancellation spelling
// (NSURLErrorCancelled, POSIX ECANCELED), a hold-cancelled track would silently
// take the attempt-spending path instead of its free requeue.
static inline BOOL VibeCloudMetadataFailureIsHoldCancellation(
        NSError *_Nullable error,
        NSUInteger preparedHoldGeneration,
        NSUInteger currentHoldGeneration) {
    return preparedHoldGeneration != currentHoldGeneration
            && [error.domain isEqualToString:NSCocoaErrorDomain]
            && error.code == NSUserCancelledError;
}

// priorAttempts counts this track's earlier *failures*, hold cancellations
// excluded — a hold spends no budget, because the transfer was cancelled on the
// app's own initiative rather than by anything about the file.
static inline VibeCloudMetadataRetry VibeCloudMetadataRetryForMaterializationFailure(
        NSError *_Nullable error,
        NSUInteger preparedHoldGeneration,
        NSUInteger currentHoldGeneration,
        NSUInteger priorAttempts,
        NSUInteger maximumAttempts) {
    if (VibeCloudMetadataFailureIsHoldCancellation(error, preparedHoldGeneration,
                                                   currentHoldGeneration)) {
        return VibeCloudMetadataRetryAtCurrentRank;
    }
    // priorAttempts does not yet include the failure being judged, so the
    // budget is spent when the one after it would be the (maximum + 1)th.
    return (priorAttempts + 1 < maximumAttempts) ? VibeCloudMetadataRetryDeferred
                                                  : VibeCloudMetadataRetryNone;
}

NS_ASSUME_NONNULL_END
