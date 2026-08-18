//
//  MetadataRetryMath.h
//  Vibe
//


#import <Foundation/Foundation.h>

// AudioLoadingConfiguration states retries after the first attempt, while the
// cloud retry verdict takes the total number of allowed attempts.
static inline NSUInteger VibeMetadataMaximumAttemptsForRetryCount(
        NSUInteger retryCount) {
    return retryCount == NSUIntegerMax ? NSUIntegerMax : retryCount + 1;
}

// Admission exhaustion is a capacity verdict, not a file verdict. A bounded
// delay gives a running claim time to finish before this entry spends another
// attempt; the cap keeps a diagnostic retry count from stretching a sweep
// indefinitely.
static inline NSTimeInterval VibeMetadataAdmissionRetryDelay(
        NSUInteger priorFailures) {
    const NSTimeInterval step = 0.25;
    const NSTimeInterval maximum = 2.0;
    if (priorFailures >= (NSUInteger)(maximum / step) - 1) {
        return maximum;
    }
    return step * (priorFailures + 1);
}
