//
//  AudioErrorRules.h
//  Vibe
//
//  What the status line says about a play failure: a function of the error
//  alone, so both screens agree and it is tested without a player.
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

// Short: the title line names the track, and the log has the full text.
// VibeAudioErrorNotPlaying is filtered out before this as benign. No default,
// so a new code is a compile warning, not the generic line. An underlying
// error of ours is the more specific cause: a refused start arrives wrapped
// in the caller's "could not resume".
static inline NSString *VibeStatusForPlayError(NSError *error) {
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying.domain isEqualToString:kVibeAudioErrorDomain]) {
        return VibeStatusForPlayError(underlying);
    }
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]) {
        switch ((VibeAudioErrorCode)error.code) {
            case VibeAudioErrorFileOpenTimedOut:   return STR_ERROR_LOAD_TIMEOUT;
            case VibeAudioErrorFileOpenFailed:     return STR_ERROR_OPEN_FAILED;
            case VibeAudioErrorEngineStartFailed:  return STR_ERROR_ENGINE_START_FAILED;
            case VibeAudioErrorDeviceUnavailable:  return STR_ERROR_DEVICE_UNAVAILABLE;
            case VibeAudioErrorDeviceInUse:        return STR_ERROR_DEVICE_IN_USE;
            case VibeAudioErrorConnectionLost:     return STR_ERROR_CONNECTION_LOST;
            case VibeAudioErrorNotPlaying:         break;
        }
    }
    return STR_ERROR_PLAYBACK_GENERIC;
}

NS_ASSUME_NONNULL_END
