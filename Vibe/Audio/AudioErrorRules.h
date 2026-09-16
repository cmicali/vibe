//
//  AudioErrorRules.h
//  Vibe
//
//  What the header's status line says about a play failure — a function of the
//  error alone, so both screens answer identically and the mapping is testable
//  without a player.
//

#import <Foundation/Foundation.h>
#import "AudioError.h"
#import "VibeStrings.h"

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

// Deliberately short: the title line already names the track and the full error
// text is in the log. VibeAudioErrorNotPlaying never arrives here — it is
// filtered on the way in as a benign no-op rather than a failure to report. The
// switch is exhaustive with no default, so a new code is a compile warning
// rather than a silent fall-through to the generic line.
static inline NSString *VibeStatusForPlayError(NSError *error) {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]) {
        switch ((VibeAudioErrorCode)error.code) {
            case VibeAudioErrorFileOpenTimedOut:   return STR_ERROR_LOAD_TIMEOUT;
            case VibeAudioErrorFileOpenFailed:     return STR_ERROR_OPEN_FAILED;
            case VibeAudioErrorEngineStartFailed:  return STR_ERROR_ENGINE_START_FAILED;
            case VibeAudioErrorDeviceUnavailable:  return STR_ERROR_DEVICE_UNAVAILABLE;
            case VibeAudioErrorNotPlaying:         break;
        }
    }
    return STR_ERROR_PLAYBACK_GENERIC;
}

NS_ASSUME_NONNULL_END
