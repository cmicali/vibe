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
