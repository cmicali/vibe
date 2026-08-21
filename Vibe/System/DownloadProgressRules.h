//
//  DownloadProgressRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

#include <math.h>

// Zero is an initial status, not evidence that bytes moved. Only a finite,
// strictly positive increase advances transfer liveness.
static inline BOOL VibeDownloadProgressIsMovement(float previousRawFraction,
                                                   float rawFraction) {
    return isfinite(rawFraction) && rawFraction > 0
            && rawFraction > previousRawFraction;
}

// Exact provider percentages silence the allocated-size heuristic only while
// the file remains dataless. A materialized filesystem sample is final truth
// even if an exact source has not unpublished yet.
static inline BOOL VibeDownloadPollShouldPublish(BOOL dataless,
                                                 BOOL iCloudActive,
                                                 BOOL fileProviderActive) {
    return !dataless || (!iCloudActive && !fileProviderActive);
}
