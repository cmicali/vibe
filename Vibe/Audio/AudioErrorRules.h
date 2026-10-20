//
//  AudioErrorRules.h
//  Vibe
//
//  Which play failures a shell shows: a function of the error alone, so both
//  screens agree and it is tested without a player. The line a shown failure
//  reads as is VibeStatusForPlayError (Common/StringRules.h).
//

#import <Foundation/Foundation.h>
#import "AudioError.h"

NS_ASSUME_NONNULL_BEGIN

static inline BOOL VibePlayErrorIsBenign(NSError *error) {
    return [error.domain isEqualToString:kVibeAudioErrorDomain]
            && error.code == VibeAudioErrorNotPlaying;
}

// Errors without a URL can describe resume/seek/device failures. AudioPlayer
// checks resume/seek submission identity before delivery; the shell cannot
// infer it from an absent URL. A URL-bearing error must match the shown row.
static inline BOOL VibePlayErrorMatchesCurrentURL(NSError *error, NSURL *_Nullable currentURL) {
    NSURL *failedURL = error.userInfo[kVibeAudioErrorTrackURLKey];
    return !failedURL || [failedURL isEqual:currentURL];
}

NS_ASSUME_NONNULL_END
