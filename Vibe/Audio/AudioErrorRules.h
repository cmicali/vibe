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
