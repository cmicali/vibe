//
//  AudioError.h
//  Vibe
//
//  The play path's error vocabulary — domain, userInfo key, codes — apart from
//  the player so that a receiver deciding what to SAY about a failure need not
//  import the engine.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kVibeAudioErrorDomain;
// userInfo key carrying the failing track's URL on play-path errors. Error
// deliveries can race a track change, so receivers must match it against the
// current track before treating the error as the current track's.
extern NSString *const kVibeAudioErrorTrackURLKey;
typedef NS_ENUM(NSInteger, VibeAudioErrorCode) {
    VibeAudioErrorFileOpenFailed = 1,
    VibeAudioErrorEngineStartFailed,
    VibeAudioErrorDeviceUnavailable,
    VibeAudioErrorNotPlaying,
    VibeAudioErrorFileOpenTimedOut,
    VibeAudioErrorDeviceInUse, // another process holds the device exclusively (macOS hog mode)
    VibeAudioErrorConnectionLost, // a streaming track's download stalled: paused in place, play replays it
};

// Descriptions are for logs, never localized; the UI's line is
// VibeStatusForPlayError (AudioErrorRules.h). An underlying error's
// description is appended in parentheses.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying);
// The same, with the failing track's URL under kVibeAudioErrorTrackURLKey.
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying, NSURL * _Nullable trackURL);

NS_ASSUME_NONNULL_END
