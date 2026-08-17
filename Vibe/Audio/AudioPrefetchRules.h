//
//  AudioPrefetchRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VibeAudioPrefetchRetirementPoint) {
    VibeAudioPrefetchAtPlaySubmission = 0,
    VibeAudioPrefetchAtPlaySettlement,
    VibeAudioPrefetchAtAbandonment,
};

static inline BOOL VibeAudioPrefetchShouldRetire(
        VibeAudioPrefetchRetirementPoint point,
        NSString *prefetchedPath,
        NSString *playPath) {
    switch (point) {
        case VibeAudioPrefetchAtPlaySubmission:
            return prefetchedPath && ![prefetchedPath isEqualToString:playPath];
        case VibeAudioPrefetchAtPlaySettlement:
            return [prefetchedPath isEqualToString:playPath];
        case VibeAudioPrefetchAtAbandonment:
            return YES;
    }
    return YES;
}
