//
//  DownloadProgressRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

#include <math.h>

// Zero is initial status, not movement.
static inline BOOL VibeDownloadProgressIsMovement(float previousRawFraction,
                                                   float rawFraction) {
    return isfinite(rawFraction) && rawFraction > 0
            && rawFraction > previousRawFraction;
}

// An exact source silences the poll only while the file is dataless; a
// materialized sample is final even before that source unpublishes.
static inline BOOL VibeDownloadPollShouldPublish(BOOL dataless,
                                                 BOOL iCloudActive,
                                                 BOOL fileProviderActive) {
    return !dataless || (!iCloudActive && !fileProviderActive);
}
